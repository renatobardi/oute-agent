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
. "$ROOT/tests/lib/otlp.sh"
guarda_start "$TMP/guarda"
rcv_stop   # sem receptor neste arquivo: porta fechada, nenhum evento alcança o coletor (a guarda, sem receptor, não vê nada, #815)
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

# 4b. sessão sem issue (#825): o evento [sessao] sai com o slug como rótulo, sem #, e sem PR associado
CASE=sem-issue; round "$CASE"
printf 'levantar w1:p2 claude 2026-01-01T00:00:02Z w1:t2\n' >> "$STATE/spawned"
FAKE="$FAKE" "$BIN/fake-tabs" '#7 foo=working' 'levantar=working'
echo 'fake-tabs idle levantar=idle' > "$FAKE/on-sleep-1"
watch
check "sem issue: código 0"                              [ "$RC" -eq 0 ]
check "sem issue: evento com o slug, sem #"             logged "[sessao] levantar: idle (sem PR)"
check "sem issue: sem evento com # vazio"               bash -c '! grep -qF "[sessao] # levantar" <<<"$1"' _ "$(log_events)"

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
cp "\$STATE/log" "\$FAKE/log.p2" 2>/dev/null || : > "\$FAKE/log.p2"
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
cp "\$STATE/log" "\$FAKE/log.p2" 2>/dev/null || : > "\$FAKE/log.p2"
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
# 9. CI verde numa linha só (#487): todos os checks do head passam = uma linha com o head e a lista (com o SonarCloud);
# falha e pendência seguem uma linha por check
succ() {
  local name="$1"
  printf '{"name":"%s","conclusion":"SUCCESS","completedAt":"2026-06-01T00:05:00Z"}' "$name"
  return $?
}
ALL="[$(succ checks),$(succ lint),$(succ 'SonarCloud Code Analysis')]"
CASE=verde; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $A OPEN '$ALL'
SH
echo : > "$FAKE/on-sleep-2"
watch
check "verde: código 0"                                  [ "$RC" -eq 0 ]
check "verde: uma linha com o head e os checks"          [ "$(ci_events)" == "[ci] PR #12 · verde (head aaaaaaa): SonarCloud Code Analysis, checks, lint" ]
check "verde: log = stdout"                              [ "$(log_events)" == "$(out_events)" ]
watch
check "verde: não repete depois do reinício"             [ "$(count "$(ci_events)")" -eq 1 ]

CASE=verdependente; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $A OPEN '[$(succ checks),{"name":"SonarCloud Code Analysis","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-06-01T00:01:00Z","completedAt":"0001-01-01T00:00:00Z"}]'
cp "\$STATE/log" "\$FAKE/log.p2" 2>/dev/null || : > "\$FAKE/log.p2"
SH
cat > "$FAKE/on-sleep-2" <<SH
fake-pr $A OPEN '[$(succ checks),$(succ 'SonarCloud Code Analysis')]'
SH
echo : > "$FAKE/on-sleep-3"
watch
check "pendente: nenhuma linha de CI enquanto um check roda" [ -z "$(grep -F '[ci]' "$FAKE/log.p2")" ]
check "pendente: a linha única sai quando o último passa" [ "$(ci_events)" == "[ci] PR #12 · verde (head aaaaaaa): SonarCloud Code Analysis, checks" ]

CASE=verdefalha; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
cat > "$FAKE/on-sleep-1" <<SH
fake-pr $A OPEN '[$(succ checks),{"name":"lint","conclusion":"FAILURE","completedAt":"2026-06-01T00:05:00Z"}]'
SH
echo : > "$FAKE/on-sleep-2"
watch
check "falha: uma linha para o check que falhou"         [ "$(ci_events)" == "[ci] PR #12 · lint: fail" ]

