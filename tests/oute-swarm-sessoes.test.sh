#!/usr/bin/env bash
# Testes do oute-swarm, tema: abrir, listar, avisar e fechar sessões: kaizen em outro repo, --max, ids do herdr, multi-repo, dispatcher reiniciado, baixa do close (#85, #170, #276, #289, #239, #407).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-sessoes.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"

# ---------------------------------------------------------------- #85: sessão kaizen em outro repo
# 5. spawn --repo --kaizen: aba e worktree no repo indicado, registro com repo e tipo, fora do --max
CASE=spawn; round "$CASE"; LAB="$TMP/$CASE/lab"; gitrepo "$LAB"
MAX=1 sw spawn 7-bar "instrução kaizen" --repo "$LAB" --kaizen
check "spawn --repo: código 0"                           [ "$RC" -eq 0 ]
check "spawn --repo: aba aberta no repo indicado"        grep -q -- "tab create --workspace w1 --cwd $LAB " "$FAKE/herdr.log"
check "spawn --repo: oute-task na worktree do repo, com a rodada (#128)" grep -q -- "pane run w1:p2 OUTE_SWARM_WORKER=1 OUTE_SWARM_ROUND=swarm-test OUTE_SELECT_FILE=$STATE/7-bar.select oute-task -r $LAB 7-bar claude" "$FAKE/herdr.log"
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

# 5d. saída sem pane: fecha a aba recém-criada pelo id da saída e nada entra no spawned
CASE=parse; round "$CASE"
before="$(cat "$STATE/spawned")"
echo '{"id":"cli:tab:create","result":{"tab":{"tab_id":"wA:t5"}}}' > "$FAKE/tab-create.out"
sw spawn 8-sem-pane "instrução"
check "sem pane: falha"                                  [ "$RC" -ne 0 ]
check "sem pane: fecha a aba pelo id da saída"           grep -qx 'tab close wA:t5' "$FAKE/herdr.log"
check "sem pane: mensagem diz que fechou"                grep -q 'não achei o pane da aba nova na saída do herdr (aba wA:t5 fechada)' <<<"$ERR"
check "sem pane: agente não registrado"                 [ "$(cat "$STATE/spawned")" == "$before" ]
check "sem pane: agente não iniciado"                    bash -c '! grep -q "$1" "$2"' _ 'pane run' "$FAKE/herdr.log"
# 5e. saída sem o id da aba (#289): fecha só a aba que o spawn criou (a do label que não estava no `tab list` de antes)
echo 'herdr: resposta inesperada' > "$FAKE/tab-create.out"
# tabs_after <fake-tabs args>: o `tab list` de depois do próximo `tab create`
tabs_after() { FAKE="$FAKE" "$BIN/fake-tabs" "$@"; mv "$FAKE/tabs.json" "$FAKE/tabs-after.json"; FAKE="$FAKE" "$BIN/fake-tabs" "${BEFORE[@]}"; }
BEFORE=(working '#8 sem-pane=idle')   # aba antiga com o mesmo label (w1:t2), de outra rodada
tabs_after working '#8 sem-pane=idle' '#8 sem-pane=idle'
sw spawn 8-sem-pane "instrução"
check "aba antiga: falha"                                [ "$RC" -ne 0 ]
check "aba antiga: fecha a aba nova"                     grep -qx 'tab close w1:t3' "$FAKE/herdr.log"
check "aba antiga: a antiga continua aberta"             bash -c '! grep -qx "$1" "$2"' _ 'tab close w1:t2' "$FAKE/herdr.log"
check "aba antiga: mensagem diz qual fechou"             grep -q '(aba w1:t3 fechada)' <<<"$ERR"
check "aba antiga: só uma aba fechada"                   [ "$(closes)" -eq 2 ]
BEFORE=(working)
tabs_after working '#8 sem-pane=idle'
sw spawn 8-sem-pane "instrução"
check "aba nova: falha"                                  [ "$RC" -ne 0 ]
check "aba nova: fechada pelo label"                     [ "$(grep -cx 'tab close w1:t2' "$FAKE/herdr.log")" -eq 1 ]
# ambíguo: duas abas novas com o label (outro spawn da mesma issue no meio)
nc="$(closes)"; BEFORE=(working '#8 sem-pane=idle')
tabs_after working '#8 sem-pane=idle' '#8 sem-pane=idle' '#8 sem-pane=idle'
sw spawn 8-sem-pane "instrução"
check "ambíguo: falha"                                   [ "$RC" -ne 0 ]
check "ambíguo: não fecha nada"                          [ "$(closes)" -eq "$nc" ]
check "ambíguo: diz o label para fechar à mão"           grep -q 'não fechei a aba "#8 sem-pane" (2 abas novas com esse label; feche à mão)' <<<"$ERR"
# nenhuma candidata: a aba antiga é a única com o label
tabs_after working '#8 sem-pane=idle'
sw spawn 8-sem-pane "instrução"
check "nenhuma: falha"                                   [ "$RC" -ne 0 ]
check "nenhuma: não fecha a aba antiga"                  [ "$(closes)" -eq "$nc" ]
check "nenhuma: diz o label para fechar à mão"           grep -q 'não fechei a aba "#8 sem-pane" (nenhuma aba nova com esse label; feche à mão)' <<<"$ERR"
# `tab list` ilegível antes do `tab create`: sem a lista de antes, nenhuma aba é dada como nova
tabs_after working '#8 sem-pane=idle'; echo 'herdr: erro' > "$FAKE/tabs.json"
sw spawn 8-sem-pane "instrução"
check "sem lista antes: falha"                           [ "$RC" -ne 0 ]
check "sem lista antes: não fecha nada"                  [ "$(closes)" -eq "$nc" ]
check "sem lista antes: diz o label e o motivo"          grep -q 'não fechei a aba "#8 sem-pane" (herdr tab list falhou; feche à mão)' <<<"$ERR"
# `tab list` ilegível depois do `tab create`
BEFORE=(working); FAKE="$FAKE" "$BIN/fake-tabs" working; echo 'herdr: erro' > "$FAKE/tabs-after.json"
sw spawn 8-sem-pane "instrução"
check "sem lista depois: falha"                          [ "$RC" -ne 0 ]
check "sem lista depois: não fecha nada"                 [ "$(closes)" -eq "$nc" ]
check "sem lista depois: diz o label e o motivo"         grep -q 'não fechei a aba "#8 sem-pane" (herdr tab list falhou; feche à mão)' <<<"$ERR"
# o `tab close` da aba nova falha: a mensagem pede para fechar à mão, com o id
FAKE="$FAKE" "$BIN/fake-tabs" working; tabs_after working '#8 sem-pane=idle'; touch "$FAKE/tab-close.fail"
sw spawn 8-sem-pane "instrução"; rm -f "$FAKE/tab-close.fail"
check "close falha: falha"                               [ "$RC" -ne 0 ]
check "close falha: diz o label e o id"                  grep -q 'não fechei a aba "#8 sem-pane" (herdr tab close falhou em w1:t2; feche à mão)' <<<"$ERR"
FAKE="$FAKE" "$BIN/fake-tabs" working
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
check "avulso: sessão avulsa, sem OUTE_SWARM_ROUND (#128)" grep -q -- "pane run w1:p[0-9]* OUTE_SWARM_WORKER=1 OUTE_SELECT_FILE=[^ ]*/avulso/8-bar.select oute-task -r .* 8-bar claude" "$FAKE/herdr.log"
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

