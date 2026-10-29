#!/usr/bin/env bash
# Testes do oute-swarm, tema: `premerge`, a conferência de antes do merge, sem modelo (#752).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh); a origin é um repositório local.
# Uso: tests/oute-swarm-premerge.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'guarda_stop; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/otlp.sh"
guarda_start "$TMP/guarda"
rcv_stop   # sem receptor neste arquivo: porta fechada, nenhum evento alcança o coletor (a guarda, sem receptor, não vê nada, #815)
. "$ROOT/tests/lib/swarm.sh"

# pm <caso>: rodada com o repo ligado a uma origin local (branch main, um commit); BASE = o sha da origin/main
pm() {
  local caso="$1"
  round "$caso"
  git init -q --bare "$TMP/$caso/origin.git"
  git -C "$REPO" -c user.email=t@t -c user.name=t checkout -q -b main
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$REPO" remote add origin "$TMP/$caso/origin.git"
  git -C "$REPO" push -q origin main
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  HEAD1=aaaaaaa1111111111111111111111111111111aa
  return 0
}
# prv <pr> <estado> <head> <mergeable> <checks json>: o `gh pr view` falso do PR
prv() {
  local pr="$1" estado="$2" cabeca="$3" mergeavel="$4" checks="$5"
  jq -n --arg s "$estado" --arg h "$cabeca" --arg m "$mergeavel" --argjson c "$checks" \
    '{state: $s, headRefOid: $h, baseRefName: "main", mergeable: $m, statusCheckRollup: $c}' > "$FAKE/prview-$pr.json"
  return 0
}
# rcout <código> <texto>: o código de saída do último `sw` e o texto na saída (rcerr: no stderr), sem regex
rcout() { local rc="$1" txt="$2"; [[ "$RC" -eq "$rc" ]] && grep -qF -- "$txt" <<<"$OUT"; return $?; }
rcerr() { local rc="$1" txt="$2"; [[ "$RC" -eq "$rc" ]] && grep -qF -- "$txt" <<<"$ERR"; return $?; }
GREEN='[{"name":"test","conclusion":"SUCCESS"},{"name":"SonarCloud Code Analysis","conclusion":"SUCCESS"}]'
NOSONAR='[{"name":"test","conclusion":"SUCCESS"}]'
# oute-sonar falso: `project` answers by $FAKE/sonar-project (exists | absent = exit 5 | token = 3 | net = 4); no file = exists
cat > "$BIN/oute-sonar" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/sonar.log"
case "$(cat "$FAKE/sonar-project" 2>/dev/null || echo exists)" in
  absent) exit 5 ;;
  token) exit 3 ;;
  net) exit 4 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/oute-sonar"

# 1. tudo em ordem: código 0 e uma linha que diz head, base e CI
CASE=ok; pm "$CASE"; prv 12 OPEN "$HEAD1" MERGEABLE "$GREEN"
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "ok: código 0"                                     [ "$RC" -eq 0 ]
check "ok: uma linha só"                                 [ "$(wc -l <<<"$OUT")" -eq 1 ]
check "ok: a linha diz head, base e CI com SonarCloud"   grep -qF "premerge #12: ok, head ${HEAD1:0:7}, base ${BASE:0:7} em main, CI verde com SonarCloud" <<<"$OUT"
sw premerge '#12' --head "${HEAD1:0:7}" --base "${BASE:0:7}"
check "ok: aceita #12 e sha de 7 caracteres"             [ "$RC" -eq 0 ]
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","state":"SUCCESS"},{"name":"SonarCloud Code Analysis","conclusion":"SUCCESS"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "ok: SUCCESS por state conta como verde"          [ "$RC" -eq 0 ]
for c in NEUTRAL SKIPPED; do
  prv 12 OPEN "$HEAD1" MERGEABLE "[{\"name\":\"test\",\"conclusion\":\"SUCCESS\"},{\"name\":\"SonarCloud Code Analysis\",\"conclusion\":\"$c\"}]"
  sw premerge 12 --head "$HEAD1" --base "$BASE"
  check "SonarCloud $c: código 4 e o pulou (não é verde)"  rcout 4 "CI não verde (pulou: SonarCloud Code Analysis)"
