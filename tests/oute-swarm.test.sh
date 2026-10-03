#!/usr/bin/env bash
# Testes do oute-swarm (#84, parte da #54). Bash puro, sem herdr, gh nem rede de verdade.
# `herdr`, `gh` e `sleep` falsos no PATH: o herdr e o gh leem JSON de $FAKE (o teste troca entre passadas),
# e o `sleep` do laço do `watch` é o gancho entre as passadas (roda $FAKE/on-sleep-<n>; sem gancho, fecha a
# rodada e o watch sai sozinho). Só comportamento externo: stdout, log e estado da rodada.
# Uso: tests/oute-swarm.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"

[[ -x "$SWARM" ]] || { echo "FAIL oute-swarm ausente ou sem +x: $SWARM"; exit 1; }
command -v jq >/dev/null || { echo "FAIL precisa de jq"; exit 1; }

# ---------------------------------------------------------------- fakes
BIN="$TMP/bin"; mkdir -p "$BIN"
# herdr: listas lidas de $FAKE/*.json; ações anotadas em $FAKE/herdr.log. `tab create` devolve o JSON do herdr
# com ids no workspace pedido, ou $FAKE/tab-create.out, se existir (saída quebrada, #276). O campo de entrada do pane é
# $FAKE/field (send-text escreve, pane read mostra entre réguas como o Claude Code, ctrl+c limpa).
cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/herdr.log"
case "$1 ${2:-}" in
  "tab list") cat "$FAKE/tabs.json" ;;
  "tab create") n=$(( $(cat "$FAKE/tabs.n" 2>/dev/null || echo 1) + 1 )); echo "$n" > "$FAKE/tabs.n"
                [[ ! -e "$FAKE/tab-create.out" ]] || { cat "$FAKE/tab-create.out"; exit 0; }
                w="$4"   # --workspace <id>: o formato real do herdr 0.9 (root_pane e tab no result, #276)
                echo "{\"id\":\"cli:tab:create\",\"result\":{\"root_pane\":{\"pane_id\":\"$w:p$n\",\"tab_id\":\"$w:t$n\"},\"tab\":{\"tab_id\":\"$w:t$n\",\"label\":\"x\"}}}" ;;
  "tab close") ;;
  "pane list") cat "$FAKE/panes.json" 2>/dev/null || echo '{"result":{"panes":[]}}' ;;
  "pane run") ;;
  "pane read") printf '%s\n❯ %s\n%s\n' "──────────────────" "$(cat "$FAKE/field" 2>/dev/null)" "──────────────────" ;;
  "pane send-text") printf '%s' "$4" > "$FAKE/field" ;;
  "pane send-keys") [[ "$4" != ctrl+c ]] || : > "$FAKE/field" ;;
  "agent list") cat "$FAKE/agents.json" 2>/dev/null || echo '{"result":{"agents":[]}}' ;;
  *) echo "herdr falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