# ---------------------------------------------------------------- #407: close registra a baixa antes de escrever
# quando a saída é cortada por | head -1 (SIGPIPE), mark_closed tem que ter rodado antes do echo
CASE=close407; round "$CASE"
# abrir 3 abas (max=3): já tem uma (7-foo), faltam 2
sw spawn 8-baz "instrução"
check "407: primeira aba aberta"                         [ "$RC" -eq 0 ]
sw spawn 9-qux "instrução"
check "407: segunda aba aberta"                          [ "$RC" -eq 0 ]
# agora temos 3 abas abertas (7-foo, 8-baz, 9-qux), total 3; o limit é 3
check "407: max atingido"                                [ "$(grep -c '^' "$STATE/spawned")" -eq 3 ]
# simular close com | head -1 (SIGPIPE cortando a saída) — não usar sw() porque captura tudo
env PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 \
  OUTE_SWARM_ID=swarm-test OUTE_SWARM_REPO="$REPO" OUTE_SWARM_MAX=3 \
  "$SWARM" close 8-baz --yes 2>/dev/null | head -1 >/dev/null
# verificar que a baixa foi registrada mesmo com pipe cortando a saída
check "407: close com | head -1 registra a baixa"       grep -qxF '8-baz' "$STATE/closed"
# tentar spawn novo — deve funcionar porque a vaga foi liberada
MAX=3 sw spawn 10-test "instrução"
check "407: novo spawn passa (vaga liberada)"           [ "$RC" -eq 0 ]
check "407: spawned tem 7-foo, 9-qux e 10-test"         [ "$(awk 'NR <= 1 || $1 ~ /(7-foo|9-qux|10-test)/ { print $1 }' "$STATE/spawned" | grep -c .)" -eq 3 ]
check_end