# 455. [canal]: o `# sessao:` do cabeçalho do pedido marca (da rodada) ou (alheio); sem o campo, sem marca
CASE=canal; round "$CASE"
cat > "$FAKE/on-sleep-1" <<'SH'
ped() {
  local id="$1" titulo="$2" extra="$3"
  printf '# oute-propose\n# titulo: %s\n# como: user\n# agente: claude\n# criado: 2026-06-01T00:00:00Z\n%s\necho x\n' "$titulo" "$extra" > "$OUTE_OUTBOX/$id.sh"
  return 0
}
ped a-rodada  "ajuste do deploy"        "# sessao: 7-foo"
ped b-alheio  "ajuste do deploy"        "# sessao: 99-outra-rodada"
ped c-antigo  "ajuste #7 sem o campo"   ""
SH
echo : > "$FAKE/on-sleep-2"
watch
check "canal: sessão da rodada leva (da rodada)"          logged "[canal] pedido pendente a-rodada: ajuste do deploy (agente claude, user) (da rodada) — aprovação no host: oute watch"
check "canal: sessão de fora leva (alheio)"               logged "[canal] pedido pendente b-alheio: ajuste do deploy (agente claude, user) (alheio) — aprovação no host: oute watch"
check "canal: pedido antigo sem o campo fica como era"    logged "[canal] pedido pendente c-antigo: ajuste #7 sem o campo (agente claude, user) — aprovação no host: oute watch"

# 873. [canal] resultado: rc 0 sai para pedido da rodada (pelo # rodada: ou # sessao: do .sh, já movido para done/ ou
# rejected/) e não sai para alheio; rc≠0 e recusa seguem saindo para todo pedido. res() cria o .out no inbox e o .sh em
# <outbox>/<done|rejected>/, como o approve entrega no container
CASE=resultado-zero; round "$CASE"
cat > "$FAKE/on-sleep-1" <<'SH'
res() {
  local id="$1" rc="$2" extra="$3" pasta="$4"
  printf '# id: %s\n# rc: %s\n# como: user\n# aprovado: 2026-06-01T00:01:00Z por t@h\n# sha256: x\n# duracao: 1 s\n# saida: 2 bytes\n\nok\n' "$id" "$rc" > "$OUTE_INBOX/$id.out"
  mkdir -p "$OUTE_OUTBOX/$pasta"
  printf '# oute-propose\n# titulo: t\n# como: user\n# agente: claude\n# criado: 2026-06-01T00:00:00Z\n%s\necho x\n' "$extra" > "$OUTE_OUTBOX/$pasta/$id.sh"
  return 0
}
res d-zero 0 "# rodada: swarm-test" done
res e-alheio 0 "# rodada: swarm-outra" done
res f-sem-campo 0 "" rejected
SH
echo : > "$FAKE/on-sleep-2"
watch
check "rc 0: pedido da rodada sai, uma vez"               logged "[canal] resultado d-zero: rc=0 (oute-inbox d-zero)"
check "rc 0: pedido de outra rodada não sai"              bash -c '! grep -qF "[canal] resultado e-alheio" <<<"$1"' _ "$(log_events)"
check "rc 0: sem cabeçalho de rodada não sai"             bash -c '! grep -qF "[canal] resultado f-sem-campo" <<<"$1"' _ "$(log_events)"
check "rc 0: log = stdout"                                [ "$(log_events)" == "$(out_events)" ]
watch
check "rc 0: não repete depois do reinício"               [ "$(count "[canal] resultado d-zero: rc=0 (oute-inbox d-zero)")" -eq 1 ]