# gh: `pr list` devolve $FAKE/prs-<nome da pasta do repo>.json (o watch roda o gh dentro do repo). `api graphql`
# (checks de um commit, #266) devolve $FAKE/checks-<sha>.json, falha se existir $FAKE/checks-<sha>.fail e anota
# cada leitura em $FAKE/gh.log (<pasta do repo> <sha>)
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr list") cat "$FAKE/prs-$(basename "$PWD").json" 2>/dev/null || echo '[]' ;;
  "api graphql") oid=""; for a in "$@"; do [[ "$a" != oid=* ]] || oid="${a#oid=}"; done
                 echo "$(basename "$PWD") $oid" >> "$FAKE/gh.log"
                 [[ ! -e "$FAKE/checks-$oid.fail" ]] || { echo "gh falso: falha pedida" >&2; exit 1; }
                 cat "$FAKE/checks-$oid.json" 2>/dev/null || echo '{"data":{"repository":{"object":null}}}' ;;
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
cat > "$BIN/oute-task" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == list ]] && echo "(worktrees falsas)"
# o último argumento (prompt da rodada, na abertura) fica em $FAKE/oute-task.last
[[ -z "${FAKE:-}" ]] || printf '%s' "${@: -1}" > "$FAKE/oute-task.last"
exit 0
SH
# sleep: só no watch (FAKE_WATCH=1) é o gancho entre passadas; nos outros comandos não faz nada
cat > "$BIN/sleep" <<'SH'
#!/usr/bin/env bash
[[ -n "${FAKE_WATCH:-}" ]] || exit 0
n=$(( $(cat "$FAKE/sleeps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/sleeps"
if [[ -f "$FAKE/on-sleep-$n" ]]; then . "$FAKE/on-sleep-$n"; else date -u +%FT%TZ > "$STATE/fechada"; fi
SH
# fake-tabs [<label>=]<status>...: abas w1:t1, w1:t2… com o agente em <status> (label padrão "#7 foo");
# usável nos ganchos on-sleep-<n>
cat > "$BIN/fake-tabs" <<'SH'
#!/usr/bin/env bash
i=0; for a in "$@"; do
  i=$((i + 1)); [[ "$a" == *=* ]] || a="#7 foo=$a"
  jq -n --arg id "w1:t$i" --arg l "${a%=*}" --arg s "${a##*=}" '{tab_id: $id, label: $l, agent_status: $s}'
done | jq -s '{result: {tabs: .}}' > "$FAKE/tabs.json"
SH
chmod +x "$BIN"/*

# round(<caso>): HOME, rodada swarm-test (repo da rodada = pasta git "repo", início no passado) e $FAKE limpos;
# issue #7 aberta na aba "#7 foo" (linha do spawned no formato antigo, sem repo). Globais: H, STATE, FAKE, REPO.
round() {
  H="$TMP/$1/home"; STATE="$H/.oute/swarm/swarm-test"; FAKE="$TMP/$1/fake"; REPO="$TMP/$1/repo"
  mkdir -p "$STATE" "$FAKE" "$TMP/$1/inbox" "$TMP/$1/outbox"
  gitrepo "$REPO"
  printf 'repo=%s\nmax=3\nlabel=\nstarted=2026-01-01T00:00:00Z\n' "$REPO" > "$STATE/meta"
  printf '7-foo w1:p1 claude 2026-01-01T00:00:01Z w1:t1\n' > "$STATE/spawned"
  FAKE="$FAKE" "$BIN/fake-tabs" working
}
gitrepo() { mkdir -p "$1" && git -C "$1" init -q 2>/dev/null; }
# sw <args>: roda o oute-swarm como o dispatcher da rodada (dentro do herdr); stdout em $OUT, stderr em $ERR
sw() {
  OUT="$(env PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID="${WS:-w1}" \
         OUTE_SWARM_ID=swarm-test OUTE_SWARM_REPO="$REPO" OUTE_SWARM_MAX="${MAX:-3}" \
         "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
# roda o watch até a rodada fechar; stdout em $OUT, stderr em $ERR, código em $RC
watch() {
  local g=(); command -v timeout >/dev/null && g=(timeout 30)
  rm -f "$FAKE/sleeps" "$STATE/fechada"
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" STATE="$STATE" FAKE_WATCH=1 \
         OUTE_INBOX="$TMP/$CASE/inbox" OUTE_OUTBOX="$TMP/$CASE/outbox" \
         ${g[@]+"${g[@]}"} "$SWARM" watch --round swarm-test 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
LOGRE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z watch \[[a-z]+\] .+$'
wlog() { grep ' watch \[' "$STATE/log" 2>/dev/null || true; }
# eventos do stdout (sem o HH:MM) e do log (sem timestamp e "watch"), para comparar
out_events() { sed -E 's/^[0-9]{2}:[0-9]{2} //' <<<"$OUT"; }
log_events() { wlog | sed -E 's/^[^ ]+ watch //'; }
logged() { grep -qxF -- "$1" <<<"$(log_events)"; }
count() { grep -cxF -- "$1" <<<"$(log_events)" || true; }

# 1. watch: cada evento impresso vai também para o log da rodada; a linha de base não grava nada
CASE=eventos; round "$CASE"
# entre a 1ª e a 2ª passada: sessão fica idle, PR #12 da issue #7 abre com CI vermelho
cat > "$FAKE/on-sleep-1" <<'SH'
cp "$STATE/log" "$FAKE/log.p1" 2>/dev/null || : > "$FAKE/log.p1"
fake-tabs idle
cat > "$FAKE/prs-repo.json" <<'J'
[{"number":12,"headRefName":"feat/7-foo","state":"OPEN","mergeable":"MERGEABLE","createdAt":"2026-06-01T00:00:00Z",
  "url":"https://github.com/x/y/pull/12","statusCheckRollup":[{"name":"test","conclusion":"FAILURE","completedAt":"2026-06-01T00:05:00Z"}]}]
J
SH
watch
check "eventos: watch sai com código 0"                  [ "$RC" -eq 0 ]
check "eventos: linha de base não grava nada no log"     [ ! -s "$FAKE/log.p1" ]
check "eventos: stdout tem o PR aberto"                  grep -q '\[pr\] PR #12 aberto' <<<"$OUT"
check "eventos: log tem a sessão idle"                   logged "[sessao] #7 foo: idle (PR #12 open)"
check "eventos: log tem o PR aberto"                     logged "[pr] PR #12 aberto (issue #7) https://github.com/x/y/pull/12"
check "eventos: log tem o CI vermelho"                   logged "[ci] PR #12 · test: fail"
check "eventos: log tem o fechamento da rodada"          logged "[rodada] swarm-test fechada (oute-swarm close --all); watch encerrado"
check "eventos: log = stdout, na mesma ordem"            [ "$(log_events)" == "$(out_events)" ]
check "eventos: timestamp UTC completo em toda linha"    [ -n "$(wlog)" -a -z "$(wlog | grep -Ev "$LOGRE")" ]

# 2. watch reiniciado sem mudança: compara com o último estado salvo e não repete o que já foi gravado
before="$(log_events)"
watch
check "reinício: código 0"                               [ "$RC" -eq 0 ]
check "reinício: nenhum evento repetido"                 [ "$(count "[pr] PR #12 aberto (issue #7) https://github.com/x/y/pull/12")$(count "[ci] PR #12 · test: fail")$(count "[sessao] #7 foo: idle (PR #12 open)")" == 111 ]
check "reinício: só o fechamento novo entrou no log"     [ "$(log_events)" == "$before"$'\n'"[rodada] swarm-test fechada (oute-swarm close --all); watch encerrado" ]

# 3. o log é o mesmo do tell: registros de outros comandos continuam lá
CASE=convive; round "$CASE"
echo "2026-01-01T00:00:02Z tell 7-foo ok" > "$STATE/log"
watch
check "convive: registro do tell preservado"             [ "$(head -1 "$STATE/log")" == "2026-01-01T00:00:02Z tell 7-foo ok" ]
check "convive: evento do watch anexado"                 logged "[rodada] swarm-test fechada (oute-swarm close --all); watch encerrado"

# 4. sessão parada sem PR: "(sem PR)", sem repetir nada
CASE=sempr; round "$CASE"
echo 'fake-tabs blocked' > "$FAKE/on-sleep-1"
watch
check "sem PR: evento da sessão"                         logged "[sessao] #7 foo: blocked (sem PR)"

# ---------------------------------------------------------------- #85: sessão kaizen em outro repo
# 5. spawn --repo --kaizen: aba e worktree no repo indicado, registro com repo e tipo, fora do --max
CASE=spawn; round "$CASE"; LAB="$TMP/$CASE/lab"; gitrepo "$LAB"
MAX=1 sw spawn 7-bar "instrução kaizen" --repo "$LAB" --kaizen
check "spawn --repo: código 0"                           [ "$RC" -eq 0 ]
check "spawn --repo: aba aberta no repo indicado"        grep -q -- "tab create --workspace w1 --cwd $LAB " "$FAKE/herdr.log"
check "spawn --repo: oute-task na worktree do repo, com a rodada (#128)" grep -q -- "pane run w1:p2 OUTE_SWARM_WORKER=1 OUTE_SWARM_ROUND=swarm-test oute-task -r $LAB 7-bar claude" "$FAKE/herdr.log"
check "spawn --repo: spawned grava repo e kaizen"        [ "$(awk '$1=="7-bar" {print $2, $6, $7}' "$STATE/spawned")" == "w1:p2 $LAB kaizen" ]
check "kaizen: fora do --max (1 normal já aberta)"       grep -q 'kaizen' <<<"$OUT"
MAX=1 sw spawn 8-baz "instrução normal"
check "limite: sessão normal continua contando"          [ "$RC" -ne 0 ]
check "limite: mensagem do limite (kaizen fora)"         grep -q 'limite da rodada atingido (1/1 abertas)' <<<"$ERR"
MAX=2 sw spawn 8-baz "instrução normal"
check "limite: normal passa com 1 normal + 1 kaizen"     [ "$RC" -eq 0 ]
check "spawn sem --repo: grava o repo da rodada"         [ "$(awk '$1=="8-baz" {print $6, $7}' "$STATE/spawned")" == "$REPO -" ]
before="$(cat "$STATE/spawned")"
sw spawn 9-x "instrução" --repo "$TMP/$CASE/nao-existe" --kaizen
check "repo inexistente: falha"                          [ "$RC" -ne 0 ]
check "repo inexistente: mensagem clara"                 grep -q "repo não encontrado: $TMP/$CASE/nao-existe" <<<"$ERR"
check "repo inexistente: nada registrado nem aberto"     [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq 2 ]
gone=pi   # #217: o Pi saiu do stack
sw spawn 9-y "instrução" --agent "$gone"
check "agente Pi: falha"                                 [ "$RC" -ne 0 ]
check "agente Pi: mensagem clara"                        grep -q "Pi saiu do stack (#217), use claude ou codex" <<<"$ERR"
check "agente Pi: nada registrado nem aberto"            [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq 2 ]

# ---------------------------------------------------------------- #170: --max conta só abas abertas
# 5b. cadeia de issues numa rodada --max 1: o elo seguinte abre depois do `oute-swarm close` do anterior
CASE=cadeia; round "$CASE"
MAX=1 sw spawn 8-elo "instrução"
check "cadeia: aba aberta ocupa a vaga"                  [ "$RC" -ne 0 ]
check "cadeia: mensagem conta abertas"                   grep -q 'limite da rodada atingido (1/1 abertas)' <<<"$ERR"
check "cadeia: mensagem aponta o close"                  grep -q 'oute-swarm close' <<<"$ERR"
FAKE="$FAKE" "$BIN/fake-tabs" '#9 outra=working'
sw close 7-foo --yes
check "cadeia: close marca a aba fechada"                grep -qxF 7-foo "$STATE/closed"
MAX=1 sw spawn 8-elo "instrução"
check "cadeia: aba fechada libera a vaga"                [ "$RC" -eq 0 ]
MAX=1 sw spawn 9-elo "instrução"
check "cadeia: elo novo aberto volta a contar"           [ "$RC" -ne 0 ]
check "cadeia: spawned segue com o histórico"            [ "$(wc -l < "$STATE/spawned")" -eq 2 ]

# ---------------------------------------------------------------- #276: ids do JSON do `herdr tab create`
# 5c. workspace com id alfabético (wA) e numérico (w9): pane e aba lidos do JSON, sem supor w<dígitos>
CASE=ws-ids; round "$CASE"
for ws in wA w9; do
  WS=$ws sw spawn "8-${ws,,}" "instrução" --force
  check "workspace $ws: código 0"                        [ "$RC" -eq 0 ]
  check "workspace $ws: agente iniciado no pane da aba nova" grep -q -- "pane run $ws:p[0-9]* OUTE_SWARM_WORKER=1 .* 8-${ws,,} claude" "$FAKE/herdr.log"
  check "workspace $ws: spawned grava pane e aba"        grep -qE "^8-${ws,,} $ws:p[0-9]+ claude [^ ]+ $ws:t[0-9]+ " "$STATE/spawned"
done
check "workspace: nenhuma aba fechada"                   [ "$(grep -c 'tab close' "$FAKE/herdr.log")" -eq 0 ]

# 5d. saída sem pane: fecha a aba recém-criada (pelo id da saída; sem id, pelo label) e nada entra no spawned
CASE=parse; round "$CASE"
before="$(cat "$STATE/spawned")"
echo '{"id":"cli:tab:create","result":{"tab":{"tab_id":"wA:t5"}}}' > "$FAKE/tab-create.out"
sw spawn 8-sem-pane "instrução"
check "sem pane: falha"                                  [ "$RC" -ne 0 ]
check "sem pane: fecha a aba pelo id da saída"           grep -qx 'tab close wA:t5' "$FAKE/herdr.log"
check "sem pane: mensagem diz que fechou"                grep -q 'não achei o pane da aba nova na saída do herdr (aba wA:t5 fechada)' <<<"$ERR"
check "sem pane: agente não registrado"                 [ "$(cat "$STATE/spawned")" == "$before" ]
check "sem pane: agente não iniciado"                    bash -c '! grep -q "$1" "$2"' _ 'pane run' "$FAKE/herdr.log"
echo 'herdr: resposta inesperada' > "$FAKE/tab-create.out"
FAKE="$FAKE" "$BIN/fake-tabs" working '#8 sem-pane=idle'
sw spawn 8-sem-pane "instrução"
check "não JSON: falha"                                  [ "$RC" -ne 0 ]
check "não JSON: fecha a aba achada pelo label"          grep -qx 'tab close w1:t2' "$FAKE/herdr.log"
check "não JSON: nada registrado"                        [ "$(cat "$STATE/spawned")" == "$before" ]
FAKE="$FAKE" "$BIN/fake-tabs" working
sw spawn 8-sem-pane "instrução"
check "aba não achada: falha"                            [ "$RC" -ne 0 ]
check "aba não achada: pede para fechar à mão"           grep -q 'não consegui fechar a aba "#8 sem-pane" (feche à mão)' <<<"$ERR"
check "aba não achada: não fecha outra aba"              [ "$(grep -c 'tab close' "$FAKE/herdr.log")" -eq 2 ]
check "parse: nada registrado em nenhuma das falhas"     [ "$(cat "$STATE/spawned")" == "$before" ]
check "parse: nada iniciado em nenhuma das falhas"       bash -c '! grep -q "$1" "$2"' _ 'pane run' "$FAKE/herdr.log"

# 6. watch multi-repo: mesma issue #7 e mesmo PR #12 em dois repos, sem colisão
CASE=multi; round "$CASE"; LAB="$TMP/$CASE/lab"; gitrepo "$LAB"
printf '7-bar w1:p2 claude 2026-01-01T00:00:02Z w1:t2 %s kaizen\n' "$LAB" >> "$STATE/spawned"
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=working" "#7 bar=working"
cat > "$FAKE/on-sleep-1" <<'SH'
fake-tabs "#7 foo=idle" "#7 bar=idle"
cat > "$FAKE/prs-repo.json" <<'J'
[{"number":12,"headRefName":"feat/7-foo","state":"OPEN","mergeable":"MERGEABLE","createdAt":"2026-06-01T00:00:00Z",
  "url":"https://github.com/x/repo/pull/12","statusCheckRollup":[{"name":"test","conclusion":"SUCCESS","completedAt":"2026-06-01T00:05:00Z"}]}]
J
cat > "$FAKE/prs-lab.json" <<'J'
[{"number":12,"headRefName":"fix/7-bar","state":"OPEN","mergeable":"CONFLICTING","createdAt":"2026-06-01T00:00:00Z",
  "url":"https://github.com/x/lab/pull/12","statusCheckRollup":[{"name":"test","conclusion":"FAILURE","completedAt":"2026-06-01T00:05:00Z"}]}]
J
SH
watch
check "multi: código 0"                                  [ "$RC" -eq 0 ]
check "multi: PR do repo da rodada"                      logged "[pr] PR #12 aberto (issue #7) https://github.com/x/repo/pull/12"
check "multi: PR do outro repo, com o repo"              logged "[pr] PR lab#12 aberto (issue lab#7) https://github.com/x/lab/pull/12"
check "multi: CI do outro repo"                          logged "[ci] PR lab#12 · test: fail"
check "multi: CI do repo da rodada"                      logged "[ci] PR #12 · test: pass"
check "multi: conflito do outro repo"                    logged "[conflito] PR lab#12 em conflito com a base (mergeable=CONFLICTING)"
check "multi: sessão da rodada com o PR dela"            logged "[sessao] #7 foo: idle (PR #12 open)"
check "multi: sessão kaizen com o PR dela"               logged "[sessao] #7 bar: idle (PR lab#12 open)"
check "multi: PR do lab não vira PR da issue #7 da rodada" [ -z "$(log_events | grep -F '(issue #7) https://github.com/x/lab')" ]
check "multi: sem conflito no repo da rodada"            [ -z "$(log_events | grep -F '[conflito] PR #12')" ]

# 7. tell, close e list com sessão de outro repo (linha do spawned com repo e kaizen)
CASE=outros; round "$CASE"; LAB="$TMP/$CASE/lab"; gitrepo "$LAB"
printf '7-bar w1:p2 claude 2026-01-01T00:00:02Z w1:t2 %s kaizen\n' "$LAB" >> "$STATE/spawned"
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=working" "#7 bar=idle"
echo '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2","agent":"claude"}]}}' > "$FAKE/panes.json"
echo '{"result":{"agents":[{"pane_id":"w1:p2","agent":"claude","agent_status":"idle"}]}}' > "$FAKE/agents.json"
sw tell 7-bar "pode seguir"
check "tell: código 0"                                   [ "$RC" -eq 0 ]
check "tell: Enter no pane da sessão"                    grep -q 'pane send-keys w1:p2 enter' "$FAKE/herdr.log"
check "tell: registrado no log, com a mensagem"          grep -q " tell 7-bar ok"$'\t'"pode seguir\$" "$STATE/log"
check "tell: prefixo do dispatcher (#214)"               [ "$(cat "$FAKE/field")" == "[dispatcher swarm-test, repassando o Bardi] pode seguir" ]
sw list
check "list: mostra a sessão de outro repo"              grep -q "7-bar w1:p2 claude .* $LAB kaizen" <<<"$OUT"
# aba renomeada: o close acha pelo id gravado no spawn (5º campo, antes do repo)
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=working" "outro nome=idle"
sw close 7-bar --yes
check "close: código 0"                                  [ "$RC" -eq 0 ]
check "close: fecha a aba pelo id gravado"               grep -q 'tab close w1:t2' "$FAKE/herdr.log"
check "close: marca a sessão fechada"                    grep -qx '7-bar' "$STATE/closed"
sw list
check "list: sessão fechada marcada"                     grep -q "$LAB kaizen (fechada)" <<<"$OUT"

# ---------------------------------------------------------------- #239: dispatcher que reiniciou sem OUTE_SWARM_ID
# swc <dir> <args>: roda o oute-swarm em <dir> sem OUTE_SWARM_ID/REPO/MAX no ambiente (WATCHING=1: o sleep falso vira
# o gancho do watch). coord <dir> <branch>: pasta git com o HEAD em <branch>.
swc() {
  local d="$1" g=(); shift; command -v timeout >/dev/null && g=(timeout 30)
  OUT="$(cd "$d" && env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" \
         STATE="$STATE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 ${WATCHING:+FAKE_WATCH=1} \
         OUTE_INBOX="$TMP/$CASE/inbox" OUTE_OUTBOX="$TMP/$CASE/outbox" \
         ${g[@]+"${g[@]}"} "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
coord() { gitrepo "$1" && git -C "$1" symbolic-ref HEAD "refs/heads/$2"; }
ASSUME='OUTE_SWARM_ID ausente; assumindo a rodada swarm-test (worktree do dispatcher)'

# 7b. spawn na worktree sessao/swarm-<id>: assume a rodada, com o max e o repo do meta, e avisa em stderr
CASE=assume; round "$CASE"; WT="$TMP/$CASE/wt"; coord "$WT" sessao/swarm-test
swc "$WT" spawn 8-bar "instrução"
check "assume: código 0"                                 [ "$RC" -eq 0 ]
check "assume: aviso em stderr com a rodada"             grep -qF "$ASSUME" <<<"$ERR"
check "assume: spawned da rodada, com o repo do meta"    [ "$(awk '$1=="8-bar" {print $6}' "$STATE/spawned")" == "$REPO" ]
check "assume: log da rodada"                            grep -q ' spawn 8-bar claude$' "$STATE/log"
check "assume: nada em avulso"                           [ ! -e "$H/.oute/swarm/avulso" ]
check "assume: prompt da sessão cita a rodada"           grep -q 'swarm-test' "$STATE/8-bar.prompt"
sed -i.bak 's/^max=.*/max=2/' "$STATE/meta"
swc "$WT" spawn 9-baz "instrução"
check "assume: max do meta recusa a 3ª aba"              [ "$RC" -ne 0 ]
check "assume: mensagem com o max do meta"               grep -q 'limite da rodada atingido (2/2 abertas)' <<<"$ERR"
check "assume: recusada não entra no spawned"            [ -z "$(awk '$1=="9-baz"' "$STATE/spawned")" ]
sed -i.bak '/^repo=/d' "$STATE/meta"
swc "$WT" spawn 9-rep "instrução" --kaizen
check "meta sem repo: vale o repo da worktree"           [ "$RC" -eq 0 -a "$(awk '$1=="9-rep" {print $6}' "$STATE/spawned")" == "$WT" ]
before="$(cat "$STATE/spawned")"
sed -i.bak '/^max=/d' "$STATE/meta"
swc "$WT" spawn 9-baz "instrução"
check "meta sem max: falha"                              [ "$RC" -ne 0 ]
check "meta sem max: mensagem clara"                     grep -q 'meta da rodada swarm-test sem max válido' <<<"$ERR"
check "meta sem max: nada registrado nem aberto"         [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq 2 ]

# 7c. pasta <repo>-swarm-<id> (branch qualquer) também vale; o OUTE_SWARM_ID, quando existe, ganha da worktree
CASE=pasta; round "$CASE"; ID=swarm-0101-0000; WT="$TMP/$CASE/repo-$ID"; coord "$WT" main
mkdir -p "$H/.oute/swarm/$ID"; printf 'repo=%s\nmax=3\nlabel=\nstarted=2026-01-01T00:00:00Z\n' "$REPO" > "$H/.oute/swarm/$ID/meta"
swc "$WT" spawn 8-bar "instrução"
check "pasta: código 0"                                  [ "$RC" -eq 0 ]
check "pasta: assume a rodada da pasta"                  grep -qF "assumindo a rodada $ID" <<<"$ERR"
check "pasta: spawned da rodada, com o repo do meta"     [ "$(awk '$1=="8-bar" {print $6}' "$H/.oute/swarm/$ID/spawned")" == "$REPO" ]
OUT="$(cd "$WT" && env PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 \
       OUTE_SWARM_ID=swarm-test "$SWARM" spawn 9-baz "instrução" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
check "variável ganha: código 0"                         [ "$RC" -eq 0 ]
check "variável ganha: grava na rodada do OUTE_SWARM_ID" grep -q '^9-baz ' "$STATE/spawned"
check "variável ganha: sem aviso"                        [ -z "$ERR" ]

# 7d. fora de worktree de dispatcher (ou com branch swarm sem meta): avulso, como antes, sem aviso
CASE=avulso; round "$CASE"; WT="$TMP/$CASE/wt"; coord "$WT" sessao/swarm-sem-meta
swc "$REPO" spawn 8-bar "instrução"
check "avulso: código 0, sem aviso"                      [ "$RC" -eq 0 -a -z "$ERR" ]
check "avulso: grava em avulso (spawned)"                grep -q '^8-bar ' "$H/.oute/swarm/avulso/spawned"
check "avulso: grava em avulso (log)"                    grep -q ' spawn 8-bar claude$' "$H/.oute/swarm/avulso/log"
check "avulso: sessão avulsa, sem OUTE_SWARM_ROUND (#128)" grep -q -- "pane run w1:p[0-9]* OUTE_SWARM_WORKER=1 oute-task -r .* 8-bar claude" "$FAKE/herdr.log"
check "avulso: a rodada não recebe nada"                 [ "$(wc -l < "$STATE/spawned")" -eq 1 ]
swc "$WT" spawn 9-baz "instrução"
check "branch swarm sem meta: código 0, sem aviso"       [ "$RC" -eq 0 -a -z "$ERR" ]
check "branch swarm sem meta: avulso"                    grep -q '^9-baz ' "$H/.oute/swarm/avulso/spawned"

# 7e. spawn, tell, close e watch sem a variável, na worktree do dispatcher: a mesma rodada, mesmo com outra mais recente
CASE=mesma; round "$CASE"; WT="$TMP/$CASE/wt"; coord "$WT" sessao/swarm-test
swc "$WT" spawn 8-bar "instrução"
NEW="$H/.oute/swarm/swarm-nova"; mkdir -p "$NEW"; cp "$STATE/meta" "$NEW/meta"
printf '7-foo w1:p9 claude 2026-01-01T00:00:01Z w1:t9\n' > "$NEW/spawned"; touch -t 203001010000 "$NEW"
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=working" "#8 bar=idle"
echo '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2","agent":"claude"}]}}' > "$FAKE/panes.json"
echo '{"result":{"agents":[{"pane_id":"w1:p2","agent":"claude","agent_status":"idle"}]}}' > "$FAKE/agents.json"
swc "$WT" tell 8-bar "pode seguir"
check "mesma: tell sai com 0"                            [ "$RC" -eq 0 ]
check "mesma: tell acha a sessão na rodada da worktree"  grep -q " tell 8-bar ok"$'\t'"pode seguir\$" "$STATE/log"
check "mesma: tell avisa a rodada assumida"              grep -qF "$ASSUME" <<<"$ERR"
swc "$WT" close 8-bar --yes
check "mesma: close na rodada da worktree"               [ "$RC" -eq 0 -a "$(head -1 <<<"$OUT")" == "rodada swarm-test" ]
check "mesma: close registra a sessão na rodada"         grep -qx '8-bar' "$STATE/closed"
WATCHING=1 swc "$WT" watch
check "mesma: watch sai com 0"                           [ "$RC" -eq 0 ]
check "mesma: watch na rodada da worktree"               grep -q 'oute-swarm watch: rodada swarm-test ' <<<"$ERR"
check "mesma: a rodada mais recente fica intacta"        [ ! -e "$NEW/log" -a ! -e "$NEW/closed" -a ! -e "$NEW/fechada" ]
swc "$REPO" close 7-foo
check "fora da worktree: close segue na mais recente"    [ "$RC" -eq 0 -a "$(head -1 <<<"$OUT")" == "rodada swarm-nova" -a -z "$ERR" ]
STATE="$NEW" WATCHING=1 swc "$WT" watch --round swarm-nova
check "watch --round: sai com 0"                         [ "$RC" -eq 0 ]
check "watch --round: ganha da worktree"                 grep -q 'oute-swarm watch: rodada swarm-nova ' <<<"$ERR"
check "watch --round: sem aviso"                         bash -c '! grep -q assumindo' _ <<<"$ERR"

# ---------------------------------------------------------------- #266: falha de CI em head já substituído
# fake-pr <sha do head> [<estado>] [<checks do head, JSON>]: PR #12 da issue #7 no repo da rodada (usável nos ganchos)
cat > "$BIN/fake-pr" <<'SH'
#!/usr/bin/env bash
jq -n --arg h "$1" --arg s "${2:-OPEN}" --argjson c "${3:-[]}" '[{number: 12, headRefName: "feat/7-foo", headRefOid: $h,
  state: $s, mergeable: "MERGEABLE", createdAt: "2026-06-01T00:00:00Z", url: "https://github.com/x/y/pull/12",
  statusCheckRollup: $c}]' > "$FAKE/prs-repo.json"
SH
# fake-checks <sha> <nome>=<conclusão>...: checks do commit (conclusão vazia = ainda rodando; "ctx:" na frente do nome
# = status de commit, não check run)
cat > "$BIN/fake-checks" <<'SH'
#!/usr/bin/env bash
sha="$1"; shift
for a in "$@"; do
  n="${a%=*}" c="${a##*=}"
  if [[ "$n" == ctx:* ]]; then jq -n --arg n "${n#ctx:}" --arg c "$c" '{__typename: "StatusContext", context: $n, state: $c, startedAt: "2026-06-01T00:01:00Z"}'
  else jq -n --arg n "$n" --arg c "$c" '{__typename: "CheckRun", name: $n, conclusion: (if $c == "" then null else $c end),
         startedAt: "2026-06-01T00:01:00Z", completedAt: (if $c == "" then null else "2026-06-01T00:05:00Z" end)}'; fi
