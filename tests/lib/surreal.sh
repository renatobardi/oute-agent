# SurrealDB fixado para os testes do agent-studio (#187), para `source` depois de definir ROOT, TMP e die.
# surreal_bin: usa o `surreal` do PATH se for a versão do compose; senão baixa o binário da release e confere o
# sha256 (cache em ~/.cache/oute-tests). Define SURREAL. surreal_start <dir>: sobe em 127.0.0.1 (porta livre),
# RocksDB em <dir>/data, root/SURREAL_TEST_PASS; define SURREAL_URL. surreal_stop: derruba.
# surreal_q <sql>: roda no ns/db do agent-studio (oute/studio) e imprime o `result` do último statement em JSON.
SV=3.3.0
grep -q "surrealdb/surrealdb:v$SV@sha256:" "$ROOT/docker/compose.yaml" \
  || die "a versão do SurrealDB no compose mudou: atualize SV e os checksums de tests/lib/surreal.sh"
SURREAL_TEST_PASS="senha-de-teste-$$"
surreal_bin() {
  local p os arch sum url cache tgz got
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
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/oute-tests"; tgz="$cache/surreal-v$SV.$os-$arch.tgz"
  mkdir -p "$cache"
  sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
  if [[ ! -f "$tgz" || "$(sha "$tgz")" != "$sum" ]]; then
    echo "# baixando surreal $SV ($os/$arch)"
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$tgz.part" "$url" || die "download do surreal falhou"
    got="$(sha "$tgz.part")"
    [[ "$got" == "$sum" ]] || { rm -f "$tgz.part"; die "checksum do surreal não confere ($got)"; }
    mv "$tgz.part" "$tgz"
  fi
  tar -xzf "$tgz" -C "$TMP" surreal || die "tar do surreal falhou"
  SURREAL="$TMP/surreal"
}
surreal_start() {
  local dir="$1" port i
  mkdir -p "$dir"
  port="${SURREAL_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')}"
  SURREAL_PORT="$port"
  "$SURREAL" start --no-banner --log warn --bind "127.0.0.1:$port" --user root --pass "$SURREAL_TEST_PASS" \
    "rocksdb://$dir/data" >>"$dir/log" 2>&1 & SURREAL_PID=$!
  SURREAL_URL="http://127.0.0.1:$port"
  for i in $(seq 1 150); do
    curl -fsS "$SURREAL_URL/health" >/dev/null 2>&1 && return 0
    kill -0 "$SURREAL_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
surreal_stop() { [[ -z "${SURREAL_PID:-}" ]] || { kill "$SURREAL_PID" 2>/dev/null; wait "$SURREAL_PID" 2>/dev/null; SURREAL_PID=""; }; }
surreal_q() {
  curl -s -u "root:$SURREAL_TEST_PASS" -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -H 'Surreal-NS: oute' -H 'Surreal-DB: studio' -X POST "$SURREAL_URL/rpc" \
    --data-binary "$(jq -cn --arg q "$1" '{id: 1, method: "query", params: [$q, {}]}')" | jq -c '.result[-1].result'
}
