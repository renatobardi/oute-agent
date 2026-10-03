#!/usr/bin/env bash
# Testes do agent-studio (ADR-08): ingestão OTLP/HTTP JSON -> DuckDB (#185), o serviço no compose e o `oute up`.
# Sobe o app de verdade (uvicorn + DuckDB, venv com as dependências fixadas por hash; tests/lib/agent-studio.sh) em
# 127.0.0.1 e confere só comportamento externo: código HTTP e o que ficou no DuckDB. Sem Docker.
# Uso: tests/agent-studio.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
. "$ROOT/tests/lib/otlp.sh"
trap 'studio_stop; rcv_stop; rm -rf "$TMP"' EXIT
studio_init
DB="$TMP/s/db.duckdb"
count() { studio_sql "$DB" "SELECT count(*) AS n FROM $1 ${2:-}" | jq -r .n; }

# ---------------------------------------------------------------- lotes de teste
# log de um agente (sem oute.event.id), hora do fato em 2025 (bem longe da hora de chegada)
cat > "$TMP/claude.json" <<'EOF'
{"resourceLogs":[{"resource":{"attributes":[
  {"key":"host.name","value":{"stringValue":"oute-mac"}},{"key":"oute.instance","value":{"stringValue":"oute-agent"}},
  {"key":"service.name","value":{"stringValue":"claude-code"}},{"key":"oute.agent","value":{"stringValue":"claude"}},
  {"key":"oute.task.id","value":{"stringValue":"oute-agent-x-20250927190640"}},{"key":"oute.swarm.round","value":{"stringValue":"swarm-0927-1900"}}]},
 "scopeLogs":[{"scope":{"name":"com.anthropic.claude_code.events"},"logRecords":[
  {"timeUnixNano":"1759000000123456789","observedTimeUnixNano":"1759000000200000000","severityNumber":9,"severityText":"INFO",
   "body":{"stringValue":"claude_code.user_prompt"},
   "attributes":[{"key":"event.name","value":{"stringValue":"user_prompt"}},{"key":"session.id","value":{"stringValue":"sess-1"}},
     {"key":"prompt","value":{"stringValue":"olá"}},{"key":"prompt_length","value":{"intValue":"3"}},
     {"key":"extra","value":{"kvlistValue":{"values":[{"key":"a","value":{"arrayValue":{"values":[{"boolValue":true},{"doubleValue":1.5}]}}}]}}}]}]}]}]}
EOF
# o mesmo log com os campos em outra ordem (o JSON do collector não garante ordem): mesmo fato, mesma chave
jq -c '.resourceLogs[0].scopeLogs[0].logRecords[0] |= (to_entries | reverse | from_entries)
       | .resourceLogs[0].resource.attributes |= reverse' "$TMP/claude.json" > "$TMP/claude-reordered.json"
# outro log sem id, 1 ns depois: fato diferente
jq -c '.resourceLogs[0].scopeLogs[0].logRecords[0].timeUnixNano = "1759000000123456790"' "$TMP/claude.json" > "$TMP/claude-2.json"
# sem timeUnixNano: vale a hora observada pela fonte
jq -c '.resourceLogs[0].scopeLogs[0].logRecords[0] |= (del(.timeUnixNano) | .body.stringValue = "sem hora")' "$TMP/claude.json" > "$TMP/observed.json"

# evento do oute-emit de verdade (oute-propose -> receptor falso), para repostar ao agent-studio
H="$TMP/prop"; BIN="$TMP/bin"; mkdir -p "$H" "$BIN"; ln -s "$ROOT/docker/oute-emit" "$BIN/oute-emit"; rcv_start "$TMP/r1"
PATH="$BIN:$PATH" OUTE_PROPOSE_AGENT=codex HOME="$H" OTEL_RESOURCE_ATTRIBUTES="host.name=oute-server,oute.instance=oute-agent" \
  "$ROOT/docker/oute-propose" "Ver disco" <<<$'set -euo pipefail\necho oi' >/dev/null 2>&1
rcv_stop
EMIT="$(ls "$TMP/r1"/*.json 2>/dev/null | head -1)"
check "oute-emit: evento capturado para o teste" test -n "$EMIT"
EVID="$(jq -r '.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] | select(.key == "oute.event.id") | .value.stringValue' "$EMIT")"
check "oute-emit: evento leva oute.event.id" test -n "$EVID"
# o mesmo evento, reenviado com outra hora de observação (outra cópia do mesmo fato): o id manda
jq -c '.resourceLogs[0].scopeLogs[0].logRecords[0].observedTimeUnixNano = "1"' "$EMIT" > "$TMP/emit-copy.json"

# ---------------------------------------------------------------- 1. autenticação
studio_start "$TMP/s" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
pcode() { code -X POST -H 'Content-Type: application/json' --data-binary "@$TMP/claude.json" "$@"; }
check "sem token: 401"                                 test "$(pcode "$STUDIO_URL/v1/logs")" = 401
check "token errado: 401"                              test "$(pcode -H "Authorization: Bearer ${STUDIO_TOKEN}errado" "$STUDIO_URL/v1/logs")" = 401
check "token sem 'Bearer': 401"                        test "$(pcode -H "Authorization: $STUDIO_TOKEN" "$STUDIO_URL/v1/logs")" = 401
check "GET /healthz sem token: 200 (só 'ok')"          test "$(curl -s "$STUDIO_URL/healthz")" = ok