done | jq -s '{data: {repository: {object: {statusCheckRollup: {contexts: {nodes: .}}}}}}' > "$FAKE/checks-$sha.json"
SH
chmod +x "$BIN/fake-pr" "$BIN/fake-checks"
A=aaaaaaa1111111111111111111111111111111aa; B=bbbbbbb2222222222222222222222222222222bb
RUN='[{"name":"checks","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-06-01T00:01:00Z","completedAt":"0001-01-01T00:00:00Z"}]'
OLDFAIL="[ci] PR #12 · checks: fail (head aaaaaaa, já substituído por bbbbbbb)"
ci_events() { log_events | grep -F '[ci]' || true; }
reads() { grep -cxF "repo $1" "$FAKE/gh.log" 2>/dev/null || true; }

# 7f. o caso da #262: o check falha no head A e um push troca o head por B antes da passada seguinte
CASE=substituido; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B OPEN '$RUN'
fake-checks $A checks=FAILURE "SonarCloud Code Analysis=SUCCESS" ctx:CodeRabbit=SUCCESS
SH
echo : > "$FAKE/on-sleep-2"
watch
check "substituído: código 0"                            [ "$RC" -eq 0 ]
check "substituído: falha do head antigo, com o head"    logged "$OLDFAIL"
check "substituído: verde do head antigo sem linha"      [ "$(ci_events)" == "$OLDFAIL" ]
check "substituído: uma vez só entre passadas"           [ "$(count "$OLDFAIL")" -eq 1 ]
check "substituído: head concluído é lido uma vez só"    [ "$(reads "$A")" -eq 1 ]
check "substituído: log = stdout"                        [ "$(log_events)" == "$(out_events)" ]
watch
check "substituído: não repete depois do reinício"       [ "$(count "$OLDFAIL")" -eq 1 -a "$(reads "$A")" -eq 1 ]

