#!/usr/bin/env bash
# Collector -> agent-studio sem perda (#189, ADR-08): roda o config/otel/collector.yaml + agent-studio.yaml de verdade
# contra o receptor OTLP falso (tests/lib/otlp-receiver.py, no lugar do agent-studio) e confere que os três sinais
# chegam com o token, que `kill -9` com lote pendente não perde nada (aceitos = recebidos depois do restart) e que,
# com o receptor fora, a fila cresce e esvazia quando ele volta. Confere também o liga/desliga do `oute up`
# (OUTE_AGENT_STUDIO=1 + item do vault), a escolha do destino por host (rede docker × vhost da tailnet, #190), o caso
# sem token e o compose. Mesmo binário fixado do tests/otelcol-queue.test.sh.
# Precisa de python3, jq e curl. Uso: tests/otelcol-studio.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"   # closed_port
CPID=""; RPID=""
cleanup() { for p in $CPID $RPID; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"   # studio_oute_funcs, studio_oute_up

. "$ROOT/tests/lib/otelcol.sh"   # otelcol_bin, otelcol_env, otelcol_start, otelcol_kill9, jqp…
otelcol_bin
check "otelcol-contrib $V"                              otelcol_version_ok

# ---------------------------------------------------------------- 1. config de produção
TOKEN="$(python3 -c "import secrets; print(secrets.token_hex(16))")"
otelcol_env
export AGENT_STUDIO_INGEST_TOKEN="$TOKEN" AGENT_STUDIO_URL=http://agent-studio:8430
C="$ROOT/config/otel"; CFG="$C/collector.yaml"; STUDIO="$C/agent-studio.yaml"
check "validate collector + none + agent-studio"        "$OTELCOL" validate --config="$CFG" --config="$C/none.yaml" --config="$STUDIO"
check "validate collector + langfuse + agent-studio"    "$OTELCOL" validate --config="$CFG" --config="$C/langfuse.yaml" --config="$STUDIO"
P="$(otelcol_print --config="$CFG" --config="$C/none.yaml" --config="$STUDIO")"
for x in traces:314572800 metrics:104857600 logs:629145600; do
  s="${x%%:*}"; q="${x#*:}"; e="otlp_http/studio_$s"
  check "$e: agent-studio:8430, json, gzip, Bearer do vault" jqp --arg e "$e" --arg t "Bearer $TOKEN" \
    '.exporters[$e] | .endpoint == "http://agent-studio:8430" and .encoding == "json" and .compression == "gzip"
     and (.headers | map(select(.name == "Authorization")) | .[0].value) == $t'
  check "$e: fila em disco de $((q / 1048576)) MB, sem bloquear" jqp --arg e "$e" --argjson q "$q" \
    '.exporters[$e].sending_queue | .storage == "file_storage/queue" and .queue_size == $q and .block_on_overflow == false'
  check "$e: retry sem prazo"                            jqp --arg e "$e" '.exporters[$e].retry_on_failure | .enabled and .max_elapsed_time == 0'
  check "$e: lote na fila com flush_timeout entre 5 e 30 s" jqp --arg e "$e" \
    '.exporters[$e].sending_queue.batch.flush_timeout | . >= 5000000000 and . <= 30000000000'
  check "$s/studio: só o $e, mesmos processors do bucket" jqp --arg p "$s/studio" --arg a "$s/archive" --arg e "$e" \
    '.service.pipelines[$p].receivers == ["otlp"] and .service.pipelines[$p].exporters == [$e]
     and .service.pipelines[$p].processors == .service.pipelines[$a].processors'
done
check "sem filtro nem batch em memória no agent-studio" jqp \
  '[.service.pipelines | to_entries[] | select(.key | endswith("/studio")) | .value.processors[]]
   | all(.[]; (startswith("filter") or startswith("batch")) | not)'
check "bucket continua igual (três pipelines archive)"  jqp '[.service.pipelines | keys[] | select(endswith("/archive"))] | length == 3'
# o print-config não mostra o sizer: confere na fonte (bytes nas filas e no lote, que é âncora única)
check "sizer: bytes nas três filas"                     [ "$(grep -c '^      sizer: bytes$' "$STUDIO")" -eq 3 ]
check "lote em bytes, até 8 MB (corpo JSON < 64 MB)"    grep -q 'batch: &studio_batch {flush_timeout: [0-9]*s, sizer: bytes, min_size: [0-9]*, max_size: 8388608}' "$STUDIO"
check "destino só pelo ambiente (o oute up escolhe, #190)" [ "$(grep -c '^    endpoint: ${env:AGENT_STUDIO_URL}$' "$STUDIO")" -eq 3 ]
P2="$(AGENT_STUDIO_URL=https://agent-studio.oute.pro otelcol_print --config="$CFG" --config="$C/none.yaml" --config="$STUDIO")"
check "vhost da tailnet nos três exporters"             jq -e '[.exporters | to_entries[] | select(.key | startswith("otlp_http/studio_")) | .value.endpoint]
  | length == 3 and all(. == "https://agent-studio.oute.pro")' <<<"$P2" >/dev/null
check "credencial de ingestão só pelo ambiente (nada fixo no arquivo)" grep -q 'Authorization: "Bearer ${env:AGENT_STUDIO_INGEST_TOKEN}"' "$STUDIO"

# ---------------------------------------------------------------- 2. `oute up` liga só com o agent-studio; compose
# só as funções do agent-studio (o script inteiro roda o case no fim), como no tests/agent-studio.test.sh
FUNCS="$(studio_oute_funcs)"
check "scripts/oute: funções do agent-studio achadas"  test -n "$FUNCS"
up() { studio_oute_up 'echo "otel=${OUTE_OTEL_STUDIO-unset}"; echo "url=${AGENT_STUDIO_URL-unset}"' "$@"; }
rm -f "$TMP/.env"
up AGENT_STUDIO_INGEST_TOKEN=t
check "sem OUTE_AGENT_STUDIO (Mac), com o token: pipeline do agent-studio" grep -qx 'otel=agent-studio' <<<"$OUT"
check "…pelo vhost da tailnet (#190)"                   grep -qx 'url=https://agent-studio.oute.pro' <<<"$OUT"
check "…sem aviso"                                     bash -c '! grep -q aviso <<<"$0"' "$OUT"
up AGENT_STUDIO_INGEST_TOKEN=t AGENT_STUDIO_URL=http://outro:1
check "…AGENT_STUDIO_URL do ambiente não manda"        grep -qx 'url=https://agent-studio.oute.pro' <<<"$OUT"
printf 'OUTE_AGENT_STUDIO_URL=https://studio.exemplo.ts.net\n' > "$TMP/.env"
up AGENT_STUDIO_INGEST_TOKEN=t
check "…OUTE_AGENT_STUDIO_URL no .env troca o vhost"   grep -qx 'url=https://studio.exemplo.ts.net' <<<"$OUT"
rm -f "$TMP/.env"
up
check "sem OUTE_AGENT_STUDIO e sem o token: collector sem o agent-studio" grep -qx 'otel=none' <<<"$OUT"
check "…avisa e cita o item do vault"                  grep -q 'aviso: AGENT_STUDIO_INGEST_TOKEN não está em .*item agent-studio da pasta oute-services' <<<"$OUT"
check "…não bloqueia (rc 0)"                           test "$RC" = 0
up OUTE_OTEL_STUDIO=agent-studio
check "…mesmo com OUTE_OTEL_STUDIO vindo do ambiente"  grep -qx 'otel=none' <<<"$OUT"
printf 'OUTE_AGENT_STUDIO=1\n' > "$TMP/.env"
up AGENT_STUDIO_INGEST_TOKEN=t AGENT_STUDIO_READ_TOKEN=r AGENT_STUDIO_SURREAL_PASS=s
check "OUTE_AGENT_STUDIO=1 com o item: pipeline do agent-studio" grep -qx 'otel=agent-studio' <<<"$OUT"
check "…pela rede docker (agent-studio:8430)"           grep -qx 'url=http://agent-studio:8430' <<<"$OUT"
up
check "OUTE_AGENT_STUDIO=1 sem o item: collector sem o agent-studio" grep -qx 'otel=none' <<<"$OUT"
up OUTE_OTEL_STUDIO=agent-studio
check "…mesmo com OUTE_OTEL_STUDIO vindo do ambiente"  grep -qx 'otel=none' <<<"$OUT"
rm -f "$TMP/.env"
COMPOSE="$ROOT/docker/compose.yaml"
check "compose: config do agent-studio escolhida pelo oute up" grep -q -- '- --config=/etc/otelcol/${OUTE_OTEL_STUDIO:-none}.yaml' "$COMPOSE"
check "compose: destino do agent-studio no collector (rede docker por padrão)" bash -c 'sed -n "/^  otel-collector:/,/^  [a-z]/p" "$0" | grep -q "AGENT_STUDIO_URL: \${AGENT_STUDIO_URL:-http://agent-studio:8430}"' "$COMPOSE"
check "compose: credencial de ingestão do agent-studio no collector" bash -c 'sed -n "/^  otel-collector:/,/^  [a-z]/p" "$0" | grep -q "AGENT_STUDIO_INGEST_TOKEN: \${AGENT_STUDIO_INGEST_TOKEN:-}"' "$COMPOSE"
check "arquivo do pipeline = nome que o oute up exporta" test -f "$C/agent-studio.yaml"

# ---------------------------------------------------------------- collector de teste: mesmo config, receptor local
RCV="$TMP/rcv"; RPORT="$(closed_port)"
rcv_up()   { RCV_TOKEN="$TOKEN" RCV_PORT="$RPORT" python3 "$ROOT/tests/lib/otlp-receiver.py" "$RCV" & RPID=$!
             local i; for i in $(seq 1 50); do curl -s -o /dev/null "127.0.0.1:$RPORT" && return 0; sleep 0.1; done; return 1; }
rcv_down() { kill -9 "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; RPID=""; }
otelcol_ports; PROM="$(closed_port)"
# só o que muda no teste: portas em 127.0.0.1, diretório da fila, endpoint do agent-studio e as métricas do collector
# lidas localmente (Prometheus em 127.0.0.1) para ver a fila. flush_timeout, filas e retry = produção.
{ otelcol_test_yaml; cat <<EOF; } > "$TMP/test.yaml"
exporters:
  otlp_http/studio_traces: {endpoint: "http://127.0.0.1:$RPORT"}
  otlp_http/studio_metrics: {endpoint: "http://127.0.0.1:$RPORT"}
  otlp_http/studio_logs: {endpoint: "http://127.0.0.1:$RPORT"}
service:
  telemetry:
    metrics:
      level: basic
      readers: [{pull: {exporter: {prometheus: {host: 127.0.0.1, port: $PROM}}}}]
EOF
start() { otelcol_start --config="$CFG" --config="$C/none.yaml" --config="$STUDIO" --config="$TMP/test.yaml"; }
# rcv_ids: os ids (corpo do log, nome do span e da métrica) de tudo que chegou ao receptor, um por linha
rcv_ids() {
  python3 - "$RCV" <<'PY'
import glob, gzip, json, sys
def ids_of(j):
    for r in j.get('resourceLogs', []):
        for s in r.get('scopeLogs', []):
            for x in s.get('logRecords', []): yield x.get('body', {}).get('stringValue')
    for r in j.get('resourceSpans', []):
        for s in r.get('scopeSpans', []):
            for x in s.get('spans', []): yield x.get('name')
    for r in j.get('resourceMetrics', []):
        for s in r.get('scopeMetrics', []):
            for x in s.get('metrics', []): yield x.get('name')
for f in glob.glob(sys.argv[1] + '/*.json'):
    raw = open(f, 'rb').read()
    for i in ids_of(json.loads(gzip.decompress(raw) if raw[:2] == b'\x1f\x8b' else raw)):
        if i is not None: print(i)
PY
}
# counts <run>: "aceitos recebidos perdidos duplicados" (recebidos/perdidos só entre os aceitos)
counts() { rcv_ids | otelcol_tally "$TMP/accepted-$1.txt"; }
# qsize: soma do otelcol_exporter_queue_size dos três exporters do agent-studio (bytes)
qsize() { curl -fs "127.0.0.1:$PROM/metrics" | awk '/^otelcol_exporter_queue_size\{.*exporter="otlp_http\/studio_/ {s += $NF} END {print s + 0}'; }
N=300   # por sinal: bem abaixo do min_size do lote (1 MB), o lote só sai pelo flush_timeout

# ---------------------------------------------------------------- 3. os três sinais chegam com o token, em segundos
rcv_up || die "receptor OTLP falso não subiu"
start || die "collector"
t0="$(date +%s)"
python3 "$ROOT/tests/lib/otlp-send.py" "$HTTP" live "$N" "$TMP/accepted-live.txt" >/dev/null
read -r a _ _ _ <<<"$(counts live)"
check "aceitou os $((N * 3)) itens (logs, traces, metrics)" [ "$a" -eq $((N * 3)) ]
if wait_all live 40; then ok "todos chegaram ao agent-studio em $(($(date +%s) - t0)) s"; else bad "faltou item ($(counts live))"; fi
check "rotas /v1/logs, /v1/traces e /v1/metrics"        bash -c 'awk 1 "$0"/*.path | sort -u | tr "\n" " " | grep -qx "/v1/logs /v1/metrics /v1/traces "' "$RCV"
check "nenhum POST sem o token (401)"                   test ! -e "$RCV/unauthorized"
check "processors do bucket: origem e oute.agent no resource" bash -c 'f=$(ls "$0"/*.json | head -1); python3 - "$f" <<"PY"
import gzip, json, sys
raw = open(sys.argv[1], "rb").read(); j = json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)
r = next(iter(v for k in ("resourceLogs", "resourceSpans", "resourceMetrics") for v in j.get(k, [])))
a = {x["key"]: list(x["value"].values())[0] for x in r["resource"]["attributes"]}
sys.exit(0 if a.get("host.name") == "oute-test" and a.get("oute.instance") == "oute-agent" and a.get("service.namespace") == "oute-agent" else 1)
PY' "$RCV"

# ---------------------------------------------------------------- 3b. oute.agent pelo service.name (#218)
# o collector marca claude e codex; o service.name do roteador de modelos, que saiu do stack, não ganha mais marca
# (o nome antigo vai partido, como no scripts/oute, para não voltar a aparecer no repo)
OLD_SVC="jev""-router"
for svc in claude-code codex_exec "$OLD_SVC"; do
  curl -fs -o /dev/null -H 'Content-Type: application/json' "127.0.0.1:$HTTP/v1/traces" -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"'"$svc"'"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"marca-'"$svc"'","startTimeUnixNano":"1759000000000000000","endTimeUnixNano":"1759000001000000000"}]}]}]}' \
    || bad "collector recusou o span de $svc"
