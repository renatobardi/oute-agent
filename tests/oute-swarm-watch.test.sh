#!/usr/bin/env bash
# Testes do oute-swarm, tema: o monitor `watch`: eventos no log da rodada, CI de head substituído, evento [issue] e PR só desta rodada (#84, #266, #387, #419).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-watch.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"

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

# 7m. Evento [issue] (#387): PR mergeado com a issue ainda aberta sai uma vez; issue fechada não gera linha
ISSUE_EV='[issue] #7 aberta depois do merge do PR #12'
issue_events() { log_events | grep -F '[issue]' || true; }
for st in OPEN CLOSED; do
  CASE="issue$st"; round "$CASE"
  FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
  echo "{\"state\":\"$st\"}" > "$FAKE/gh-issue-7.json"
  cat > "$FAKE/on-sleep-1" <<SH
fake-pr $A MERGED
SH
  echo : > "$FAKE/on-sleep-2"
  OUTE_WATCH_ISSUE_DELAY=0 watch
  if [[ $st == OPEN ]]; then
    check "issue aberta: código 0"                       [ "$RC" -eq 0 ]
    check "issue aberta: uma linha [issue] no log"       [ "$(issue_events)" == "$ISSUE_EV" ]
    check "issue aberta: log = stdout"                   [ "$(log_events)" == "$(out_events)" ]
  else
    check "issue fechada: sem linha [issue]"             [ -z "$(issue_events)" ]
    check "issue fechada: o PR mergeado saiu"            logged "[pr] PR #12 mergeado (issue #7)"
  fi
done

# 7n. watch só de PR de sessão desta rodada (#419): outra rodada com a mesma issue #7 não entra no monitor
# a) a sessão #7 já fechada nesta rodada; o PR de outra rodada, com o mesmo número de issue, nunca foi visto
CASE=outra-rodada; round "$CASE"
echo '7-foo' > "$STATE/closed"
cat > "$FAKE/on-sleep-1" <<'SH'
fake-pr aaaaaaa1111111111111111111111111111111aa OPEN
SH
echo : > "$FAKE/on-sleep-2"
watch
check "outra rodada: código 0"                           [ "$RC" -eq 0 ]
check "outra rodada: sem [pr] para o PR de outra rodada" [ -z "$(log_events | grep -F '[pr]')" ]
check "outra rodada: sem [ci] nem [conflito]"            [ -z "$(log_events | grep -E '^\[(ci|conflito)\]')" ]
# b) a sessão #7 aberta nesta rodada: o PR com o número dela entra (o caso de antes continua valendo)
CASE=minha-rodada; round "$CASE"
cat > "$FAKE/on-sleep-1" <<'SH'
fake-pr aaaaaaa1111111111111111111111111111111aa OPEN
SH
echo : > "$FAKE/on-sleep-2"
watch
check "minha rodada: PR da sessão aberta entra"          logged "[pr] PR #12 aberto (issue #7) https://github.com/x/y/pull/12"
# c) sessão fechada da própria rodada: o PR que o watch já tinha visto segue acompanhado até o merge
CASE=fechada-vista; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
cat > "$FAKE/on-sleep-1" <<'SH'
fake-pr aaaaaaa1111111111111111111111111111111aa OPEN '[{"name":"test","conclusion":"FAILURE","completedAt":"2026-06-01T00:05:00Z"}]'
echo '7-foo' >> "$STATE/closed"
SH
cat > "$FAKE/on-sleep-2" <<'SH'
fake-pr aaaaaaa1111111111111111111111111111111aa MERGED
SH
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_ISSUE_DELAY=0 watch
check "fechada vista: código 0"                          [ "$RC" -eq 0 ]
check "fechada vista: CI do PR depois do close"          logged "[ci] PR #12 · test: fail"
check "fechada vista: mergeado depois do close"          logged "[pr] PR #12 mergeado (issue #7)"
check "fechada vista: log = stdout"                      [ "$(log_events)" == "$(out_events)" ]
check_end