# ---------------------------------------------------------------- 2. gravação e dedupe
check "com token: 200"                                 test "$(post logs "$TMP/claude.json")" = 200
check "mesmo log repostado: 200"                       test "$(post logs "$TMP/claude.json")" = 200
check "mesmo log, campos em outra ordem: 200"          test "$(post logs "$TMP/claude-reordered.json")" = 200
check "outro log (1 ns depois): 200"                   test "$(post logs "$TMP/claude-2.json")" = 200
check "evento do oute-emit: 200"                       test "$(post logs "$EMIT")" = 200
check "evento do oute-emit repostado: 200"             test "$(post logs "$EMIT")" = 200
check "cópia do evento (outra observação): 200"        test "$(post logs "$TMP/emit-copy.json")" = 200
gzip -c "$TMP/claude.json" > "$TMP/claude.json.gz"
check "corpo gzip (compressão do collector): 200"      test "$(post logs "$TMP/claude.json.gz" -H 'Content-Encoding: gzip')" = 200
check "sem timeUnixNano: 200"                          test "$(post logs "$TMP/observed.json")" = 200
studio_stop
check "log sem id repetido (3 envios + gzip) = 1 linha" test "$(count logs "WHERE time_unix_nano = 1759000000123456789")" = 1
check "outro log sem id = outra linha"                 test "$(count logs "WHERE time_unix_nano = 1759000000123456790")" = 1
check "evento do oute-emit 3 vezes = 1 linha (id)"     test "$(count logs "WHERE oute_event_id = '$EVID'")" = 1
check "total: 4 linhas"                                test "$(count logs)" = 4
row="$(studio_sql "$DB" "SELECT * FROM logs WHERE time_unix_nano = 1759000000123456789")"
check "colunas fixas: origem, agente, serviço"         jqe '.host_name == "oute-mac" and .oute_instance == "oute-agent" and .oute_agent == "claude" and .service_name == "claude-code"' <<<"$row"
check "colunas fixas: sessão, oute.task.id, rodada"    jqe '.session_id == "sess-1" and .oute_task_id == "oute-agent-x-20250927190640" and .oute_swarm_round == "swarm-0927-1900"' <<<"$row"
check "colunas fixas: event.name, corpo, severidade"   jqe '.event_name == "user_prompt" and .body == "claude_code.user_prompt" and .severity_text == "INFO" and .severity_number == 9' <<<"$row"
check "hora = hora do fato (2025), não a de chegada"   jqe '(.time | startswith("2025-09-27 19:06:40.123456")) and (.received_at | startswith("2025") | not)' <<<"$row"
check "JSON: atributos completos do registro"          jqe '.attributes as $a | $a.prompt == "olá" and $a.prompt_length == 3 and $a.extra.a == [true, 1.5]' <<<"$row"
check "JSON: atributos completos do resource"          jqe '.resource_attributes["service.name"] == "claude-code"' <<<"$row"
check "chave de dedupe = hash do conteúdo"             jqe '.dedupe_key | test("^h:[0-9a-f]{64}$")' <<<"$row"
row="$(studio_sql "$DB" "SELECT * FROM logs WHERE oute_event_id = '$EVID'")"
check "evento: chave = oute.event.id"                  jqe --arg id "$EVID" '.dedupe_key == "ev:" + $id' <<<"$row"
check "evento: event.name, agente e origem"            jqe '.event_name == "oute.canal.proposed" and .oute_agent == "codex" and .host_name == "oute-server" and .service_name == "oute"' <<<"$row"
row="$(studio_sql "$DB" "SELECT * FROM logs WHERE body = 'sem hora'")"
check "sem timeUnixNano: hora = a observada pela fonte" jqe '.time_unix_nano == 1759000000200000000' <<<"$row"

# ---------------------------------------------------------------- 3. reinício: dedupe continua valendo
studio_start "$TMP/s" || { echo "FAIL agent-studio não voltou"; exit 1; }
check "depois do restart, repostar: 200"               test "$(post logs "$TMP/claude.json")" = 200
check "depois do restart, evento repostado: 200"       test "$(post logs "$EMIT")" = 200

# ---------------------------------------------------------------- 4. corpo inválido = erro permanente
printf 'não é json' > "$TMP/lixo"
check "corpo que não é JSON: 400"                      test "$(post logs "$TMP/lixo")" = 400
printf '{"resourceLogs": 3}' > "$TMP/forma"
check "JSON fora do formato OTLP: 400"                 test "$(post logs "$TMP/forma")" = 400
check "protobuf (Content-Type errado): 415"            test "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $STUDIO_TOKEN" \
                                                         -H 'Content-Type: application/x-protobuf' --data-binary "@$TMP/claude.json" "$STUDIO_URL/v1/logs")" = 415
check "gzip corrompido: 400"                           test "$(post logs "$TMP/claude.json" -H 'Content-Encoding: gzip')" = 400
studio_stop
check "nada gravado pelos envios repetidos/inválidos"  test "$(count logs)" = 4

# ---------------------------------------------------------------- 5. falha na gravação = 503, nada gravado
studio_start "$TMP/s" STUDIO_FAIL=1 || { echo "FAIL agent-studio (falha injetada) não subiu"; exit 1; }
check "gravação falha depois do INSERT: 503"           test "$(post logs "$TMP/claude-2.json" -H 'X-Nada: 1')" = 503
jq -c '.resourceLogs[0].scopeLogs[0].logRecords[0].timeUnixNano = "1759000000999999999"' "$TMP/claude.json" > "$TMP/novo.json"
check "log novo com a gravação falhando: 503"          test "$(post logs "$TMP/novo.json")" = 503
check "503 traz Retry-After"                           bash -c 'curl -s -D - -o /dev/null -X POST -H "Authorization: Bearer $0" -H "Content-Type: application/json" --data-binary "@$1" "$2/v1/logs" | grep -qi "^retry-after:"' "$STUDIO_TOKEN" "$TMP/novo.json" "$STUDIO_URL"
studio_stop
check "falha = rollback: o log novo não ficou"         test "$(count logs "WHERE time_unix_nano = 1759000000999999999")" = 0
studio_start "$TMP/s" || { echo "FAIL agent-studio não voltou"; exit 1; }
check "o collector reenvia depois: 200"                test "$(post logs "$TMP/novo.json")" = 200
studio_stop
check "reenvio depois da falha grava uma vez"          test "$(count logs "WHERE time_unix_nano = 1759000000999999999")" = 1

# ---------------------------------------------------------------- 6. sem token configurado, não sobe
OUT="$(env AGENT_STUDIO_INGEST_TOKEN= AGENT_STUDIO_DB="$TMP/x.duckdb" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio 2>&1)"; RC=$?
check "credencial de ingestão vazia: sai com erro"         test "$RC" -ne 0
check "credencial de ingestão vazia: diz o item do vault"  grep -q "item agent-studio" <<<"$OUT"
check "credencial de ingestão vazia: não cria o banco"     test ! -e "$TMP/x.duckdb"

# ---------------------------------------------------------------- 6b. spans e métricas (#186)
# spans do Claude Code (claude_code.llm_request), do Codex (session_task.turn) e o jev.decision do jev-router
# (histórico até 2026-09-30, #218: o jev-router saiu do stack; a ingestão continua lendo o registro antigo)
cat > "$TMP/traces.json" <<'EOF'
{"resourceSpans":[
 {"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"oute-server"}},{"key":"oute.instance","value":{"stringValue":"oute-agent"}},
   {"key":"service.name","value":{"stringValue":"claude-code"}},{"key":"oute.agent","value":{"stringValue":"claude"}}]},
  "scopeSpans":[{"scope":{"name":"com.anthropic.claude_code.tracing"},"spans":[
   {"traceId":"0AF7651916CD43DD8448EB211C80319C","spanId":"B7AD6B7169203331","parentSpanId":"00F067AA0BA902B7","name":"claude_code.llm_request","kind":1,
    "startTimeUnixNano":"1759000000000000000","endTimeUnixNano":"1759000002500000000","status":{"code":1},
    "attributes":[{"key":"session.id","value":{"stringValue":"sess-c"}},{"key":"model","value":{"stringValue":"claude-sonnet-5"}},
      {"key":"input_tokens","value":{"intValue":"120"}},{"key":"output_tokens","value":{"intValue":"45"}},
      {"key":"cache_read_tokens","value":{"intValue":"1000"}},{"key":"cache_creation_tokens","value":{"intValue":"7"}},
      {"key":"request_id","value":{"stringValue":"req_011CfeRV8czH1ekSXWhWUQtd"}}],
    "events":[{"timeUnixNano":"1759000001000000000","name":"primeiro_token","attributes":[{"key":"n","value":{"intValue":"1"}}]}]}]}]},
 {"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"oute-mac"}},{"key":"service.name","value":{"stringValue":"codex_exec"}},
   {"key":"oute.agent","value":{"stringValue":"codex"}}]},
  "scopeSpans":[{"spans":[
   {"traceId":"1af7651916cd43dd8448eb211c80319c","spanId":"c7ad6b7169203331","name":"session_task.turn",
    "startTimeUnixNano":"1759000010000000000","endTimeUnixNano":"1759000011000000000",
    "attributes":[{"key":"model","value":{"stringValue":"gpt-5-codex"}},{"key":"codex.turn.token_usage.non_cached_input_tokens","value":{"intValue":"300"}},
      {"key":"codex.turn.token_usage.output_tokens","value":{"intValue":"80"}},{"key":"codex.turn.token_usage.cached_input_tokens","value":{"intValue":"2000"}}]}]}]},
 {"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"oute-server"}},{"key":"service.name","value":{"stringValue":"jev-router"}}]},
  "scopeSpans":[{"spans":[
   {"traceId":"2af7651916cd43dd8448eb211c80319c","spanId":"d7ad6b7169203331","name":"jev.decision",
    "startTimeUnixNano":"1759000020000000000","endTimeUnixNano":"1759000020500000000","status":{"code":2,"message":"deu ruim"},
    "attributes":[{"key":"oute.agent","value":{"stringValue":"pi"}},{"key":"gen_ai.request.model","value":{"stringValue":"@preset/oute-cheap"}},
      {"key":"gen_ai.response.model","value":{"stringValue":"openai/gpt-oss-20b"}},{"key":"gen_ai.usage.input_tokens","value":{"intValue":"50"}},
      {"key":"gen_ai.usage.output_tokens","value":{"intValue":"10"}},{"key":"oute.cost_usd","value":{"doubleValue":0.00037435}}]}]}]}]}
