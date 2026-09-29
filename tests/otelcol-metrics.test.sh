#!/usr/bin/env bash
# Métricas do próprio collector no pipeline (#162, #152): o config/otel/collector.yaml manda as métricas internas
# (fila: tamanho e capacidade; envio que falhou; dado recusado) via OTLP ao próprio receiver, sem porta nova, e elas
# chegam ao bucket em otel/metrics/ como qualquer métrica. Fonte do alerta de fila e de recusa (#136); o alerta fica fora.
# Roda o collector de verdade (binário fixado, tests/lib/otelcol.sh) com dois readers: o receptor OTLP falso
# (tests/lib/otlp-receiver.py, protobuf lido por otlp-pb-metrics.py) e o receiver do próprio collector -> S3 falso.
# Precisa de python3, jq e curl. Uso: tests/otelcol-metrics.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"   # rcv_start, rcv_stop, closed_port
CPID=""; S3PID=""; RCV_PID=""
cleanup() { for p in $CPID $S3PID; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rcv_stop; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
die() { echo "FAIL $*"; exit 1; }
for c in python3 jq curl tar; do command -v "$c" >/dev/null || die "precisa de $c"; done

. "$ROOT/tests/lib/otelcol.sh"   # otelcol_bin, V
otelcol_bin

# ---------------------------------------------------------------- 1. config de produção
export OUTE_HOST=oute-test OUTE_INSTANCE=oute-agent OCI_S3_REGION=sa-saopaulo-1 OCI_S3_ENDPOINT=http://127.0.0.1:9 \
  LANGFUSE_HOST=https://langfuse.invalid OUTE_LANGFUSE_AUTH=x AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
CFG="$ROOT/config/otel/collector.yaml"
check "validate collector.yaml + langfuse.yaml"         "$OTELCOL" validate --config="$CFG" --config="$ROOT/config/otel/langfuse.yaml"
check "validate collector.yaml + none.yaml"             "$OTELCOL" validate --config="$CFG" --config="$ROOT/config/otel/none.yaml"
P="$("$OTELCOL" print-config --mode=unredacted --format=json --config="$CFG" 2>/dev/null)"
jqp() { jq -e "$@" >/dev/null <<<"$P"; }
check "telemetry.metrics: level basic"                  jqp '.service.telemetry.metrics.level | ascii_downcase == "basic"'
check "telemetry.metrics: um reader, OTLP http/protobuf" jqp '.service.telemetry.metrics.readers
  | length == 1 and (.[0].periodic.exporter.otlp.protocol == "http/protobuf")'
# o endpoint é o receiver OTLP/HTTP do próprio collector, em loopback: nenhuma porta nova (nem o Prometheus :8888)
check "telemetry.metrics: manda ao próprio receiver (loopback, porta do otlp http)" jqp '
  (.receivers.otlp.protocols.http.endpoint | split(":")[-1]) as $p
  | .service.telemetry.metrics.readers[0].periodic.exporter.otlp.endpoint == "http://127.0.0.1:\($p)/v1/metrics"'
check "telemetry.metrics: nenhum reader pull (porta nova)" jqp '[.service.telemetry.metrics.readers[] | has("pull")] | any | not'
check "metrics/archive recebe do otlp e vai ao bucket"  jqp '.service.pipelines["metrics/archive"]
  | (.receivers | index("otlp") != null) and .exporters == ["awss3/metrics"]'

# ---------------------------------------------------------------- collector de teste: mesmo config, portas locais
S3D="$TMP/s3"; mkdir -p "$S3D"; echo down > "$S3D/mode"
python3 "$ROOT/tests/lib/fakes3.py" "$S3D" & S3PID=$!
for _ in $(seq 1 50); do [[ -s "$S3D/port" ]] && break; sleep 0.1; done
[[ -s "$S3D/port" ]] || die "S3 falso não subiu"
export OCI_S3_ENDPOINT="http://127.0.0.1:$(cat "$S3D/port")"
rcv_start "$TMP/rcv"; [[ -s "$TMP/rcv/port" ]] || die "receptor OTLP falso não subiu"
HTTP="$(closed_port)"; GRPC="$(closed_port)"; HC="$(closed_port)"
# só o que muda no teste: portas em 127.0.0.1, diretório da fila, flush_timeout de 5 s (produção: 5 min) e os readers
# a cada 1 s (produção: 60 s): o do próprio receiver (como em produção, na porta de teste) e o do receptor falso
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
service:
  telemetry:
    metrics:
      readers:
        - periodic: {interval: 1000, exporter: {otlp: {protocol: http/protobuf, endpoint: "http://127.0.0.1:$HTTP/v1/metrics"}}}
        - periodic: {interval: 1000, exporter: {otlp: {protocol: http/protobuf, endpoint: "$OTEL_EXPORTER_OTLP_ENDPOINT/v1/metrics"}}}
EOF
# retry.yaml (só na fase 3): retry desligado, para o envio com o S3 fora ser abandonado e o send_failed_* subir com o
# collector no ar. Em produção o retry é sem prazo e o send_failed_* só sobe quando um envio é abandonado (na parada).
cat > "$TMP/retry.yaml" <<EOF
exporters:
  awss3/traces: {retry_on_failure: {enabled: false}}
  awss3/metrics: {retry_on_failure: {enabled: false}}
  awss3/logs: {retry_on_failure: {enabled: false}}
EOF
start() {
  "$OTELCOL" --config="$CFG" --config="$TMP/test.yaml" "$@" >>"$TMP/collector.log" 2>&1 & CPID=$!
  local i; for i in $(seq 1 100); do curl -fs -o /dev/null "127.0.0.1:$HC" && return 0; sleep 0.1; done
  echo "# collector não subiu"; tail -20 "$TMP/collector.log"; return 1
}
stop() {
  kill -TERM "$CPID"; for _ in $(seq 1 300); do kill -0 "$CPID" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null; CPID=""
}
refused() { [[ -s "$S3D/refused" ]] && wc -l <"$S3D/refused" | tr -d ' ' || echo 0; }
# pontos que chegaram ao receptor falso: um JSON por ponto {name, value, attrs}
pts() { local f; f=("$TMP"/rcv/*.json); [[ -e "${f[0]}" ]] && python3 "$ROOT/tests/lib/otlp-pb-metrics.py" "${f[@]}"; }
EXP="traces:314572800:spans metrics:104857600:metric_points logs:629145600:log_records"

# ---------------------------------------------------------------- 2. receptor OTLP falso: as métricas saem
# S3 fora: o lote fica na fila (retry sem prazo), então queue_size > 0 nos três exporters
start || die "collector"
python3 "$ROOT/tests/lib/otlp-send.py" "$HTTP" m 50 "$TMP/accepted.txt" >/dev/null
# 3 recusas = no mínimo um envio completo (o SDK do S3 tenta 3 vezes); o queue_size > 0 abaixo vale por exporter
for _ in $(seq 1 40); do [[ "$(refused)" -ge 3 ]] && break; sleep 0.5; done
check "S3 fora: o collector tentou e levou 503"         [ "$(refused)" -ge 3 ]
sleep 3   # mais uns ciclos do reader depois da falha
PTS="$(pts)"
has() { jq -se "$@" >/dev/null <<<"$PTS"; }
for x in $EXP; do
  IFS=: read -r s q u <<<"$x"; e="awss3/$s"
  check "receptor: otelcol_exporter_queue_capacity de $e = $((q / 1048576)) MB" has --arg e "$e" --argjson q "$q" \
    'map(select(.name == "otelcol_exporter_queue_capacity" and .attrs.exporter == $e)) | length > 0 and all(.value == $q)'
  check "receptor: otelcol_exporter_queue_size de $e > 0 com o S3 fora" has --arg e "$e" \
    'any(.[]; .name == "otelcol_exporter_queue_size" and .attrs.exporter == $e and .value > 0)'
  check "receptor: otelcol_receiver_refused_$u do otlp"    has --arg n "otelcol_receiver_refused_$u" \
    'any(.[]; .name == $n and .attrs.receiver == "otlp")'
done
# parada com o S3 fora: o envio em curso é abandonado (send_failed_* sobe; o lote continua no disco, #137) e o
# último envio do reader leva isso ao receptor falso
stop
PTS="$(pts)"
for x in $EXP; do
  IFS=: read -r s _ u <<<"$x"
  check "receptor: otelcol_exporter_send_failed_$u de awss3/$s > 0 (parada com o S3 fora)" has --arg e "awss3/$s" \
    --arg n "otelcol_exporter_send_failed_$u" 'any(.[]; .name == $n and .attrs.exporter == $e and .value > 0)'
done

# ---------------------------------------------------------------- 3. bucket: as métricas chegam em otel/metrics/
# sobe de novo (retry desligado, retry.yaml) com o S3 ainda fora: o lote do disco é abandonado e o send_failed_* sobe
# com o collector no ar; depois o S3 volta e as métricas do collector chegam ao bucket pelo metrics/archive
rm -f "$TMP"/rcv/*.json
start --config="$TMP/retry.yaml" || die "collector (restart)"
FAILED='[.[] | select((.name | startswith("otelcol_exporter_send_failed_")) and .value > 0) | .attrs.exporter] | unique
  == ["awss3/logs", "awss3/metrics", "awss3/traces"]'
for _ in $(seq 1 60); do PTS="$(pts)"; has "$FAILED" && break; sleep 0.5; done
check "S3 fora, sem retry: send_failed_* > 0 nos três exporters com o collector no ar" has "$FAILED"
echo ok > "$S3D/mode"
# os contadores do receiver só nascem quando o sinal chega: manda os três de novo
python3 "$ROOT/tests/lib/otlp-send.py" "$HTTP" m2 50 "$TMP/accepted2.txt" >/dev/null
PRE="/oute-observability/otel/metrics/host=oute-test/instance=oute-agent/"
# pontos das métricas do collector no S3 falso: um JSON por ponto {path, name, value, exporter, receiver}
bucket() {
  [[ -s "$S3D/objects.jsonl" ]] || return 0
  jq -c 'def attr($k): [.attributes[]? | select(.key == $k) | .value.stringValue] | first;
         .path as $p | .otlp.resourceMetrics[]?.scopeMetrics[].metrics[] | .name as $n
         | (.sum // .gauge).dataPoints[]?
         | {path: $p, name: $n, value: ((.asInt // .asDouble // 0) | tonumber), exporter: attr("exporter"), receiver: attr("receiver")}' \
    "$S3D/objects.jsonl"
}
# inb [--arg k v]... <filtro>: o filtro roda sobre os pontos em otel/metrics/host=…/instance=…/
inb() { local f="${!#}"; jq -se --arg pre "$PRE" "${@:1:$#-1}" 'map(select(.path | startswith($pre))) | '"$f" >/dev/null <<<"$B"; }
WANT='all(("awss3/traces", "awss3/metrics", "awss3/logs") as $e
        | ("otelcol_exporter_queue_size", "otelcol_exporter_queue_capacity") as $n | any(.[]; .name == $n and .exporter == $e); .)
      and ([.[] | select((.name | startswith("otelcol_exporter_send_failed_")) and .value > 0) | .exporter] | unique
        == ["awss3/logs", "awss3/metrics", "awss3/traces"])
      and all(("spans", "metric_points", "log_records") as $u
        | any(.[]; .name == "otelcol_receiver_refused_\($u)" and .receiver == "otlp"); .)'
for _ in $(seq 1 120); do B="$(bucket)"; inb "$WANT" && break; sleep 0.5; done
B="$(bucket)"
for x in $EXP; do
  IFS=: read -r s _ u <<<"$x"; e="awss3/$s"
  check "bucket: otelcol_exporter_queue_size e _queue_capacity de $e" inb --arg e "$e" \
    'any(.[]; .name == "otelcol_exporter_queue_size" and .exporter == $e) and any(.[]; .name == "otelcol_exporter_queue_capacity" and .exporter == $e)'
  check "bucket: otelcol_exporter_send_failed_$u de $e > 0" inb --arg e "$e" --arg n "otelcol_exporter_send_failed_$u" \
    'any(.[]; .name == $n and .exporter == $e and .value > 0)'
  check "bucket: otelcol_receiver_refused_$u do otlp" inb --arg n "otelcol_receiver_refused_$u" \
    'any(.[]; .name == $n and .receiver == "otlp")'
done
stop

[[ "$fail" -eq 0 ]] || { echo "# log do collector:"; tail -30 "$TMP/collector.log"; }
echo "# $pass ok, $fail falha(s)"
[[ "$fail" -eq 0 ]]