done
# agent_of <service.name>: oute.agent do resource e do span que chegaram ao receptor ("-" = sem o atributo)
agent_of() {
  python3 - "$RCV" "$1" <<'PY'
import glob, gzip, json, sys
# valor vazio conta como ausente: o transform copia o oute.agent do resource para o span mesmo quando ele não existe
def attrs(l): return {x["key"]: v[0] for x in l or [] for v in [list(x.get("value", {}).values())] if v}
for f in glob.glob(sys.argv[1] + "/*.json"):
    raw = open(f, "rb").read(); j = json.loads(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)
    for r in j.get("resourceSpans", []):
        a = attrs(r.get("resource", {}).get("attributes"))
        if a.get("service.name") != sys.argv[2]: continue
        sp = [x for s in r.get("scopeSpans", []) for x in s.get("spans", [])]
        print(a.get("oute.agent", "-"), attrs(sp[0].get("attributes")).get("oute.agent", "-")); sys.exit(0)
sys.exit(1)
PY
}
for _ in $(seq 1 80); do agent_of "$OLD_SVC" >/dev/null 2>&1 && agent_of claude-code >/dev/null 2>&1 && agent_of codex_exec >/dev/null 2>&1 && break; sleep 0.5; done
check "oute.agent: claude-code vira claude (resource e span)" test "$(agent_of claude-code)" = "claude claude"
check "oute.agent: codex_exec vira codex"                test "$(agent_of codex_exec)" = "codex codex"
check "oute.agent: service.name do roteador não é mais marcado (#218)" test "$(agent_of "$OLD_SVC")" = "- -"