# 7g. falha já emitida enquanto o head era o atual não sai de novo quando ele é substituído
CASE=jaemitida; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $A OPEN '[{"name":"checks","conclusion":"FAILURE","completedAt":"2026-06-01T00:05:00Z"}]'
SH
cat > "$FAKE/on-sleep-2" <<SH
fake-pr $B OPEN '$RUN'
fake-checks $A checks=FAILURE lint=FAILURE
SH
watch
check "já emitida: a falha do head atual saiu"           logged "[ci] PR #12 · checks: fail"
check "já emitida: sem segunda linha para o mesmo check" [ "$(count "$OLDFAIL")" -eq 0 ]
check "já emitida: outro check do mesmo head sai"        logged "[ci] PR #12 · lint: fail (head aaaaaaa, já substituído por bbbbbbb)"

# 7h. head antigo com check ainda rodando fica em observação; cancelado (o push novo cancela o run) não é falha
CASE=rodando; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B OPEN '$RUN'
fake-checks $A checks= lint=CANCELLED
cp "\$STATE/log" "\$FAKE/log.p2" 2>/dev/null || : > "\$FAKE/log.p2"
SH
cat > "$FAKE/on-sleep-2" <<SH
cp "\$STATE/log" "\$FAKE/log.p2"
fake-checks $A checks=FAILURE lint=CANCELLED
SH
echo : > "$FAKE/on-sleep-3"
watch
check "rodando: nada enquanto o check roda, nem pelo cancelado" [ -z "$(grep -F '[ci]' "$FAKE/log.p2")" ]
check "rodando: a falha sai quando o check conclui"      [ "$(ci_events)" == "$OLDFAIL" ]
check "rodando: observação termina com o head concluído" [ "$(reads "$A")" -eq 2 ]

