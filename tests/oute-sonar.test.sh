#!/usr/bin/env bash
# Testes do `oute-sonar` (#226): leitura do SonarCloud (gate, issues, hotspots) de um PR ou da main, só GET em
# https://sonarcloud.io. Um `curl` falso no PATH guarda o que recebeu (método, endereço, argv) e responde com
# fixtures; confere o token pelo arquivo de configuração do stdin (`-K -`). Token sentinela gerado na hora, nunca real.
# Só comportamento externo: stdout, stderr, código de saída e as chamadas que o curl falso viu.
# Uso: tests/oute-sonar.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v openssl >/dev/null && command -v git >/dev/null || die "precisa de jq, openssl e git"
SONAR="$ROOT/docker/oute-sonar"
[[ -x "$SONAR" ]] || die "oute-sonar ausente ou sem +x: $SONAR"

BIN="$TMP/bin"; FAKE="$TMP/fake"; mkdir -p "$BIN" "$FAKE" "$TMP/nogit"
TOK="sntl$(openssl rand -hex 12)"
cat > "$BIN/curl" <<'CURL'
#!/usr/bin/env bash
# curl falso: só aceita GET em https://sonarcloud.io/…; token conferido no arquivo de configuração do stdin
args=("$@"); out=""; fmt=""; cfg=0; url=""; viol=""; i=0
while [ $i -lt $# ]; do
  a="${args[$i]}"
  case "$a" in
    -X|--request) [ "${args[$((i+1))]}" = GET ] || viol="método ${args[$((i+1))]}"; i=$((i+1)) ;;
    -d|--data*|-F|--form*|-T|--upload-file|-I|--head|--json) viol="opção $a" ;;
    -o) out="${args[$((i+1))]}"; i=$((i+1)) ;;
    -w) fmt="${args[$((i+1))]}"; i=$((i+1)) ;;
    -K) cfg=1; i=$((i+1)) ;;
    --proto|--max-time) i=$((i+1)) ;;
    -*) ;;
    *) url="$a" ;;
  esac
  i=$((i+1))
done
printf '%s\n' "$*" >> "$FAKE/argv.log"
[ "$cfg" = 1 ] && conf="$(cat)" || conf=""
case "$url" in https://sonarcloud.io/*) ;; *) viol="${viol:+$viol; }endereço fora de https://sonarcloud.io/: $url" ;; esac
if [ -n "$viol" ]; then echo "VIOLATION $viol" >> "$FAKE/curl.log"; exit 7; fi
echo "GET $url" >> "$FAKE/curl.log"
[ -z "${FAKE_NET_FAIL:-}" ] || exit 6
p="${url#https://sonarcloud.io/}"; path="${p%%\?*}"; q="${p#*\?}"; name="${path//\//_}"; ident=""
case "$name" in
  api_issues_changelog) ident="$(grep -o 'issue=[^&]*' <<<"$q" | cut -d= -f2)" ;;
  api_hotspots_show) ident="$(grep -o 'hotspot=[^&]*' <<<"$q" | cut -d= -f2)" ;;
esac
f="$FAKE/$name${ident:+.$ident}.json"; code=200
[ -f "$f" ] || { code=404; f=/dev/null; }
[ -f "$FAKE/$name.code" ] && code="$(cat "$FAKE/$name.code")"
if [ "$conf" != "header = \"Authorization: Bearer $FAKE_TOKEN\"" ]; then
  code=401; printf '{"errors":[{"msg":"token invalido %s"}]}' "$FAKE_TOKEN" > "$out"
else
  cat "$f" > "$out"
fi
printf '%s' "$code"
CURL
chmod +x "$BIN/curl"

