#!/usr/bin/env bash
# Testes do oute-swarm, tema: eventos operacionais da rodada no receptor OTLP falso: tell --wait, snapshot de cota, ask/answered (#124, #181, #347, #386).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-eventos.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/swarm-otlp.sh"

# ---------------------------------------------------------------- #124: eventos operacionais (receptor OTLP falso)
# 8. abertura, spawn, tell (ok e recusado), close, rodada fechada e watch
CASE=eventos-op; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
OUT="$(env PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 "$SWARM" "$REPO" --max 2 --label bug 2>&1)"; RC=$?
nr="$(ls "$H/.oute/swarm" | grep -v '^swarm-test$' | head -1)"
check "abertura: código 0"                               [ "$RC" -eq 0 -a -n "$nr" ]
check "abertura: meta com o agente do dispatcher"      grep -qx 'agent=claude' "$H/.oute/swarm/$nr/meta"
check "abertura: aviso com o dispatcher (#214)"          grep -qxF "dispatcher $nr · repo repo · max 2 · label bug" <<<"$OUT"
check "abertura: prompt do dispatcher (#214)"            grep -qF "Você é o **dispatcher** da rodada \`$nr\`" "$FAKE/oute-task.last"
check "abertura: limpeza reconhece os dois nomes (#214)" grep -q '"dispatcher da rodada `<id>`".*"coordenadora da rodada `<id>`"' "$FAKE/oute-task.last"
check "abertura: linha no log"                           grep -q " abertura $nr (repo repo, max 2, label bug)$" "$H/.oute/swarm/$nr/log"
check "abertura: oute.swarm.round.opened"                [ "$(ev '.name == "oute.swarm.round.opened"' | jq -c --arg r "$nr" 'select(.attrs["oute.swarm.round"] == $r and .attrs["oute.swarm.repo"] == "repo"
                                                              and .attrs["oute.swarm.max"] == "2" and .attrs["oute.swarm.label"] == "bug" and .attrs["oute.agent"] == "claude")' | grep -c .)" -eq 1 ]
sw spawn 8-bar "faça a issue 8" --agent codex
e="$(ev '.name == "oute.swarm.session.spawned"')"
check "spawn: código 0"                                  [ "$RC" -eq 0 ]
check "spawn: linha no log"                              grep -q ' spawn 8-bar codex$' "$STATE/log"
check "spawn: sessão, issue, agente da sessão, repo"     jq -e '.attrs["oute.swarm.round"] == "swarm-test" and .attrs["oute.swarm.session"] == "8-bar" and .attrs["oute.swarm.issue"] == "8"
                                                              and .attrs["oute.swarm.session.agent"] == "codex" and .attrs["oute.swarm.repo"] == "repo" and .attrs["oute.swarm.kaizen"] == false' <<<"$e" >/dev/null