done
# check de revisor externo pulado não bloqueia (CodeRabbit SKIPPED, kaizen swarm-1027-0802): ok com o pulou na linha;
# check pendente de outro vem antes do pulou na classificação
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","conclusion":"SUCCESS"},{"name":"CodeRabbit","conclusion":"SKIPPED"},{"name":"SonarCloud Code Analysis","conclusion":"SUCCESS"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "check externo pulado: código 0"                    [ "$RC" -eq 0 ]
check "check externo pulado: o pulou sai na linha"        grep -qF "CI verde com SonarCloud (pulou: CodeRabbit), aberto e sem conflito" <<<"$OUT"
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","conclusion":"SUCCESS"},{"name":"CodeRabbit","conclusion":"SKIPPED"},{"name":"outro","status":"IN_PROGRESS"},{"name":"SonarCloud Code Analysis","conclusion":"SUCCESS"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "check pendente vence o pulado: código 4"           rcout 4 "CI não verde (pendente: outro)"
prv 12 OPEN "$HEAD1" UNKNOWN "$GREEN"
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "mergeable UNKNOWN: código 5, não é sem conflito" rcout 5 "mergeable UNKNOWN"

# 2. head diferente do auditado: 2
prv 12 OPEN bbbbbbb2222222222222222222222222222222bb MERGEABLE "$GREEN"
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "head: código 2"                                   [ "$RC" -eq 2 ]
check "head: a linha diz auditado e atual"               grep -qF "recusado, head mudou (auditado aaaaaaa, atual bbbbbbb)" <<<"$OUT"

# 3. base que andou na origin: 3
prv 12 OPEN "$HEAD1" MERGEABLE "$GREEN"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m outro-merge
git -C "$REPO" push -q origin main
NEWBASE="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" reset -q --hard "$BASE"; git -C "$REPO" update-ref -d refs/remotes/origin/main
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "base: código 3"                                   [ "$RC" -eq 3 ]
check "base: a linha diz ensaiada e atual"               grep -qF "recusado, base mudou (ensaiada ${BASE:0:7}, atual ${NEWBASE:0:7} em main)" <<<"$OUT"
sw premerge 12 --head "$HEAD1" --base "$NEWBASE"
check "base: com a base nova no comando, passa"          [ "$RC" -eq 0 ]

# 4. CI não verde: 4, em cada forma
CASE=ci; pm "$CASE"
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","conclusion":"FAILURE"},{"name":"SonarCloud Code Analysis","conclusion":"SUCCESS"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "ci vermelho: código 4 e o nome do check"          rcout 4 "CI não verde (falhou: test)"
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","conclusion":"SUCCESS"},{"name":"SonarCloud Code Analysis","conclusion":""}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "ci pendente: código 4 e o nome do check"          rcout 4 "CI não verde (pendente: SonarCloud Code Analysis)"
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","conclusion":"SUCCESS"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "sem SonarCloud: código 4 (verde sem ele não vale)" rcout 4 "pendente: sem o SonarCloud Code Analysis"
prv 12 OPEN "$HEAD1" MERGEABLE '[]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "sem checks: código 4"                             rcout 4 "pendente: sem checks"

