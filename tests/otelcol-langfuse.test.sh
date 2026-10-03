#!/usr/bin/env bash
# Langfuse sem o texto do status do span (#149, ADR-04): roda o config/otel/collector.yaml + langfuse.yaml de verdade
# (processors de produção) com o receptor OTLP falso (tests/lib/otlp-receiver.py) no lugar do Langfuse e o S3 falso
# (tests/lib/fakes3.py) no lugar do bucket. Um span de erro com um marcador no status.message chega ao Langfuse com o
# código de erro e sem a mensagem (o marcador não aparece em POST nenhum) e ao bucket com a mensagem intacta.
# Mesmo binário fixado dos outros testes do collector. Precisa de python3, jq e curl. Uso: tests/otelcol-langfuse.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"   # rcv_start, rcv_stop, closed_port
CPID=""; S3PID=""; RCV_PID=""
cleanup() { for p in $CPID $S3PID; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rcv_stop; rm -rf "$TMP"; }
trap cleanup EXIT
. "$ROOT/tests/lib/check.sh"
for c in python3 jq curl tar; do command -v "$c" >/dev/null || die "precisa de $c"; done

. "$ROOT/tests/lib/otelcol.sh"   # otelcol_bin, V
otelcol_bin

# ---------------------------------------------------------------- 1. config de produção
export OUTE_HOST=oute-test OUTE_INSTANCE=oute-agent OCI_S3_REGION=sa-saopaulo-1 OCI_S3_ENDPOINT="http://127.0.0.1:$(closed_port)" \
  LANGFUSE_HOST=https://langfuse.invalid OUTE_LANGFUSE_AUTH=x AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  AGENT_STUDIO_INGEST_TOKEN=x AGENT_STUDIO_URL=http://agent-studio:8430
C="$ROOT/config/otel"; CFG="$C/collector.yaml"; LF="$C/langfuse.yaml"
check "validate collector + langfuse"                   "$OTELCOL" validate --config="$CFG" --config="$LF"
check "validate collector + none"                       "$OTELCOL" validate --config="$CFG" --config="$C/none.yaml"
P="$("$OTELCOL" print-config --mode=unredacted --format=json --config="$CFG" --config="$LF" --config="$C/agent-studio.yaml" 2>/dev/null)"
check "metadata_only esvazia o status.message"          jq -e '.processors["transform/metadata_only"].trace_statements
  | any(.[]; .context == "span" and (.statements | index("set(span.status.message, \"\")") != null))' <<<"$P" >/dev/null
check "status.code fica (nenhuma linha mexe nele)"      bash -c '! grep -q "span\.status\.code" "$0"' "$LF"
check "só o traces/langfuse passa pelo metadata_only (archive e studio sem mudança)" jq -e '
  [.service.pipelines | to_entries[] | select(.value.processors | index("transform/metadata_only")) | .key] == ["traces/langfuse"]' <<<"$P" >/dev/null

# ---------------------------------------------------------------- collector de teste: mesmo config, destinos locais
S3D="$TMP/s3"; mkdir -p "$S3D"
python3 "$ROOT/tests/lib/fakes3.py" "$S3D" & S3PID=$!
for _ in $(seq 1 50); do [[ -s "$S3D/port" ]] && break; sleep 0.1; done
[[ -s "$S3D/port" ]] || die "S3 falso não subiu"
export OCI_S3_ENDPOINT="http://127.0.0.1:$(cat "$S3D/port")"
RCV="$TMP/langfuse"; rcv_start "$RCV"; [[ -s "$RCV/port" ]] || die "receptor OTLP falso não subiu"
export LANGFUSE_HOST="$OTEL_EXPORTER_OTLP_ENDPOINT"
HTTP="$(closed_port)"; GRPC="$(closed_port)"; HC="$(closed_port)"
# só o que muda no teste: portas em 127.0.0.1 (também a do reader das métricas do collector), diretório da fila,
# flush_timeout do bucket de 5 s (produção: 5 min) e o exporter do Langfuse em JSON sem gzip, para o receptor ler o
# corpo como veio. Processors e pipelines = produção.
cat > "$TMP/test.yaml" <<EOF
extensions:
  health_check: {endpoint: 127.0.0.1:$HC}
  file_storage/queue: {directory: $TMP/queue}
receivers:
  otlp: {protocols: {grpc: {endpoint: 127.0.0.1:$GRPC}, http: {endpoint: 127.0.0.1:$HTTP}}}
