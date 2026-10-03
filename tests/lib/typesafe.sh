# Funções dos testes do Jev no seletor (#257), para `source`: a TypeSafe falsa (fake-typesafe.py) e o que chegou nela.
# ts_start <dir>: sobe a falsa com TLS (o seletor só fala https, #313; certificado gerado na hora, pelo openssl, e
#   posto em SSL_CERT_FILE, que o Python do seletor lê), exporta OUTE_SELECT_JEV_URL (o endereço dela) e
#   OUTE_TYPESAFE_API_KEY (chave gerada na hora, também em $TS_KEY); ts_stop: derruba.
# ts_set <modo> [fase] [confiança]: o que a falsa responde (modos no fake-typesafe.py).
# ts_calls: quantos pedidos chegaram; ts_last: o último pedido, {path, auth, body}; ts_reset: zera os pedidos.
# ts_off: tira do ambiente a chave, o endereço e o certificado (teste que não pode chamar TypeSafe nenhuma, nem a de verdade).
TS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ts_start() {
  TS_DIR="$1"; mkdir -p "$TS_DIR"; rm -f "$TS_DIR/port"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
    -keyout "$TS_DIR/key.pem" -out "$TS_DIR/cert.pem" >/dev/null 2>&1 || { echo "typesafe.sh: o openssl não gerou o certificado" >&2; return 1; }
  export SSL_CERT_FILE="$TS_DIR/cert.pem"
  python3 "$TS_LIB/fake-typesafe.py" "$TS_DIR" & TS_PID=$!
  local i scheme=https; for i in $(seq 1 50); do [[ -s "$TS_DIR/port" ]] && break; sleep 0.1; done
  TS_KEY="chave-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  export OUTE_SELECT_JEV_URL="$scheme://127.0.0.1:$(cat "$TS_DIR/port")/v1/systemone" OUTE_TYPESAFE_API_KEY="$TS_KEY"
}
ts_stop() { [[ -z "${TS_PID:-}" ]] || { kill "$TS_PID" 2>/dev/null; wait "$TS_PID" 2>/dev/null; TS_PID=""; }; }
ts_set() { printf '%s' "$1" > "$TS_DIR/mode"; printf '%s' "${2:-build}" > "$TS_DIR/choice"; printf '%s' "${3:-0.9}" > "$TS_DIR/confidence"; }
ts_calls() { cat "$TS_DIR/requests.jsonl" 2>/dev/null | grep -c . || true; }
ts_last() { tail -n1 "$TS_DIR/requests.jsonl" 2>/dev/null; }
ts_reset() { rm -f "$TS_DIR/requests.jsonl"; }
ts_off() { unset OUTE_TYPESAFE_API_KEY OUTE_SELECT_JEV_URL OUTE_SELECT_JEV_TIMEOUT SSL_CERT_FILE; }