# rc≠0 e recusa de pedido alheio ou sem .sh continuam saindo; rc 0 de sessão da rodada (spawned) também sai
CASE=resultado-outros; round "$CASE"
cat > "$FAKE/on-sleep-1" <<'SH'
res() {
  local id="$1" rc="$2" extra="$3" pasta="$4"
  printf '# id: %s\n# rc: %s\n# como: user\n# aprovado: 2026-06-01T00:01:00Z por t@h\n# sha256: x\n# duracao: 1 s\n# saida: 2 bytes\n\nok\n' "$id" "$rc" > "$OUTE_INBOX/$id.out"
  mkdir -p "$OUTE_OUTBOX/$pasta"
  printf '# oute-propose\n# titulo: t\n# como: user\n# agente: claude\n# criado: 2026-06-01T00:00:00Z\n%s\necho x\n' "$extra" > "$OUTE_OUTBOX/$pasta/$id.sh"
  return 0
}
res g-erro 2 "# rodada: swarm-outra" done
res h-recusa 126 "" rejected
printf '# id: h-recusa\n# rc: 126\n# recusado: 2026-06-01T00:00:30Z por t@h\n# sha256: x\n\nrecusado pelo usuário; nada foi executado.\n' > "$OUTE_INBOX/h-recusa.out"
res i-sessao 0 "# sessao: 7-foo" done
printf '# id: j-sem-sh\n# rc: 1\n\nfalhou\n' > "$OUTE_INBOX/j-sem-sh.out"
SH
echo : > "$FAKE/on-sleep-2"
watch
check "rc≠0: pedido de outra rodada sai como antes"       logged "[canal] resultado g-erro: rc=2 (oute-inbox g-erro)"
check "recusa: sai como antes"                            logged "[canal] pedido h-recusa recusado no host"
check "rc 0: sessão da rodada (spawned) sai"              logged "[canal] resultado i-sessao: rc=0 (oute-inbox i-sessao)"
check "rc≠0: sem o .sh também sai"                        logged "[canal] resultado j-sem-sh: rc=1 (oute-inbox j-sem-sh)"

# 766. pendência parada (#766, da #767): PR aberto, CI vermelho ou sessão `done` sem PR, 30 minutos (OUTE_WATCH_STALL_S, padrão
# 1800 s) sem mudar, saem numa linha `[pendencia]`; sem pendência, nada. O relógio é o arquivo OUTE_WATCH_CLOCK (epoch)
pend_events() {
  log_events | grep -F '[pendencia]' || true
  return 0
}
clock() {
  local epoch="$1"
  echo "$epoch" > "$FAKE/clock"
  return 0
}
# hook <n> <epoch> [<comando extra>]: o gancho da passada <n> avança o relógio e, se pedido, muda o estado
hook() {
  local n="$1" epoch="$2" extra="${3:-:}"
  printf 'echo %s > "$FAKE/clock"\n%s\n' "$epoch" "$extra" > "$FAKE/on-sleep-$n"
  return 0
}
T0=1800000000

# PR aberto sem mudança: nada aos 28 min, uma linha aos 31, nada aos 36 nem aos 62, de novo aos 152 (repete a cada 2 h
# no máximo, OUTE_WATCH_PEND_REPEAT_S; antes repetia a cada 30 min e a mesma linha saiu 58 vezes, kaizen swarm-1027-0802)
CASE=pendparada; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
hook 1 $((T0 + 1680)); hook 2 $((T0 + 1860)); hook 3 $((T0 + 2160)); hook 4 $((T0 + 3720)); hook 5 $((T0 + 9120))
echo : > "$FAKE/on-sleep-6"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "pendência: código 0"                              [ "$RC" -eq 0 ]
check "pendência: PR aberto parado sai aos 31 min e só 2 h depois" [ "$(pend_events)" == "[pendencia] 1 parada(s) há 31 min ou mais, sem mudança: PR #12 aberto"$'\n'"[pendencia] 1 parada(s) há 152 min ou mais, sem mudança: PR #12 aberto" ]
check "pendência: a linha vai ao stdout, igual ao log"    [ "$(log_events)" == "$(out_events)" ]
clock $((T0 + 3800)); echo : > "$FAKE/on-sleep-1"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "pendência: reinício dentro das 2 h não repete (estado em disco)" [ "$(pend_events | wc -l | tr -d ' ')" -eq 2 ]

