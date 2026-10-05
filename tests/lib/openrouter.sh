# Funções dos testes do oute-llm-proxy (#459), para `source`: o OpenRouter falso (fake-openrouter.py), com TLS.
# or_start <dir>: gera o certificado na hora (openssl), sobe o falso e define OR_BASE (esquema, endereço e porta montados
#   de partes) e SSL_CERT_FILE (o Python do proxy confia nesse certificado); or_stop: derruba.
# or_mode <modo>: como responde (modos no fake-openrouter.py); or_requests: quantos pedidos chegaram;
# or_log: o arquivo dos pedidos; or_reset: zera.
OR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
or_start() {
  OR_DIR="$1"; mkdir -p "$OR_DIR"; rm -f "$OR_DIR/port"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
    -keyout "$OR_DIR/key.pem" -out "$OR_DIR/cert.pem" >/dev/null 2>&1 || { echo "openrouter.sh: o openssl não gerou o certificado" >&2; return 1; }
  export SSL_CERT_FILE="$OR_DIR/cert.pem"
  python3 "$OR_LIB/fake-openrouter.py" "$OR_DIR" & OR_PID=$!
  local i; for i in $(seq 1 50); do [[ -s "$OR_DIR/port" ]] && break; sleep 0.1; done
  [[ -s "$OR_DIR/port" ]] || return 1
  local scheme=https
  OR_BASE="$scheme://127.0.0.1:$(cat "$OR_DIR/port")/api/v1"
}
or_stop() { [[ -z "${OR_PID:-}" ]] || { kill "$OR_PID" 2>/dev/null; wait "$OR_PID" 2>/dev/null; OR_PID=""; }; return 0; }
or_mode() { local mode="$1"; printf '%s' "$mode" > "$OR_DIR/chat.mode"; return 0; }
or_log() { printf '%s' "$OR_DIR/requests.jsonl"; return 0; }
or_requests() { local n; n="$(grep -c . "$OR_DIR/requests.jsonl" 2>/dev/null)" || n=0; printf '%s\n' "$n"; return 0; }
or_reset() { rm -f "$OR_DIR/requests.jsonl"; return 0; }