check "spawn: oute.agent = dispatcher, origem"         jq -e '.attrs["oute.agent"] == "claude" and .res["host.name"] == "oute-mac" and .res["service.name"] == "oute"' <<<"$e" >/dev/null
check "spawn: corpo = prompt da sessão"                  jq -e '.body | startswith("faça a issue 8\n\n")' <<<"$e" >/dev/null
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=working" "#8 bar=idle"
echo '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2","agent":"claude"}]}}' > "$FAKE/panes.json"
echo '{"result":{"agents":[{"pane_id":"w1:p2","agent":"claude","agent_status":"idle"}]}}' > "$FAKE/agents.json"
sw tell 8-bar "pode seguir, Bardi aprovou"
check "tell ok: evento com o texto"                      [ "$RC" -eq 0 -a "$(n '.name == "oute.swarm.tell" and .attrs["oute.swarm.session"] == "8-bar" and .attrs["oute.swarm.tell.result"] == "ok"
                                                              and .attrs["oute.swarm.tell.forced"] == false and .body == "pode seguir, Bardi aprovou"')" -eq 1 ]
# 8b. tell --wait (#181): espera a sessão parar e envia; uma linha no log por tell
agst() { echo '{"result":{"agents":[{"pane_id":"w1:p2","agent":"claude","agent_status":"'"$1"'"}]}}' > "$FAKE/agents.json"; }
tells() { grep -c ' tell 8-bar ' "$STATE/log" || true; }
export OUTE_SWARM_TELL_POLL=0.1
t0="$(tells)"; agst working; rm -f "$FAKE/tsleeps" "$FAKE/on-tsleep-"*
echo 'echo "{\"result\":{\"agents\":[{\"pane_id\":\"w1:p2\",\"agent\":\"claude\",\"agent_status\":\"idle\"}]}}" > "$FAKE/agents.json"' > "$FAKE/on-tsleep-2"
FAKE_TELLWAIT=1 sw tell 8-bar "ok do Bardi" --wait
check "wait: ocupada → parada, código 0 e enviado"       bash -c '[ "$1" -eq 0 ] && grep -q "pane send-keys w1:p2 enter" "$2"' _ "$RC" "$FAKE/herdr.log"
check "wait: esperou de verdade (≥ 2 sleeps antes do envio)" [ "$(cat "$FAKE/tsleeps")" -ge 2 ]
check "wait: uma única linha no log, ok (--wait, Ns)"    bash -c '[ "$1" -eq 1 ] && grep -qE " tell 8-bar ok \(--wait, [0-9]+s\)${2}ok do Bardi\$" "$3"' _ "$(( $(tells) - t0 ))" $'\t' "$STATE/log"
check "wait: oute-emit lê ok (--wait, …): result=ok, forced=false" [ "$(n '.name == "oute.swarm.tell" and .attrs["oute.swarm.tell.result"] == "ok" and .attrs["oute.swarm.tell.forced"] == false and .body == "ok do Bardi"')" -eq 1 ]
t0="$(tells)"; agst idle
FAKE_TELLWAIT=1 sw tell 8-bar "já parada" --wait
check "wait: sessão já parada envia na hora"             bash -c '[ "$1" -eq 0 ] && grep -qE " tell 8-bar ok \(--wait, [0-9]+s\)" "$2"' _ "$RC" "$STATE/log"
t0="$(tells)"; agst working; : > "$FAKE/herdr.log"
FAKE_TELLWAIT=1 sw tell 8-bar "nunca" --wait --timeout 1
check "wait: timeout → código 3, nada enviado"           bash -c '[ "$1" -eq 3 ] && ! grep -qE "send-(text|keys)" "$2"' _ "$RC" "$FAKE/herdr.log"
check "wait: timeout → uma linha, recusa final"          bash -c '[ "$1" -eq 1 ] && grep -qE " tell 8-bar recusado: sessão #8 bar ocupada \(working\) depois de [0-9]+ s de espera${2}nunca\$" "$3"' _ "$(( $(tells) - t0 ))" $'\t' "$STATE/log"
check "wait: timeout → mensagem em stderr"               grep -qE 'depois de [0-9]+ s de espera; nada enviado' <<<"$ERR"
t0="$(tells)"; rm -f "$FAKE/tsleeps" "$FAKE/on-tsleep-"*
echo 'echo "{\"result\":{\"panes\":[]}}" > "$FAKE/panes.json"' > "$FAKE/on-tsleep-1"
FAKE_TELLWAIT=1 sw tell 8-bar "pane sumiu" --wait
check "wait: pane some na espera → recusa na hora (código 1)" bash -c '[ "$1" -eq 1 ] && grep -q "pane da aba #8 bar não encontrado" "$2"' _ "$RC" "$STATE/log"
check "wait: pane some → uma linha no log"               [ "$(( $(tells) - t0 ))" -eq 1 ]
echo '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2","agent":"claude"}]}}' > "$FAKE/panes.json"; agst idle
t0="$(tells)"
sw tell 8-bar "x" --wait --force
check "wait+force: erro de uso, sem linha no log"        bash -c '[ "$1" -eq 1 ] && [ "$2" -eq "$3" ]' _ "$RC" "$(tells)" "$t0"
sw tell 8-bar "x" --timeout 5
check "timeout sem wait: erro de uso, sem linha"         bash -c '[ "$1" -eq 1 ] && [ "$2" -eq "$3" ]' _ "$RC" "$(tells)" "$t0"
sw tell 8-bar "x" --wait --timeout abc
check "timeout não numérico: erro de uso, sem linha"     bash -c '[ "$1" -eq 1 ] && [ "$2" -eq "$3" ]' _ "$RC" "$(tells)" "$t0"
agst working
sw tell 8-bar "x"
check "sem wait: ocupada recusa como antes (código 1)"   bash -c '[ "$1" -eq 1 ] && grep -q "ocupada (working); tente depois (o Bardi pode usar --force)" "$2"' _ "$RC" "$STATE/log"
agst idle; unset OUTE_SWARM_TELL_POLL
check "docs: ajuda, comandos.md e swarm.md citam --wait"  bash -c 'grep -qF -- "--wait [--timeout <s>]" "$1" && grep -qF -- "--wait [--timeout <s>]" "$2" && grep -qF "**\`--wait\`:**" "$3"' _ "$SWARM" "$ROOT/docker/comandos.md" "$ROOT/docker/swarm.md"
sw close 8-bar --yes
check "close: linha com hora no log"                     grep -qE '^[0-9T:Z-]+ close 8-bar$' "$STATE/log"
check "close: oute.swarm.session.closed"                 [ "$(n '.name == "oute.swarm.session.closed" and .attrs["oute.swarm.session"] == "8-bar"')" -eq 1 ]
sw tell 8-bar "de novo"
check "tell recusado: evento com motivo e texto"         [ "$RC" -ne 0 -a "$(n '.name == "oute.swarm.tell" and .attrs["oute.swarm.tell.result"] == "recusado"
                                                              and (.attrs["oute.swarm.tell.reason"] | startswith("aba #8 bar já fechada")) and .body == "de novo"')" -eq 1 ]
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=idle"
sw close --all --yes
check "close --all: sessão e rodada fechadas"            [ "$(n '.name == "oute.swarm.session.closed" and .attrs["oute.swarm.session"] == "7-foo"')" -eq 1 -a \
                                                           "$(n '.name == "oute.swarm.round.closed" and .attrs["oute.swarm.round"] == "swarm-test"')" -eq 1 ]
cat > "$FAKE/on-sleep-1" <<'SH'
cat > "$FAKE/prs-repo.json" <<'J'
[{"number":12,"headRefName":"feat/7-foo","state":"OPEN","mergeable":"MERGEABLE","createdAt":"2026-06-01T00:00:00Z",
  "url":"https://github.com/x/y/pull/12","statusCheckRollup":[{"name":"test","conclusion":"FAILURE","completedAt":"2026-06-01T00:05:00Z"}]}]
J
SH
rm -f "$STATE/closed"   # #419: PR nunca visto só entra com a sessão aberta; aqui o foco é o evento, não o close
watch
check "watch: pr, ci e rodada como observação"           [ "$(n '.name == "oute.swarm.watch.pr" and .attrs["oute.swarm.source"] == "watch" and (.body | startswith("[pr] PR #12 aberto"))')" -eq 1 -a \
                                                           "$(n '.name == "oute.swarm.watch.ci" and .body == "[ci] PR #12 · test: fail"')" -eq 1 -a "$(n '.name == "oute.swarm.watch.rodada"')" -eq 1 ]
check "todos: oute.agent=claude e origem do host"        [ "$(n 'true')" -gt 0 -a "$(n '.attrs["oute.agent"] != "claude" or .res["oute.agent"] != "claude" or .res["host.name"] != "oute-mac" or .res["oute.instance"] != "oute-agent"')" -eq 0 ]
check "todos: uma linha do log = um evento"              [ "$(n 'true')" -eq "$(( $(wc -l < "$STATE/log") + $(wc -l < "$H/.oute/swarm/$nr/log") ))" ]
rcv_stop
# 9. coletor fora do ar: mesma saída e mesmo código, sem travar
CASE=fora; round "$CASE"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(closed_port)"
t0=$(date +%s)
sw spawn 9-baz "instrução"
check "fora do ar: spawn com código 0 e a mesma saída"   [ "$RC" -eq 0 -a "$OUT" == "aberta: #9 → pane w1:p2 · worktree repo-9-baz · agente claude · modelo claude-sonnet-5-5 (fase build, label)" ]
check "fora do ar: sem erro na tela"                     [ -z "$ERR" ]
check "fora do ar: rápido"                               [ $(( $(date +%s) - t0 )) -le 3 ]
check "fora do ar: log continua sendo gravado"           grep -q ' spawn 9-baz claude$' "$STATE/log"
unset OTEL_EXPORTER_OTLP_ENDPOINT
# 12. snapshot da cota (#347): spawn e close chamam `oute-emit quota` em segundo plano; a leitura nunca atrasa nem derruba
CASE=cota; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
QB="$TMP/$CASE/qbin"; mkdir -p "$QB"
# oute-quota falso: o JSON e a espera vêm de arquivos (o sw só repassa o ambiente que ele escolhe); rc de $QB/rc
cat > "$QB/oute-quota" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ ! -f "$d/sleep" ]] || sleep "$(cat "$d/sleep")"
[[ ! -f "$d/json" ]] || cat "$d/json"
exit "$(cat "$d/rc" 2>/dev/null || echo 0)"
SH
chmod +x "$QB/oute-quota"
# o `sw` põe $BIN na frente do PATH: o oute-quota de $BIN (o falso de cota folgada) passa a repassar ao desta seção
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$QB/oute-quota" > "$BIN/oute-quota"
R5="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"schema":1,"agents":{"claude":{"status":"ok","stale":false,"age_s":0,"windows":{"5h":{"used_pct":15,"resets_at":"%s"}}},"codex":{"status":"unknown","reason":"rede","windows":{}}}}' "$R5" > "$QB/json"
# espera (até 10 s) o que o segundo plano ainda vai entregar
until_n() { local i; for i in $(seq 1 100); do [[ "$(eval "$1")" -ge "$2" ]] && return 0; sleep 0.1; done; return 1; }
OLDPATH="$PATH"; export PATH="$QB:$PATH"
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=working" "#9 cota=idle"
sw spawn 9-cota "faça a issue 9"
check "cota, spawn: código 0 e nada de cota na tela"     bash -c '[ "$1" -eq 0 ] && ! grep -qi "quota" <<<"$2"' _ "$RC" "$OUT$ERR"
check "cota, spawn: pontos da cota chegam (used_pct e reset_in_seconds do Claude)" until_n "mp '.name == \"oute.quota.used_pct\" and .res[\"oute.agent\"] == \"claude\" and .value == 15' | grep -c ." 1
check "cota, spawn: evento unknown do Codex com momento spawn" until_n "n '.name == \"oute.quota.unknown\" and .attrs[\"oute.quota.moment\"] == \"spawn\" and .attrs[\"oute.agent\"] == \"codex\"'" 1
sw close 9-cota --yes
check "cota, close: fecha e emite o evento com momento close" bash -c '[ "$1" -eq 0 ]' _ "$RC"
check "cota, close: unknown do Codex com momento close"  until_n "n '.name == \"oute.quota.unknown\" and .attrs[\"oute.quota.moment\"] == \"close\"'" 1
# close sem nada fechado (já fechada): não lê a cota
c0="$(n '.name == "oute.quota.unknown"')"; p0="$(ls "$RCV_DIR"/*.json | wc -l)"
sw close 9-cota --yes
sleep 1
check "cota, close sem nada a fechar: sem snapshot novo" [ "$(ls "$RCV_DIR"/*.json | wc -l)" -eq "$p0" -a "$(n '.name == "oute.quota.unknown"')" -eq "$c0" ]
# oute-quota lento (6 s): o spawn volta antes, com a mesma saída
echo 6 > "$QB/sleep"
FAKE="$FAKE" "$BIN/fake-tabs" "#10 lenta=idle"
t0=$(date +%s); sw spawn 10-lenta "faça a issue 10"; dt=$(( $(date +%s) - t0 ))
check "cota lenta: o spawn não espera a leitura ($dt s)" bash -c '[ "$1" -eq 0 ] && [ "$2" -le 4 ] && grep -q "aberta: #10" <<<"$3"' _ "$RC" "$dt" "$OUT"
# oute-quota que falha (rc 2, sem saída) e que não existe: spawn igual
rm -f "$QB/sleep"; echo 2 > "$QB/rc"; : > "$QB/json"
FAKE="$FAKE" "$BIN/fake-tabs" "#11 falha=idle"
sw spawn 11-falha "faça a issue 11"
check "cota com falha na leitura: spawn abre normalmente" bash -c '[ "$1" -eq 0 ] && grep -q "aberta: #11" <<<"$2"' _ "$RC" "$OUT"
export PATH="$OLDPATH"
cp "$ROOT/tests/lib/fake-oute-quota.sh" "$BIN/oute-quota"
rcv_stop
# 13. decisão pendente do Bardi (#386): `ask` e `answered` gravam no log da rodada e emitem os eventos
CASE=ask; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
sw ask "1. aprovar a triagem  (#386, #387)  2. cortar a #387"
check "ask: código 0 e confirmação com a rodada"         bash -c '[ "$1" -eq 0 ] && grep -qF "swarm-test" <<<"$2"' _ "$RC" "$OUT"
check "ask: linha pergunta com hora no log"              grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z pergunta 1\. aprovar a triagem \(#386, #387\) 2\. cortar a #387$' "$STATE/log"
check "ask: oute.swarm.round.asked com a pergunta no corpo" [ "$(n '.name == "oute.swarm.round.asked" and .attrs["oute.swarm.round"] == "swarm-test" and .attrs["oute.agent"] == "claude" and .body == "1. aprovar a triagem (#386, #387) 2. cortar a #387"')" -eq 1 ]
sw ask "$(printf 'linha um\nlinha\tdois\r\001fim')"
check "ask: quebra de linha, TAB e controle viram uma linha só" bash -c '[ "$1" -eq 0 ] && grep -qE " pergunta linha um linha dois fim\$" "$2" && [ "$(grep -c "" "$2")" -eq 2 ]' _ "$RC" "$STATE/log"
LONG="$(printf 'x%.0s' $(seq 1 450))"
sw ask "$LONG"
check "ask: texto longo cortado em 300 caracteres, com …"  bash -c 'l="$(grep " pergunta x" "$1" | tail -1 | sed "s/^[^ ]* pergunta //")"; [ "${#l}" -eq 300 ] && [ "${l: -1}" = "…" ]' _ "$STATE/log"
check "ask: evento do texto longo também limitado"       [ "$(n '.name == "oute.swarm.round.asked" and (.body | length) == 300 and (.body | endswith("…"))')" -eq 1 ]
t0="$(wc -l < "$STATE/log")"
sw ask ""
check "ask vazio: erro de uso, sem linha no log"         bash -c '[ "$1" -eq 1 ] && [ "$2" -eq "$3" ] && grep -qF "pergunta vazia" <<<"$4"' _ "$RC" "$(wc -l < "$STATE/log")" "$t0" "$ERR"
sw ask
check "ask sem argumento: erro de uso"                   bash -c '[ "$1" -eq 1 ] && grep -qF "uso: oute-swarm ask" <<<"$2" && [ "$3" -eq "$4" ]' _ "$RC" "$ERR" "$(wc -l < "$STATE/log")" "$t0"
sw ask "a" "b"
check "ask com argumento a mais: erro de uso"            bash -c '[ "$1" -eq 1 ] && [ "$2" -eq "$3" ]' _ "$RC" "$(wc -l < "$STATE/log")" "$t0"
sw answered
check "answered: código 0 e linha resposta no log"       bash -c '[ "$1" -eq 0 ] && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z resposta\$" "$2"' _ "$RC" "$STATE/log"
check "answered: oute.swarm.round.answered sem corpo"    [ "$(n '.name == "oute.swarm.round.answered" and .attrs["oute.swarm.round"] == "swarm-test" and .body == null')" -eq 1 ]
t0="$(wc -l < "$STATE/log")"
sw answered "sim, a 1"
check "answered com argumento: erro, a resposta não vai ao log" bash -c '[ "$1" -eq 1 ] && [ "$2" -eq "$3" ] && ! grep -qF "sim, a 1" "$4"' _ "$RC" "$(wc -l < "$STATE/log")" "$t0" "$STATE/log"
# triagem: a rodada ainda não tem aba (sem spawned)
rm -f "$STATE/spawned"; t0="$(wc -l < "$STATE/log")"
sw ask "1. aprovar a triagem"
check "ask na triagem (sem spawned): grava e emite"      bash -c '[ "$1" -eq 0 ] && [ "$(wc -l < "$2")" -eq "$(( $3 + 1 ))" ]' _ "$RC" "$STATE/log" "$t0"
# sem OUTE_SWARM_ID e fora da worktree do dispatcher: a rodada mais recente
OUT="$(cd "$TMP" && env -u OUTE_SWARM_ID PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" "$SWARM" ask "sem id" 2>"$FAKE/err")"; RC=$?
check "ask sem OUTE_SWARM_ID: usa a rodada mais recente"  bash -c '[ "$1" -eq 0 ] && grep -qE " pergunta sem id\$" "$2"' _ "$RC" "$STATE/log"
EMPTYH="$TMP/$CASE/vazio"; mkdir -p "$EMPTYH"
OUT="$(cd "$TMP" && env -u OUTE_SWARM_ID PATH="$BIN:$PATH" HOME="$EMPTYH" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" "$SWARM" ask "x" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
check "ask sem nenhuma rodada: erro, nada gravado"        bash -c '[ "$1" -eq 1 ] && grep -qF "nenhuma rodada" <<<"$2"' _ "$RC" "$ERR"
NOMETA="$TMP/$CASE/semmeta"; mkdir -p "$NOMETA/.oute/swarm/swarm-0101-0000"
OUT="$(cd "$TMP" && env -u OUTE_SWARM_ID PATH="$BIN:$PATH" HOME="$NOMETA" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" "$SWARM" ask "x" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
check "ask com pasta de rodada sem meta: erro com mensagem, nada gravado" bash -c '[ "$1" -eq 1 ] && grep -qF "nenhuma rodada" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$ERR" "$NOMETA/.oute/swarm/swarm-0101-0000/log"
t0="$(wc -l < "$STATE/log")"
sw ask "$(printf 'aprovar \xe2\x80\xaeodnum\xe2\x80\xac a\xe2\x80\xa8b\xe2\x80\xa9c\xe2\x80\x8bd\xe2\x81\xa6e\xef\xbb\xbff ação')"
check "ask: marcas de direção e separadores Unicode saem (U+202E, U+2028/9, U+200B, U+2066, U+FEFF), o acento fica" bash -c '[ "$1" -eq 0 ] && tail -1 "$2" | grep -qE " pergunta aprovar odnum abcdef ação\$"' _ "$RC" "$STATE/log"
sw ask "$(printf '\xe2\x80\xae\xe2\x80\xa8')"
check "ask só de marcas Unicode: vira vazio, erro e nada gravado" bash -c '[ "$1" -eq 1 ] && grep -qF "pergunta vazia" <<<"$2" && [ "$(wc -l < "$3")" -eq "$4" ]' _ "$RC" "$ERR" "$STATE/log" "$(( t0 + 1 ))"
rcv_stop
# prompt do dispatcher, ajuda e comandos
opn --max 2
D="$FAKE/oute-task.last"
check "dispatcher: chama ask ao parar com opções numeradas (#386)" grep -qF 'toda vez que parar com opções numeradas para o Bardi' "$D"
check "dispatcher: ask com pergunta curta, sem saída de host (#386)" grep -qF 'nunca saída de comando, de host ou de tela' "$D"
check "dispatcher: answered ao receber a resposta (#386)" grep -qF 'o primeiro passo é `oute-swarm answered`' "$D"
check "ajuda e comandos.md citam ask e answered (#386)"   bash -c 'for f in "$@"; do grep -qF "oute-swarm ask" "$f" && grep -qF "oute-swarm answered" "$f" || exit 1; done' _ "$SWARM" "$ROOT/docker/comandos.md"
check_end