fx() { cat > "$FAKE/$1.json"; }   # <nome> (stdin): fixture
fixtures() {
  rm -f "${FAKE:?}"/*.json "${FAKE:?}"/*.code
  fx api_project_pull_requests_list <<'J'
{"pullRequests":[{"key":"6","commit":{"sha":"0000"}},{"key":"7","commit":{"sha":"abc123def"},"analysisDate":"2026-10-01T10:00:00+0000"}]}
J
  fx api_project_branches_list <<'J'
{"branches":[{"name":"x","isMain":false,"commit":{"sha":"nope"}},{"name":"main","isMain":true,"commit":{"sha":"cafe9999"},"analysisDate":"2026-10-02T08:00:00+0000"}]}
J
  fx api_qualitygates_project_status <<'J'
{"projectStatus":{"status":"ERROR","conditions":[
 {"status":"OK","metricKey":"new_coverage","actualValue":"90","errorThreshold":"80","comparator":"LT"},
 {"status":"ERROR","metricKey":"new_security_rating","actualValue":"3","errorThreshold":"1","comparator":"GT"}]}}
J
  fx api_issues_search <<'J'
{"paging":{"total":3},"issues":[
 {"key":"AXopen","rule":"docker:S6505","severity":"MAJOR","status":"OPEN","component":"acme_demo:docker/Dockerfile","line":64,"message":"Evite scripts de instalação"},
 {"key":"AXfp","rule":"shell:S1234","severity":"MINOR","status":"RESOLVED","resolution":"FALSE-POSITIVE","component":"acme_demo:scripts/a.sh","line":3,"message":"achado aceito"},
 {"key":"AXwf","rule":"shell:S9999","severity":"INFO","status":"RESOLVED","resolution":"WONTFIX","component":"acme_demo:scripts/b.sh","message":"outro aceito"}]}
J
  fx api_issues_changelog.AXfp <<'J'
{"changelog":[{"user":"bot-login","creationDate":"2026-09-01T00:00:00+0000","diffs":[{"key":"assignee","newValue":"x"}]},
 {"user":"bot-login","creationDate":"2026-10-01T12:00:00+0000","diffs":[{"key":"resolution","newValue":"FALSE-POSITIVE"},{"key":"status","newValue":"RESOLVED"}]}]}
J
  fx api_issues_changelog.AXwf <<'J'
{"changelog":[{"user":"renato","creationDate":"2026-10-02T09:30:00+0000","diffs":[{"key":"resolution","newValue":"WONTFIX"}]}]}
J
  fx api_hotspots_search <<'J'
{"paging":{"total":2},"hotspots":[
 {"key":"HSopen","ruleKey":"shell:S4423","vulnerabilityProbability":"HIGH","status":"TO_REVIEW","component":"acme_demo:docker/x.sh","line":9,"message":"revisar esta chamada"},
 {"key":"HSsafe","ruleKey":"shell:S5332","vulnerabilityProbability":"LOW","status":"REVIEWED","resolution":"SAFE","component":"acme_demo:docker/y.sh","line":12,"message":"http interno"}]}
J
  fx api_hotspots_show.HSsafe <<'J'
{"changelog":[{"user":"bot-login","creationDate":"2026-10-02T15:45:00+0000","diffs":[{"key":"status","oldValue":"TO_REVIEW","newValue":"REVIEWED"},{"key":"resolution","newValue":"SAFE"}]}]}
J
}

REPO="$TMP/repo"; git init -q "$REPO"; git -C "$REPO" remote add origin git@github.com:acme/demo.git
export GIT_CEILING_DIRECTORIES="$TMP" FAKE FAKE_TOKEN="$TOK"

# run <args…>: oute-sonar no repo de teste, token sentinela; saída em $OUT, stderr em $ERR, código em $RC
# (WD muda o diretório; RUN_TOKEN: valor do SONAR_TOKEN, ou - para tirá-lo; RUN_ENV: variáveis extras; RUN_CMD: o comando)
WD="$REPO"; RUN_TOKEN="$TOK"; RUN_ENV=(); RUN_CMD=("$SONAR")
run() {
  : > "$FAKE/curl.log"; : > "$FAKE/argv.log"
  local envs=(); [[ "$RUN_TOKEN" = - ]] || envs=("SONAR_TOKEN=$RUN_TOKEN")
  OUT="$(cd "$WD" && env -u SONAR_TOKEN -u OUTE_SONAR_PROJECT -u OUTE_SONAR_ORG -u SHELLOPTS PATH="$BIN:$PATH" \
        ${envs[@]+"${envs[@]}"} ${RUN_ENV[@]+"${RUN_ENV[@]}"} "${RUN_CMD[@]}" "$@" 2>"$TMP/err" </dev/null)"; RC=$?
  ERR="$(cat "$TMP/err")"
}
rc_is() { [ "$RC" -eq "$1" ]; }
rc_nocall() { [ "$RC" -eq "$1" ] && [ ! -s "$FAKE/curl.log" ]; }
nocalls() { [ ! -s "$FAKE/curl.log" ]; }
err_has() { grep -qF -- "$1" <<<"$ERR"; }
err_hasnt() { ! err_has "$1"; }
log_has() { grep -qF -- "$1" "$FAKE/curl.log"; }
log_hasnt() { ! log_has "$1"; }
secret_free() { ! grep -qF -- "$TOK" <<<"$OUT"; }
secret_free_all() { secret_free && err_hasnt "$TOK" && ! grep -qF -- "$TOK" "$FAKE/argv.log" "$FAKE/curl.log"; }
json_is() { jq -e "$@" <<<"$OUT" >/dev/null; }

fixtures

echo "# 1. uso (saída 2, sem chamada de rede)"
for a in "" "pr" "pr abc" "pr 7x" "pr 7;id" "pr -1" "pr 7 8" "bogus" "main main" "pr 7 main"; do
  # shellcheck disable=SC2086
  run $a; check "uso: '$a' -> 2, sem rede" rc_nocall 2
done
RUN_ENV=(OUTE_SONAR_PROJECT="a b"); run main; check "chave com espaço -> 2, sem rede" rc_nocall 2
RUN_ENV=(OUTE_SONAR_PROJECT='a;b'); run main; check "chave com ; -> 2, sem rede" rc_nocall 2
RUN_ENV=(OUTE_SONAR_PROJECT='a&b=c'); run main; check "chave com & -> 2, sem rede" rc_nocall 2
RUN_ENV=(OUTE_SONAR_ORG='o rg'); run main; check "organização inválida -> 2, sem rede" rc_nocall 2
RUN_ENV=()
WD="$TMP/nogit"; run main; check "sem projeto e sem remoto origin -> 2, sem rede" rc_nocall 2
git init -q "$TMP/norem"; WD="$TMP/norem"; run main; check "repo sem origin -> 2" rc_nocall 2
WD="$REPO"
run --help; check "--help -> 0" rc_is 0

echo "# 2. sem token (saída 3, sem rede)"
RUN_TOKEN=-; run pr 7
check "sem SONAR_TOKEN -> 3" rc_is 3; check "sem token: mensagem clara" err_has "SONAR_TOKEN ausente"; check "sem token: sem rede" nocalls
RUN_TOKEN=""; run main; check "SONAR_TOKEN vazio -> 3" rc_nocall 3
RUN_TOKEN='a"b'; run main; check "token com aspas -> 3, sem rede" rc_nocall 3
check "token inválido não é repetido no erro" err_hasnt 'a"b'
RUN_TOKEN="$TOK"

echo "# 3. PR com gate reprovado (saída 1)"
run pr 7
check "gate ERROR -> 1" rc_is 1
check "mostra o commit analisado" has 'abc123def'
check "mostra a data da análise" has '2026-10-01'
check "gate: ERROR" has_line 'gate: ERROR'
check "condição reprovada, com atual e limite" has 'reprovou: new_security_rating  atual=3 limite=GT 1'
check "condição aprovada não aparece" hasnt 'new_coverage'
check "issue: regra, arquivo, linha e mensagem" has 'docker:S6505 MAJOR docker/Dockerfile:64  OPEN  Evite scripts de instalação'
check "issue FALSE-POSITIVE: quem e quando" has 'FALSE-POSITIVE \[FALSE-POSITIVE por bot-login em 2026-10-01T12:00:00+0000\]'
check "issue WONTFIX: quem e quando" has 'WONTFIX \[WONTFIX por renato em 2026-10-02T09:30:00+0000\]'
check "issue aberta não leva transição" bash -c '! grep -F "docker:S6505" <<<"$1" | grep -q "por "' _ "$OUT"
check "hotspot: regra, arquivo, linha e mensagem" has 'shell:S4423 HIGH docker/x.sh:9  TO_REVIEW  revisar esta chamada'
check "hotspot revisado: quem mudou e quando" has 'REVIEWED/SAFE \[SAFE por bot-login em 2026-10-02T15:45:00+0000\]'
check "chave do projeto deduzida do origin (acme_demo)" log_has 'projectKey=acme_demo'
check "consultou o PR 7" log_has 'pullRequest=7'
check "token fora da saída" secret_free_all

echo "# 3b. --json"
run pr 7 --json
check "--json -> 1 também" rc_is 1
check "json: projeto e alvo" json_is '.project == "acme_demo" and .target == "PR 7"'
check "json: commit e data" json_is '.commit == "abc123def" and .analyzed_at == "2026-10-01T10:00:00+0000"'
check "json: gate e condição reprovada" json_is '.gate.status == "ERROR" and .gate.failed[0].metric == "new_security_rating" and .gate.failed[0].actual == "3"'
check "json: issue com regra, arquivo, linha e mensagem" json_is '.issues[0] | .rule == "docker:S6505" and .file == "docker/Dockerfile" and .line == 64 and .message == "Evite scripts de instalação"'
check "json: transição da issue FALSE-POSITIVE" json_is '.issues[] | select(.key == "AXfp") | .transition.by == "bot-login" and .transition.at == "2026-10-01T12:00:00+0000"'
check "json: transição da issue WONTFIX" json_is '.issues[] | select(.key == "AXwf") | .transition.by == "renato"'
check "json: hotspot revisado com transição" json_is '.hotspots[] | select(.key == "HSsafe") | .resolution == "SAFE" and .transition.by == "bot-login"'
check "json: hotspot a revisar sem transição" json_is '.hotspots[] | select(.key == "HSopen") | has("transition") | not'
run --json pr 7; check "--json antes do modo também vale" json_is '.target == "PR 7"'

echo "# 4. gate aprovado (saída 0) e main"
fx api_qualitygates_project_status <<'J'
{"projectStatus":{"status":"OK","conditions":[{"status":"OK","metricKey":"new_coverage","actualValue":"90","errorThreshold":"80","comparator":"LT"}]}}
J
run pr 7; check "gate OK -> 0" rc_is 0; check "gate OK: texto" has_line 'gate: OK'
fx api_qualitygates_project_status <<'J'
{"projectStatus":{"status":"WARN","conditions":[]}}
J
run pr 7; check "gate WARN -> 0" rc_is 0
fx api_qualitygates_project_status <<'J'
{"projectStatus":{"status":"OK","conditions":[]}}
J
run main
check "main: gate OK -> 0" rc_is 0
check "main: commit da branch principal" has 'commit cafe9999'
check "main: sem pullRequest" log_hasnt 'pullRequest'
check "main: usa a lista de branches" log_has 'api/project_branches/list?project=acme_demo'
run main --json; check "main --json: alvo" json_is '.target == "main" and .commit == "cafe9999"'

echo "# 5. projeto e organização"
RUN_ENV=(OUTE_SONAR_PROJECT=outro:proj.1-x OUTE_SONAR_ORG=minha-org); run main
check "OUTE_SONAR_PROJECT vale mais que o origin" log_has 'project=outro:proj.1-x'
check "organização na consulta" log_has 'organization=minha-org'
RUN_ENV=()
git -C "$REPO" remote set-url origin https://github.com/acme/demo.git; run main
check "origin https com .git" log_has 'project=acme_demo'
git -C "$REPO" remote set-url origin https://github.com/acme/demo; run main
check "origin https sem .git" log_has 'project=acme_demo'
git -C "$REPO" remote set-url origin git@github.com:acme/demo.git

echo "# 6. só GET em https://sonarcloud.io"
fixtures; run pr 7
check "houve chamadas" bash -c '[ -s "$1" ]' _ "$FAKE/curl.log"
check "só GET" bash -c '! grep -v "^GET " "$1" | grep -q .' _ "$FAKE/curl.log"
check "só https://sonarcloud.io/" bash -c '! grep -v "^GET https://sonarcloud\.io/" "$1" | grep -q .' _ "$FAKE/curl.log"
check "nenhuma violação do curl falso" log_hasnt VIOLATION
check "nenhum -X/-d/--data no argv" bash -c '! grep -E -q -- "(^| )(-X|-d|-F|-T|--request|--data[a-z-]*|--form|--upload-file)( |$)" "$1"' _ "$FAKE/argv.log"
PLAIN="http"   # o esquema sem TLS monta-se de partes: nenhum literal dele neste arquivo
check "sem ${PLAIN}:// no argv" bash -c '! grep -q "$2://" "$1"' _ "$FAKE/argv.log" "$PLAIN"
check "o curl falso rejeita POST (o teste enxerga a violação)" bash -c 'PATH="$1:$PATH" FAKE="$2" curl -X POST https://sonarcloud.io/x >/dev/null; grep -q VIOLATION "$2/curl.log"' _ "$BIN" "$FAKE"
check "o curl falso rejeita outro host" bash -c 'PATH="$1:$PATH" FAKE="$2" curl https://example.com/x >/dev/null; grep -q "VIOLATION.*example.com" "$2/curl.log"' _ "$BIN" "$FAKE"
check "o curl falso rejeita ${PLAIN}://" bash -c 'PATH="$1:$PATH" FAKE="$2" curl "$3://sonarcloud.io/x" >/dev/null; grep -q VIOLATION "$2/curl.log"' _ "$BIN" "$FAKE" "$PLAIN"

echo "# 7. token fora da saída, do erro e do argv"
fixtures; run pr 7
check "sucesso: token fora de saída, erro e argv" secret_free_all
check "o token chegou ao curl (stdin), senão a resposta seria 401" rc_is 1
RUN_TOKEN="${TOK}x"; run pr 7
check "401 -> 4" rc_is 4
check "401: mensagem com o código" err_has "HTTP 401"
check "401: o token certo, que a resposta repete, não vai à saída, ao erro nem ao argv" secret_free_all
RUN_TOKEN="$TOK"
RUN_CMD=(bash -x "$SONAR"); run pr 7
check "bash -x: sai 1 como sempre" rc_is 1
check "bash -x: token fora da saída, do erro (xtrace) e do argv" secret_free_all
RUN_CMD=("$SONAR"); RUN_ENV=(SHELLOPTS=xtrace); run pr 7
check "SHELLOPTS=xtrace: token fora da saída e do erro" secret_free_all
RUN_ENV=(PS4='+ ${SONAR_TOKEN} '); run pr 7
check "PS4 com o token: fora do erro" secret_free_all
RUN_ENV=()

echo "# 8. falhas de rede, API e análise (saída 4)"
RUN_ENV=(FAKE_NET_FAIL=1); run pr 7
check "rede fora -> 4" rc_is 4; check "rede fora: mensagem" err_has "falha de rede"; check "rede fora: token fora do erro" secret_free_all
RUN_ENV=()
fixtures; echo 500 > "$FAKE/api_qualitygates_project_status.code"; run pr 7
check "HTTP 500 -> 4" rc_is 4; check "HTTP 500: mensagem" err_has "HTTP 500"
fixtures; echo '{"pullRequests":[{"key":"6"}]}' > "$FAKE/api_project_pull_requests_list.json"; run pr 7
check "PR sem análise -> 4" rc_is 4; check "PR sem análise: mensagem" err_has "não tem análise"
fixtures; echo '{"branches":[]}' > "$FAKE/api_project_branches_list.json"; run main
check "main sem análise -> 4" rc_is 4
fixtures; echo '{"projectStatus":{"status":"NONE"}}' > "$FAKE/api_qualitygates_project_status.json"; run pr 7
check "gate NONE -> 4" rc_is 4
fixtures; echo 'não é json' > "$FAKE/api_issues_search.json"; run pr 7
check "corpo que não é JSON -> 4" rc_is 4
fixtures; rm "$FAKE/api_issues_changelog.AXfp.json"; run pr 7
check "changelog da issue indisponível -> 4 (não finge que ninguém mudou)" rc_is 4
fixtures; rm "$FAKE/api_hotspots_show.HSsafe.json"; run pr 7
check "histórico do hotspot indisponível -> 4" rc_is 4
fixtures; sed -i 's/AXfp/AX fp;rm/' "$FAKE/api_issues_search.json"; run pr 7
check "chave de issue estranha vinda da API -> 4" rc_is 4
check "chave de issue estranha não vai à URL" log_hasnt 'fp;rm'

echo "# 9. texto do SonarCloud é dado"
fixtures; esc=$'\033'
jq --arg m "ruim${esc}[31m linha1
linha2" '.issues[0].message = $m' "$FAKE/api_issues_search.json" > "$TMP/i.json" && mv "$TMP/i.json" "$FAKE/api_issues_search.json"
run pr 7
check "sem caractere de controle na saída" bash -c '! printf "%s" "$1" | LC_ALL=C grep -q "[[:cntrl:]]"' _ "$(printf '%s' "$OUT" | tr '\n' ' ')"
check "mensagem em uma linha só" has 'ruim \[31m linha1 linha2'
run pr 7 --json; check "json guarda o texto escapado" json_is '.issues[0].message | contains("linha2")'

echo "# 10. paginação"
fixtures; sed -i 's/"total":3/"total":501/' "$FAKE/api_issues_search.json"; run pr 7 --json
check "pediu a página 2" log_has 'p=2'
check "juntou as duas páginas (3 + 3 issues)" json_is '.issues | length == 6'
check "500 por página" log_has 'ps=500'
fixtures; run pr 7; check "uma página quando cabe" log_hasnt 'p=2'

echo "# 11. SONAR_TOKEN chega ao ~/.oute_env (allowlist do entrypoint, #226)"
# o filtro é o do entrypoint, lido de lá: declare -px | grep -E '^declare -x (…)'
FILT="$(grep -o "grep -E '\^declare -x ([^']*)'" "$ROOT/docker/entrypoint.sh" | head -n 1)"
check "o filtro do entrypoint foi encontrado" bash -c '[ -n "$1" ]' _ "$FILT"
ENVF="$(env -i PATH="$PATH" SONAR_TOKEN="$TOK" OUTE_SONAR_ORG=minha-org SONARX_OUTRO=nao bash -c "export SONAR_TOKEN OUTE_SONAR_ORG SONARX_OUTRO; declare -px | $FILT")"
check "SONAR_TOKEN entra no .oute_env" bash -c 'grep -q "^declare -x SONAR_TOKEN=" <<<"$1"' _ "$ENVF"
check "OUTE_SONAR_ORG entra no .oute_env" bash -c 'grep -q "^declare -x OUTE_SONAR_ORG=" <<<"$1"' _ "$ENVF"
check "nome fora da allowlist (SONARX_) não entra" bash -c '! grep -q SONARX_ <<<"$1"' _ "$ENVF"

check_end
