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
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
die() { echo "FAIL $*"; exit 1; }
for c in python3 jq curl tar; do command -v "$c" >/dev/null || die "precisa de $c"; done

# ---------------------------------------------------------------- binário fixado (mesma versão do compose)
V=0.161.0
grep -q "opentelemetry-collector-contrib:\${OUTE_OTELCOL_VERSION:-$V}" "$ROOT/docker/compose.yaml" \
  || die "a versão do collector no compose mudou: atualize V e os checksums deste teste"
otelcol_bin() {
  local p os arch sum url cache tgz got
  p="$(command -v otelcol-contrib || true)"
  if [[ -n "$p" ]] && "$p" --version 2>/dev/null | grep -q " $V\$"; then OTELCOL="$p"; return; fi
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) die "SO sem binário fixado: $(uname -s)" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "arquitetura sem binário fixado: $(uname -m)" ;; esac
  # sha256 dos .tar.gz da release v0.161.0 (opentelemetry-collector-releases, conferidos com os .sha256 publicados)
  case "$os-$arch" in
    linux-amd64)  sum=778c689efa681ff6e4722ce9f66b9b7f57c3ba009ab2e2b43dc2e0315862c731 ;;
    linux-arm64)  sum=cd5de93213a0dbb90e4998b3b9e4e15ed691ec635cf7cf4147f95799fb16b676 ;;
    darwin-amd64) sum=357fc0a7a77f5d42cab2f46af6be301062a7824b82454cc264cb8661fa9a8734 ;;
    darwin-arm64) sum=ccc0cf5de5242adcaedc7b5aebed43a1dc56aa2dc7de6ebc495d5db60512d34c ;;
  esac
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$V/otelcol-contrib_${V}_${os}_${arch}.tar.gz"
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/oute-tests"; tgz="$cache/otelcol-contrib_${V}_${os}_${arch}.tar.gz"
  mkdir -p "$cache"
  sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
  if [[ ! -f "$tgz" || "$(sha "$tgz")" != "$sum" ]]; then
    echo "# baixando otelcol-contrib $V ($os/$arch)"
    curl -fsSL --retry 3 -o "$tgz.part" "$url" || die "download do otelcol-contrib falhou"
    got="$(sha "$tgz.part")"
    [[ "$got" == "$sum" ]] || { rm -f "$tgz.part"; die "checksum do otelcol-contrib não confere ($got)"; }
    mv "$tgz.part" "$tgz"
  fi
  tar -xzf "$tgz" -C "$TMP" otelcol-contrib || die "tar do otelcol-contrib falhou"
  OTELCOL="$TMP/otelcol-contrib"
}
otelcol_bin
check "otelcol-contrib $V"                              bash -c '"$1" --version | grep -q " $2\$"' _ "$OTELCOL" "$V"

# ---------------------------------------------------------------- 1. config de produção
export OUTE_HOST=oute-test OUTE_INSTANCE=oute-agent OCI_S3_REGION=sa-saopaulo-1 OCI_S3_ENDPOINT=http://127.0.0.1:9 \
  LANGFUSE_HOST=https://langfuse.invalid OUTE_LANGFUSE_AUTH=x AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
CFG="$ROOT/config/otel/collector.yaml"
check "validate collector.yaml + langfuse.yaml"         "$OTELCOL" validate --config="$CFG" --config="$ROOT/config/otel/langfuse.yaml"
check "validate collector.yaml + none.yaml"             "$OTELCOL" validate --config="$CFG" --config="$ROOT/config/otel/none.yaml"
P="$("$OTELCOL" print-config --mode=unredacted --format=json --config="$CFG" 2>/dev/null)"
jqp() { jq -e "$@" >/dev/null <<<"$P"; }
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
S3D="$TMP/s3"; mkdir -p "$S3D"; echo ok > "$S3D/mode"
python3 "$ROOT/tests/lib/fakes3.py" "$S3D" & S3PID=$!
for _ in $(seq 1 50); do [[ -s "$S3D/port" ]] && break; sleep 0.1; done
[[ -s "$S3D/port" ]] || die "S3 falso não subiu"
export OCI_S3_ENDPOINT="http://127.0.0.1:$(cat "$S3D/port")"
HTTP="$(closed_port)"; GRPC="$(closed_port)"; HC="$(closed_port)"
# só o que muda no teste: portas em 127.0.0.1, diretório da fila e flush_timeout de 5 s (produção: 5 min)
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
  telemetry: {metrics: {level: none}}
EOF
start() {
  "$OTELCOL" --config="$CFG" --config="$TMP/test.yaml" >>"$TMP/collector.log" 2>&1 & CPID=$!
  local i; for i in $(seq 1 100); do curl -fs -o /dev/null "127.0.0.1:$HC" && return 0; sleep 0.1; done
  echo "# collector não subiu"; tail -20 "$TMP/collector.log"; return 1
}
# counts <run>: "aceitos recebidos perdidos duplicados" (recebidos/perdidos só entre os aceitos)
counts() {
  python3 - "$S3D/received.jsonl" "$TMP/accepted-$1.txt" <<'PY'
import collections, json, sys
acc = set(l.strip() for l in open(sys.argv[2]) if l.strip())
c = collections.Counter()
try:
    for l in open(sys.argv[1]): c.update(json.loads(l)['ids'])
except FileNotFoundError: pass
print(len(acc), len(acc & set(c)), len(acc - set(c)), sum(c[i] - 1 for i in acc if c[i] > 1))
PY
}
# wait_all <run> <s>: espera até <s> segundos por todos os aceitos no S3
wait_all() { local i; for i in $(seq 1 $(($2 * 2))); do set -- "$1" "$2" $(counts "$1"); [[ "$5" -eq 0 ]] && return 0; sleep 0.5; done; return 1; }
N=300   # por sinal: bem abaixo do min_size (20000), o lote só sai pelo flush_timeout

# ---------------------------------------------------------------- 2. kill -9 com lote pendente
start || die "collector"
python3 "$ROOT/tests/lib/otlp-send.py" "$HTTP" k9 "$N" "$TMP/accepted-k9.txt" >/dev/null
read -r a r _ _ <<<"$(counts k9)"
check "kill -9: aceitou os $((N * 3)) itens (logs, traces, metrics)" [ "$a" -eq $((N * 3)) ]
check "kill -9: lote ainda pendente (nada no S3)"      [ "$r" -eq 0 ]
kill -9 "$CPID"; wait "$CPID" 2>/dev/null; CPID=""
start || die "collector (restart)"
if wait_all k9 30; then ok "kill -9: aceitos = recebidos depois do restart"; else bad "kill -9: perdeu itens ($(counts k9))"; fi
read -r _ _ _ d <<<"$(counts k9)"; echo "# kill -9: duplicados=$d"

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

[[ "$fail" -eq 0 ]] || { echo "# log do collector:"; tail -30 "$TMP/collector.log"; }
echo "# $pass ok, $fail falha(s)"
[[ "$fail" -eq 0 ]]
