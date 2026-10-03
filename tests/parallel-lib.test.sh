#!/usr/bin/env bash
# Testes do tests/lib/parallel.sh e do que as libs do agent-studio, do SurrealDB e do collector fazem com ele (#336):
# o cache de teste montado por 8 processos ao mesmo tempo, o download com checksum, a nova tentativa com outra porta
# quando o servidor morre antes do health, o prazo de subida e o trap que derruba o serviço antes de subi-lo.
# Não baixa nem roda venv, SurrealDB ou collector: usa servidores de mentira. Precisa de python3, jq, curl e tar.
# Uso: tests/parallel-lib.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOLD_PIDS=""
trap 'for p in $HOLD_PIDS ${CPID:-} ${STUDIO_PID:-} ${SURREAL_PID:-}; do kill "$p" 2>/dev/null; done; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/parallel.sh"
. "$ROOT/tests/lib/otlp.sh"
. "$ROOT/tests/lib/agent-studio.sh"
. "$ROOT/tests/lib/surreal.sh"
. "$ROOT/tests/lib/otelcol.sh"
CHECK_OUT=+1

# ---------------------------------------------------------------- 1. cache_publish: 8 processos, cache vazio
# o construtor falso demora (0,3 a 0,7 s) para os 8 se sobreporem; cada processo é um bash à parte (o $$ é o que
# separa o caminho de montagem de cada um)
cat > "$TMP/worker.sh" <<EOF
. "$ROOT/tests/lib/parallel.sh"
fake_ok() { [[ -f "\$1/marker" && "\$(cat "\$1/marker")" == ok && -f "\$1/payload" ]]; }
fake_build() { echo "\$\$" >> "\$BUILDS"; mkdir -p "\$1"; sleep 0.\$((RANDOM % 5 + 3)); echo ok > "\$1/marker"; echo dados > "\$1/payload"; }
fake_bad() { mkdir -p "\$1"; echo lixo > "\$1/marker"; }
fake_fail() { mkdir -p "\$1"; echo parcial > "\$1/x"; return 7; }
cache_publish "\$@"
EOF
C="$TMP/cache"; BUILDS="$TMP/builds"; export BUILDS; : > "$BUILDS"
for i in 1 2 3 4 5 6 7 8; do ( bash "$TMP/worker.sh" "$C/venv" fake_ok fake_build; echo $? > "$TMP/rc.$i" ) & done
wait
check "8 chamadas simultâneas, cache vazio: todas com rc 0" bash -c 'cat "$1"/rc.* | sort | uniq -c | grep -qx " *8 0"' _ "$TMP"
check "8 chamadas: mais de um construiu (a corrida existiu)" bash -c '[ "$(wc -l < "$1")" -ge 2 ]' _ "$BUILDS"
check "8 chamadas: o cache tem só o destino, sem .tmp nem .bad" bash -c '[ "$(ls -A "$1")" = venv ]' _ "$C"
check "8 chamadas: destino íntegro e sem diretório aninhado dentro" bash -c '[ "$(ls -A "$1/venv" | tr "\n" " ")" = "marker payload " ] && [ "$(cat "$1/venv/marker")" = ok ]' _ "$C"

# ---------------------------------------------------------------- 2. já montado, falhas e destino estragado
: > "$BUILDS"
bash "$TMP/worker.sh" "$C/venv" fake_ok fake_build; RC=$?
check "já montado: rc 0 sem construir de novo" bash -c '[ "$1" -eq 0 ] && [ ! -s "$2" ]' _ "$RC" "$BUILDS"

bash "$TMP/worker.sh" "$C/falha" fake_ok fake_fail; RC=$?
check "construtor falha: rc 1" test "$RC" -eq 1
check "construtor falha: nada fica no cache" bash -c '[ ! -e "$1/falha" ] && ! ls -A "$1" | grep -q tmp' _ "$C"