# 7i. leitura dos checks do head antigo falha: aviso, o head segue em observação e a falha sai na passada seguinte
CASE=ghfalha; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B OPEN '$RUN'
fake-checks $A checks=FAILURE
: > "\$FAKE/checks-$A.fail"
SH
cat > "$FAKE/on-sleep-2" <<SH
cp "\$STATE/log" "\$FAKE/log.p2"
rm -f "\$FAKE/checks-$A.fail"
SH
watch
check "gh falha: aviso na passada da falha"              grep -qF '[aviso] gh falhou nesta passada' "$FAKE/log.p2"
check "gh falha: sem [ci] na passada da falha"           bash -c '! grep -qF "[ci]" "$1"' _ "$FAKE/log.p2"
check "gh falha: a falha sai quando o gh volta"          [ "$(ci_events)" == "$OLDFAIL" ]
check "gh falha: aviso de volta"                         logged "[aviso] gh respondendo de novo"

# 7j. resposta sem o repositório (não é JSON dos checks): mesmo tratamento da falha do gh
CASE=ghlixo; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B OPEN '$RUN'
echo '{"errors":[{"message":"x"}]}' > "\$FAKE/checks-$A.json"
SH
cat > "$FAKE/on-sleep-2" <<SH
fake-checks $A checks=FAILURE
SH
watch
check "gh lixo: aviso"                                   logged "[aviso] gh falhou nesta passada; mantendo o último estado conhecido"
check "gh lixo: nova leitura"                            [ "$(reads "$A")" -eq 2 ]
check "gh lixo: a falha sai na passada seguinte"         [ "$(ci_events)" == "$OLDFAIL" ]

