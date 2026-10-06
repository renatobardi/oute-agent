#!/usr/bin/env bash
# Testes do oute-llm-proxy (#459): o proxy do LLM do ai-memory. OpenRouter falso com TLS (certificado gerado na hora pelo
# openssl, tests/lib/openrouter.sh) e receptor OTLP falso no lugar do collector (tests/lib/otlp.sh). Só comportamento
# externo: o que o ai-memory (cliente) recebe, o que o OpenRouter falso recebe e o que chega ao collector.
# Uso: tests/oute-llm-proxy.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/parallel.sh"
. "$ROOT/tests/lib/otlp.sh"
. "$ROOT/tests/lib/openrouter.sh"
px_stop() { [[ -z "${PX_PID:-}" ]] || { kill "$PX_PID" 2>/dev/null; wait "$PX_PID" 2>/dev/null; PX_PID=""; }; return 0; }
trap 'px_stop; rcv_stop; or_stop; rm -rf "${TMP:?}"' EXIT
command -v jq >/dev/null && command -v python3 >/dev/null && command -v curl >/dev/null && command -v openssl >/dev/null \
  || die "precisa de jq, python3, curl e openssl"

PROXY="$ROOT/docker/oute-llm-proxy"
# chave só deste teste, aleatória a cada execução (nunca a de verdade)
KEY="sk-teste-$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
CLIENT_KEY="cliente-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
PROMPT_TEXT="PROMPT-SECRETO-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
RESPONSE_TEXT="TEXTO-DE-RESPOSTA-SECRETO"
SCHEME=http
unset OTEL_EXPORTER_OTLP_ENDPOINT LLM_PROXY_API_KEY LLM_PROXY_UPSTREAM