bash "$TMP/worker.sh" "$C/ruim" fake_ok fake_bad; RC=$?
check "monta mas a verificação não passa: rc 1" test "$RC" -eq 1
check "monta mas a verificação não passa: nenhum resto" bash -c '! ls -A "$1" | grep -q "ruim"' _ "$C"

mkdir -p "$C/quebrado"; echo lixo > "$C/quebrado/marker"      # resto de uma montagem que morreu
bash "$TMP/worker.sh" "$C/quebrado" fake_ok fake_build; RC=$?
check "destino estragado: refeito, rc 0" bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/quebrado/marker")" = ok ] && [ "$(ls -A "$2/quebrado" | wc -l)" -eq 2 ]' _ "$RC" "$C"
check "destino estragado: sem .bad nem .tmp" bash -c '! ls -A "$1" | grep -qE "\.(bad|tmp)"' _ "$C"

# ---------------------------------------------------------------- 3. cache_dir e cache_download
check "cache_dir: XDG_CACHE_HOME vale" test "$(XDG_CACHE_HOME=/x cache_dir)" = /x/oute-tests
check "cache_dir: sem XDG, ~/.cache" test "$(env -u XDG_CACHE_HOME HOME=/h bash -c ". '$ROOT/tests/lib/parallel.sh'; cache_dir")" = /h/.cache/oute-tests
printf 'conteudo bom\n' > "$TMP/bom"; SUM="$(cache_sha256 "$TMP/bom")"
check "cache_sha256: 64 hexa" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' _ "$SUM"
# curl falso na frente do PATH: grava o que FAKE_CURL_BODY manda, ou falha; conta as chamadas
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'EOF'
#!/usr/bin/env bash
echo chamou >> "$FAKE_CURL_LOG"
[[ "${FAKE_CURL_FAIL:-0}" != 1 ]] || exit 22
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { printf '%s' "$FAKE_CURL_BODY" > "$2"; break; }; shift; done
EOF
chmod +x "$FB/curl"; export FAKE_CURL_LOG="$TMP/curl.log"; : > "$FAKE_CURL_LOG"
export XDG_CACHE_HOME="$TMP/dl"
mkdir -p "$XDG_CACHE_HOME/oute-tests"; cp "$TMP/bom" "$XDG_CACHE_HOME/oute-tests/pronto.tgz"
OUT="$(PATH="$FB:$PATH" cache_download pronto.tgz https://exemplo.invalid/x "$SUM")"; RC=$?
check "download: já no cache com o checksum certo, não chama o curl" bash -c '[ "$1" -eq 0 ] && [ ! -s "$2" ]' _ "$RC" "$FAKE_CURL_LOG"
OUT="$(FAKE_CURL_BODY='conteudo bom
' PATH="$FB:$PATH" cache_download novo.tgz https://exemplo.invalid/x "$SUM")"; RC=$?
check "download: baixa, confere e entra no cache" bash -c '[ "$1" -eq 0 ] && cmp -s "$2/oute-tests/novo.tgz" "$3"' _ "$RC" "$XDG_CACHE_HOME" "$TMP/bom"
OUT="$(FAKE_CURL_BODY='adulterado' PATH="$FB:$PATH" cache_download ruim.tgz https://exemplo.invalid/x "$SUM")"; RC=$?
check "download com checksum errado: rc 1" test "$RC" -eq 1
check "download com checksum errado: diz o checksum" has 'checksum de ruim.tgz não confere'
check "download com checksum errado: nada entra no cache" bash -c '! ls -A "$1/oute-tests" | grep -q ruim' _ "$XDG_CACHE_HOME"
OUT="$(FAKE_CURL_FAIL=1 PATH="$FB:$PATH" cache_download falhou.tgz https://exemplo.invalid/x "$SUM")"; RC=$?
check "download que o curl não completa: rc 1, nada no cache" bash -c '[ "$1" -eq 1 ] && ! ls -A "$2/oute-tests" | grep -q falhou' _ "$RC" "$XDG_CACHE_HOME"
check "download: nenhum .tmp sobrou" bash -c '! ls -A "$1/oute-tests" | grep -qE "\.(tmp|bad)"' _ "$XDG_CACHE_HOME"
unset XDG_CACHE_HOME