EOF
# métricas: as do próprio collector (#162: gauge da fila por exporter, sum de envios que falharam) + histograma
cat > "$TMP/metrics.json" <<'EOF'
{"resourceMetrics":[
 {"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"oute-mac"}},{"key":"oute.instance","value":{"stringValue":"oute-agent"}},
   {"key":"service.name","value":{"stringValue":"otelcol-contrib"}}]},
  "scopeMetrics":[{"scope":{"name":"go.opentelemetry.io/collector/exporter/exporterhelper"},"metrics":[
   {"name":"otelcol_exporter_queue_size","unit":"{items}","gauge":{"dataPoints":[
     {"timeUnixNano":"1759000060000000000","asInt":"524288000","attributes":[{"key":"exporter","value":{"stringValue":"awss3/logs"}}]},
     {"timeUnixNano":"1759000060000000000","asInt":"0","attributes":[{"key":"exporter","value":{"stringValue":"awss3/traces"}}]}]}},
   {"name":"otelcol_exporter_queue_capacity","unit":"{items}","gauge":{"dataPoints":[
     {"timeUnixNano":"1759000060000000000","asInt":"629145600","attributes":[{"key":"exporter","value":{"stringValue":"awss3/logs"}}]}]}},
   {"name":"otelcol_exporter_send_failed_log_records","unit":"{records}","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[
     {"startTimeUnixNano":"1758990000000000000","timeUnixNano":"1759000060000000000","asInt":"3","attributes":[{"key":"exporter","value":{"stringValue":"awss3/logs"}}]}]}}]}]},
 {"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"oute-server"}},{"key":"service.name","value":{"stringValue":"claude-code"}}]},
  "scopeMetrics":[{"metrics":[
   {"name":"claude_code.cost.usage","unit":"USD","sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[
     {"timeUnixNano":"1759000070000000000","asDouble":0.5,"attributes":[{"key":"session.id","value":{"stringValue":"sess-c"}},{"key":"oute.agent","value":{"stringValue":"claude"}}]}]}},
   {"name":"latencia","unit":"ms","histogram":{"aggregationTemporality":1,"dataPoints":[
     {"timeUnixNano":"1759000070000000000","count":"4","sum":10.5,"bucketCounts":["1","3"],"explicitBounds":[5]}]}}]}]}]}
EOF
studio_start "$TMP/s" || { echo "FAIL agent-studio não voltou"; exit 1; }
for sig in traces metrics; do
  check "$sig: sem token = 401"                        test "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "@$TMP/$sig.json" "$STUDIO_URL/v1/$sig")" = 401
  check "$sig: token errado = 401"                     test "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${STUDIO_TOKEN}x" -H 'Content-Type: application/json' --data-binary "@$TMP/$sig.json" "$STUDIO_URL/v1/$sig")" = 401
  check "$sig: com token = 200"                        test "$(post "$sig" "$TMP/$sig.json")" = 200
  check "$sig: mesmo lote reenviado = 200"             test "$(post "$sig" "$TMP/$sig.json")" = 200
  gzip -c "$TMP/$sig.json" > "$TMP/$sig.json.gz"
  check "$sig: mesmo lote em gzip = 200"               test "$(post "$sig" "$TMP/$sig.json.gz" -H 'Content-Encoding: gzip')" = 200
