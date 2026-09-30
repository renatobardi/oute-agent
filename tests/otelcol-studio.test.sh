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
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
die() { echo "FAIL $*"; exit 1; }
for c in python3 jq curl tar; do command -v "$c" >/dev/null || die "precisa de $c"; done

. "$ROOT/tests/lib/otelcol.sh"   # otelcol_bin, V
otelcol_bin
check "otelcol-contrib $V"                              bash -c '"$1" --version | grep -q " $2\$"' _ "$OTELCOL" "$V"

# ---------------------------------------------------------------- 1. config de produção
TOKEN="$(python3 -c "import secrets; print(secrets.token_hex(16))")"
export OUTE_HOST=oute-test OUTE_INSTANCE=oute-agent OCI_S3_REGION=sa-saopaulo-1 OCI_S3_ENDPOINT="http://127.0.0.1:$(closed_port)" \
  LANGFUSE_HOST=https://langfuse.invalid OUTE_LANGFUSE_AUTH=x AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required AGENT_STUDIO_TOKEN="$TOKEN" \
  AGENT_STUDIO_URL=http://agent-studio:8430
C="$ROOT/config/otel"; CFG="$C/collector.yaml"; STUDIO="$C/agent-studio.yaml"
check "validate collector + none + agent-studio"        "$OTELCOL" validate --config="$CFG" --config="$C/none.yaml" --config="$STUDIO"
check "validate collector + langfuse + agent-studio"    "$OTELCOL" validate --config="$CFG" --config="$C/langfuse.yaml" --config="$STUDIO"
P="$("$OTELCOL" print-config --mode=unredacted --format=json --config="$CFG" --config="$C/none.yaml" --config="$STUDIO" 2>/dev/null)"
jqp() { jq -e "$@" >/dev/null <<<"$P"; }
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
P2="$(AGENT_STUDIO_URL=https://agent-studio.oute.pro "$OTELCOL" print-config --mode=unredacted --format=json --config="$CFG" --config="$C/none.yaml" --config="$STUDIO" 2>/dev/null)"
check "vhost da tailnet nos três exporters"             jq -e '[.exporters | to_entries[] | select(.key | startswith("otlp_http/studio_")) | .value.endpoint]
  | length == 3 and all(. == "https://agent-studio.oute.pro")' <<<"$P2" >/dev/null
check "token só pelo ambiente (nada fixo no arquivo)"   grep -q 'Authorization: "Bearer ${env:AGENT_STUDIO_TOKEN}"' "$STUDIO"