# o intervalo de repetição vem de OUTE_WATCH_PEND_REPEAT_S: com 1800 repete aos 62 min; valor inválido volta às 2 h
CASE=pendrepete; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
hook 1 $((T0 + 1860)); hook 2 $((T0 + 3720)); hook 3 $((T0 + 3721))
echo : > "$FAKE/on-sleep-4"
OUTE_WATCH_PEND_REPEAT_S=1800 OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "repetição: com 1800 s, a linha dos 62 min sai"     [ "$(pend_events | sed -n 2p)" == "[pendencia] 1 parada(s) há 62 min ou mais, sem mudança: PR #12 aberto" ]
OUTE_WATCH_PEND_REPEAT_S=abc OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "repetição: valor inválido volta ao padrão de 2 h"  [ "$(pend_events | wc -l | tr -d ' ')" -eq 2 ]

# mudança zera o relógio: o CI fica vermelho aos 33 min; só 30 min depois dessa mudança a pendência sai, com o check
CASE=pendmuda; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
hook 1 $((T0 + 1700))
hook 2 $((T0 + 2000)) "fake-pr $A OPEN '[{\"name\":\"lint\",\"conclusion\":\"FAILURE\",\"completedAt\":\"2026-06-01T00:05:00Z\"}]'"
hook 3 $((T0 + 3000)) 'cp "$STATE/log" "$FAKE/log.p4" 2>/dev/null || : > "$FAKE/log.p4"'
hook 4 $((T0 + 3900))
echo : > "$FAKE/on-sleep-5"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "muda: nada antes de 30 min da última mudança"     [ -z "$(grep -F '[pendencia]' "$FAKE/log.p4")" ]
check "muda: sai com o check vermelho, contado da mudança" [ "$(pend_events)" == "[pendencia] 1 parada(s) há 31 min ou mais, sem mudança: PR #12 aberto, CI vermelho: lint" ]

# sessão done sem PR sai; PR mergeado com a sessão done, e sessão working sem PR, não são pendência
CASE=pendsessao; round "$CASE"
clock "$T0"
hook 1 $((T0 + 100)) "fake-tabs done"; hook 2 $((T0 + 2000))
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "sessão: done sem PR, parada, sai"                 [ "$(pend_events)" == "[pendencia] 1 parada(s) há 31 min ou mais, sem mudança: #7 foo: done sem PR" ]

CASE=pendnada; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" MERGED
clock "$T0"
hook 1 $((T0 + 100)) "fake-tabs done"; hook 2 $((T0 + 9000)); hook 3 $((T0 + 20000))
echo : > "$FAKE/on-sleep-4"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "sem pendência: PR mergeado e sessão done com PR, nada" [ -z "$(pend_events)" ]

CASE=pendtrabalha; round "$CASE"
clock "$T0"
hook 1 $((T0 + 9000))
echo : > "$FAKE/on-sleep-2"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "sem pendência: sessão working sem PR, nada"        [ -z "$(pend_events)" ]

# o prazo vem de OUTE_WATCH_STALL_S; valor inválido volta ao padrão de 1800
CASE=pendprazo; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
hook 1 $((T0 + 700)); hook 2 $((T0 + 1000))
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_STALL_S=600 OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "prazo: 600 s, sai aos 11 min"                     [ "$(pend_events)" == "[pendencia] 1 parada(s) há 11 min ou mais, sem mudança: PR #12 aberto" ]
CASE=pendinvalido; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
hook 1 $((T0 + 1000))
echo : > "$FAKE/on-sleep-2"
OUTE_WATCH_STALL_S=abc OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "prazo: valor inválido usa 1800 s, nada aos 16 min" [ -z "$(pend_events)" ]