done
# ids em maiúsculas (outro encoder) = o mesmo span
jq -c '.resourceSpans[1].scopeSpans[0].spans[0] |= (.traceId |= ascii_upcase | .spanId |= ascii_upcase)' "$TMP/traces.json" > "$TMP/spans-upper.json"
check "traces: mesmo span com ids em maiúsculas = 200" test "$(post traces "$TMP/spans-upper.json")" = 200
printf '{"resourceSpans":[{"scopeSpans":[{"spans":[{"name":"sem id"}]}]}]}' > "$TMP/span-sem-id.json"
check "traces: span sem traceId/spanId = 400"          test "$(post traces "$TMP/span-sem-id.json")" = 400
printf '{"resourceMetrics": 3}' > "$TMP/forma-m"
check "metrics: fora do formato = 400"                 test "$(post metrics "$TMP/forma-m")" = 400
studio_stop
check "spans: reenvio não duplica (3 spans)"           test "$(count spans)" = 3
check "metrics: reenvio não duplica (6 pontos)"        test "$(count metrics)" = 6
row="$(studio_sql "$DB" "SELECT * FROM spans WHERE name = 'claude_code.llm_request'")"
# como em produção, o span do Claude chega sem custo: ele vem no log api_request de mesmo request_id, lido na consulta (#157)
check "span Claude: modelo, tokens, sem custo no span"  jqe '.model == "claude-sonnet-5" and .input_tokens == 120 and .output_tokens == 45 and .cache_read_tokens == 1000 and .cache_creation_tokens == 7 and .cost_usd == null' <<<"$row"
check "span Claude: ids em minúsculas, pai, duração"   jqe '.trace_id == "0af7651916cd43dd8448eb211c80319c" and .span_id == "b7ad6b7169203331" and .parent_span_id == "00f067aa0ba902b7" and .duration_ns == 2500000000' <<<"$row"
check "span Claude: origem, agente, sessão, hora"      jqe '.host_name == "oute-server" and .oute_agent == "claude" and .session_id == "sess-c" and (.time | startswith("2025-09-27 19:06:40"))' <<<"$row"
check "span Claude: chave trace_id + span_id"          jqe '.dedupe_key == "s:0af7651916cd43dd8448eb211c80319c:b7ad6b7169203331"' <<<"$row"
check "span Claude: eventos e atributos em JSON"       jqe '.events[0].name == "primeiro_token" and .events[0].attributes.n == 1 and .attributes.model == "claude-sonnet-5"' <<<"$row"
row="$(studio_sql "$DB" "SELECT * FROM spans WHERE name = 'session_task.turn'")"
check "span Codex: modelo e tokens (sem custo real)"   jqe '.model == "gpt-5-codex" and .input_tokens == 300 and .output_tokens == 80 and .cache_read_tokens == 2000 and .cost_usd == null and .oute_agent == "codex"' <<<"$row"
row="$(studio_sql "$DB" "SELECT * FROM spans WHERE name = 'jev.decision'")"
check "jev.decision: modelo servido, tokens, custo"    jqe '.model == "openai/gpt-oss-20b" and .input_tokens == 50 and .output_tokens == 10 and .cost_usd == 0.00037435 and .oute_agent == "pi"' <<<"$row"
check "jev.decision: status de erro"                   jqe '.status_code == 2 and .status_message == "deu ruim"' <<<"$row"
row="$(studio_sql "$DB" "SELECT * FROM metrics WHERE metric_name = 'otelcol_exporter_queue_size' AND (attributes->>'exporter') = 'awss3/logs'")"
check "métrica do collector: fila, valor, origem"      jqe '.metric_type == "gauge" and .value == 524288000 and .host_name == "oute-mac" and .service_name == "otelcol-contrib" and .unit == "{items}"' <<<"$row"
check "métrica do collector: hora do fato"             jqe '.time | startswith("2025-09-27 19:07:40")' <<<"$row"
check "métrica: chave = hash"                          jqe '.dedupe_key | test("^h:[0-9a-f]{64}$")' <<<"$row"
check "métrica do collector: os dois exporters"        test "$(count metrics "WHERE metric_name = 'otelcol_exporter_queue_size'")" = 2
row="$(studio_sql "$DB" "SELECT * FROM metrics WHERE metric_name = 'otelcol_exporter_send_failed_log_records'")"
check "métrica sum: monotônica, temporalidade, início" jqe '.metric_type == "sum" and .value == 3 and .is_monotonic == true and .aggregation_temporality == 2 and .start_unix_nano == 1758990000000000000' <<<"$row"
row="$(studio_sql "$DB" "SELECT * FROM metrics WHERE metric_name = 'claude_code.cost.usage'")"
check "métrica do Claude: sessão e agente do ponto"    jqe '.value == 0.5 and .session_id == "sess-c" and .oute_agent == "claude"' <<<"$row"
row="$(studio_sql "$DB" "SELECT * FROM metrics WHERE metric_name = 'latencia'")"
check "histograma: soma, contagem e buckets no JSON"   jqe '.metric_type == "histogram" and .value == 10.5 and .count == 4 and .point.bucketCounts == ["1","3"]' <<<"$row"
# mesmas regras de 503 dos logs: falha depois do INSERT volta tudo
studio_start "$TMP/s" STUDIO_FAIL=1 || { echo "FAIL agent-studio (falha injetada) não subiu"; exit 1; }
jq -c '.resourceSpans[0].scopeSpans[0].spans[0].spanId = "e7ad6b7169203331"' "$TMP/traces.json" > "$TMP/spans-novo.json"
jq -c '.resourceMetrics[0].scopeMetrics[0].metrics[0].gauge.dataPoints[0].timeUnixNano = "1759000120000000000"' "$TMP/metrics.json" > "$TMP/metrics-novo.json"
check "traces: gravação falha = 503"                   test "$(post traces "$TMP/spans-novo.json")" = 503
check "metrics: gravação falha = 503"                  test "$(post metrics "$TMP/metrics-novo.json")" = 503
studio_stop
check "traces: 503 = nada gravado"                     test "$(count spans)" = 3
check "metrics: 503 = nada gravado"                    test "$(count metrics)" = 6

# ---------------------------------------------------------------- 7. serviço no compose
SVC="$(compose_service agent-studio)"
has() { grep -qE -- "$1" <<<"$SVC"; }
check "compose: serviço agent-studio existe"           test -n "$SVC"
check "compose: só com o profile agent-studio"         has '^    profiles: \[agent-studio\]$'
check "compose: publicado só em 127.0.0.1"             has '^      - "127\.0\.0\.1:\$\{OUTE_AGENT_STUDIO_PORT:-8430\}:8430"$'
check "compose: nunca 0.0.0.0"                         bash -c '! grep -q "0\.0\.0\.0" <<<"$0"' "$(grep -v '^ *#' <<<"$SVC")"
check "compose: mem_limit"                             has '^    mem_limit: \$\{OUTE_AGENT_STUDIO_MEM:-2g\}$'
check "compose: volume nomeado para o DuckDB"          has '^      - oute-agent-studio:/data/agent-studio$'
check "compose: volume declarado"                      grep -qx '  oute-agent-studio:' "$ROOT/docker/compose.yaml"
check "compose: mesma imagem do agent"                 has 'image: ghcr\.io/renatobardi/oute-agent:\$\{OUTE_VERSION:-latest\}'
check "compose: um processo (python -m agent_studio)"  has 'entrypoint: \["/opt/agent-studio/venv/bin/python", "-m", "agent_studio"\]'
check "compose: credencial de ingestão do ambiente (services.env)" has 'AGENT_STUDIO_INGEST_TOKEN: \$\{AGENT_STUDIO_INGEST_TOKEN:-\}'
check "compose: credencial de leitura do ambiente (agent.env)" has 'AGENT_STUDIO_READ_TOKEN: \$\{AGENT_STUDIO_READ_TOKEN:-\}'
check "Dockerfile: copia o pacote e instala por hash"  bash -c 'grep -q "COPY docker/agent-studio/agent_studio /opt/agent-studio/app/agent_studio" "$0" && grep -q -- "--require-hashes -r /opt/agent-studio/requirements.txt" "$0"' "$ROOT/docker/Dockerfile"

