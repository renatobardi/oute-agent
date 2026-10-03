# Funções dos testes da conferência diária de preços (#339), para `source`: as fontes falsas (fake-price-sources.py).
# ps_start <dir>: sobe com TLS (certificado gerado na hora, pelo openssl, posto em SSL_CERT_FILE, que o Python do
#   agent-studio lê) e exporta AGENT_STUDIO_PRICE_URL_MODELS_DEV e AGENT_STUDIO_PRICE_URL_OPENROUTER; ps_stop: derruba.
# ps_body <fonte> <arquivo>: o JSON que a fonte responde; ps_mode <fonte> <modo>: como responde (modos no fake-price-sources.py).
# ps_requests: quantos pedidos chegaram; ps_log: o arquivo dos pedidos; ps_reset: zera.
# ps_off: tira do ambiente as URLs e o certificado (teste que não pode chamar fonte nenhuma, nem a de verdade).
PS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ps_start() {
  PS_DIR="$1"; mkdir -p "$PS_DIR"; rm -f "$PS_DIR/port"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
    -keyout "$PS_DIR/key.pem" -out "$PS_DIR/cert.pem" >/dev/null 2>&1 || { echo "price-sources.sh: o openssl não gerou o certificado" >&2; return 1; }
  export SSL_CERT_FILE="$PS_DIR/cert.pem"
  python3 "$PS_LIB/fake-price-sources.py" "$PS_DIR" & PS_PID=$!
  local i; for i in $(seq 1 50); do [[ -s "$PS_DIR/port" ]] && break; sleep 0.1; done
  [[ -s "$PS_DIR/port" ]] || return 1
  local scheme=https base; base="$scheme://127.0.0.1:$(cat "$PS_DIR/port")"
  export AGENT_STUDIO_PRICE_URL_MODELS_DEV="$base/models.dev/api.json" AGENT_STUDIO_PRICE_URL_OPENROUTER="$base/openrouter/api/v1/models"
}
ps_stop() { [[ -z "${PS_PID:-}" ]] || { kill "$PS_PID" 2>/dev/null; wait "$PS_PID" 2>/dev/null; PS_PID=""; }; }
ps_body() { cp "$2" "$PS_DIR/$1.body"; rm -f "$PS_DIR/$1.mode"; }
ps_mode() { printf '%s' "$2" > "$PS_DIR/$1.mode"; }
ps_log() { printf '%s' "$PS_DIR/requests.jsonl"; }
ps_requests() { cat "$PS_DIR/requests.jsonl" 2>/dev/null | grep -c . || true; }
ps_reset() { rm -f "$PS_DIR/requests.jsonl"; }
ps_off() { unset AGENT_STUDIO_PRICE_URL_MODELS_DEV AGENT_STUDIO_PRICE_URL_OPENROUTER AGENT_STUDIO_PRICE_CHECK SSL_CERT_FILE; }