# ---------------------------------------------------------------- 4. servidor que morre antes do health: outra porta
# servidor de mentira: serve 200 em qualquer GET na porta dada (ou escuta e não responde: modo hang); porta tomada = morre
cat > "$TMP/server.py" <<'EOF'
import http.server, socket, sys, time
port, mode = int(sys.argv[1]), (sys.argv[2] if len(sys.argv) > 2 else "ok")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
if mode == "hang":
    s = socket.socket(); s.bind(("127.0.0.1", port)); s.listen(); time.sleep(300)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
# porta tomada por outro processo (presa, sem escutar: o connect é recusado na hora): cada chamada devolve uma
hold() { python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1], flush=True); time.sleep(300)' > "$TMP/hold.$1" & HOLD_PIDS="$HOLD_PIDS $!"
  local i; for i in $(seq 1 50); do [[ -s "$TMP/hold.$1" ]] && break; sleep 0.1; done; cat "$TMP/hold.$1"; }
hold 1 >/dev/null; hold 2 >/dev/null; hold 3 >/dev/null
HELD1="$(cat "$TMP/hold.1")"; HELD2="$(cat "$TMP/hold.2")"; HELD3="$(cat "$TMP/hold.3")"
# free_port com fila: devolve as portas de $TMP/portq na ordem e, acabada a fila, as de verdade
eval "orig_$(declare -f free_port)"
free_port() {
  local p; p="$(head -1 "$TMP/portq" 2>/dev/null)"
  if [[ -n "$p" ]]; then sed 1d "$TMP/portq" > "$TMP/portq.n"; mv "$TMP/portq.n" "$TMP/portq"; echo "$p"; else orig_free_port; fi
}
alive() { kill -0 "$1" 2>/dev/null; }

# agent-studio: o "python" do venv é um script que sobe o servidor de mentira na AGENT_STUDIO_PORT
cat > "$TMP/fake-py" <<EOF
#!/usr/bin/env bash
exec python3 "$TMP/server.py" "\$AGENT_STUDIO_PORT" "\${FAKE_MODE:-ok}"
EOF
chmod +x "$TMP/fake-py"; STUDIO_PY="$TMP/fake-py"
printf '%s\n' "$HELD1" > "$TMP/portq"
studio_start "$TMP/st1" FAKE_MODE=ok 2> "$TMP/st1.err"; RC=$?
check "studio_start: 1ª porta ocupada, sobe na 2ª (rc 0)" test "$RC" -eq 0
check "studio_start: STUDIO_URL é a porta que subiu, não a ocupada" bash -c '[ "$1" != "http://127.0.0.1:$2" ] && curl -fsS --max-time 3 "$1/healthz" >/dev/null' _ "$STUDIO_URL" "$HELD1"
check "studio_start: avisa a tentativa que falhou" bash -c 'grep -qF "subida falhou na porta $1 (tentativa 1 de 3)" "$2"' _ "$HELD1" "$TMP/st1.err"
check "studio_start: o processo está de pé" alive "$STUDIO_PID"
studio_stop
check "studio_stop: derruba" bash -c '! kill -0 "$1" 2>/dev/null' _ "$STUDIO_PID"
printf '%s\n%s\n%s\n' "$HELD1" "$HELD2" "$HELD3" > "$TMP/portq"
studio_start "$TMP/st2" 2> "$TMP/st2.err"; RC=$?
check "studio_start: 3 portas ocupadas, desiste com rc 1" test "$RC" -eq 1
check "studio_start: 3 tentativas, nenhuma a mais" test "$(grep -c 'subida falhou' "$TMP/st2.err")" -eq 3
check "studio_start: não deixa processo para trás" bash -c '! kill -0 "$1" 2>/dev/null' _ "$STUDIO_PID"
STARTUP_TIMEOUT=1; : > "$TMP/portq"
studio_start "$TMP/st3" FAKE_MODE=hang 2> "$TMP/st3.err"; RC=$?
check "studio_start: vivo e sem health no prazo, rc 1 sem tentar outra porta" bash -c '[ "$1" -eq 1 ] && ! grep -q "subida falhou" "$2"' _ "$RC" "$TMP/st3.err"
check "studio_start: prazo estourado derruba o processo" bash -c '! kill -0 "$1" 2>/dev/null' _ "$STUDIO_PID"
STARTUP_TIMEOUT=60
check "o prazo de subida é de 60 s, num lugar só" bash -c '[ "$1" -eq 60 ] && [ "$2" -eq 3 ] && ! grep -nE "seq 1 (100|150)|STARTUP_TIMEOUT=" "$3/agent-studio.sh" "$3/surreal.sh" "$3/otelcol.sh"' _ "$STARTUP_TIMEOUT" "$START_TRIES" "$ROOT/tests/lib"

