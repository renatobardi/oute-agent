# Funções dos testes de eventos operacionais (#124), para `source`: receptor OTLP falso e leitura do que chegou.
# rcv_start <dir>: sobe o receptor e exporta OTEL_EXPORTER_OTLP_ENDPOINT; rcv_stop: derruba.
# events <dir>: um objeto JSON por registro recebido: {name, time, body, attrs{}, res{}}.
# ev <jq-select>: registros recebidos pelo receptor atual que casam o filtro; n <jq-select>: quantos.
# mpoints <dir>: um objeto por ponto de métrica (gauge) recebido: {name, unit, value, time, attrs{}, res{}, path}; mp <jq-select>: os do receptor atual.
OTLP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$OTLP_LIB/parallel.sh"   # free_port
rcv_start() {
  RCV_DIR="$1"; mkdir -p "$RCV_DIR"; rm -f "$RCV_DIR/port"
  python3 "$OTLP_LIB/otlp-receiver.py" "$RCV_DIR" & RCV_PID=$!
  local i; for i in $(seq 1 50); do [[ -s "$RCV_DIR/port" ]] && break; sleep 0.1; done
  export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(cat "$RCV_DIR/port")"
}
rcv_stop() {
  [[ -z "${RCV_PID:-}" ]] || { kill "$RCV_PID" 2>/dev/null; wait "$RCV_PID" 2>/dev/null; RCV_PID=""; }
  # com a guarda (#815), sem receptor o endpoint é uma porta fechada: nada chega a um coletor de verdade (o evento
  # fica no spool do HOME do teste), e a guarda só vê o que sai antes do primeiro receptor
  [[ -z "${GUARDA_DIR:-}" ]] || export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(closed_port)"
  return 0
}
# guarda (#815): o container tem OTEL_* reais e o ~/.oute_env com o coletor de verdade. Um evento que o teste manda sem
# receptor próprio, com o endpoint herdado, iria ao coletor real. guarda_start <dir>: sobe um receptor que só guarda o que
# chegar e aponta o ambiente a ele; guarda_check (pelo check) falha se algum POST chegou lá; guarda_posts: quantos.
guarda_start() {
  local dir="$1"
  GUARDA_DIR="$dir"; mkdir -p "$GUARDA_DIR"; rm -f "$GUARDA_DIR/port"
  unset OTEL_EXPORTER_OTLP_LOGS_ENDPOINT
  python3 "$OTLP_LIB/otlp-receiver.py" "$GUARDA_DIR" & GUARDA_PID=$!
  disown "$GUARDA_PID"   # fora da tabela de jobs: um `wait` do teste não espera a guarda
  local i; for i in $(seq 1 50); do [[ -s "$GUARDA_DIR/port" ]] && break; sleep 0.1; done
  GUARDA_EP="http://127.0.0.1:$(cat "$GUARDA_DIR/port")"
  export OTEL_EXPORTER_OTLP_ENDPOINT="$GUARDA_EP"
  return 0
}
guarda_posts() { ls "$GUARDA_DIR"/*.json 2>/dev/null | wc -l | tr -d ' '; return 0; }
guarda_check() {
  [[ "$(guarda_posts)" -eq 0 ]] || for f in "$GUARDA_DIR"/*.json; do echo "     guarda | $(cat "${f%.json}.path" 2>/dev/null) $(head -c 300 "$f")"; done
  check "guarda: nenhum evento saiu para endpoint que não é o receptor do teste ($(guarda_posts) POST)" [ "$(guarda_posts)" -eq 0 ]
  return $?
}
guarda_stop() { [[ -z "${GUARDA_PID:-}" ]] || { kill "$GUARDA_PID" 2>/dev/null; GUARDA_PID=""; }; return 0; }
events() {
  local f; f=("$1"/*.json); [[ -e "${f[0]}" ]] || return 0
  jq -c '.resourceLogs[]? | (.resource.attributes | map({(.key): (.value | to_entries[0].value)}) | add) as $res
         | .scopeLogs[].logRecords[] | {name: .eventName, time: .timeUnixNano, body: (.body.stringValue // null),
           attrs: (.attributes | map({(.key): (.value | to_entries[0].value)}) | add), res: $res}' "${f[@]}"
}
# mpoints <dir>: um objeto por ponto de métrica recebido (gauge): {name, unit, value, time, attrs{}, res{}, path}
mpoints() {
  local f; for f in "$1"/*.json; do
    [[ -e "$f" ]] || return 0
    jq -c --arg path "$(cat "${f%.json}.path" 2>/dev/null)" '.resourceMetrics[]? | (.resource.attributes | map({(.key): (.value | to_entries[0].value)}) | add) as $res
      | .scopeMetrics[].metrics[] | .name as $n | .unit as $u | .gauge.dataPoints[]
      | {name: $n, unit: $u, value: ((.asDouble // (.asInt | tonumber))), time: .timeUnixNano,
         attrs: ((.attributes // []) | map({(.key): (.value | to_entries[0].value)}) | add), res: $res, path: $path}' "$f"
  done
}
mp() { mpoints "$RCV_DIR" | jq -c "select($1)"; }
ev() { events "$RCV_DIR" | jq -c "select($1)"; }
n() { ev "$1" | grep -c . || true; }
# closed_port: porta local sem ninguém escutando (receptor fora do ar)
closed_port() { free_port; }