# 821, L4: pendência com pergunta ao Bardi sem resposta sobre o item não sai; sem pergunta sai (acima); outro item sai;
# depois da resposta, sai. A pergunta casa com o número inteiro: "#12" não casa com "#120"
CASE=pendpergunta; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
echo "$(date -u +%FT%TZ) pergunta PR #12: mergear agora? 1 sim 2 não" >> "$STATE/log"
hook 1 $((T0 + 1860)); hook 2 $((T0 + 3720))
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "L4 pergunta aberta: código 0"                      [ "$RC" -eq 0 ]
check "L4 pergunta aberta sobre o PR: nada sai, nem aos 62 min" [ -z "$(pend_events)" ]

CASE=pendoutra; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
echo "$(date -u +%FT%TZ) pergunta PR #120: outra coisa? 1 sim 2 não" >> "$STATE/log"
hook 1 $((T0 + 1860))
echo : > "$FAKE/on-sleep-2"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "L4 pergunta sobre #120 não segura o PR #12"        [ "$(pend_events)" == "[pendencia] 1 parada(s) há 31 min ou mais, sem mudança: PR #12 aberto" ]

# #821 (achado 6 da auditoria do #823): o número sem borda à esquerda casava com outro repo ("outro#12" calava o #12)
CASE=pendoutrorepo; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
echo "$(date -u +%FT%TZ) pergunta outro#12: mesma coisa? 1 sim 2 não" >> "$STATE/log"
hook 1 $((T0 + 1860))
echo : > "$FAKE/on-sleep-2"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "L4 pergunta sobre outro#12 não segura o #12 deste repo" [ "$(pend_events)" == "[pendencia] 1 parada(s) há 31 min ou mais, sem mudança: PR #12 aberto" ]

# #821 (achado 1 da reauditoria do #823): `PR#12` e `<repo da rodada>#12` (aqui `repo`) calam o #12; `outro#12` não (acima)
CASE=pendformas; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
echo "$(date -u +%FT%TZ) pergunta PR#12: mergear? 1 sim 2 não" >> "$STATE/log"
echo "$(date -u +%FT%TZ) pergunta repo#12: mergear? 1 sim 2 não" >> "$STATE/log"
hook 1 $((T0 + 1860)); hook 2 $((T0 + 3720))
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "L4 PR#12 e repo#12 calam o #12 deste repo"         [ -z "$(pend_events)" ]

CASE=pendrespondida; round "$CASE"
FAKE="$FAKE" "$BIN/fake-pr" "$A" OPEN
clock "$T0"
echo "$(date -u +%FT%TZ) pergunta PR #12: mergear agora? 1 sim 2 não" >> "$STATE/log"
hook 1 $((T0 + 1860)); hook 2 $((T0 + 2100)) 'echo "$(date -u +%FT%TZ) resposta" >> "$STATE/log"'
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "L4 pergunta respondida: a pendência volta a sair, com o relógio de antes" [ "$(pend_events)" == "[pendencia] 1 parada(s) há 35 min ou mais, sem mudança: PR #12 aberto" ]

# a sessão `done` sem PR também é item: a pergunta sobre "#7 foo" segura a pendência dela
CASE=pendsessaopergunta; round "$CASE"
echo "$(date -u +%FT%TZ) pergunta #7 foo: continuar a sessão? 1 sim 2 não" >> "$STATE/log"
clock "$T0"
hook 1 $((T0 + 100)) "fake-tabs done"; hook 2 $((T0 + 2000))
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "L4 sessão com pergunta aberta: nada sai"           [ -z "$(pend_events)" ]

# 821, L3: o religar (chamado pelo boot do container) põe um watch em cada rodada aberta com sessão; a rodada fechada e a
# sem `spawned` ficam como estão. O watch religado roda em segundo plano e termina sozinho (a rodada fecha no sleep falso)
CASE=religar; round "$CASE"
FECHADA="$H/.oute/swarm/swarm-fechada"; SEMSESS="$H/.oute/swarm/swarm-semsessao"
mkdir -p "$FECHADA" "$SEMSESS"
cp "$STATE/meta" "$STATE/spawned" "$FECHADA/"; touch "$FECHADA/fechada"
cp "$STATE/meta" "$SEMSESS/"; : > "$SEMSESS/spawned"
OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" STATE="$STATE" FAKE_WATCH=1 \
       OUTE_INBOX="$TMP/$CASE/inbox" OUTE_OUTBOX="$TMP/$CASE/outbox" "$SWARM" religar 2>"$FAKE/err")"; RC=$?