px_url() { printf '%s://127.0.0.1:%s' "$SCHEME" "$PX_PORT"; }
px_health() { curl -fsS --max-time 2 "$SCHEME://127.0.0.1:$1/healthz"; }
# px_launch <porta>: sobe o proxy com o ambiente de $PX_ENV (array)
px_launch() {
  env LLM_PROXY_BIND=127.0.0.1 LLM_PROXY_PORT="$1" OUTE_HOST=host-teste OUTE_INSTANCE=inst-teste \
    ${PX_ENV[@]+"${PX_ENV[@]}"} python3 "$PROXY" 2>>"$PX_LOG" & SPAWN_PID=$! PX_PID=$!
}
# px_start [VAR=valor…]: sobe o proxy (porta livre) e define PX_PORT
px_start() {
  PX_ENV=("$@"); PX_LOG="$TMP/proxy.log"
  spawn_try "$START_TRIES" "" px_launch px_health || return 1
  PX_PORT="$SPAWN_PORT"
}
# call [curl args…]: POST de chat/completions como o ai-memory; corpo em $TMP/resp, código em $CODE
call() {
  CODE="$(curl -s -o "$TMP/resp" -w '%{http_code}' --max-time 60 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $CLIENT_KEY" -H 'Cookie: sessao=abc' "$@" \
    --data "{\"model\":\"openai/gpt-oss-120b\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT_TEXT\"}]}" \
    "$(px_url)/api/v1/chat/completions")" || CODE="000"
}
# spans: um objeto por span recebido no "collector"
spans() {
  local f; for f in "$RCV_DIR"/*.json; do
    [[ -e "$f" && "$(cat "${f%.json}.path" 2>/dev/null)" == /v1/traces ]] || continue
    jq -c '.resourceSpans[] | (.resource.attributes | map({(.key): (.value | to_entries[0].value)}) | add) as $res
      | .scopeSpans[].spans[] | {name, status, start: .startTimeUnixNano, end: .endTimeUnixNano,
        attrs: (.attributes | map({(.key): (.value | to_entries[0].value)}) | add), res: $res}' "$f"
  done
}
span_count() { spans | grep -c . || true; }
wait_spans() {  # wait_spans <n>: espera n spans (emissão assíncrona)
  local i; for i in $(seq 1 100); do [[ "$(span_count)" -ge "$1" ]] && return 0; sleep 0.1; done; return 1
}
last_span() { spans | tail -n 1; }

or_start "$TMP/or" || die "o OpenRouter falso não subiu"
rcv_start "$TMP/rcv"
COLLECTOR="$OTEL_EXPORTER_OTLP_ENDPOINT"

# ---------------------------------------------------------------- 1. chamada normal
px_start LLM_PROXY_API_KEY="$KEY" LLM_PROXY_UPSTREAM="$OR_BASE" OTEL_EXPORTER_OTLP_ENDPOINT="$COLLECTOR" \
  LLM_PROXY_HEARTBEAT_SECONDS=1 LLM_PROXY_RETRY_SECONDS=0.2 || die "o proxy não subiu"
OUT="$(px_health "$PX_PORT")"
check "healthz: 200 e diz que há chave"                       jqe '.status == "ok" and .key == true' <<<"$OUT"
check "healthz: não chama o OpenRouter"                       test "$(or_requests)" -eq 0
call
check "chamada: 200 com a resposta do OpenRouter intacta"     bash -c '[ "$1" = 200 ] && jq -e ".model == \"openai/gpt-oss-120b\" and .usage.cost == 0.000321" "$2" >/dev/null' _ "$CODE" "$TMP/resp"
check "chamada: o OpenRouter recebeu a chave do proxy"        bash -c 'jq -e --arg k "Bearer $1" "select(.method == \"POST\") | .auth == \$k" "$2" >/dev/null' _ "$KEY" "$(or_log)"
check "chamada: a chave do cliente não vai ao OpenRouter"     bash -c '! grep -qF -- "$1" "$2"' _ "$CLIENT_KEY" "$(or_log)"
check "chamada: cookie do cliente não vai ao OpenRouter"      bash -c '! jq -e "select(.cookie != \"\")" "$1" >/dev/null' _ "$(or_log)"
check "chamada: o pedido chegou inteiro ao OpenRouter"        bash -c 'jq -e --arg p "$1" "select(.method == \"POST\") | (.body | contains(\$p)) and .ctype == \"application/json\"" "$2" >/dev/null' _ "$PROMPT_TEXT" "$(or_log)"
wait_spans 1 || bad "chamada: o span não chegou ao collector"
S="$(last_span)"
check "span: nome ai_memory.llm_request e status ok"          jqe '.name == "ai_memory.llm_request" and .status.code == 1' <<<"$S"
check "span: agente ai-memory (no span e no resource)"        jqe '.attrs["oute.agent"] == "ai-memory" and .res["oute.agent"] == "ai-memory"' <<<"$S"
check "span: host e instância"                                jqe '.res["host.name"] == "host-teste" and .res["oute.instance"] == "inst-teste"' <<<"$S"
check "span: modelo pedido e respondido"                      jqe '.attrs["gen_ai.request.model"] == "openai/gpt-oss-120b" and .attrs["gen_ai.response.model"] == "openai/gpt-oss-120b"' <<<"$S"
check "span: tokens de entrada (sem cache), saída e cache"    jqe '(.attrs["gen_ai.usage.input_tokens"] | tonumber) == 100 and (.attrs["gen_ai.usage.output_tokens"] | tonumber) == 30
                                                                   and (.attrs["gen_ai.usage.cache_read_input_tokens"] | tonumber) == 20' <<<"$S"
check "span: custo = usage.cost da resposta"                  jqe '.attrs["oute.cost_usd"] == 0.000321' <<<"$S"
check "span: com uso (usage_missing falso) e status HTTP"     jqe '.attrs["oute.llm.usage_missing"] == false and (.attrs["http.response.status_code"] | tonumber) == 200' <<<"$S"
check "span: início antes do fim"                             jqe '(.start | tonumber) < (.end | tonumber)' <<<"$S"
check "telemetria: nem prompt, nem resposta, nem chave"       bash -c '! cat "$1"/*.json | grep -qF -e "$2" -e "$3" -e "$4" -e "$5"' _ "$RCV_DIR" "$PROMPT_TEXT" "$RESPONSE_TEXT" "$KEY" "$CLIENT_KEY"
check "log do proxy: nem prompt, nem resposta, nem chave"     bash -c '! grep -qF -e "$2" -e "$3" -e "$4" -e "$5" "$1"' _ "$PX_LOG" "$PROMPT_TEXT" "$RESPONSE_TEXT" "$KEY" "$CLIENT_KEY"
check "log do proxy: tem a linha da chamada (modelo e custo)" grep -q 'status=200 model=openai/gpt-oss-120b .* cost=0.000321' "$PX_LOG"
check "argv do proxy: sem a chave"                            bash -c '! ps -o args= -p "$1" | grep -qF -- "$2"' _ "$PX_PID" "$KEY"

# heartbeat
wait_hb() { local i; for i in $(seq 1 60); do [[ -n "$(mp '.name == "oute.llm_proxy.up"')" ]] && return 0; sleep 0.1; done; return 1; }
wait_hb || bad "heartbeat: não chegou"
HB="$(mp '.name == "oute.llm_proxy.up"' | head -n 1)"
check "heartbeat: métrica oute.llm_proxy.up = 1 com a origem" jqe '.value == 1 and .res["host.name"] == "host-teste" and .res["oute.instance"] == "inst-teste" and .res["oute.agent"] == "ai-memory"' <<<"$HB"
check "heartbeat: diz que a chave está presente"              jqe '.attrs["oute.llm_proxy.key_present"] == true' <<<"$HB"

# ---------------------------------------------------------------- 2. resposta sem usage
or_mode nousage; N="$(span_count)"; call
check "sem usage: 200 repassado ao cliente"                   test "$CODE" = 200
wait_spans $((N + 1)) || bad "sem usage: o span não chegou"
S="$(last_span)"
check "sem usage: span existe, sem tokens e sem custo"        jqe '.attrs["oute.llm.usage_missing"] == true and (.attrs | has("oute.cost_usd") | not) and (.attrs | has("gen_ai.usage.input_tokens") | not)
                                                                   and .status.code == 1' <<<"$S"
check "sem usage: o modelo vem da resposta"                   jqe '.attrs["gen_ai.response.model"] == "openai/gpt-oss-120b"' <<<"$S"

# ---------------------------------------------------------------- 3. erro 5xx do OpenRouter (o corpo repete a chave)
or_mode 500; N="$(span_count)"; call
check "5xx: o cliente recebe o 500"                           test "$CODE" = 500
check "5xx: o corpo de erro não leva a chave"                 bash -c '! grep -qF -- "$1" "$2"' _ "$KEY" "$TMP/resp"
check "5xx: o corpo de erro segue legível (redigido)"         bash -c 'grep -q "falha interna" "$1" && grep -q "redacted" "$1"' _ "$TMP/resp"
wait_spans $((N + 1)) || bad "5xx: o span não chegou"
S="$(last_span)"
check "5xx: span com status de erro e HTTP 500"               jqe '.status.code == 2 and .status.message == "HTTP 500" and (.attrs["http.response.status_code"] | tonumber) == 500
                                                                   and .attrs["oute.llm.usage_missing"] == true' <<<"$S"
check "5xx: log sem a chave"                                  bash -c '! grep -qF -- "$2" "$1"' _ "$PX_LOG" "$KEY"
or_mode 429; N="$(span_count)"
CODE="$(curl -s -o "$TMP/resp" -D "$TMP/hdr" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{"model":"openai/gpt-oss-120b"}' "$(px_url)/api/v1/chat/completions")"
check "429: repassa o código e o Retry-After"                 bash -c '[ "$1" = 429 ] && grep -qi "^retry-after: 7" "$2"' _ "$CODE" "$TMP/hdr"

# ---------------------------------------------------------------- 4. streaming (SSE)
or_mode sse; N="$(span_count)"; call --no-buffer
check "sse: o cliente recebe o fluxo inteiro"                 bash -c '[ "$1" = 200 ] && grep -q "TEXTO-DE-RESPOSTA" "$2" && grep -q "\[DONE\]" "$2"' _ "$CODE" "$TMP/resp"
wait_spans $((N + 1)) || bad "sse: o span não chegou"
S="$(last_span)"
check "sse: tokens e custo lidos do último pedaço"            jqe '(.attrs["gen_ai.usage.input_tokens"] | tonumber) == 100 and (.attrs["gen_ai.usage.output_tokens"] | tonumber) == 30
                                                                   and .attrs["oute.cost_usd"] == 0.000321 and .attrs["oute.llm.stream"] == false' <<<"$S"

# ---------------------------------------------------------------- 5. resposta grande
or_mode big; N="$(span_count)"; call
check "grande: 20 MiB chegam inteiros ao cliente"             bash -c '[ "$1" = 200 ] && [ "$(wc -c < "$2")" -gt 20971520 ]' _ "$CODE" "$TMP/resp"
wait_spans $((N + 1)) || bad "grande: o span não chegou"
S="$(last_span)"
check "grande: acima do teto de leitura não inventa uso"      jqe '.attrs["oute.llm.usage_missing"] == true and .status.code == 1' <<<"$S"
or_mode ok; N="$(span_count)"; call
check "grande: o proxy segue respondendo depois"              test "$CODE" = 200
wait_spans $((N + 1)) || bad "grande: o span da chamada seguinte não chegou"

# ---------------------------------------------------------------- 6. rotas
N="$(span_count)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$(px_url)/api/v1/outra")"
check "rota fora da lista: 404"                               test "$CODE" = 404
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$(px_url)/api/v1/chat/completions")"
check "GET em chat/completions: 404"                          test "$CODE" = 404
or_reset
CODE="$(curl -s -o "$TMP/resp" -w '%{http_code}' -H "Authorization: Bearer $CLIENT_KEY" "$(px_url)/api/v1/models")"
check "GET models: repassa com a chave do proxy"              bash -c '[ "$1" = 200 ] && jq -e --arg k "Bearer $2" "select(.path == \"/api/v1/models\") | .auth == \$k" "$3" >/dev/null' _ "$CODE" "$KEY" "$(or_log)"
sleep 0.5
check "rotas: nenhuma gerou span de consumo"                  test "$(span_count)" -eq "$N"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Transfer-Encoding: chunked' --data '{}' "$(px_url)/api/v1/chat/completions")"
check "pedido sem Content-Length: 411"                        test "$CODE" = 411

# ---------------------------------------------------------------- 7. OpenRouter fora do ar
or_stop; N="$(span_count)"; call
check "upstream fora: 502 com erro fixo, sem a chave"         bash -c '[ "$1" = 502 ] && ! grep -qF -- "$2" "$3" && grep -q "upstream indispon" "$3"' _ "$CODE" "$KEY" "$TMP/resp"
wait_spans $((N + 1)) || bad "upstream fora: o span não chegou"
check "upstream fora: span de erro"                           jqe '.status.code == 2 and .status.message == "upstream indisponível"' <<<"$(last_span)"
or_start "$TMP/or" || die "o OpenRouter falso não voltou"
px_stop

# ---------------------------------------------------------------- 8. collector fora do ar: a chamada não espera por ele
rcv_stop; DEAD="$(closed_port)"
px_start LLM_PROXY_API_KEY="$KEY" LLM_PROXY_UPSTREAM="$OR_BASE" OTEL_EXPORTER_OTLP_ENDPOINT="$SCHEME://127.0.0.1:$DEAD" \
  LLM_PROXY_HEARTBEAT_SECONDS=0 LLM_PROXY_RETRY_SECONDS=0.2 || die "o proxy não subiu (collector fora)"
call
check "collector fora: a chamada responde 200 do mesmo jeito" test "$CODE" = 200
sleep 1
check "collector fora: o log avisa, sem dado"                 grep -q 'emissão ao collector falhou' "$TMP/proxy.log"
RCV_DIR2="$TMP/rcv2"; mkdir -p "$RCV_DIR2"
RCV_PORT="$DEAD" python3 "$ROOT/tests/lib/otlp-receiver.py" "$RCV_DIR2" & RCV_PID=$!
RCV_DIR="$RCV_DIR2"
wait_spans 1 || bad "collector de volta: o span guardado não chegou"
check "collector de volta: o span guardado é entregue"        jqe '.name == "ai_memory.llm_request" and .attrs["oute.cost_usd"] == 0.000321' <<<"$(last_span)"
rcv_stop; px_stop

# ---------------------------------------------------------------- 9. sem chave
rcv_start "$TMP/rcv3"; or_reset
px_start LLM_PROXY_UPSTREAM="$OR_BASE" OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" LLM_PROXY_HEARTBEAT_SECONDS=1 || die "o proxy não subiu (sem chave)"
call
check "sem chave: 503 e nada vai ao OpenRouter"               bash -c '[ "$1" = 503 ] && [ "$2" -eq 0 ]' _ "$CODE" "$(or_requests)"
check "sem chave: healthz diz que não há chave"               jqe '.key == false' <<<"$(px_health "$PX_PORT")"
sleep 0.3
check "sem chave: nenhuma chamada virou consumo"              test "$(span_count)" -eq 0
px_stop

# ---------------------------------------------------------------- 10. upstream que não é https
px_start LLM_PROXY_API_KEY="$KEY" LLM_PROXY_UPSTREAM="$SCHEME://127.0.0.1:9/api/v1" OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" LLM_PROXY_HEARTBEAT_SECONDS=0 || die "o proxy não subiu (upstream http)"
call
check "upstream sem TLS: 502 e a chave não sai"               bash -c '[ "$1" = 502 ] && [ "$2" -eq 0 ]' _ "$CODE" "$(or_requests)"
px_stop

# ---------------------------------------------------------------- 11. certificado que o proxy não conhece
SSL_SAVE="$SSL_CERT_FILE"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=outro -keyout "$TMP/outro-key.pem" -out "$TMP/outro.pem" >/dev/null 2>&1
SSL_CERT_FILE="$TMP/outro.pem" px_start LLM_PROXY_API_KEY="$KEY" LLM_PROXY_UPSTREAM="$OR_BASE" OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" LLM_PROXY_HEARTBEAT_SECONDS=0 || die "o proxy não subiu (certificado)"
or_reset; call
check "certificado não confiável: 502 e nenhum pedido chega"  bash -c '[ "$1" = 502 ] && [ "$2" -eq 0 ]' _ "$CODE" "$(or_requests)"
export SSL_CERT_FILE="$SSL_SAVE"
px_stop

# ---------------------------------------------------------------- 12. pedido acima de 8 MiB (#564)
or_reset; px_start LLM_PROXY_API_KEY="$KEY" LLM_PROXY_UPSTREAM="$OR_BASE" OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" LLM_PROXY_HEARTBEAT_SECONDS=0 || die "o proxy não subiu (413)"
N="$(span_count)"; call -H "Content-Length: $((8 * 1024 * 1024 + 1))"
check "pedido acima de 8 MiB: 413, nada vai ao OpenRouter"    bash -c '[ "$1" = 413 ] && [ "$2" -eq 0 ] && grep -q "pedido grande demais" "$3"' _ "$CODE" "$(or_requests)" "$TMP/resp"
sleep 0.3
check "pedido acima de 8 MiB: não vira consumo"               test "$(span_count)" -eq "$N"
call
check "pedido acima de 8 MiB: o proxy segue respondendo"      test "$CODE" = 200
px_stop

# ---------------------------------------------------------------- 13. upstream que não responde dentro do prazo (#564)
# o prazo de produção é 300 s (UPSTREAM_TIMEOUT); aqui 1 s, e o OpenRouter falso demora 30 s
or_reset; or_mode hang; px_start LLM_PROXY_API_KEY="$KEY" LLM_PROXY_UPSTREAM="$OR_BASE" LLM_PROXY_UPSTREAM_TIMEOUT=1 OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" LLM_PROXY_HEARTBEAT_SECONDS=0 || die "o proxy não subiu (timeout)"
N="$(span_count)"; T0="$(date +%s)"; call; T1="$(date +%s)"
check "upstream lento: 502 com erro fixo, sem a chave"        bash -c '[ "$1" = 502 ] && ! grep -qF -- "$2" "$3" && grep -q "upstream indispon" "$3"' _ "$CODE" "$KEY" "$TMP/resp"
check "upstream lento: o proxy desiste no prazo, não espera o upstream" test $((T1 - T0)) -lt 15
wait_spans $((N + 1)) || bad "upstream lento: o span não chegou"
check "upstream lento: span de erro"                          jqe '.status.code == 2 and .status.message == "upstream indisponível"' <<<"$(last_span)"
or_mode ok; call
check "upstream lento: o proxy segue respondendo depois"      test "$CODE" = 200
px_stop

check_end
