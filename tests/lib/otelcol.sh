# Apoio dos testes do collector (tests/otelcol-*.test.sh; #161, #162, #246), para `source` depois de definir ROOT e TMP
# e de carregar o tests/lib/check.sh (die, check, ok, bad) e o tests/lib/otlp.sh (closed_port). Ao carregar, confere
# python3, jq, curl e tar (sem eles, sai com 1) e a versão do collector no compose.
# otelcol_bin: usa o otelcol-contrib do PATH se for a versão do compose; senão baixa o binário fixado e confere o
# sha256 (cache em ~/.cache/oute-tests). Define OTELCOL e V. otelcol_version_ok: o binário é o da versão V.
# otelcol_env: exporta o ambiente que o config/otel/collector.yaml lê (origem, S3 numa porta fechada,
# credenciais de mentira); o teste exporta por cima o que for dele.
# otelcol_print <--config=…>: o config final em JSON; jqp <filtro jq>: `jq -e` sem saída sobre $P, o config impresso.
# otelcol_s3_start <dir> [modo]: sobe o S3 falso (fakes3.py; modo ok ou down em <dir>/mode), define S3PID e aponta o
# OCI_S3_ENDPOINT para ele; sem ele no ar, sai com 1.
# otelcol_ports: define HTTP, GRPC e HC (portas livres). otelcol_test_yaml [s3]: o começo do config só do teste
# (health check, diretório da fila e receiver em 127.0.0.1); com `s3`, mais os exporters do bucket com flush_timeout
# de 5 s (produção: 5 min), e o teste acrescenta os exporters dele logo depois.
# otelcol_start <--config=…>: sobe o collector (log em $TMP/collector.log), define CPID e espera o health check;
# se não subir, mostra o fim do log e devolve 1. otelcol_kill: `kill -9` no collector.
# otelcol_tally <aceitos>: lê do stdin os ids que chegaram ao destino, um por linha, e imprime "aceitos recebidos
# perdidos duplicados" (recebidos e perdidos só entre os aceitos). O teste define counts <run> com ele.
# wait_all <run> <s>: espera até <s> segundos por todos os aceitos no destino (usa o counts do teste).
# otelcol_kill9 <s> <destino> [detalhe]: o cenário do `kill -9` com lote pendente (casos "kill -9: …"): manda N por
# sinal, mata, sobe de novo com o start do teste e espera <s> segundos. Usa HTTP, N, start e counts do teste.
# otelcol_log: com caso falhando, mostra o fim do log do collector; vai antes do check_end.
for c in python3 jq curl tar; do command -v "$c" >/dev/null || die "precisa de $c"; done
OTELCOL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$tgz.part" "$url" || die "download do otelcol-contrib falhou"
    got="$(sha "$tgz.part")"
    [[ "$got" == "$sum" ]] || { rm -f "$tgz.part"; die "checksum do otelcol-contrib não confere ($got)"; }
    mv "$tgz.part" "$tgz"
  fi
  tar -xzf "$tgz" -C "$TMP" otelcol-contrib || die "tar do otelcol-contrib falhou"
  OTELCOL="$TMP/otelcol-contrib"
}
otelcol_version_ok() { "$OTELCOL" --version | grep -q " $V\$"; }
otelcol_env() {
  export OUTE_HOST=oute-test OUTE_INSTANCE=oute-agent OCI_S3_REGION=sa-saopaulo-1 OCI_S3_ENDPOINT="http://127.0.0.1:$(closed_port)" \
    AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y \
    AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
}
otelcol_print() { "$OTELCOL" print-config --mode=unredacted --format=json "$@" 2>/dev/null; }
jqp() { jq -e "$@" >/dev/null <<<"$P"; }
otelcol_s3_start() {
  mkdir -p "$1"; [[ -z "${2:-}" ]] || echo "$2" > "$1/mode"
  python3 "$OTELCOL_LIB/fakes3.py" "$1" & S3PID=$!
  local i; for i in $(seq 1 50); do [[ -s "$1/port" ]] && break; sleep 0.1; done
  [[ -s "$1/port" ]] || die "S3 falso não subiu"
  export OCI_S3_ENDPOINT="http://127.0.0.1:$(cat "$1/port")"
}
otelcol_ports() { HTTP="$(closed_port)"; GRPC="$(closed_port)"; HC="$(closed_port)"; }
otelcol_test_yaml() {
  cat <<EOF
extensions:
  health_check: {endpoint: 127.0.0.1:$HC}
  file_storage/queue: {directory: $TMP/queue}
receivers:
  otlp: {protocols: {grpc: {endpoint: 127.0.0.1:$GRPC}, http: {endpoint: 127.0.0.1:$HTTP}}}
EOF
  [[ "${1:-}" != s3 ]] || cat <<EOF
exporters:
  awss3/traces: {sending_queue: {batch: {flush_timeout: 5s}}}
  awss3/metrics: {sending_queue: {batch: {flush_timeout: 5s}}}
  awss3/logs: {sending_queue: {batch: {flush_timeout: 5s}}}
EOF
}
otelcol_start() {
  "$OTELCOL" "$@" >>"$TMP/collector.log" 2>&1 & CPID=$!
  local i; for i in $(seq 1 100); do curl -fs -o /dev/null "127.0.0.1:$HC" && return 0; sleep 0.1; done
  echo "# collector não subiu"; tail -20 "$TMP/collector.log"; return 1
}
otelcol_kill() { kill -9 "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null; CPID=""; }
otelcol_tally() {
  python3 -c '
import collections, sys
acc = set(l.strip() for l in open(sys.argv[1]) if l.strip())
c = collections.Counter(l.rstrip("\n") for l in sys.stdin)
print(len(acc), len(acc & set(c)), len(acc - set(c)), sum(c[i] - 1 for i in acc if c[i] > 1))' "$1"
}
wait_all() { local i; for i in $(seq 1 $(($2 * 2))); do set -- "$1" "$2" $(counts "$1"); [[ "$5" -eq 0 ]] && return 0; sleep 0.5; done; return 1; }
otelcol_kill9() {
  local a r d
  python3 "$OTELCOL_LIB/otlp-send.py" "$HTTP" k9 "$N" "$TMP/accepted-k9.txt" >/dev/null
  read -r a r _ _ <<<"$(counts k9)"
  check "kill -9: aceitou os $((N * 3)) itens${3:+ $3}" [ "$a" -eq $((N * 3)) ]
  check "kill -9: lote ainda pendente (nada no $2)"     [ "$r" -eq 0 ]
  otelcol_kill
  start || die "collector (restart)"
  if wait_all k9 "$1"; then ok "kill -9: aceitos = recebidos depois do restart"; else bad "kill -9: perdeu itens ($(counts k9))"; fi
  read -r _ _ _ d <<<"$(counts k9)"; echo "# kill -9: duplicados=$d"
}
otelcol_log() { [[ "$fail" -eq 0 ]] || { echo "# log do collector:"; tail -30 "$TMP/collector.log"; }; }