# ---------------------------------------------------------------- 8. `oute up`: item do vault -> profile
# só as funções do agent-studio (o script inteiro roda o case no fim)
FUNCS="$(sed -n '/^# --- agent-studio (ADR-08/,/^legacy_cleanup()/p' "$ROOT/scripts/oute" | sed '$d')"
check "scripts/oute: funções do agent-studio achadas"  test -n "$FUNCS"
envf="$TMP/env"; : > "$envf"
T1="$(python3 -c "import secrets; print(secrets.token_hex(8))")"; S1="$(python3 -c "import secrets; print(secrets.token_hex(8))")"
up() { OUT="$(cd "$TMP" && env -i PATH="$PATH" HOME="$TMP" "$@" bash -c "set -euo pipefail; ROOT=$TMP; AGENT_ENV_FILE=~/.oute/agent.env
  SERVICES_ENV_FILE=~/.oute/services.env; SERVICES_FOLDER=oute-services
  env_get() { sed -n \"s/^[[:space:]]*\$1=//p\" \"\$ROOT/.env\" 2>/dev/null | tail -1; }
  $FUNCS"$'\n'"agent_studio_up; echo \"profiles=\${COMPOSE_PROFILES:-}\"; echo \"token=\${AGENT_STUDIO_INGEST_TOKEN:-}\"; echo \"antigo=\${AGENT_STUDIO_TOKEN:-}\"" 2>&1)"; RC=$?; }
rm -f "$TMP/.env"
R1="$(python3 -c "import secrets; print(secrets.token_hex(8))")"
up AGENT_STUDIO_INGEST_TOKEN=$T1 AGENT_STUDIO_SURREAL_PASS=$S1
check "sem OUTE_AGENT_STUDIO (Mac): não liga, sem aviso" test "$OUT" = "profiles="$'\n'"token=$T1"$'\n'"antigo="
printf 'OUTE_AGENT_STUDIO=1\n' > "$TMP/.env"
up AGENT_STUDIO_INGEST_TOKEN=$T1 AGENT_STUDIO_READ_TOKEN=$R1 AGENT_STUDIO_SURREAL_PASS=$S1
check ".env com OUTE_AGENT_STUDIO=1, credenciais e senha: liga" grep -qx 'profiles=agent-studio' <<<"$OUT"
check "…e sem aviso"                                   bash -c '! grep -q aviso <<<"$0"' "$OUT"
# transição (#256): só o token único de antes
up AGENT_STUDIO_TOKEN=$T1 AGENT_STUDIO_SURREAL_PASS=$S1
check "só o token antigo: liga, com ele na ingestão"   bash -c 'grep -qx "profiles=agent-studio" <<<"$0" && grep -qx "token=$1" <<<"$0"' "$OUT" "$T1"
check "só o token antigo: o nome antigo não segue ao compose" grep -qx 'antigo=' <<<"$OUT"
check "só o token antigo: avisa a transição e a pasta" grep -q 'aviso: transição (#256).*AGENT_STUDIO_INGEST_TOKEN.*pasta oute-services' <<<"$OUT"
check "sem a credencial de leitura: avisa e sobe"      grep -q 'aviso: AGENT_STUDIO_READ_TOKEN não está em .*pasta oute-agent' <<<"$OUT"
check "avisos sem valor de segredo"                    bash -c '! grep -qF -e "$1" -e "$2" <<<"$(grep aviso <<<"$0")"' "$OUT" "$T1" "$S1"
up AGENT_STUDIO_INGEST_TOKEN=$T1 AGENT_STUDIO_TOKEN=${T1}velho AGENT_STUDIO_SURREAL_PASS=$S1 AGENT_STUDIO_READ_TOKEN=$R1
check "credencial nova vence o token antigo, sem aviso" bash -c 'grep -qx "token=$1" <<<"$0" && ! grep -q aviso <<<"$0"' "$OUT" "$T1"
up AGENT_STUDIO_INGEST_TOKEN=$T1 AGENT_STUDIO_READ_TOKEN=$R1 AGENT_STUDIO_SURREAL_PASS=$S1 COMPOSE_PROFILES=outro
check "soma ao COMPOSE_PROFILES que já existe"         grep -qx 'profiles=outro,agent-studio' <<<"$OUT"
up
check "sem o item no vault: não liga"                  grep -qx 'profiles=' <<<"$OUT"
check "sem o item no vault: avisa e cita o item"       grep -q 'aviso: OUTE_AGENT_STUDIO=1, mas AGENT_STUDIO_INGEST_TOKEN AGENT_STUDIO_SURREAL_PASS não está em .*services.env (item agent-studio da pasta oute-services' <<<"$OUT"
check "sem o item no vault: não bloqueia (rc 0)"       test "$RC" = 0
up AGENT_STUDIO_INGEST_TOKEN=$T1
check "item sem a senha do SurrealDB: não liga"        grep -qx 'profiles=' <<<"$OUT"
check "item sem a senha do SurrealDB: avisa qual falta" grep -q 'mas AGENT_STUDIO_SURREAL_PASS não está em' <<<"$OUT"
rm -f "$TMP/.env"
up OUTE_AGENT_STUDIO=1 AGENT_STUDIO_INGEST_TOKEN=$T1 AGENT_STUDIO_SURREAL_PASS=$S1
check "OUTE_AGENT_STUDIO=1 no ambiente também liga"    grep -qx 'profiles=agent-studio' <<<"$OUT"
check "up chama agent_studio_up depois dos segredos"   grep -q 'host_secrets "$refresh"; agent_studio_up;' "$ROOT/scripts/oute"
check "down/status enxergam o profile"                 bash -c 'grep -q "\-\-profile \"\$STUDIO_PROFILE\" down" "$0" && grep -q "\-\-profile \"\$STUDIO_PROFILE\" ps" "$0"' "$ROOT/scripts/oute"

# ---------------------------------------------------------------- 9. SurrealDB: estado derivado (#187)
. "$ROOT/tests/lib/surreal.sh"
surreal_bin
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não subiu"; }
trap 'studio_stop; rcv_stop; surreal_stop; rm -rf "$TMP"' EXIT
sq() { surreal_q "$1"; }

# eventos de verdade: oute-emit lendo os artefatos (canal e rodada) -> receptor falso -> repostados ao agent-studio
E="$TMP/emit"; mkdir -p "$E/outbox" "$E/inbox"; rcv_start "$TMP/r2"
emit() { HOME="$E" PATH="$BIN:$PATH" OTEL_RESOURCE_ATTRIBUTES="host.name=oute-server,oute.instance=oute-agent" "$ROOT/docker/oute-emit" "$@"; }
P1=20260929-074200-ver-disco; P2=20260929-074300-limpar; P3=20260929-074400-pendente; P4=20260929-074500-fora-de-ordem
for p in $P1 $P2 $P3 $P4; do
  printf '# oute-propose\n# titulo: pedido %s\n# como: root\n# agente: claude\n# criado: 2026-09-29T07:%s:00Z\n\necho %s\n' \
    "$p" "${p:11:2}" "$p" > "$E/outbox/$p.sh"
  emit canal "$p"
done
printf '# id: %s\n# rc: 0\n# como: root\n# aprovado: 2026-09-29T07:42:30Z por bardi@oute-server\n# duracao: 3 s\n# saida: 12 bytes\n# sha256: 409eccc983f8\n\nSAIDA-DO-HOST\n' "$P1" > "$E/inbox/$P1.out"
printf '# id: %s\n# rc: 126\n# recusado: 2026-09-29T07:43:30Z por bardi@oute-mac\n# sha256: aaaaaaaaaaaa\n\nrecusado\n' "$P2" > "$E/inbox/$P2.out"
printf '# id: %s\n# rc: 1\n# aprovado: 2026-09-29T07:45:30Z por bardi@oute-server\n\n' "$P4" > "$E/inbox/$P4.out"
for p in $P1 $P2 $P4; do emit canal "$p"; done
RND=swarm-0929-0742; R="$E/.oute/swarm/$RND"; mkdir -p "$R"
printf 'repo=/workspace/oute-agent\nmax=2\nlabel=studio-ingestao\nagent=claude\n' > "$R/meta"
printf '185-logs w1:p1 codex 2026-09-29T07:43:00Z w1:t1 /workspace/oute-agent\n186-spans w1:p2 claude 2026-09-29T07:44:00Z w1:t2 /workspace/oute-agent\n' > "$R/spawned"
: > "$R/log"
for l in "2026-09-29T07:42:00Z abertura $RND (repo oute-agent, max 2, label studio-ingestao)" \
         "2026-09-29T07:43:00Z spawn 185-logs codex" "2026-09-29T07:44:00Z spawn 186-spans claude" \
         "2026-09-29T08:10:00Z close 185-logs" "2026-09-29T09:00:00Z rodada fechada"; do
  printf '%s\n' "$l" >> "$R/log"; emit swarm "$RND" "$l"
done
rcv_stop
check "oute-emit: 12 eventos capturados (7 canal, 5 rodada)" test "$(events "$TMP/r2" | grep -c .)" = 12
# decided do P4 fica à parte, para chegar ANTES do proposed
DEC4="$(grep -l "\"$P4\"" "$TMP/r2"/*.json | xargs grep -l oute.canal.decided)"
mkdir -p "$TMP/r2-sem-dec4"; for f in "$TMP/r2"/*.json; do [[ "$f" == "$DEC4" ]] || cp "$f" "$TMP/r2-sem-dec4/"; done
# sessões do oute-task (#128; o oute-emit ainda não as emite): uma de rodada (worker 185-logs) e uma avulsa removida,
# e a conversa do Claude que roda na sessão de rodada (identidade da sessão no resource)
cat > "$TMP/task.json" <<'EOF'
{"resourceLogs":[{"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"oute-server"}},{"key":"oute.instance","value":{"stringValue":"oute-agent"}},
  {"key":"service.name","value":{"stringValue":"oute"}},{"key":"oute.agent","value":{"stringValue":"claude"}}]},
 "scopeLogs":[{"scope":{"name":"oute-emit"},"logRecords":[
  {"timeUnixNano":"1790668980000000000","eventName":"oute.task.opened","attributes":[{"key":"event.name","value":{"stringValue":"oute.task.opened"}},
    {"key":"oute.event.id","value":{"stringValue":"task-ev-1"}},{"key":"oute.task.id","value":{"stringValue":"oute-agent-185-logs-20260929074300"}},
    {"key":"oute.task.repo","value":{"stringValue":"oute-agent"}},{"key":"oute.task.slug","value":{"stringValue":"185-logs"}},
    {"key":"oute.task.agent","value":{"stringValue":"codex"}},{"key":"oute.swarm.round","value":{"stringValue":"swarm-0929-0742"}},
    {"key":"oute.swarm.session","value":{"stringValue":"185-logs"}}]},
  {"timeUnixNano":"1790668000000000000","eventName":"oute.task.opened","attributes":[{"key":"event.name","value":{"stringValue":"oute.task.opened"}},
    {"key":"oute.event.id","value":{"stringValue":"task-ev-2"}},{"key":"oute.task.id","value":{"stringValue":"lab-conserto-20260929072640"}},
    {"key":"oute.task.repo","value":{"stringValue":"lab"}},{"key":"oute.task.slug","value":{"stringValue":"conserto"}},{"key":"oute.task.agent","value":{"stringValue":"claude"}}]},
  {"timeUnixNano":"1790675000000000000","eventName":"oute.task.removed","attributes":[{"key":"event.name","value":{"stringValue":"oute.task.removed"}},
    {"key":"oute.event.id","value":{"stringValue":"task-ev-3"}},{"key":"oute.task.id","value":{"stringValue":"lab-conserto-20260929072640"}},
    {"key":"oute.task.reason","value":{"stringValue":"pr-mergeado"}}]}]}]},
 {"resource":{"attributes":[{"key":"host.name","value":{"stringValue":"oute-server"}},{"key":"service.name","value":{"stringValue":"claude-code"}},
  {"key":"oute.task.id","value":{"stringValue":"oute-agent-185-logs-20260929074300"}},{"key":"oute.swarm.round","value":{"stringValue":"swarm-0929-0742"}}]},
 "scopeLogs":[{"logRecords":[{"timeUnixNano":"1790669000000000000","body":{"stringValue":"claude_code.api_request"},
  "attributes":[{"key":"session.id","value":{"stringValue":"conv-185"}},{"key":"oute.agent","value":{"stringValue":"codex"}}]}]}]}]}
EOF

SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS")
OUT="$(env AGENT_STUDIO_INGEST_TOKEN="$T1" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS= AGENT_STUDIO_DB="$TMP/y.duckdb" \
  PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio 2>&1)"; RC=$?
check "SurrealDB sem senha: não sobe e diz o item"     bash -c '[[ $0 -ne 0 ]] && grep -q "AGENT_STUDIO_SURREAL_PASS vazio" <<<"$1"' "$RC" "$OUT"
DB="$TMP/s2/db.duckdb"
studio_start "$TMP/s2" "${SENV[@]}" || { cat "$TMP/s2/stderr"; die "agent-studio com SurrealDB não subiu"; }
check "decided antes do proposed: 200"                 test "$(post logs "$DEC4")" = 200
postall() { local f rc=0; for f in "$1"/*.json; do [[ "$(post logs "$f")" == 200 ]] || rc=1; done; [[ "$(post logs "$TMP/task.json")" == 200 ]] || rc=1; return $rc; }
check "eventos e sessões: 200"                         postall "$TMP/r2-sem-dec4"
p1="$(sq "SELECT * FROM pedido:\`$P1\`" | jq -c '.[0]')"
check "pedido executado: estado, decisão, rc, aprovador" jqe '.state == "decidido" and .decision == "executado" and .rc == 0 and .approver == "bardi@oute-server" and .decided_by == "human"' <<<"$p1"
check "pedido executado: título, como, agente, horas"  jqe --arg t "pedido $P1" '.title == $t and .as == "root" and .agent == "claude" and (.proposed_at | startswith("2026-09-29T07:42:00")) and (.decided_at | startswith("2026-09-29T07:42:30"))' <<<"$p1"
check "pedido executado: duração, saída, sem a saída"  jqe '.duration_s == 3 and .output_bytes == 12 and (tostring | contains("SAIDA-DO-HOST") | not)' <<<"$p1"
check "pedido executado: liga aos eventos (ids)"       jqe '(.proposed_event | length) == 32 and (.decided_event | length) == 32' <<<"$p1"
check "pedido recusado"                                jqe '.[0].state == "decidido" and .[0].decision == "recusado" and .[0].rc == 126 and .[0].approver == "bardi@oute-mac"' <<<"$(sq "SELECT * FROM pedido:\`$P2\`")"
check "pedido sem decisão: pendente"                   jqe '.[0].state == "pendente" and .[0].decision == null' <<<"$(sq "SELECT * FROM pedido:\`$P3\`")"
check "decided antes do proposed: continua decidido"   jqe --arg t "pedido $P4" '.[0].state == "decidido" and .[0].rc == 1 and .[0].title == $t' <<<"$(sq "SELECT * FROM pedido:\`$P4\`")"
r="$(sq "SELECT * FROM rodada:\`$RND\`" | jq -c '.[0]')"
check "rodada: fechada, repo, max, dispatcher, horas" jqe '.state == "fechada" and .repo == "oute-agent" and .max == 2 and .agent == "claude" and (.opened_at | startswith("2026-09-29T07:42")) and (.closed_at | startswith("2026-09-29T09:00"))' <<<"$r"
w="$(sq "SELECT *, rodada.state AS rodada_state, sessao.repo AS sessao_repo FROM worker:['$RND', '185-logs']" | jq -c '.[0]')"
check "worker 185: fechado, agente, issue, ligado à rodada" jqe --arg r "$RND" '.state == "fechada" and .agent == "codex" and .issue == 185 and .rodada_state == "fechada" and (.spawned_at | startswith("2026-09-29T07:43")) and (.closed_at | startswith("2026-09-29T08:10"))' <<<"$w"
check "worker 185: ligado à sessão do oute-task"       jqe '.sessao_repo == "oute-agent" and (.sessao | tostring | contains("oute-agent-185-logs-20260929074300"))' <<<"$w"
check "worker 186: aberto (spawn sem close)"           jqe '.[0].state == "aberta" and .[0].agent == "claude"' <<<"$(sq "SELECT * FROM worker:['$RND', '186-spans']")"
check "rodada -> workers (2)"                          test "$(sq "SELECT count() AS n FROM worker WHERE rodada = rodada:\`$RND\` GROUP ALL" | jq '.[0].n')" = 2
s1="$(sq "SELECT *, rodada.repo AS rodada_repo, worker.slug AS worker_slug FROM sessao:\`oute-agent-185-logs-20260929074300\`" | jq -c '.[0]')"
check "sessão de rodada: aberta, ligada à rodada e ao worker" jqe '.state == "aberta" and .agent == "codex" and .slug == "185-logs" and .rodada_repo == "oute-agent" and .worker_slug == "185-logs"' <<<"$s1"
s2="$(sq "SELECT * FROM sessao:\`lab-conserto-20260929072640\`" | jq -c '.[0]')"
check "sessão avulsa: removida, motivo, sem rodada"    jqe '.state == "removida" and .removed_reason == "pr-mergeado" and .repo == "lab" and .rodada == null and (.removed_at | startswith("2026-09-29T09:43:20"))' <<<"$s2"
c="$(sq "SELECT *, sessao.slug AS sessao_slug FROM conversa:\`conv-185\`" | jq -c '.[0]')"
check "conversa ligada à sessão (session.id -> oute.task.id)" jqe '.sessao_slug == "185-logs" and .agent == "codex" and .service == "claude-code"' <<<"$c"
snap() { local t; for t in pedido rodada worker sessao conversa; do sq "SELECT * FROM $t ORDER BY id"; done; }
reenvia() { postall "$TMP/r2-sem-dec4" && postall "$TMP/r2-sem-dec4" && [[ "$(post logs "$DEC4")" == 200 ]]; }
before="$(snap)"
check "reenvio do mesmo lote (2 vezes): 200"           reenvia
check "reenvio não duplica nem muda nada no SurrealDB" test "$(snap)" = "$before"
check "contagens: 4 pedidos, 1 rodada, 2 workers, 2 sessões, 1 conversa" \
  test "$(for t in pedido rodada worker sessao conversa; do sq "SELECT count() AS n FROM $t GROUP ALL" | jq -r '.[0].n'; done | tr '\n' ' ')" = "4 1 2 2 1 "

# SurrealDB fora: 503 e nada no DuckDB; quando volta, o reenvio grava nos dois
P5=20260929-080000-com-surreal-fora
printf '# oute-propose\n# titulo: fora\n# como: user\n# agente: pi\n# criado: 2026-09-29T08:00:00Z\n\necho x\n' > "$E/outbox/$P5.sh"
rcv_start "$TMP/r3"; emit canal "$P5"; rcv_stop
EV5="$(ls "$TMP/r3"/*.json | head -1)"
surreal_stop
check "SurrealDB fora: 503"                            test "$(post logs "$EV5")" = 503
check "SurrealDB fora: métrica (sem estado) grava: 200" test "$(post metrics "$TMP/metrics.json")" = 200
studio_stop
check "SurrealDB fora: nada do evento no DuckDB"       test "$(count logs "WHERE (attributes->>'oute.canal.id') = '$P5'")" = 0
surreal_start "$TMP/sdb" || die "SurrealDB não voltou"
studio_start "$TMP/s2" "${SENV[@]}" || die "agent-studio não voltou"
check "SurrealDB de volta: o reenvio grava (200)"      test "$(post logs "$EV5")" = 200
check "SurrealDB de volta: pedido no SurrealDB"        jqe '.[0].state == "pendente" and .[0].agent == "pi"' <<<"$(sq "SELECT * FROM pedido:\`$P5\`")"
check "SurrealDB de volta: dados antigos continuam"    jqe '.[0].state == "decidido"' <<<"$(sq "SELECT * FROM pedido:\`$P1\`")"
studio_stop
check "SurrealDB de volta: evento no DuckDB, uma vez"  test "$(count logs "WHERE (attributes->>'oute.canal.id') = '$P5'")" = 1
check "DuckDB: eventos da rodada e do canal, uma vez"  test "$(count logs "WHERE event_name LIKE 'oute.%'")" = 16

# serviço surrealdb no compose
SVC="$(compose_service surrealdb)"
check "compose: surrealdb fixado por digest"           has '^    image: \$\{OUTE_SURREALDB_IMAGE:-surrealdb/surrealdb:v[0-9.]+@sha256:[0-9a-f]{64}\}$'
check "compose: surrealdb só no profile agent-studio"  has '^    profiles: \[agent-studio\]$'
check "compose: surrealdb sem porta publicada"         bash -c '! grep -qE "^    ports:" <<<"$0"' "$SVC"
check "compose: surrealdb com mem_limit"               has '^    mem_limit: \$\{OUTE_SURREALDB_MEM:-1g\}$'
check "compose: surrealdb em RocksDB num volume"       bash -c 'grep -q "rocksdb:///data/surrealdb" <<<"$0" && grep -q "^      - oute-surrealdb:/data/surrealdb$" <<<"$0"' "$SVC"
check "compose: surrealdb com senha do vault"          has 'SURREAL_PASS: \$\{AGENT_STUDIO_SURREAL_PASS:-\}'
check "compose: surrealdb sem --unauthenticated"       bash -c '! grep -q unauthenticated <<<"$0"' "$SVC"
check "compose: volume-init dá o dono do volume"       grep -q '^      - oute-surrealdb:/v/surrealdb$' "$ROOT/docker/compose.yaml"

# ---------------------------------------------------------------- 10. telemetria própria ao collector (#188)
# o agent-studio exporta pelo SDK OTel (OTLP/HTTP protobuf) ao receptor falso; o decodificador usa o proto do venv
dec() { "$STUDIO_PY" "$ROOT/tests/lib/otlp-pb-decode.py" "$1" "$2"; }
# um objeto por registro de log: {sev, body, attrs{}, res{}}
tlogs() { dec "$1" logs | jq -c '.resourceLogs[] | (.resource.attributes | map({(.key): (.value | to_entries[0].value)}) | add) as $res
  | .scopeLogs[].logRecords[] | {sev: .severityText, body: .body.stringValue, attrs: ((.attributes // []) | map({(.key): (.value | to_entries[0].value)}) | add), res: $res}'; }
# um objeto por ponto de métrica: {name, value, attrs{}, res{}} (soma dos pontos cumulativos: o último vale)
tmetrics() { dec "$1" metrics | jq -c '.resourceMetrics[] | (.resource.attributes | map({(.key): (.value | to_entries[0].value)}) | add) as $res
  | .scopeMetrics[].metrics[] | .name as $n | ((.sum // .histogram).dataPoints[])
  | {name: $n, value: ((.asInt // .asDouble // .count) | tonumber), attrs: ((.attributes // []) | map({(.key): (.value | to_entries[0].value)}) | add), res: $res}'; }
last() { tmetrics "$TMP/r4" | jq -s -c --arg n "$1" "map(select(.name == \$n and ($2))) | last | .value // 0"; }
TENV=(OTEL_RESOURCE_ATTRIBUTES="host.name=oute-server,oute.instance=oute-agent,deployment.environment=oute-server"
      OTEL_METRIC_EXPORT_INTERVAL=300 OTEL_BLRP_SCHEDULE_DELAY=100 AGENT_STUDIO_LOG_EVERY=1)
rcv_start "$TMP/r4"; TEL_EP="$OTEL_EXPORTER_OTLP_ENDPOINT"; unset OTEL_EXPORTER_OTLP_ENDPOINT
studio_start "$TMP/s3" "${TENV[@]}" OTEL_EXPORTER_OTLP_ENDPOINT="$TEL_EP" || { cat "$TMP/s3/stderr"; die "agent-studio com telemetria não subiu"; }
post logs "$TMP/claude.json" >/dev/null; post logs "$TMP/claude.json" >/dev/null; post logs "$TMP/claude-2.json" >/dev/null
for i in 1 2 3; do pcode -H "Authorization: Bearer ${STUDIO_TOKEN}errado" "$STUDIO_URL/v1/logs" >/dev/null; done
sleep 1.2
pcode "$STUDIO_URL/v1/logs" >/dev/null
post logs "$TMP/lixo" >/dev/null
studio_stop   # SIGTERM: o SDK exporta o que ficou no lote
studio_start "$TMP/s3" "${TENV[@]}" OTEL_EXPORTER_OTLP_ENDPOINT="$TEL_EP" STUDIO_FAIL=1 || die "agent-studio (falha injetada) não subiu"
post logs "$TMP/novo.json" >/dev/null
studio_stop
L="$(tlogs "$TMP/r4")"
check "telemetria: logs chegaram ao collector"         test -n "$L"
check "origem de sempre + service.name próprio"        jqe -s 'all(.res["service.name"] == "agent-studio" and .res["host.name"] == "oute-server" and .res["oute.instance"] == "oute-agent")' <<<"$L"
check "sem oute.agent (não é agente)"                  jqe -s 'all(.res["oute.agent"] == null)' <<<"$L"
check "log: requisição recusada (token)"               jqe -s 'map(select(.sev == "WARN" and (.body | startswith("recusado: token ausente ou errado (logs)")))) | length == 2' <<<"$L"
check "log: 3 recusas seguidas = 1 aviso; o seguinte conta os suprimidos" \
                                                       jqe -s 'map(select(.body | startswith("recusado: token"))) | .[1].body | endswith("(+2 suprimidos desde o último aviso)")' <<<"$L"
check "log: corpo inválido"                            jqe -s 'any(.body | startswith("recusado: logs inválido"))' <<<"$L"
check "log: gravação que falhou (503)"                 jqe -s 'any(.sev == "ERROR" and (.body == "gravação falhou, respondi 503 (logs, 1 registros): RuntimeError"))' <<<"$L"
check "log: tipo do aviso no atributo"                 jqe -s 'any(.attrs["agent_studio.warning"] == "write-failed")' <<<"$L"
check "sucesso não vira log OTel (só stderr)"          jqe -s 'all(.body | test("gravados") | not)' <<<"$L"
check "métrica: requisições 200 (3)"                   test "$(last agent_studio.requests '.attrs["http.response.status_code"] == "200"')" = 3
check "métrica: requisições 401 (4)"                   test "$(last agent_studio.requests '.attrs["http.response.status_code"] == "401"')" = 4
check "métrica: requisições 400 (1)"                   test "$(last agent_studio.requests '.attrs["http.response.status_code"] == "400"')" = 1
check "métrica: requisições 503 (1)"                   test "$(last agent_studio.requests '.attrs["http.response.status_code"] == "503"')" = 1
check "métrica: registros gravados (2)"               test "$(last agent_studio.records.written '.attrs.signal == "logs"')" = 2
check "métrica: registros repetidos (1)"               test "$(last agent_studio.records.duplicate '.attrs.signal == "logs"')" = 1
check "métrica: duração da gravação (ok e erro)"       bash -c '[[ "$0" -ge 3 && "$1" -ge 1 ]]' "$(last agent_studio.write.duration '.attrs.result == "ok"')" "$(last agent_studio.write.duration '.attrs.result == "error"')"
# sem laço: a telemetria do agent-studio volta a ele (#155) e não gera registro novo
dec "$TMP/r4" logs > "$TMP/own-logs.jsonl"
dec "$TMP/r4" metrics > "$TMP/own-metrics.jsonl"
rm -rf "$TMP/r4"/*; mkdir -p "$TMP/own"
split -l 1 "$TMP/own-logs.jsonl" "$TMP/own/l."; split -l 1 "$TMP/own-metrics.jsonl" "$TMP/own/m."
studio_start "$TMP/s3" "${TENV[@]}" OTEL_EXPORTER_OTLP_ENDPOINT="$TEL_EP" || die "agent-studio não voltou"
own() { local f rc=0; for f in "$TMP/own"/l.*; do [[ "$(post logs "$f")" == 200 ]] || rc=1; done
        for f in "$TMP/own"/m.*; do [[ "$(post metrics "$f")" == 200 ]] || rc=1; done; return $rc; }
check "a própria telemetria volta pela ingestão: 200"  own
check "…duas vezes (reenvio): 200"                     own
studio_stop
rcv_stop
check "sem laço: ingerir a própria telemetria não gera log OTel" test -z "$(tlogs "$TMP/r4")"
check "sem laço: só métricas agregadas (contadores)"   test "$(last agent_studio.requests '.attrs["http.response.status_code"] == "200"')" -gt 0
DB="$TMP/s3/db.duckdb"
check "a própria telemetria ficou no DuckDB, uma vez"  test "$(count logs "WHERE service_name = 'agent-studio'")" = "$(jq -s '[.[].resourceLogs[].scopeLogs[].logRecords[]] | length' "$TMP/own-logs.jsonl")"
check "métricas do agent-studio no DuckDB"             test "$(count metrics "WHERE metric_name = 'agent_studio.requests'")" -gt 0
check "compose: telemetria ao otel-collector local"    bash -c 'grep -q "OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318" <<<"$0" && grep -q "OTEL_SERVICE_NAME: agent-studio" <<<"$0" && grep -q "OTEL_RESOURCE_ATTRIBUTES: host.name=\${OUTE_HOST:-oute},oute.instance=\${OUTE_INSTANCE:-oute-agent}" <<<"$0"' \
                                                         "$(awk '/^  agent-studio:$/ {on=1; next} on && /^  [a-z]/ {exit} on {print}' "$ROOT/docker/compose.yaml")"

check_end
