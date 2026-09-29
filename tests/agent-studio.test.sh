#!/usr/bin/env bash
# Testes do agent-studio (ADR-08): ingestão OTLP/HTTP JSON -> DuckDB (#185), o serviço no compose e o `oute up`.
# Sobe o app de verdade (uvicorn + DuckDB, venv com as dependências fixadas por hash; tests/lib/agent-studio.sh) em
# 127.0.0.1 e confere só comportamento externo: código HTTP e o que ficou no DuckDB. Sem Docker.
# Uso: tests/agent-studio.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/agent-studio.sh"
. "$ROOT/tests/lib/otlp.sh"
trap 'studio_stop; rcv_stop; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
jqe() { jq -e "$@" >/dev/null; }
command -v jq >/dev/null && command -v python3 >/dev/null && command -v curl >/dev/null \
  || { echo "FAIL precisa de jq, python3 e curl"; exit 1; }
studio_venv || { echo "FAIL não montei o venv do agent-studio (docker/agent-studio/requirements.txt)"; exit 1; }
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
code() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "@$TMP/claude.json" "$@"; }
check "sem token: 401"                                 test "$(code "$STUDIO_URL/v1/logs")" = 401
check "token errado: 401"                              test "$(code -H 'Authorization: Bearer errado' "$STUDIO_URL/v1/logs")" = 401
check "token sem 'Bearer': 401"                        test "$(code -H "Authorization: $STUDIO_TOKEN" "$STUDIO_URL/v1/logs")" = 401
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
OUT="$(env AGENT_STUDIO_TOKEN= AGENT_STUDIO_DB="$TMP/x.duckdb" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio 2>&1)"; RC=$?
check "AGENT_STUDIO_TOKEN vazio: sai com erro"         test "$RC" -ne 0
check "AGENT_STUDIO_TOKEN vazio: diz o item do vault"  grep -q "item agent-studio" <<<"$OUT"
check "AGENT_STUDIO_TOKEN vazio: não cria o banco"     test ! -e "$TMP/x.duckdb"

# ---------------------------------------------------------------- 7. serviço no compose
SVC="$(awk '/^  agent-studio:$/ {on=1; print; next} on && /^  [a-z]/ {exit} on {print}' "$ROOT/docker/compose.yaml")"
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
check "compose: token do ambiente (agent.env)"         has 'AGENT_STUDIO_TOKEN: \$\{AGENT_STUDIO_TOKEN:-\}'
check "Dockerfile: copia o pacote e instala por hash"  bash -c 'grep -q "COPY docker/agent-studio/agent_studio /opt/agent-studio/app/agent_studio" "$0" && grep -q -- "--require-hashes -r /opt/agent-studio/requirements.txt" "$0"' "$ROOT/docker/Dockerfile"

# ---------------------------------------------------------------- 8. `oute up`: item do vault -> profile
# só as funções do agent-studio (o script inteiro roda o case no fim)
FUNCS="$(sed -n '/^# --- agent-studio (ADR-08/,/^router_sync()/p' "$ROOT/scripts/oute" | sed '$d')"
check "scripts/oute: funções do agent-studio achadas"  test -n "$FUNCS"
envf="$TMP/env"; : > "$envf"
up() { OUT="$(cd "$TMP" && env -i PATH="$PATH" HOME="$TMP" "$@" bash -c "set -euo pipefail; ROOT=$TMP; AGENT_ENV_FILE=~/.oute/agent.env
  env_get() { sed -n \"s/^[[:space:]]*\$1=//p\" \"\$ROOT/.env\" 2>/dev/null | tail -1; }
  $FUNCS"$'\n'"agent_studio_up; echo \"profiles=\${COMPOSE_PROFILES:-}\"; echo \"token=\${AGENT_STUDIO_TOKEN:-}\"" 2>&1)"; RC=$?; }
rm -f "$TMP/.env"
up AGENT_STUDIO_TOKEN=t1
check "sem OUTE_AGENT_STUDIO (Mac): não liga, sem aviso" bash -c '[[ "$0" == "profiles="$'"'"'\n'"'"'"token=t1" ]]' "$OUT"
printf 'OUTE_AGENT_STUDIO=1\n' > "$TMP/.env"
up AGENT_STUDIO_TOKEN=t1
check ".env com OUTE_AGENT_STUDIO=1 e token: liga"     grep -qx 'profiles=agent-studio' <<<"$OUT"
check "…e sem aviso"                                   bash -c '! grep -q aviso <<<"$0"' "$OUT"
up AGENT_STUDIO_TOKEN=t1 COMPOSE_PROFILES=outro
check "soma ao COMPOSE_PROFILES que já existe"         grep -qx 'profiles=outro,agent-studio' <<<"$OUT"
up
check "sem o item no vault: não liga"                  grep -qx 'profiles=' <<<"$OUT"
check "sem o item no vault: avisa e cita o item"       grep -q 'aviso: OUTE_AGENT_STUDIO=1, mas AGENT_STUDIO_TOKEN não está em .*item agent-studio' <<<"$OUT"
check "sem o item no vault: não bloqueia (rc 0)"       test "$RC" = 0
rm -f "$TMP/.env"
up OUTE_AGENT_STUDIO=1 AGENT_STUDIO_TOKEN=t1
check "OUTE_AGENT_STUDIO=1 no ambiente também liga"    grep -qx 'profiles=agent-studio' <<<"$OUT"
check "up chama agent_studio_up depois dos segredos"   grep -q 'host_secrets "$refresh"; agent_studio_up;' "$ROOT/scripts/oute"
check "down/status enxergam o profile"                 bash -c 'grep -q "\-\-profile \"\$STUDIO_PROFILE\" down" "$0" && grep -q "\-\-profile \"\$STUDIO_PROFILE\" ps" "$0"' "$ROOT/scripts/oute"

printf '\n%d ok, %d falha(s)\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