check "religar: código 0"                                 [ "$RC" -eq 0 ]
check "religar: anuncia só a rodada aberta com sessão"     [ "$OUT" == "watch religado: swarm-test" ]
for _ in $(seq 1 100); do grep -qF 'watch encerrado' "$STATE/log" 2>/dev/null && break; /bin/sleep 0.1; done
check "religar: o watch da rodada aberta roda e termina"  logged "[rodada] swarm-test fechada (oute-swarm close --all); watch encerrado"
check "religar: rodada fechada não ganha watch"           [ ! -e "$FECHADA/watch.out" -a ! -e "$FECHADA/watch.pid" ]
check "religar: rodada sem sessão não ganha watch"        [ ! -e "$SEMSESS/watch.out" -a ! -e "$SEMSESS/watch.pid" ]
# o boot chama o religar depois do herdr server (sem ele, o watch sobe antes do herdr e falha na primeira passada)
check "religar: o entrypoint chama religar depois do herdr server" bash -c 'l="$(grep -n "herdr server start" "$1/docker/entrypoint.sh" | head -1 | cut -d: -f1)"; r="$(grep -n "oute-swarm religar" "$1/docker/entrypoint.sh" | head -1 | cut -d: -f1)"; [[ -n "$l" && -n "$r" && "$r" -gt "$l" ]]' _ "$ROOT"

# #821 (achado 2 da auditoria do #823): o religar não troca um watch vivo da rodada; com watch.pid de processo morto, religa
# rel_religar: roda o religar do caso (saída em $OUT, sem o watch em segundo plano preso na captura)
rel_religar() {
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" STATE="$STATE" FAKE_WATCH=1 \
         OUTE_INBOX="$TMP/$CASE/inbox" OUTE_OUTBOX="$TMP/$CASE/outbox" "$SWARM" religar 2>"$FAKE/err")"; RC=$?
  return 0
}
CASE=religarvivo; round "$CASE"
# exec -a: o próprio sleep vira o watch no /proc (um só processo, que o kill encerra)
bash -c 'exec -a "oute-swarm watch --round swarm-test" sleep 60' </dev/null >/dev/null 2>&1 & LIVE=$!
echo "$LIVE" > "$STATE/watch.pid"
rel_religar
check "religar: watch vivo não é trocado (aviso na saída)" [ "$OUT" == "watch já ativo, sem religar: swarm-test" ]
check "religar: watch vivo não ganha um segundo watch"    [ ! -e "$STATE/watch.out" ]
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null || true

# NIT 4 da reauditoria: `watch --round swarm-test-2` (outra rodada, id que começa igual) não conta como watch vivo de swarm-test
CASE=religarprefixo; round "$CASE"
bash -c 'exec -a "oute-swarm watch --round swarm-test-2" sleep 60' </dev/null >/dev/null 2>&1 & LIVE=$!
echo "$LIVE" > "$STATE/watch.pid"
rel_religar
check "religar: id que começa igual não pula a rodada"    [ "$OUT" == "watch religado: swarm-test" ]
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null || true
for _ in $(seq 1 100); do grep -qF 'watch encerrado' "$STATE/log" 2>/dev/null && break; /bin/sleep 0.1; done

CASE=religarmorto; round "$CASE"
bash -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null || true
echo "$DEAD" > "$STATE/watch.pid"
rel_religar
check "religar: watch.pid de processo morto religa a rodada" [ "$OUT" == "watch religado: swarm-test" ]
for _ in $(seq 1 100); do grep -qF 'watch encerrado' "$STATE/log" 2>/dev/null && break; /bin/sleep 0.1; done

guarda_check
guarda_stop
check_end