# ---------------------------------------------------------------- 4. kill -9 com lote pendente
otelcol_kill9 40 receptor

# ---------------------------------------------------------------- 5. receptor fora: a fila cresce e esvazia na volta
rcv_down
python3 "$ROOT/tests/lib/otlp-send.py" "$HTTP" down "$N" "$TMP/accepted-down.txt" >/dev/null
read -r a _ _ _ <<<"$(counts down)"
check "receptor fora: aceitou os $((N * 3)) itens"      [ "$a" -eq $((N * 3)) ]
q=0; for _ in $(seq 1 40); do q="$(qsize)"; [[ "${q:-0}" -gt 0 ]] && break; sleep 0.5; done
check "receptor fora: a fila do agent-studio cresce ($q bytes)" [ "${q:-0}" -gt 0 ]
sleep 12   # passa do flush_timeout: o lote sai da fila, falha e volta para ela
read -r _ r _ _ <<<"$(counts down)"
check "receptor fora: nada entregue"                    [ "$r" -eq 0 ]
q="$(qsize)"; check "receptor fora: nada descartado, a fila continua com $q bytes" [ "${q:-0}" -gt 0 ]
rcv_up || die "receptor OTLP falso não voltou"
if wait_all down 90; then ok "receptor de volta: aceitos = recebidos"; else bad "receptor de volta: perdeu itens ($(counts down))"; fi
q=1; for _ in $(seq 1 40); do q="$(qsize)"; [[ "${q:-1}" -eq 0 ]] && break; sleep 0.5; done
check "receptor de volta: a fila esvazia"               [ "${q:-1}" -eq 0 ]
check "nenhum POST sem o token (401), no fim"           test ! -e "$RCV/unauthorized"

otelcol_log
check_end
