#!/usr/bin/env bash
# Testes do canal de aprovação no host (`oute approve`, #210). Bash puro, sem Docker: `docker` e `oute-emit` são
# falsos. O container "existe" enquanto o arquivo $F_UP existir; `docker exec` roda o comando local com
# HOME=$F_CTR_HOME (o $HOME do container). A resposta do prompt vem de OUTE_APPROVE_TTY (arquivo no lugar do /dev/tty).
# Cenário da #210: o script aprovado derruba o próprio oute-agent (oute down), deixa um daemon herdando o stdout
# (como o rclone mount --daemon do oute up) e o container volta só depois do fim do script.
# #158: `oute approve <id>` decide só aquele pedido; argumento ruim sai antes de qualquer `docker` (log em $F_DOCKER).
# Uso: tests/oute-approve.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
# credenciais reais nunca chegam ao scripts/oute daqui (docker é falso, mas o script lê o ambiente)
for v in $(compgen -e | grep -E '^(OCI_|GH_TOKEN$|GITHUB_TOKEN$|AGENT_STUDIO_|BW_|LANGFUSE_)' || true); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTE="$ROOT/scripts/oute"
TMP="$(mktemp -d)"
cleanup() { [[ -s "$TMP/daemons" ]] && kill $(cat "$TMP/daemons") 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=30   # o bad mostra o fim da saída
has() { grep -q -- "$1" <<<"$OUT"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
up() { [[ -e "$F_UP" ]]; }
echo "$*" >> "$F_DOCKER"
case "$1" in
  ps)   up && echo abc123; exit 0 ;;
  exec) shift; [[ "$1" == -i ]] && shift; shift
        up || { echo "Error response from daemon: No such container: oute-agent" >&2; exit 1; }
        HOME="$F_CTR_HOME" exec "$@" ;;
  *)    exit 9 ;;
esac
SH
cat > "$BIN/oute-emit" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$F_EMITS"
SH
chmod +x "$BIN/docker" "$BIN/oute-emit"

export PATH="$BIN:$PATH" OUTE_HOST=teste OUTE_INSTANCE=teste
export F_UP="$TMP/up" F_CTR_HOME="$TMP/ctr" F_EMITS="$TMP/emits" F_RUNS="$TMP/runs" F_DAEMONS="$TMP/daemons" F_DOCKER="$TMP/docker.calls"
export OUTE_APPROVE_TTY="$TMP/answer"

