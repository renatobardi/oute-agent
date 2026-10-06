#!/usr/bin/env bash
# Testes das duas credenciais do agent-studio (#256, ADR-08 §6): a de ingestão (só o collector) grava e não lê; a de
# leitura (agente, tray, tela) lê e, na ingestão, leva 403. Mais a transição (uma credencial só, pelo nome antigo ou
# com as duas iguais) e o compose: o `agent` não recebe credencial de serviço e o `surrealdb` fica numa rede que o
# `agent` não alcança. App de verdade, sem SurrealDB e sem Docker (com `docker compose` no host, confere também o
# compose resolvido).
# Uso: tests/agent-studio-auth.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
. "$ROOT/tests/lib/compose-config.sh"
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init

READ="$(python3 -c "import secrets; print(secrets.token_hex(16))")"
ING=(-H "Authorization: Bearer $STUDIO_TOKEN"); RD=(-H "Authorization: Bearer $READ")
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import kv, rl, rs, span
tmp = sys.argv[1]
res = {"host.name": "oute-server", "service.name": "claude-code", "oute.agent": "claude"}
json.dump({"resourceLogs": [rl(res, [{"timeUnixNano": "1759000000000000000", "body": {"stringValue": "um"},
                                      "attributes": kv({"session.id": "conv-auth"})}])]}, open(f"{tmp}/logs.json", "w"))
json.dump({"resourceSpans": [rs(res, [span("tool", 1759000000, 1, {"session.id": "conv-auth"})])]},
          open(f"{tmp}/traces.json", "w"))
json.dump({"resourceMetrics": [{"resource": {"attributes": kv(res)}, "scopeMetrics": [{"metrics": [
    {"name": "m", "sum": {"dataPoints": [{"timeUnixNano": "1759000000000000000", "asInt": "1"}]}}]}]}]},
          open(f"{tmp}/metrics.json", "w"))
PY
# ingest <sinal> [curl args…]: POST do lote de exemplo sem credencial nenhuma além da que vier nos args
ingest() { local sig="$1"; shift; code -X POST -H 'Content-Type: application/json' --data-binary "@$TMP/$sig.json" "$@" "$STUDIO_URL/v1/$sig"; }
count() { studio_sql "$1" "SELECT (SELECT count(*) FROM logs) + (SELECT count(*) FROM spans) + (SELECT count(*) FROM metrics) AS n" | jq -r .n; }
login() { curl -s -D "$TMP/h" -o /dev/null -w '%{http_code}' -X POST --data-urlencode "token=$1" "$STUDIO_URL/login"; }

# ---------------------------------------------------------------- 1. duas credenciais
studio_start "$TMP/s1" AGENT_STUDIO_READ_TOKEN="$READ" || { cat "$TMP/s1/stderr"; die "agent-studio não subiu"; }
check "duas credenciais: sobe sem o aviso de transição" bash -c '! grep -q "transição" "$0"' "$TMP/s1/stderr"
for sig in logs traces metrics; do
  check "POST /v1/$sig com a de leitura: 403"           test "$(ingest "$sig" "${RD[@]}")" = 403
  check "POST /v1/$sig sem credencial: 401"             test "$(ingest "$sig")" = 401
  check "POST /v1/$sig com credencial errada: 401"      test "$(ingest "$sig" -H "Authorization: Bearer ${READ}x")" = 401
done
L="$(login "$READ")"; COOKIE="$(tr -d '\r' < "$TMP/h" | grep -i '^set-cookie: agent_studio=' | sed 's/^[^:]*: *//; s/;.*//')"
check "login com a de leitura: 303 e cookie"            test "$L" = 303 -a -n "$COOKIE"
check "cookie do login lê (200) e não ingere (401)"     test "$(code -H "Cookie: $COOKIE" "$STUDIO_URL/v1/usage")$(ingest logs -H "Cookie: $COOKIE")" = 200401
for p in usage alerts tray; do
  check "GET /v1/$p com a de leitura: 200"              test "$(code "${RD[@]}" "$STUDIO_URL/v1/$p")" = 200
  check "GET /v1/$p com a de ingestão: 401"             test "$(code "${ING[@]}" "$STUDIO_URL/v1/$p")" = 401
  check "GET /v1/$p sem credencial: 401"                test "$(code "$STUDIO_URL/v1/$p")" = 401