# 4b. sem o check do SonarCloud: passa só se o repo não tem projeto no SonarCloud (oute-sonar project = 5)
CASE=sonar; pm "$CASE"
echo absent > "$FAKE/sonar-project"
prv 12 OPEN "$HEAD1" MERGEABLE "$NOSONAR"; sw premerge 12 --head "$HEAD1" --base "$BASE"
check "sem projeto no SonarCloud: código 0"              [ "$RC" -eq 0 ]
check "sem projeto: a linha diz o repo e o CI verde"     grep -qF "CI verde (no SonarCloud project for this repo), aberto e sem conflito" <<<"$OUT"
check "sem projeto: perguntou ao oute-sonar project"     grep -qx 'project' "$FAKE/sonar.log"
echo exists > "$FAKE/sonar-project"
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "projeto existe e o check falta: código 4"         rcout 4 "pendente: sem o SonarCloud Code Analysis"
echo net > "$FAKE/sonar-project"
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "oute-sonar sem resposta (4): código 4"            rcout 4 "pendente: sem o SonarCloud Code Analysis"
echo token > "$FAKE/sonar-project"
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "oute-sonar sem token (3): código 4"               rcout 4 "pendente: sem o SonarCloud Code Analysis"
echo absent > "$FAKE/sonar-project"; : > "$FAKE/sonar.log"
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","conclusion":"FAILURE"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "sem projeto, outro check falhou: código 4"        rcout 4 "falhou: test"
check "sem projeto, outro check falhou: nem consulta"    [ ! -s "$FAKE/sonar.log" ]
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","status":"IN_PROGRESS"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "sem projeto, outro check pendente: código 4"      rcout 4 "pendente: test"
prv 12 OPEN "$HEAD1" MERGEABLE '[]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "sem projeto, sem checks: código 4"                rcout 4 "pendente: sem checks"
prv 12 OPEN "$HEAD1" MERGEABLE '[{"name":"test","conclusion":"SUCCESS"},{"name":"SonarCloud Code Analysis","conclusion":"NEUTRAL"}]'
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "check presente e não verde, projeto sem: código 4" rcout 4 "CI não verde (pulou: SonarCloud Code Analysis)"
check "check presente: não consulta o oute-sonar"        [ ! -s "$FAKE/sonar.log" ]

# 5. estado do PR: 5 (fechado, mergeado, em conflito), e vale antes do head
CASE=estado; pm "$CASE"
for st in MERGED CLOSED; do
  prv 12 "$st" "$HEAD1" MERGEABLE "$GREEN"; sw premerge 12 --head "$HEAD1" --base "$BASE"
  check "estado $st: código 5 e a linha"                 rcout 5 "PR $st (não está aberto)"
done
prv 12 OPEN "$HEAD1" CONFLICTING "$GREEN"; sw premerge 12 --head "$HEAD1" --base "$BASE"
check "conflito: código 5"                               rcout 5 "em conflito com a base"
prv 12 MERGED bbbbbbb2222222222222222222222222222222bb MERGEABLE "$GREEN"; sw premerge 12 --head "$HEAD1" --base "$BASE"
check "estado vem antes do head (mergeado com head novo = 5)" [ "$RC" -eq 5 ]

# 6. sem resposta do gh ou do git: 6
CASE=falha; pm "$CASE"
rm -f "$FAKE/prview-12.json"; sw premerge 12 --head "$HEAD1" --base "$BASE"
check "gh sem resposta: código 6"                        rcout 6 "sem resposta do gh"
prv 12 OPEN "$HEAD1" MERGEABLE "$GREEN"; git -C "$REPO" remote set-url origin "$TMP/$CASE/nao-existe.git"
sw premerge 12 --head "$HEAD1" --base "$BASE"
check "git sem resposta: código 6"                       rcout 6 "sem resposta do git (origin/main)"

# 7. uso
sw premerge 12 --head "$HEAD1"
check "sem --base: erro de uso, código 1"                rcerr 1 "uso: oute-swarm premerge"
sw premerge 12 --head xyz --base "$BASE"
check "sha que não é hex: erro de uso"                   [ "$RC" -eq 1 ]
sw premerge --head "$HEAD1" --base "$BASE"
check "sem PR: erro de uso"                              [ "$RC" -eq 1 ]
sw premerge 12 --head "$HEAD1" --base "$BASE" --nada
check "opção desconhecida: código 1"                     rcerr 1 "opção desconhecida: --nada"

guarda_check
guarda_stop
check_end