# 7k. PR fechado ou mergeado: o head antigo é lido uma vez (a falha concluída sai) e sai da observação mesmo com check rodando
CASE=mergeado; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B MERGED
fake-checks $A checks=FAILURE lint=
SH
echo : > "$FAKE/on-sleep-2"
watch
check "mergeado: falha concluída do head antigo sai"     logged "$OLDFAIL"
check "mergeado: sem nova leitura depois do merge"       [ "$(reads "$A")" -eq 1 ]

# 7l. `gh pr list` falha na passada seguinte à troca de head: a observação é mantida e a falha sai uma vez só
CASE=listafalha; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B OPEN '$RUN'
fake-checks $A checks=
SH
cat > "$FAKE/on-sleep-2" <<SH
cp "\$FAKE/prs-repo.json" "\$FAKE/prs.ok"; echo 'não é json' > "\$FAKE/prs-repo.json"
fake-checks $A checks=FAILURE
SH
cat > "$FAKE/on-sleep-3" <<SH
cp "\$FAKE/prs.ok" "\$FAKE/prs-repo.json"
SH
echo : > "$FAKE/on-sleep-4"
watch
check "lista falha: observação mantida, falha uma vez"   [ "$(ci_events)" == "$OLDFAIL" ]

# 7l2. PR some da lista da rodada com o head antigo em observação: a observação termina
CASE=sumiu; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B OPEN '$RUN'
fake-checks $A checks=
SH
cat > "$FAKE/on-sleep-2" <<SH
echo '[]' > "\$FAKE/prs-repo.json"
SH
echo : > "$FAKE/on-sleep-3"
watch
check "PR sumiu: código 0, sem [ci] e sem nova leitura"  [ "$RC" -eq 0 -a -z "$(ci_events)" -a "$(reads "$A")" -eq 1 ]