done
check "tela com a de leitura: 200"                      test "$(code "${RD[@]}" "$STUDIO_URL/conversas")" = 200
check "tela com a de ingestão: manda ao login (303)"    test "$(code "${ING[@]}" "$STUDIO_URL/conversas")" = 303
L="$(login "$STUDIO_TOKEN")"
check "login com a de ingestão: 401"                    test "$L" = 401
check "login com a de ingestão: sem cookie"             bash -c '! grep -qi "^set-cookie: agent_studio=[0-9a-f]" "$0"' "$TMP/h"
check "resposta do 403 sem nada do cliente"             test "$(curl -s -X POST -H 'Content-Type: application/json' "${RD[@]}" --data-binary '{"x":"eco-do-cliente"}' "$STUDIO_URL/v1/logs")" = '{"message":"forbidden"}'
studio_stop
check "recusas não gravaram nada"                       test "$(count "$TMP/s1/db.duckdb")" = 0
studio_start "$TMP/s1" AGENT_STUDIO_READ_TOKEN="$READ" || die "agent-studio não voltou"
for sig in logs traces metrics; do
  check "POST /v1/$sig com a de ingestão: 200"          test "$(ingest "$sig" "${ING[@]}")" = 200
done
studio_stop
check "ingestão gravou os três sinais"                  test "$(count "$TMP/s1/db.duckdb")" = 3
check "stderr sem valor de credencial"                  bash -c '! grep -qF -e "$1" -e "$2" "$0"' "$TMP/s1/stderr" "$STUDIO_TOKEN" "$READ"

# ---------------------------------------------------------------- 2. transição: uma credencial só
# nome de antes da #256 (imagem nova com item antigo no vault): ingere e lê com o mesmo valor, e avisa
AGENT_STUDIO_INGEST_TOKEN="" studio_start "$TMP/s2" AGENT_STUDIO_TOKEN="$STUDIO_TOKEN" || { cat "$TMP/s2/stderr"; die "agent-studio (nome antigo) não subiu"; }
check "nome antigo: ingere (200)"                       test "$(ingest logs "${ING[@]}")" = 200
check "nome antigo: lê (200)"                           test "$(code "${ING[@]}" "$STUDIO_URL/v1/usage")" = 200
check "nome antigo: login com ele (303)"                test "$(login "$STUDIO_TOKEN")" = 303
check "nome antigo: avisa a transição no stderr"        grep -q 'aviso: sem credencial de leitura própria' "$TMP/s2/stderr"
studio_stop
# leitura igual à ingestão = uma credencial só (nunca 403 nela mesma), com o aviso
studio_start "$TMP/s3" AGENT_STUDIO_READ_TOKEN="$STUDIO_TOKEN" || die "agent-studio (credenciais iguais) não subiu"
check "credenciais iguais: ingere e lê"                 test "$(ingest logs "${ING[@]}")$(code "${ING[@]}" "$STUDIO_URL/v1/tray")" = 200200
check "credenciais iguais: avisa no stderr"             grep -q 'aviso: sem credencial de leitura própria' "$TMP/s3/stderr"
studio_stop
# credencial nova vence o nome antigo; o valor antigo não abre nada
studio_start "$TMP/s4" AGENT_STUDIO_TOKEN="${STUDIO_TOKEN}velho" AGENT_STUDIO_READ_TOKEN="$READ" || die "agent-studio (nome novo + antigo) não subiu"
check "nome novo vence: o valor antigo não ingere nem lê" test "$(ingest logs -H "Authorization: Bearer ${STUDIO_TOKEN}velho")$(code -H "Authorization: Bearer ${STUDIO_TOKEN}velho" "$STUDIO_URL/v1/usage")" = 401401
studio_stop
# só a de leitura não sobe: sem ingestão não há serviço
OUT="$(env AGENT_STUDIO_READ_TOKEN="$READ" AGENT_STUDIO_DB="$TMP/x.duckdb" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio 2>&1)"; RC=$?
check "sem a de ingestão: não sobe e diz a pasta"       bash -c '[[ $0 -ne 0 ]] && grep -q "AGENT_STUDIO_INGEST_TOKEN vazio (item agent-studio da pasta oute-services" <<<"$1"' "$RC" "$OUT"
check "sem a de ingestão: não cria o banco"             test ! -e "$TMP/x.duckdb"

