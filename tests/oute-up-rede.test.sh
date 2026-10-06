#!/usr/bin/env bash
# `oute up` repete o `compose up` quando a rede falha com "Address already in use" (#518). Bash puro: `docker` falso
# que falha F_FAILS vezes com a mensagem do erro (ou F_OTHER=1 com outro erro) e depois sobe; `sleep` falso não espera.
# Uso: tests/oute-up-rede.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap '[[ -z "${SSHD_PID:-}" ]] || { kill "$SSHD_PID"; wait "$SSHD_PID"; } 2>/dev/null; rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home/.ssh" "$TMP/oute" "$TMP/repo/scripts" "$TMP/repo/docker"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$F_LOG"
case "$1" in
  compose) case " $* " in
    *" up "*) n="$(grep -c ' up -d' "$F_LOG")"
              if [[ "${F_OTHER:-0}" == 1 ]]; then echo "Error: pull access denied" >&2; exit 1; fi
              if [[ "$n" -le "${F_FAILS:-0}" ]]; then
                echo "failed to create network oute-agent_oute: Error response from daemon: failed to allocate gateway (172.19.0.1): Address already in use" >&2; exit 1
              fi ;;
    *" ps "*) echo "NAME  STATUS" ;;
  esac ;;
  image) exit 0 ;;
  volume) exit 1 ;;
  ps|rm) exit 0 ;;
  *) exit 9 ;;
esac
SH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$F_SLEEP"\n' > "$BIN/sleep"
chmod +x "$BIN"/*
export F_LOG="$TMP/docker.log" F_SLEEP="$TMP/sleep.log"

cp "$ROOT/scripts/oute" "$TMP/repo/scripts/oute"; cp "$ROOT/VERSION" "$TMP/repo/VERSION"; : > "$TMP/repo/docker/compose.yaml"
printf 'export GH_TOKEN=x\nexport AI_MEMORY_AUTH_TOKEN=y\n' > "$TMP/oute/agent.env"
echo "ssh-ed25519 AAAA teste" > "$TMP/home/.ssh/none.pub"

# sshd de mentira: manda o banner a quem conecta (o `up` espera o SSH-2.0 antes de voltar)
command -v python3 >/dev/null || die "python3 ausente (sshd de mentira)"
python3 - "$TMP/port" <<'PY' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept(); c.sendall(b"SSH-2.0-teste\r\n"); c.close()
PY
SSHD_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
[[ -s "$TMP/port" ]] || die "sshd de mentira não subiu"

# oute env VAR=… : roda `oute up` do checkout de mentira com os falsos; saída em $OUT, código em $RC.
oute() {
  : > "$F_LOG"; : > "$F_SLEEP"
  OUT="$(env -u OCI_S3_ACCESS_KEY -u OCI_S3_SECRET_KEY -u OCI_S3_ENDPOINT -u OCI_S3_REGION -u GH_TOKEN \
    -u AGENT_STUDIO_INGEST_TOKEN -u AGENT_STUDIO_READ_TOKEN -u AGENT_STUDIO_SURREAL_PASS -u AGENT_STUDIO_MARK_TOKEN \
    -u OUTE_AGENT_STUDIO -u COMPOSE_PROFILES -u BW_SESSION -u OUTE_UP_RETRIES \
    PATH="$BIN:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/oute" OUTE_HOST=teste OUTE_UP_RETRY_WAIT=7 \
    OUTE_SSH_HOST=127.0.0.1 OUTE_SSH_PORT="$(cat "$TMP/port")" OUTE_SSH_AUTHORIZED_KEYS="$TMP/home/.ssh/none.pub" \
    "$@" "$TMP/repo/scripts/oute" up 2>&1)"; RC=$?
}
ups() { grep -c ' up -d' "$F_LOG" || true; }

check "sintaxe (bash -n)" bash -n "$ROOT/scripts/oute"

oute env F_FAILS=0
check "sem erro: uma subida"                    test "$(ups)" = 1
check "sem erro: não espera"                    test ! -s "$F_SLEEP"

oute env F_FAILS=1
check "erro uma vez: duas subidas"              test "$(ups)" = 2
check "erro uma vez: rc 0"                      [ "$RC" -eq 0 ]
check "erro uma vez: espera 7 s"                test "$(cat "$F_SLEEP")" = 7
check "erro uma vez: avisa a repetição"         has 'tentativa 1 de 3'

oute env F_FAILS=99
check "erro sempre: três subidas"               test "$(ups)" = 3
check "erro sempre: rc != 0"                    [ "$RC" -ne 0 ]
check "erro sempre: duas esperas"               test "$(grep -c . "$F_SLEEP")" = 2

oute env F_OTHER=1
check "outro erro: uma subida só"               test "$(ups)" = 1
check "outro erro: rc != 0"                     [ "$RC" -ne 0 ]
check "outro erro: sem espera"                  test ! -s "$F_SLEEP"

oute env F_FAILS=1 OUTE_UP_RETRIES=1
check "OUTE_UP_RETRIES=1: uma subida e rc != 0" bash -c '[ "$1" = 1 ] && [ "$2" -ne 0 ]' _ "$(ups)" "$RC"

check_end