# 7m. PR de outro repo: a leitura roda no repo do PR e a linha leva o repo
CASE=oldmulti; round "$CASE"; LAB="$TMP/$CASE/lab"; gitrepo "$LAB"
printf '7-bar w1:p2 claude 2026-01-01T00:00:02Z w1:t2 %s kaizen\n' "$LAB" >> "$STATE/spawned"
FAKE="$FAKE" "$BIN/fake-tabs" "#7 foo=working" "#7 bar=working"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN "$RUN"; mv "$FAKE/prs-repo.json" "$FAKE/prs-lab.json"
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $B OPEN '$RUN'; mv "\$FAKE/prs-repo.json" "\$FAKE/prs-lab.json"
fake-checks $A checks=FAILURE
SH
watch
check "outro repo: falha do head antigo com o repo"      logged "[ci] PR lab#12 · checks: fail (head aaaaaaa, já substituído por bbbbbbb)"
check "outro repo: leitura feita no repo do PR"          [ "$(grep -cxF "lab $A" "$FAKE/gh.log")" -eq 1 ]

# ---------------------------------------------------------------- #124: eventos operacionais (receptor OTLP falso)
# cada linha do log da rodada também chega ao receptor como log OTLP (oute-emit), com a origem e o oute.agent
. "$ROOT/tests/lib/otlp.sh"
trap 'rcv_stop; rm -rf "$TMP"' EXIT
ln -sf "$ROOT/docker/oute-emit" "$BIN/oute-emit"
export OTEL_RESOURCE_ATTRIBUTES="host.name=oute-mac,oute.instance=oute-agent"

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
check "fora do ar: spawn com código 0 e a mesma saída"   [ "$RC" -eq 0 -a "$OUT" == "aberta: #9 → pane w1:p2 · worktree repo-9-baz · agente claude" ]
check "fora do ar: sem erro na tela"                     [ -z "$ERR" ]
check "fora do ar: rápido"                               [ $(( $(date +%s) - t0 )) -le 3 ]
check "fora do ar: log continua sendo gravado"           grep -q ' spawn 9-baz claude$' "$STATE/log"
unset OTEL_EXPORTER_OTLP_ENDPOINT