# ---------------------------------------------------------------- 2b. o cookie de marcação (#510; em Path=/ desde a #537)
MARK="$(python3 -c "import secrets; print(secrets.token_hex(16))")"
studio_start "$TMP/s5" AGENT_STUDIO_READ_TOKEN="$READ" AGENT_STUDIO_MARK_TOKEN="$MARK" || { cat "$TMP/s5/stderr"; die "agent-studio (com marcação) não subiu"; }
login "$READ" >/dev/null; COOKIE="$(tr -d '\r' < "$TMP/h" | grep -i '^set-cookie: agent_studio=' | sed 's/^[^:]*: *//; s/;.*//')"
M="$(curl -s -D "$TMP/hm" -o /dev/null -w '%{http_code}' -X POST -H "Cookie: $COOKIE" -H "Origin: $STUDIO_URL" --data-urlencode "token=$MARK" "$STUDIO_URL/marcar")"
# a linha que põe o cookie (com valor) e a que apaga o antigo (valor vazio)
SET="$(tr -d '\r' < "$TMP/hm" | grep -i '^set-cookie: agent_studio_mark=[0-9a-f]')"
OLD="$(tr -d '\r' < "$TMP/hm" | grep -i '^set-cookie: agent_studio_mark=' | grep -vi '^set-cookie: agent_studio_mark=[0-9a-f]')"
check "entrada de marcação: 303 e um cookie de marcação só"  bash -c '[ "$1" = 303 ] && [ "$(grep -c . <<<"$2")" = 1 ]' _ "$M" "$SET"
check "cookie de marcação: Path=/ (vai às faixas de todas as telas e ao /ack)" grep -qiE '; *Path=/(;|$)' <<<"$SET"
check "cookie de marcação: mantém HttpOnly"                  grep -qiE '; *HttpOnly(;|$)' <<<"$SET"
check "cookie de marcação: mantém Secure"                    grep -qiE '; *Secure(;|$)' <<<"$SET"
check "cookie de marcação: mantém SameSite=Strict"           grep -qiE '; *SameSite=Strict(;|$)' <<<"$SET"
check "cookie de marcação: não leva a credencial"            bash -c '! grep -qF "$1" "$2"' _ "$MARK" "$TMP/hm"
check "a entrada apaga o cookie antigo de Path=/rodada (um nome, um cookie)" bash -c '[ "$(grep -c . <<<"$1")" = 1 ] && grep -qiE "; *Path=/rodada(;|\$)" <<<"$1" && grep -qiE "Max-Age=0(;|\$)" <<<"$1"' _ "$OLD"
check "cookie de leitura: segue em Path=/ com SameSite=Lax"  bash -c 'c="$(tr -d "\r" < "$1" | grep -i "^set-cookie: agent_studio=")"; grep -qiE "; *Path=/(;|\$)" <<<"$c" && grep -qi "SameSite=Lax" <<<"$c"' _ "$TMP/h"
check "a credencial de leitura na entrada de marcação: 401 e nenhum cookie de marcação" bash -c 'st="$(curl -s -D "$4" -o /dev/null -w "%{http_code}" -X POST -H "Cookie: $1" -H "Origin: $2" --data-urlencode "token=$3" "$2/marcar")"; [ "$st" = 401 ] && ! grep -qi "^set-cookie: agent_studio_mark=[0-9a-f]" "$4"' _ "$COOKIE" "$STUDIO_URL" "$READ" "$TMP/hx"
studio_stop
check "stderr sem a credencial de marcação"                  bash -c '! grep -qF "$1" "$0"' "$TMP/s5/stderr" "$MARK"

