# SurrealDB fixado para os testes do agent-studio (#187), para `source` depois de definir ROOT, TMP e die.
# surreal_bin: usa o `surreal` do PATH se for a versão do compose; senão baixa o binário da release e confere o
# sha256 (cache em ~/.cache/oute-tests, montado sem corrida entre testes em paralelo: tests/lib/parallel.sh, #336).
# Define SURREAL. surreal_start <dir>: sobe em 127.0.0.1 (porta livre; se o processo morre antes do health, tenta
# outra, até START_TRIES; espera STARTUP_TIMEOUT), RocksDB em <dir>/data, root/SURREAL_TEST_PASS; define SURREAL_URL
# e SURREAL_PORT (já definida = reinício na mesma porta, uma tentativa). surreal_stop: derruba.
# surreal_q <sql>: roda no ns/db do agent-studio (oute/studio) e imprime o `result` do último statement em JSON.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/parallel.sh"
SV=3.3.0
grep -q "surrealdb/surrealdb:v$SV@sha256:" "$ROOT/docker/compose.yaml" \
  || die "a versão do SurrealDB no compose mudou: atualize SV e os checksums de tests/lib/surreal.sh"
# credencial só do teste, aleatória a cada execução
SURREAL_TEST_PASS="$(python3 -c "import secrets; print(secrets.token_hex(16))")"
surreal_bin() {
  local p os arch sum url
  p="$(command -v surreal || true)"
  if [[ -n "$p" ]] && "$p" version 2>/dev/null | grep -q "^$SV "; then SURREAL="$p"; return; fi
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) die "SO sem binário fixado: $(uname -s)" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "arquitetura sem binário fixado: $(uname -m)" ;; esac
  # sha256 dos .tgz da release v3.3.0 (surrealdb/surrealdb, conferidos com o digest publicado pelo GitHub)
  case "$os-$arch" in
    linux-amd64) sum=44aeab565f7e7e39d2d0bf0583c8aae648babc91373c70b2658288d95bbbcd55 ;;
    linux-arm64) sum=f03356497f875057126641f06757671542e0a7b75f18fd13820c2dab29349d74 ;;
    *) die "sem binário fixado do SurrealDB para $os-$arch" ;;
  esac
  url="https://github.com/surrealdb/surrealdb/releases/download/v$SV/surreal-v$SV.$os-$arch.tgz"
  cache_download "surreal-v$SV.$os-$arch.tgz" "$url" "$sum" || die "download do surreal falhou"
  tar -xzf "$CACHE_FILE" -C "$TMP" surreal || die "tar do surreal falhou"
  SURREAL="$TMP/surreal"
}
surreal_health() { curl -fsS --max-time 2 "http://127.0.0.1:$1/health"; }
surreal_launch() {
  "$SURREAL" start --no-banner --log warn --bind "127.0.0.1:$1" --user root --pass "$SURREAL_TEST_PASS" \
    "rocksdb://$SURREAL_DIR/data" >>"$SURREAL_DIR/log" 2>&1 & SPAWN_PID=$! SURREAL_PID=$!
}
surreal_start() {
  SURREAL_DIR="$1"; mkdir -p "$SURREAL_DIR"
  # SURREAL_PORT já definida (reinício): o agent-studio aponta para ela, então é uma tentativa só, na mesma porta
  if [[ -n "${SURREAL_PORT:-}" ]]; then spawn_try 1 "$SURREAL_PORT" surreal_launch surreal_health || return 1
  else spawn_try "$START_TRIES" "" surreal_launch surreal_health || return 1; fi
  SURREAL_PORT="$SPAWN_PORT"; SURREAL_URL="http://127.0.0.1:$SURREAL_PORT"
}
surreal_stop() { [[ -z "${SURREAL_PID:-}" ]] || { kill "$SURREAL_PID" 2>/dev/null; wait "$SURREAL_PID" 2>/dev/null; SURREAL_PID=""; }; }
surreal_q() {
  curl -s -u "root:$SURREAL_TEST_PASS" -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -H 'Surreal-NS: oute' -H 'Surreal-DB: studio' -X POST "$SURREAL_URL/rpc" \
    --data-binary "$(jq -cn --arg q "$1" '{id: 1, method: "query", params: [$q, {}]}')" | jq -c '.result[-1].result'
}