# ---------------------------------------------------------------- 2. `oute up` liga só com o agent-studio; compose
# só as funções do agent-studio (o script inteiro roda o case no fim), como no tests/agent-studio.test.sh
FUNCS="$(sed -n '/^# --- agent-studio (ADR-08/,/^router_sync()/p' "$ROOT/scripts/oute" | sed '$d')"
check "scripts/oute: funções do agent-studio achadas"  test -n "$FUNCS"
up() { OUT="$(cd "$TMP" && env -i PATH="$PATH" HOME="$TMP" "$@" bash -c "set -euo pipefail; ROOT=$TMP; AGENT_ENV_FILE=~/.oute/agent.env
  env_get() { sed -n \"s/^[[:space:]]*\$1=//p\" \"\$ROOT/.env\" 2>/dev/null | tail -1; }
  $FUNCS"$'\n'"agent_studio_up; echo \"otel=\${OUTE_OTEL_STUDIO-unset}\"; echo \"url=\${AGENT_STUDIO_URL-unset}\"" 2>&1)"; RC=$?; }
rm -f "$TMP/.env"
up AGENT_STUDIO_TOKEN=t
check "sem OUTE_AGENT_STUDIO (Mac), com o token: pipeline do agent-studio" grep -qx 'otel=agent-studio' <<<"$OUT"
check "…pelo vhost da tailnet (#190)"                   grep -qx 'url=https://agent-studio.oute.pro' <<<"$OUT"
check "…sem aviso"                                     bash -c '! grep -q aviso <<<"$0"' "$OUT"
up AGENT_STUDIO_TOKEN=t AGENT_STUDIO_URL=http://outro:1
check "…AGENT_STUDIO_URL do ambiente não manda"        grep -qx 'url=https://agent-studio.oute.pro' <<<"$OUT"
printf 'OUTE_AGENT_STUDIO_URL=https://studio.exemplo.ts.net\n' > "$TMP/.env"
up AGENT_STUDIO_TOKEN=t
check "…OUTE_AGENT_STUDIO_URL no .env troca o vhost"   grep -qx 'url=https://studio.exemplo.ts.net' <<<"$OUT"
rm -f "$TMP/.env"
up
check "sem OUTE_AGENT_STUDIO e sem o token: collector sem o agent-studio" grep -qx 'otel=none' <<<"$OUT"
check "…avisa e cita o item do vault"                  grep -q 'aviso: AGENT_STUDIO_TOKEN não está em .*item agent-studio' <<<"$OUT"
check "…não bloqueia (rc 0)"                           test "$RC" = 0
up OUTE_OTEL_STUDIO=agent-studio
check "…mesmo com OUTE_OTEL_STUDIO vindo do ambiente"  grep -qx 'otel=none' <<<"$OUT"
printf 'OUTE_AGENT_STUDIO=1\n' > "$TMP/.env"
up AGENT_STUDIO_TOKEN=t AGENT_STUDIO_SURREAL_PASS=s
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
check "compose: token do agent-studio no collector"    bash -c 'sed -n "/^  otel-collector:/,/^  [a-z]/p" "$0" | grep -q "AGENT_STUDIO_TOKEN: \${AGENT_STUDIO_TOKEN:-}"' "$COMPOSE"
check "arquivo do pipeline = nome que o oute up exporta" test -f "$C/agent-studio.yaml"

# ---------------------------------------------------------------- collector de teste: mesmo config, receptor local
RCV="$TMP/rcv"; RPORT="$(closed_port)"
rcv_up()   { RCV_TOKEN="$TOKEN" RCV_PORT="$RPORT" python3 "$ROOT/tests/lib/otlp-receiver.py" "$RCV" & RPID=$!
             local i; for i in $(seq 1 50); do curl -s -o /dev/null "127.0.0.1:$RPORT" && return 0; sleep 0.1; done; return 1; }
rcv_down() { kill -9 "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; RPID=""; }
HTTP="$(closed_port)"; GRPC="$(closed_port)"; HC="$(closed_port)"; PROM="$(closed_port)"
# só o que muda no teste: portas em 127.0.0.1, diretório da fila, endpoint do agent-studio e as métricas do collector
# lidas localmente (Prometheus em 127.0.0.1) para ver a fila. flush_timeout, filas e retry = produção.
cat > "$TMP/test.yaml" <<EOF
extensions:
  health_check: {endpoint: 127.0.0.1:$HC}
  file_storage/queue: {directory: $TMP/queue}
receivers:
  otlp: {protocols: {grpc: {endpoint: 127.0.0.1:$GRPC}, http: {endpoint: 127.0.0.1:$HTTP}}}
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
start() {
  "$OTELCOL" --config="$CFG" --config="$C/none.yaml" --config="$STUDIO" --config="$TMP/test.yaml" >>"$TMP/collector.log" 2>&1 & CPID=$!
  local i; for i in $(seq 1 100); do curl -fs -o /dev/null "127.0.0.1:$HC" && return 0; sleep 0.1; done
  echo "# collector não subiu"; tail -20 "$TMP/collector.log"; return 1
}
# counts <run>: "aceitos recebidos perdidos duplicados" (recebidos/perdidos só entre os aceitos)
counts() {
  python3 - "$RCV" "$TMP/accepted-$1.txt" <<'PY'
import collections, glob, gzip, json, sys
acc = set(l.strip() for l in open(sys.argv[2]) if l.strip())
c = collections.Counter()
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
    c.update(ids_of(json.loads(gzip.decompress(raw) if raw[:2] == b'\x1f\x8b' else raw)))
print(len(acc), len(acc & set(c)), len(acc - set(c)), sum(c[i] - 1 for i in acc if c[i] > 1))
PY
}
# wait_all <run> <s>: espera até <s> segundos por todos os aceitos no receptor
wait_all() { local i; for i in $(seq 1 $(($2 * 2))); do set -- "$1" "$2" $(counts "$1"); [[ "$5" -eq 0 ]] && return 0; sleep 0.5; done; return 1; }
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

# ---------------------------------------------------------------- 4. kill -9 com lote pendente
python3 "$ROOT/tests/lib/otlp-send.py" "$HTTP" k9 "$N" "$TMP/accepted-k9.txt" >/dev/null
read -r a r _ _ <<<"$(counts k9)"
check "kill -9: aceitou os $((N * 3)) itens"            [ "$a" -eq $((N * 3)) ]
check "kill -9: lote ainda pendente (nada no receptor)" [ "$r" -eq 0 ]
kill -9 "$CPID"; wait "$CPID" 2>/dev/null; CPID=""
start || die "collector (restart)"
if wait_all k9 40; then ok "kill -9: aceitos = recebidos depois do restart"; else bad "kill -9: perdeu itens ($(counts k9))"; fi
read -r _ _ _ d <<<"$(counts k9)"; echo "# kill -9: duplicados=$d"

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

[[ "$fail" -eq 0 ]] || { echo "# log do collector:"; tail -30 "$TMP/collector.log"; }
echo "# $pass ok, $fail falha(s)"
[[ "$fail" -eq 0 ]]