# ---------------------------------------------------------------- 3. compose: o que cada serviço recebe e a rede
COMPOSE="$ROOT/docker/compose.yaml"
nocomment() { grep -v '^ *#'; }
AGENT="$(compose_service agent | nocomment)"; STUDIO="$(compose_service agent-studio | nocomment)"
SURREAL="$(compose_service surrealdb | nocomment)"; COL="$(compose_service otel-collector | nocomment)"
check "compose: os quatro serviços achados"             test -n "$AGENT" -a -n "$STUDIO" -a -n "$SURREAL" -a -n "$COL"
check "compose: agent sem credencial do agent-studio nem do SurrealDB" bash -c '! grep -qE "AGENT_STUDIO_[A-Z_]*(TOKEN|PASS)|SURREAL" <<<"$0"' "$AGENT"
check "compose: agent sem env_file"                     bash -c '! grep -q "env_file" <<<"$0"' "$AGENT"
check "compose: agent só com o secret agent_env"        test "$(awk '/^    secrets:/ {on=1; next} on && /^      - / {print $2; next} on {exit}' <<<"$AGENT")" = agent_env
check "compose: só o agent monta o agent_env"           test "$(nocomment < "$COMPOSE" | grep -c '^      - agent_env$')" = 1
check "compose: services.env não é montado em nenhum serviço" bash -c '! grep -q "services.env" <(grep -v "^ *#" "$0")' "$COMPOSE"
check "compose: collector com a credencial de ingestão" grep -q 'AGENT_STUDIO_INGEST_TOKEN: \${AGENT_STUDIO_INGEST_TOKEN:-}' <<<"$COL"
check "compose: collector sem a de leitura e sem a senha" bash -c '! grep -qE "READ_TOKEN|SURREAL" <<<"$0"' "$COL"
check "compose: agent fora da rede studio"                  bash -c 'grep -q "^      oute:$" <<<"$0" && ! grep -q "studio" <<<"$(sed -n "/^    networks:/,/^    [a-z]/p" <<<"$0")"' "$AGENT"
check "compose: surrealdb só na rede studio"            grep -qx '    networks: \[studio\]' <<<"$SURREAL"
check "compose: agent-studio nas redes oute e studio"   grep -qx '    networks: \[oute, studio\]' <<<"$STUDIO"
check "compose: collector fora da rede studio (oute e llm, #459)" grep -qx '    networks: \[oute, llm\]' <<<"$COL"
check "compose: rede studio interna"                    bash -c 'sed -n "/^  studio:/,/^  [a-z]/p" "$0" | grep -qx "    internal: true"' "$COMPOSE"
check "compose: surrealdb sem porta publicada"          bash -c '! grep -qE "^    ports:" <<<"$0"' "$SURREAL"
# compose resolvido, quando o host tem `docker compose` (o CI de PR não tem a garantia; sem ele, só o texto acima)
if docker compose version >/dev/null 2>&1; then
  CFG="$(compose_config agent-studio 2>"$TMP/cfg.err")" || CFG=""
  check "compose config: resolve"                       test -n "$CFG"
  check "compose config: surrealdb só na rede studio"   jqe '.services.surrealdb.networks | keys == ["studio"]' <<<"$CFG"
  check "compose config: agent nas redes oute e memoria, nunca na studio" jqe '.services.agent.networks | keys == ["memoria", "oute"]' <<<"$CFG"
  check "compose config: rede studio interna"           jqe '.networks.studio.internal == true' <<<"$CFG"
  check "compose config: agent sem credencial de serviço no environment" jqe '.services.agent.environment | keys | map(select(test("AGENT_STUDIO_[A-Z_]*(TOKEN|PASS)|SURREAL"))) == []' <<<"$CFG"
  # o endereço não é credencial: o agent lê o agent-studio por ele, com a de leitura do agent_env (#259)
  check "compose config: do agent-studio, o agent só recebe o endereço" jqe '.services.agent.environment | keys | map(select(test("AGENT_STUDIO"))) == ["AGENT_STUDIO_URL"]' <<<"$CFG"
  check "compose config: surrealdb sem porta"           jqe '.services.surrealdb.ports == null' <<<"$CFG"
else
  echo "# compose config: pulado (sem docker compose neste host)"
fi

check_end