# SurrealDB: o binário é um script que lê --bind e sobe o servidor de mentira
cat > "$TMP/fake-surreal" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do [[ "\$1" == --bind ]] && { b="\$2"; break; }; shift; done
exec python3 "$TMP/server.py" "\${b##*:}"
EOF
chmod +x "$TMP/fake-surreal"; SURREAL="$TMP/fake-surreal"; unset SURREAL_PORT
printf '%s\n' "$HELD1" > "$TMP/portq"
surreal_start "$TMP/sv1" 2> "$TMP/sv1.err"; RC=$?
check "surreal_start: 1ª porta ocupada, sobe na 2ª" bash -c '[ "$1" -eq 0 ] && [ "$2" != "$3" ] && [ "$4" = "http://127.0.0.1:$2" ] && curl -fsS --max-time 3 "$4/health" >/dev/null' _ "$RC" "$SURREAL_PORT" "$HELD1" "$SURREAL_URL"
surreal_stop
SURREAL_PORT="$HELD2"                                   # reinício: o agent-studio aponta para esta porta
surreal_start "$TMP/sv2" 2> "$TMP/sv2.err"; RC=$?
check "surreal_start: reinício em porta fixa ocupada: rc 1, uma tentativa só" bash -c '[ "$1" -eq 1 ] && [ "$(grep -c "subida falhou" "$2")" -eq 1 ] && [ "$3" = "$4" ]' _ "$RC" "$TMP/sv2.err" "$SURREAL_PORT" "$HELD2"
unset SURREAL_PORT

