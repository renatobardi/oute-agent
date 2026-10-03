#!/usr/bin/env bash
# Collector sem perda no bucket (#161, #152): roda o config/otel/collector.yaml de verdade contra um S3 falso e confere
# que nada do que o collector aceitou se perde com `kill -9` com lote pendente nem com o S3 fora na parada
# (aceitos = recebidos depois do restart). Base: lab do #137 (docs/research/137-medir-collector no 13e79ba).
# Sem Docker: usa o otelcol-contrib do PATH se for a versão do compose; senão baixa o binário fixado e confere o
# sha256 (cache em ~/.cache/oute-tests). Precisa de python3, jq e curl. Uso: tests/otelcol-queue.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"   # closed_port
CPID=""; S3PID=""
cleanup() { for p in $CPID $S3PID; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
. "$ROOT/tests/lib/check.sh"

. "$ROOT/tests/lib/otelcol.sh"   # otelcol_bin, otelcol_env, otelcol_s3_start, otelcol_start, otelcol_kill9, jqp…
otelcol_bin
check "otelcol-contrib $V"                              otelcol_version_ok

# ---------------------------------------------------------------- 1. config de produção
otelcol_env
CFG="$ROOT/config/otel/collector.yaml"
check "validate collector.yaml + langfuse.yaml"         "$OTELCOL" validate --config="$CFG" --config="$ROOT/config/otel/langfuse.yaml"
check "validate collector.yaml + none.yaml"             "$OTELCOL" validate --config="$CFG" --config="$ROOT/config/otel/none.yaml"
P="$(otelcol_print --config="$CFG")"
for x in traces:314572800 metrics:104857600 logs:629145600; do
  s="${x%%:*}"; q="${x#*:}"
  check "awss3/$s: fila em disco de $((q / 1048576)) MB, sem bloquear" jqp --arg e "awss3/$s" --argjson q "$q" \
    '.exporters[$e].sending_queue | .storage == "file_storage/queue" and .queue_size == $q and .block_on_overflow == false'
  check "awss3/$s: lote na fila (5m, 20000..50000)"     jqp --arg e "awss3/$s" \
    '.exporters[$e].sending_queue.batch | .flush_timeout == 300000000000 and .min_size == 20000 and .max_size == 50000'
  check "awss3/$s: retry sem prazo"                      jqp --arg e "awss3/$s" \
    '.exporters[$e].retry_on_failure | .enabled and .max_elapsed_time == 0'
  check "$s/archive: sem batch em memória"               jqp --arg p "$s/archive" \
    '.service.pipelines[$p].processors | index("batch/archive") == null and all(.[]; startswith("batch") | not)'
done
# o print-config não mostra o sizer: confere na fonte (bytes na fila, itens no lote)
check "sizer: bytes nas três filas"                     [ "$(grep -c '^      sizer: bytes$' "$CFG")" -eq 3 ]
check "processor batch/archive removido"                bash -c '! grep -q "batch/archive" "$1"' _ "$CFG"
check "file_storage/queue ativo no service"             jqp '.service.extensions | index("file_storage/queue") != null'

# ---------------------------------------------------------------- collector de teste: mesmo config, portas locais
S3D="$TMP/s3"; otelcol_s3_start "$S3D" ok
otelcol_ports
# só o que muda no teste: portas em 127.0.0.1, diretório da fila e flush_timeout de 5 s (produção: 5 min)
{ otelcol_test_yaml s3; cat <<EOF; } > "$TMP/test.yaml"
service:
  telemetry: {metrics: {level: none}}
EOF
start() { otelcol_start --config="$CFG" --config="$TMP/test.yaml"; }
# counts <run>: "aceitos recebidos perdidos duplicados" (recebidos/perdidos só entre os aceitos)
counts() { { [[ ! -s "$S3D/received.jsonl" ]] || jq -r '.ids[]' "$S3D/received.jsonl"; } | otelcol_tally "$TMP/accepted-$1.txt"; }
N=300   # por sinal: bem abaixo do min_size (20000), o lote só sai pelo flush_timeout

# ---------------------------------------------------------------- 2. kill -9 com lote pendente
start || die "collector"
otelcol_kill9 30 S3 "(logs, traces, metrics)"

# ---------------------------------------------------------------- 3. S3 fora na parada
# Na parada o collector loga "Exporting failed. Dropping data." com o S3 fora: com a fila em disco o lote não sai do
# bbolt (#137 C2) e é entregue depois do restart, que é o que este bloco confere.
echo down > "$S3D/mode"
python3 "$ROOT/tests/lib/otlp-send.py" "$HTTP" s3down "$N" "$TMP/accepted-s3down.txt" >/dev/null
read -r a _ _ _ <<<"$(counts s3down)"
check "S3 fora: aceitou os $((N * 3)) itens"             [ "$a" -eq $((N * 3)) ]
for _ in $(seq 1 40); do [[ -s "$S3D/refused" ]] && break; sleep 0.5; done
check "S3 fora: o collector tentou e levou 503"         [ -s "$S3D/refused" ]
t0="$(date +%s)"; kill -TERM "$CPID"
for _ in $(seq 1 300); do kill -0 "$CPID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$CPID" 2>/dev/null; then bad "S3 fora: parada limpa em menos de 30 s (stop_grace_period)"; kill -9 "$CPID"
else ok "S3 fora: parada limpa em $(($(date +%s) - t0)) s (< 30 s do stop_grace_period)"; fi
wait "$CPID" 2>/dev/null; CPID=""
read -r _ r _ _ <<<"$(counts s3down)"
check "S3 fora: nada entregue antes do restart"         [ "$r" -eq 0 ]
echo ok > "$S3D/mode"
start || die "collector (restart)"
if wait_all s3down 60; then ok "S3 fora: aceitos = recebidos depois do restart"; else bad "S3 fora: perdeu itens ($(counts s3down))"; fi

otelcol_log
check_end
