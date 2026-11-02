#!/usr/bin/env bash
# Testes do `oute ssh <cmd> [args]` do host: o comando e os argumentos chegam inteiros ao container.
# O ssh junta os argumentos com espaço e o shell remoto os separa de novo; o `bash -lc` precisa receber a linha
# toda como um só argumento, senão roda só o nome do comando (`oute ssh oute-sonar pr 894` rodava `oute-sonar`).
# Bash puro, sem Docker nem rede: o `ssh` é um dublê que faz o mesmo que o OpenSSH com o comando remoto.
# Uso: tests/oute-ssh.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=10

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"
# dublê do OpenSSH: pula as opções e o destino, junta o resto com espaço e roda no shell "remoto"
cat > "$BIN/ssh" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in -p) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift
[[ $# -gt 0 ]] || exit 0
exec bash -c "$*"
SH
# comando do "container": um argumento por linha
cat > "$BIN/argv-dump" <<'SH'
#!/usr/bin/env bash
printf '[%s]\n' "$@"
SH
chmod +x "$BIN/ssh" "$BIN/argv-dump"
DUMP="$BIN/argv-dump"

run() { OUT="$(HOME="$TMP/home" PATH="$BIN:$PATH" OUTE_HOME="$TMP/oute-home" OUTE_HOST=teste OUTE_INSTANCE=teste "$ROOT/scripts/oute" ssh "$@" </dev/null 2>&1)"; RC=$?; return 0; }
lines() { local want="$1"; [[ "$OUT" == "$want" ]]; return $?; }

run "$DUMP" pr 894
check "comando com argumentos: os argumentos chegam"         lines $'[pr]\n[894]'
check "comando com argumentos: rc 0"                          test "$RC" -eq 0

run "$DUMP pr 894"
check "comando inteiro entre aspas: os argumentos chegam"     lines $'[pr]\n[894]'

run "$DUMP x | tr x y"
check "linha com pipe roda no container"                      lines '[y]'

check_end