# collector: o binário lê o endpoint do health check do config do teste e sobe o servidor de mentira nele
cat > "$TMP/fake-otelcol" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == --config=* ]] && f="\${a#--config=}" && grep -q health_check "\$f" 2>/dev/null && p="\$(sed -n 's/.*health_check: {endpoint: 127.0.0.1:\([0-9]*\)}.*/\1/p' "\$f")"; done
exec python3 "$TMP/server.py" "\$p"
EOF
chmod +x "$TMP/fake-otelcol"; OTELCOL="$TMP/fake-otelcol"; mkdir -p "$TMP/queue"
HTTP="$HELD2"; GRPC="$HELD3"; HC="$HELD1"
otelcol_test_yaml > "$TMP/test.yaml"; echo "# endpoint de teste: http://127.0.0.1:$HTTP/v1/metrics" >> "$TMP/test.yaml"
printf '%s\n%s\n%s\n' "$(orig_free_port)" "$(orig_free_port)" "$(orig_free_port)" > "$TMP/portq"
NEW_HTTP="$(sed -n 1p "$TMP/portq")"; NEW_GRPC="$(sed -n 2p "$TMP/portq")"; NEW_HC="$(sed -n 3p "$TMP/portq")"
: > "$TMP/collector.log"
otelcol_start --config="$ROOT/config/otel/collector.yaml" --config="$TMP/test.yaml" > "$TMP/oc1.out" 2> "$TMP/oc1.err"; RC=$?
check "otelcol_start: 1ª porta do health ocupada, sobe com outras (rc 0)" test "$RC" -eq 0
check "otelcol_start: HTTP, GRPC e HC são as novas" bash -c '[ "$1" = "$4" ] && [ "$2" = "$5" ] && [ "$3" = "$6" ]' _ "$HTTP" "$GRPC" "$HC" "$NEW_HTTP" "$NEW_GRPC" "$NEW_HC"
check "otelcol_start: o config do teste passa a ter as portas novas, em todo lugar" bash -c 'grep -qF "health_check: {endpoint: 127.0.0.1:$2}" "$1" && grep -qF "http: {endpoint: 127.0.0.1:$3}" "$1" && grep -qF "grpc: {endpoint: 127.0.0.1:$4}" "$1" && grep -qF "127.0.0.1:$3/v1/metrics" "$1"' _ "$TMP/test.yaml" "$NEW_HC" "$NEW_HTTP" "$NEW_GRPC"
check "otelcol_start: nenhuma porta velha sobrou no config" bash -c '! grep -qE "127\.0\.0\.1:($2|$3|$4)([^0-9]|$)" "$1"' _ "$TMP/test.yaml" "$HELD1" "$HELD2" "$HELD3"
check "otelcol_start: o config de produção não é tocado" bash -c 'cd "$1" && git diff --quiet -- config/otel' _ "$ROOT"
check "otelcol_start: avisa a tentativa que falhou" grep -qF 'tentativa 1 de 3' "$TMP/oc1.err"
check "otelcol_start: o collector está de pé" alive "$CPID"
otelcol_kill
# 3 mortes seguidas: desiste com rc 1, diz que não subiu, e o CPID fica (o otelcol_log/cleanup do teste usa)
HC="$HELD1"; HTTP="$HELD2"; GRPC="$HELD3"
otelcol_test_yaml > "$TMP/test2.yaml"
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$HELD2" "$HELD3" "$HELD1" "$HELD2" "$HELD3" "$HELD1" > "$TMP/portq"
otelcol_start --config="$TMP/test2.yaml" > "$TMP/oc2.out" 2> "$TMP/oc2.err"; RC=$?
check "otelcol_start: morre nas 3 tentativas: rc 1" test "$RC" -eq 1
check "otelcol_start: 3 tentativas e o aviso final" bash -c '[ "$(grep -c "collector morreu antes do health" "$1")" -eq 2 ] && grep -qxF "# collector não subiu" "$2"' _ "$TMP/oc2.err" "$TMP/oc2.out"
check "otelcol_start: o último processo não sobra" bash -c '! kill -0 "$1" 2>/dev/null' _ "$CPID"

# ---------------------------------------------------------------- 5. trap antes de subir o serviço, em todo teste
# o trap (ou a função que ele chama) que derruba cada serviço vem numa linha anterior à primeira que o sobe
NO_TRAP=""
for t in "$ROOT"/tests/*.test.sh; do
  case "$t" in */parallel-lib.test.sh|*/otelcol-lib.test.sh) continue ;; esac
  while IFS=: read -r start stop; do
    first="$(grep -nE "^[^#]*\b$start\b" "$t" | grep -v "^[0-9]*:$start()" | head -1 | cut -d: -f1)"
    [[ -n "$first" ]] || continue
    armed="$(grep -nE "^(trap |cleanup\(\))" "$t" | grep -E "$stop" | head -1 | cut -d: -f1)"
    [[ -n "$armed" && "$armed" -lt "$first" ]] || NO_TRAP="$NO_TRAP $(basename "$t"):$start"
  done <<'PAIRS'
studio_start:studio_stop
surreal_start:surreal_stop
rcv_start:rcv_stop
ps_start:ps_stop
otelcol_start:CPID
otelcol_s3_start:S3PID
PAIRS
done
check "todo teste arma o trap que derruba o serviço antes de subi-lo${NO_TRAP:+ (faltam:$NO_TRAP)}" test -z "$NO_TRAP"

check_end