exporters:
  awss3/traces: {sending_queue: {batch: {flush_timeout: 5s}}}
  awss3/metrics: {sending_queue: {batch: {flush_timeout: 5s}}}
  awss3/logs: {sending_queue: {batch: {flush_timeout: 5s}}}
  otlphttp/langfuse: {encoding: json, compression: none}
service:
  telemetry:
    metrics:
      readers:
        - periodic: {interval: 60000, exporter: {otlp: {protocol: http/protobuf, endpoint: "http://127.0.0.1:$HTTP/v1/metrics"}}}
EOF
"$OTELCOL" --config="$CFG" --config="$LF" --config="$TMP/test.yaml" >>"$TMP/collector.log" 2>&1 & CPID=$!
for _ in $(seq 1 100); do curl -fs -o /dev/null "127.0.0.1:$HC" && break; sleep 0.1; done
curl -fs -o /dev/null "127.0.0.1:$HC" || { tail -20 "$TMP/collector.log"; die "collector não subiu"; }

# ---------------------------------------------------------------- 2. três spans do Claude: erro com marcador, ok, sem status
MARK="MARCADOR-149-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
PYTHONPATH="$ROOT/tests/lib" python3 - "$MARK" >"$TMP/batch.json" <<'PY'
import json, sys, time
from otlp_json import rs, span
t = time.time()
err = span("t149-erro", t, 1, {"tool_name": "Bash", "success": "false"}, err=True)
err["status"]["message"] = f"{sys.argv[1]}: /home/oute/segredo.txt: No such file or directory"
ok = span("t149-ok", t, 1, {"tool_name": "Read"}); ok["status"] = {"code": 1}
plain = span("t149-sem-status", t, 1, {"tool_name": "Grep"})
print(json.dumps({"resourceSpans": [rs({"service.name": "claude-code"}, [err, ok, plain])]}))
PY
check "collector aceitou o lote"                        curl -fs -o /dev/null -H 'Content-Type: application/json' \
  --data-binary @"$TMP/batch.json" "127.0.0.1:$HTTP/v1/traces"

# spans <arquivos OTLP-JSON...>: um JSON por span {name, code, msg}
spans() { jq -c '.resourceSpans[]?.scopeSpans[].spans[] | {name, code: (.status.code // 0), msg: (.status.message // "")}' "$@" 2>/dev/null; }
lf()  { local f; f=("$RCV"/*.json); [[ -e "${f[0]}" ]] && spans "${f[@]}"; }
s3()  { [[ -s "$S3D/objects.jsonl" ]] && jq -c '.otlp' "$S3D/objects.jsonl" | spans /dev/stdin; }
got() { [[ "$($1 | jq -s '[.[] | select(.name | startswith("t149-"))] | length')" -ge 3 ]]; }
for _ in $(seq 1 120); do got lf && got s3 && break; sleep 0.5; done
LFS="$(lf)"; S3S="$(s3)"
one() { jq -se --arg n "$2" "map(select(.name == \$n)) | length == 1 and (.[0] | $3)" >/dev/null <<<"$1"; }

# ---------------------------------------------------------------- 3. Langfuse: código fica, texto sai
check "Langfuse: span de erro chega com código 2 e sem mensagem" one "$LFS" t149-erro '.code == 2 and .msg == ""'
check "Langfuse: span ok chega com código 1"            one "$LFS" t149-ok '.code == 1 and .msg == ""'
check "Langfuse: span sem status chega sem status"      one "$LFS" t149-sem-status '.code == 0 and .msg == ""'
check "Langfuse: o marcador não aparece em POST nenhum" bash -c '! grep -rqF -- "$1" "$0"' "$RCV" "$MARK"
check "Langfuse: o marcador foi conferido em POST de traces" bash -c 'grep -qx /api/public/otel/v1/traces "$0"/*.path' "$RCV"

# ---------------------------------------------------------------- 4. bucket: mensagem intacta
check "bucket: span de erro com código 2 e a mensagem intacta" one "$S3S" t149-erro \
  '.code == 2 and (.msg | startswith("'"$MARK"': /home/oute/"))'
check "bucket: span ok com código 1"                    one "$S3S" t149-ok '.code == 1'

[[ "$fail" -eq 0 ]] || { echo "# log do collector:"; tail -30 "$TMP/collector.log"; }
check_end
