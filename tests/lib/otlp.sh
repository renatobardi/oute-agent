# Funções dos testes de eventos operacionais (#124), para `source`: receptor OTLP falso e leitura do que chegou.
# rcv_start <dir>: sobe o receptor e exporta OTEL_EXPORTER_OTLP_ENDPOINT; rcv_stop: derruba.
# events <dir>: um objeto JSON por registro recebido: {name, time, body, attrs{}, res{}}.
OTLP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rcv_start() {
  RCV_DIR="$1"; mkdir -p "$RCV_DIR"; rm -f "$RCV_DIR/port"
  python3 "$OTLP_LIB/otlp-receiver.py" "$RCV_DIR" & RCV_PID=$!
  local i; for i in $(seq 1 50); do [[ -s "$RCV_DIR/port" ]] && break; sleep 0.1; done
  export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(cat "$RCV_DIR/port")"
}
rcv_stop() { [[ -z "${RCV_PID:-}" ]] || { kill "$RCV_PID" 2>/dev/null; wait "$RCV_PID" 2>/dev/null; RCV_PID=""; }; }
events() {
  local f; f=("$1"/*.json); [[ -e "${f[0]}" ]] || return 0
  jq -c '.resourceLogs[] | (.resource.attributes | map({(.key): (.value | to_entries[0].value)}) | add) as $res
         | .scopeLogs[].logRecords[] | {name: .eventName, time: .timeUnixNano, body: (.body.stringValue // null),
           attrs: (.attributes | map({(.key): (.value | to_entries[0].value)}) | add), res: $res}' "${f[@]}"
}
# closed_port: porta local sem ninguém escutando (receptor fora do ar)
closed_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