# ---------------------------------------------------------------- #212: agente das sessões da rodada (--agent na abertura)
# opn <args>: abre o dispatcher no repo da rodada de teste (HOME do caso); stdout em $OUT, stderr em $ERR.
# so_teste: nenhuma rodada nova nem oute-task chamado. sp_agent <rodada> <slug>: agente gravado no spawned
opn() {
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" \
         OUTE_LIB="$ROOT/docker" HERDR_ENV=1 "$SWARM" "$REPO" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
nova() { ls "$H/.oute/swarm" | grep -v '^swarm-test$' | head -1; }
so_teste() { [ "$(ls "$H/.oute/swarm")" == swarm-test ] && [ ! -e "$FAKE/oute-task.last" ]; }
sp_agent() { awk -v s="$2" '$1 == s {print $3}' "$H/.oute/swarm/$1/spawned"; }
ran() { grep -qF -- "oute-task -r $REPO $1 $2 " "$FAKE/herdr.log"; }

# 10. abertura com --agent: meta, prompt, aviso, log e oute.swarm.round.opened
CASE=agente-abre; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
opn --max 2 --agent codex
nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
check "--agent: código 0 e rodada nova"                  [ "$RC" -eq 0 -a -n "$nr" ]
check "--agent: meta com workers=codex e agent=claude"   [ "$(grep -cxE 'workers=codex|agent=claude' "$M")" -eq 2 ]
check "--agent: prompt com o agente da rodada"           grep -qF 'Agente das sessões: `codex` (escolhido pelo Bardi na abertura, `--agent codex`).' "$FAKE/oute-task.last"
check "--agent: prompt manda não passar --agent"         grep -qF -- '- **Agente:** não passe `--agent` no `spawn`' "$FAKE/oute-task.last"
check "--agent: triagem com o agente de cada sessão"     grep -qF 'área tocada, agente da sessão,' "$FAKE/oute-task.last"
check "--agent: sem placeholder no prompt"               [ -z "$(grep -o '{{[A-Z_]*}}' "$FAKE/oute-task.last")" ]
check "--agent: aviso com o agente"                      grep -qxF "dispatcher $nr · repo repo · max 2 · agente codex" <<<"$ERR"
check "--agent: linha do log com o agente"               grep -q " abertura $nr (repo repo, max 2, agente codex)$" "$H/.oute/swarm/$nr/log"
check "--agent: round.opened com oute.swarm.round.agent" [ "$(n '.name == "oute.swarm.round.opened" and .attrs["oute.swarm.round.agent"] == "codex" and .attrs["oute.agent"] == "claude"')" -eq 1 ]
rcv_stop

# 10b. abertura sem --agent: meta sem workers=, prompt com "seletor", evento sem o atributo
CASE=agente-sem; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
opn --max 2
nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
check "sem --agent: código 0 e rodada nova"              [ "$RC" -eq 0 -a -n "$nr" ]
check "sem --agent: meta sem workers="                   [ -z "$(grep '^workers' "$M")" -a "$(grep -cx 'agent=claude' "$M")" -eq 1 ]
check "sem --agent: prompt com seletor"                  grep -qF 'Agente das sessões: seletor (a rodada abriu sem `--agent`' "$FAKE/oute-task.last"
check "sem --agent: aviso e log como antes"              [ "$(grep -cxF "dispatcher $nr · repo repo · max 2" <<<"$ERR")" -eq 1 -a "$(grep -c " abertura $nr (repo repo, max 2)$" "$H/.oute/swarm/$nr/log")" -eq 1 ]
check "sem --agent: round.opened sem round.agent"        [ "$(n '.name == "oute.swarm.round.opened"')" -eq 1 -a "$(n '.name == "oute.swarm.round.opened" and (.attrs | has("oute.swarm.round.agent"))')" -eq 0 ]
sw spawn 8-bar "instrução"
check "sem --agent: spawn usa claude"                    [ "$RC" -eq 0 -a "$(sp_agent swarm-test 8-bar)" == claude ]
check "sem --agent: oute-task com claude"                ran 8-bar claude
rcv_stop

# 10c. --agent inválido: erro claro, sem rodada nem oute-task
CASE=agente-invalido; round "$CASE"
opn --agent foo
check "inválido: código != 0"                            [ "$RC" -ne 0 ]
check "inválido: mensagem clara"                         grep -qF 'agente inválido: foo; use claude ou codex' <<<"$ERR"
check "inválido: nenhuma rodada criada"                  so_teste
opn --max 2 --agent pi
check "Pi na abertura: recusado, sem rodada"             [ "$RC" -ne 0 -a "$(grep -c 'Pi saiu do stack (#217)' <<<"$ERR")" -eq 1 ]
check "Pi na abertura: nenhuma rodada criada"            so_teste

# 10d. spawn numa rodada com workers=codex: padrão do meta, sobreposição e kaizen
CASE=agente-spawn; round "$CASE"; echo workers=codex >> "$STATE/meta"
sw spawn 8-def "instrução"
check "padrão do meta: código 0"                         [ "$RC" -eq 0 ]
check "padrão do meta: spawned com codex"                [ "$(sp_agent swarm-test 8-def)" == codex ]
check "padrão do meta: oute-task com codex"              ran 8-def codex
check "padrão do meta: saída e log com codex"            [ "${OUT##* · }" == "agente codex" -a "$(grep -c ' spawn 8-def codex$' "$STATE/log")" -eq 1 ]
sw spawn 9-ovr "instrução" --agent claude
check "--agent sobrepõe: claude no spawned e no oute-task" [ "$RC" -eq 0 -a "$(sp_agent swarm-test 9-ovr)" == claude ]
check "--agent sobrepõe: oute-task com claude"           ran 9-ovr claude
sw spawn 10-kz "instrução" --kaizen
check "kaizen: segue o padrão da rodada"                 [ "$RC" -eq 0 -a "$(awk '$1 == "10-kz" {print $3, $7}' "$STATE/spawned")" == "codex kaizen" ]
check "kaizen: oute-task com codex"                      ran 10-kz codex

# 10e. dispatcher reiniciado sem OUTE_SWARM_ID: o padrão vem do meta da rodada assumida
WT="$TMP/$CASE/wt"; coord "$WT" sessao/swarm-test
swc "$WT" spawn 11-rei "instrução" --kaizen
check "reinício: assume a rodada e usa codex"            [ "$RC" -eq 0 -a "$(sp_agent swarm-test 11-rei)" == codex ]
check "reinício: aviso de rodada assumida"               grep -qF "$ASSUME" <<<"$ERR"

# 10f. spawn avulso não herda o agente de rodada nenhuma
swc "$REPO" spawn 12-av "instrução"
check "avulso: claude, mesmo com rodada workers=codex"   [ "$RC" -eq 0 -a "$(sp_agent avulso 12-av)" == claude ]

# 10g. workers= inválido no meta: erro claro, nada aberto; --agent explícito não depende dele
sed -i.bak 's/^workers=.*/workers=pi/' "$STATE/meta"; before="$(cat "$STATE/spawned")"; tabs="$(grep -c 'tab create' "$FAKE/herdr.log")"
sw spawn 13-x "instrução" --kaizen
check "meta inválido: código != 0"                       [ "$RC" -ne 0 ]
check "meta inválido: mensagem com a origem"             grep -qF 'Pi saiu do stack (#217), use claude ou codex (workers= do meta da rodada swarm-test)' <<<"$ERR"
check "meta inválido: nada registrado nem aberto"        [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq "$tabs" ]
sw spawn 13-y "instrução" --kaizen --agent claude
check "meta inválido + --agent: abre com o explícito"    [ "$RC" -eq 0 -a "$(sp_agent swarm-test 13-y)" == claude ]

check_end