# novo cenário: host e container limpos, container de pé, um pedido na outbox
reset() {
  rm -rf "$TMP/host" "$TMP/ctr" "$F_EMITS" "$F_RUNS" "$F_DOCKER"; mkdir -p "$TMP/host" "$TMP/ctr/outbox" "$TMP/ctr/inbox"
  touch "$F_UP"
}
propose() {  # $1=id, stdin=corpo do script
  { printf '# oute-propose\n# titulo: teste %s\n# como: user\n\nset -euo pipefail\n' "$1"; cat; } > "$TMP/ctr/outbox/$1.sh"
}
# roda `oute approve [args…]` com prazo: se passar de $1 s, é o travamento da #210 (ou o --watch, que não sai)
run_approve() {
  local limit="$1" i=0 pid; shift
  HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve "$@" > "$TMP/approve.log" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    (( i >= limit * 10 )) && { kill "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; OUT="$(cat "$TMP/approve.log")"; RC=124; return; }
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid"; RC=$?; OUT="$(cat "$TMP/approve.log")"
}
inbox() { cat "$TMP/ctr/inbox/$1.out" 2>/dev/null; }
runs_dir="$TMP/host/.oute/approve/runs"

# script que imita `oute down` + `oute up`: container some, daemon herda o stdout, container volta 2 s depois do fim
RESTART_BODY='echo x >> "$F_RUNS"
echo "antes do down"
rm -f "$F_UP"
sleep 30 & echo $! >> "$F_DAEMONS"
( sleep 2; touch "$F_UP" ) >/dev/null 2>&1 &
echo "depois do up"
exit 7'

# --- 1. script recria o próprio container: resultado gravado mesmo assim
reset; id=20260930-010101-restart-proprio-agent
propose "$id" <<<"$RESTART_BODY"
echo s > "$OUTE_APPROVE_TTY"
run_approve 20
check "restart: approve termina (não trava no daemon que herdou o stdout)" test "$RC" = 0
R="$(inbox "$id")"
check "restart: inbox/<id>.out gravado com rc 7" grep -q '^# rc: 7$' <<<"$R"
check "restart: .out tem duração e tamanho" bash -c 'grep -q "^# duracao: [0-9]* s$" <<<"$1" && grep -q "^# saida: [0-9]* bytes$" <<<"$1"' _ "$R"
check "restart: .out tem a saída inteira do script" bash -c 'grep -q "antes do down" <<<"$1" && grep -q "depois do up" <<<"$1"' _ "$R"
check "restart: pedido movido para outbox/done" test -f "$TMP/ctr/outbox/done/$id.sh" -a ! -e "$TMP/ctr/outbox/$id.sh"
check "restart: approve.log registra exec rc=7" grep -q "$id.*exec.rc=7" "$TMP/host/.oute/approve/approve.log"
check "restart: nada ficou pendente no host" bash -c '! compgen -G "$1/*.result" >/dev/null' _ "$runs_dir"
check "restart: evento canal emitido" grep -qx "canal $id" "$F_EMITS"
check "restart: script rodou uma vez" test "$(wc -l < "$F_RUNS" | tr -d ' ')" = 1

# --- 2. container não volta no prazo: resultado fica no host e a próxima rodada entrega, sem rodar de novo
reset; id=20260930-020202-container-demora
propose "$id" <<'SH'
echo x >> "$F_RUNS"
rm -f "$F_UP"
echo "rodou"
SH
echo s > "$OUTE_APPROVE_TTY"
OUTE_APPROVE_WAIT=2 run_approve 20
check "sem container: approve termina com 0" test "$RC" = 0
check "sem container: avisa que o resultado ficou no host" has "resultado de $id guardado"
check "sem container: resultado guardado em runs/<id>.done.result" grep -q '^# rc: 0$' "$runs_dir/$id.done.result"
check "sem container: approve.log registra mesmo assim" grep -q "$id.*exec.rc=0" "$TMP/host/.oute/approve/approve.log"
check "sem container: inbox ainda sem .out" test ! -e "$TMP/ctr/inbox/$id.out"
# oute approve avulso chamado com o container ainda fora: espera ele voltar e entrega (não morre na guarda)
: > "$OUTE_APPROVE_TTY"; ( sleep 2; touch "$F_UP" ) >/dev/null 2>&1 &
run_approve 20
check "próxima rodada (container fora ao chamar): espera e termina com 0" test "$RC" = 0
check "próxima rodada: não mostra o pedido de novo" bash -c '! grep -q "pedido $1" <<<"$2"' _ "$id" "$OUT"
check "próxima rodada: entrega o .out guardado" bash -c 'grep -q "^# rc: 0$" <<<"$1" && grep -q rodou <<<"$1"' _ "$(inbox "$id")"
check "próxima rodada: pedido em outbox/done e nada pendente" \
  bash -c 'test -f "$1/done/$2.sh" -a ! -e "$1/$2.sh" && ! compgen -G "$3/*.result" >/dev/null' _ "$TMP/ctr/outbox" "$id" "$runs_dir"
check "próxima rodada: script não rodou de novo" test "$(wc -l < "$F_RUNS" | tr -d ' ')" = 1
check "próxima rodada: evento canal emitido na entrega" grep -qx "canal $id" "$F_EMITS"

# --- 2b. container fora e não volta: approve avulso tenta, avisa, morre na guarda e o resultado segue no host
reset; id=20260930-020303-container-nao-volta
propose "$id" <<'SH'
echo x >> "$F_RUNS"
rm -f "$F_UP"
SH
echo s > "$OUTE_APPROVE_TTY"
OUTE_APPROVE_WAIT=1 run_approve 20
: > "$OUTE_APPROVE_TTY"
OUTE_APPROVE_WAIT=2 run_approve 20
check "sem volta: approve avulso sai com erro de container fora" bash -c '[[ $1 != 0 ]] && grep -q "não está rodando" <<<"$2"' _ "$RC" "$OUT"
check "sem volta: avisou que o resultado segue guardado" has "resultado de $id guardado"
check "sem volta: resultado continua no host" test -f "$runs_dir/$id.done.result"

# --- 3. recusa: mesma entrega (rc 126, outbox/rejected), nada executado
reset; id=20260930-030303-recusado
propose "$id" <<'SH'
echo x >> "$F_RUNS"
SH
echo r > "$OUTE_APPROVE_TTY"
run_approve 20
check "recusa: .out com rc 126" grep -q '^# rc: 126$' "$TMP/ctr/inbox/$id.out"
check "recusa: pedido em outbox/rejected" test -f "$TMP/ctr/outbox/rejected/$id.sh" -a ! -e "$TMP/ctr/outbox/$id.sh"
check "recusa: nada executado" test ! -e "$F_RUNS"

# --- 4. sem resposta: fica pendente, nada gravado
reset; id=20260930-040404-pendente
propose "$id" <<<'echo x >> "$F_RUNS"'
: > "$OUTE_APPROVE_TTY"
run_approve 20
check "pendente: sem .out, pedido segue na outbox" test ! -e "$TMP/ctr/inbox/$id.out" -a -f "$TMP/ctr/outbox/$id.sh"

# --- 6. #158: `oute approve <id>` decide só aquele pedido, com o mesmo prompt e o mesmo registro
reset; a=20260930-060601-outro-pedido; id=20260930-060602-so-este
propose "$a" <<<'echo a >> "$F_RUNS"'
propose "$id" <<<'echo b >> "$F_RUNS"; echo "rodou b"'
echo s > "$OUTE_APPROVE_TTY"
run_approve 20 "$id"
check "id: rc 0" test "$RC" = 0
# (o read só mostra o prompt num terminal; é o mesmo approve_one, conferido pelo tests/comandos-approve.test.sh)
check "id: mostra o pedido, como o approve sem id" bash -c 'grep -q "pedido $1" <<<"$2" && grep -q "^título: teste $1$" <<<"$2"' _ "$id" "$OUT"
check "id: não mostra o outro pedido" bash -c '! grep -q "pedido $1" <<<"$2"' _ "$a" "$OUT"
check "id: só o script dele rodou" test "$(cat "$F_RUNS")" = b
check "id: inbox/<id>.out com rc 0 e a saída" bash -c 'grep -q "^# rc: 0$" <<<"$1" && grep -q "rodou b" <<<"$1"' _ "$(inbox "$id")"
check "id: .out no host" test -f "$runs_dir/$id.out"
check "id: approve.log registra exec rc=0" grep -q "$id.*exec.rc=0" "$TMP/host/.oute/approve/approve.log"
check "id: evento canal emitido" grep -qx "canal $id" "$F_EMITS"
check "id: pedido em outbox/done" test -f "$TMP/ctr/outbox/done/$id.sh"
check "id: o outro segue pendente, sem .out" test -f "$TMP/ctr/outbox/$a.sh" -a ! -e "$TMP/ctr/inbox/$a.out"

# recusa e "N" pelo id: mesmos ramos do approve sem id
reset; id=20260930-060603-recusa-id
propose "$id" <<<'echo x >> "$F_RUNS"'
echo r > "$OUTE_APPROVE_TTY"; run_approve 20 "$id"
check "id recusa: rc 0, .out com rc 126, outbox/rejected, nada rodou" \
  bash -c '[[ $1 == 0 ]] && grep -q "^# rc: 126$" "$2/inbox/$3.out" && test -f "$2/outbox/rejected/$3.sh" -a ! -e "$4"' _ "$RC" "$TMP/ctr" "$id" "$F_RUNS"
check "id recusa: approve.log registra recusado" grep -q "$id.*recusado" "$TMP/host/.oute/approve/approve.log"
reset; id=20260930-060604-fica-id
propose "$id" <<<'echo x >> "$F_RUNS"'
: > "$OUTE_APPROVE_TTY"; run_approve 20 "$id"
check "id N: rc 0, fica pendente" bash -c '[[ $1 == 0 ]] && grep -q "fica pendente" <<<"$2" && test -f "$3" -a ! -e "$4"' _ "$RC" "$OUT" "$TMP/ctr/outbox/$id.sh" "$TMP/ctr/inbox/$id.out"

# --- 7. id fora do formato: rc 2, sem tocar o container (nem para entregar resultado guardado)
reset; id=20260930-070701-guardado
mkdir -p "$runs_dir"; printf '# id: %s\n# rc: 0\n\nok\n' "$id" > "$runs_dir/$id.done.result"
for bad in 'x' '2026-09-30-x' '20260930-070701-Maiusc' '20260930-070701-a/../b' '20260930-070701-' '' '20260930-070701-a b'; do
  run_approve 20 "$bad"
  check "id inválido [$bad]: rc 2" test "$RC" = 2
  check "id inválido [$bad]: diz o uso" has "uso: oute approve"
done
check "id inválido: nenhum docker chamado" test ! -e "$F_DOCKER"
check "id inválido: resultado guardado continua no host" test -f "$runs_dir/$id.done.result"
check "id inválido: nada no prompt" bash -c '! grep -q "executar?" <<<"$1"' _ "$OUT"

# --- 8. id válido que não está pendente: mensagem e rc 1
reset; id=20260930-080801-nao-existe
run_approve 20 "$id"
check "não pendente (não existe): rc 1" test "$RC" = 1
check "não pendente: mensagem" has "pedido $id não está pendente"
reset; id=20260930-080802-ja-decidido
propose "$id" <<<'echo x >> "$F_RUNS"'
mkdir -p "$TMP/ctr/outbox/done"; mv "$TMP/ctr/outbox/$id.sh" "$TMP/ctr/outbox/done/"
echo s > "$OUTE_APPROVE_TTY"; run_approve 20 "$id"
check "não pendente (já decidido): rc 1, nada rodou" bash -c '[[ $1 == 1 ]] && test ! -e "$2"' _ "$RC" "$F_RUNS"

# --- 9. argumento desconhecido: uso e rc 2, sem docker
reset
for args in '--foo' '-x' '--watch extra' '20260930-090901-a 20260930-090902-b'; do
  # shellcheck disable=SC2086
  run_approve 20 $args
  check "argumento desconhecido [$args]: rc 2 e uso" bash -c '[[ $1 == 2 ]] && grep -q "uso: oute approve" <<<"$2"' _ "$RC" "$OUT"
done
check "argumento desconhecido: nenhum docker chamado" test ! -e "$F_DOCKER"

# --- 10. resultado guardado (#210) sai antes também no modo <id>
reset; a=20260930-100001-guardado; id=20260930-100002-novo
mkdir -p "$runs_dir"; printf '# id: %s\n# rc: 0\n\nguardado ok\n' "$a" > "$runs_dir/$a.done.result"
propose "$id" <<<'echo novo >> "$F_RUNS"'
echo s > "$OUTE_APPROVE_TTY"; run_approve 20 "$id"
check "id + guardado: rc 0" test "$RC" = 0
check "id + guardado: o guardado foi entregue e saiu do host" bash -c 'grep -q "guardado ok" "$1" && test ! -e "$2"' _ "$TMP/ctr/inbox/$a.out" "$runs_dir/$a.done.result"
check "id + guardado: entregue antes do pedido novo" test "$(grep -E '^canal ' "$F_EMITS" | tr '\n' ' ')" = "canal $a canal $id "
# o id do próprio resultado guardado: entrega, e ele não está mais pendente (não roda de novo)
reset; id=20260930-100003-guardado-mesmo
propose "$id" <<<'echo x >> "$F_RUNS"'
mkdir -p "$runs_dir"; printf '# id: %s\n# rc: 0\n\nguardado\n' "$id" > "$runs_dir/$id.done.result"
echo s > "$OUTE_APPROVE_TTY"; run_approve 20 "$id"
check "id do guardado: entrega, rc 1 (não pendente), nada rodou" \
  bash -c '[[ $1 == 1 ]] && grep -q guardado "$2" && test -f "$3" -a ! -e "$4"' _ "$RC" "$TMP/ctr/inbox/$id.out" "$TMP/ctr/outbox/done/$id.sh" "$F_RUNS"

# --- 11. --watch e -w como antes: decidem o que chega e seguem esperando (sai só pelo prazo do teste)
for w in --watch -w; do
  reset; id=20260930-110001-watch
  propose "$id" <<<'echo w >> "$F_RUNS"'
  echo s > "$OUTE_APPROVE_TTY"; run_approve 4 "$w"
  check "$w: segue esperando (não sai sozinho)" test "$RC" = 124
  check "$w: decidiu o pedido uma vez" bash -c 'grep -q "^# rc: 0$" "$1" && test "$(cat "$2")" = w' _ "$TMP/ctr/inbox/$id.out" "$F_RUNS"
done

# --- 5. mount_shared (oute up) não deixa o daemon do rclone com o stdio de quem chamou
# rclone falso: deixa um "daemon" com os descritores herdados, como o fd 7 do rclone mount --daemon real.
# uname falso = Darwin: pula o /etc/fuse.conf do Linux (o que se testa é o stdio, igual nos dois)
cat > "$BIN/rclone" <<'SH'
#!/usr/bin/env bash
sleep 30 & echo $! >> "$F_DAEMONS"
exit 0
SH
printf '#!/bin/sh\necho Darwin\n' > "$BIN/uname"; chmod +x "$BIN/rclone" "$BIN/uname"
i=0
HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" OCI_S3_ACCESS_KEY=k OCI_S3_SECRET_KEY=s OCI_S3_ENDPOINT=e OCI_S3_REGION=r \
  "$OUTE" sync-shared 2>&1 | cat > "$TMP/mount.log" & pid=$!
while kill -0 "$pid" 2>/dev/null && (( i < 100 )); do sleep 0.1; i=$((i + 1)); done
OUT="$(cat "$TMP/mount.log")"
check "mount: pipe de quem chamou fecha com o daemon do rclone vivo" test "$i" -lt 100
check "mount: montou" has "storage: oci:oute-shared montado"
rm -f "$BIN/rclone" "$BIN/uname"

check_end
