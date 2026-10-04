#!/usr/bin/env bash
# Testes do `oute tray` (#260). Bash puro, sem macOS: `uname`, `swift`, `launchctl` e `codesign` são falsos, então
# aqui se confere o que o install/uninstall deixa no HOME (o .app, o LaunchAgent, a tabela tray-hosts) e o erro fora
# do macOS. Compilar de verdade e abrir no login ficam na validação do Mac (`swift build && swift test` no PR).
# Uso: tests/oute-tray.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
# credenciais reais nunca chegam ao scripts/oute daqui
for v in $(compgen -e | grep -E '^(OCI_|GH_TOKEN$|GITHUB_TOKEN$|AGENT_STUDIO_|BW_)' || true); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTE="$ROOT/scripts/oute"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=5

# roda `oute tray [args…]` num HOME só do teste
run_tray() {
  mkdir -p "$TMP/home"
  OUT="$(HOME="$TMP/home" OUTE_HOME="$TMP/home/.oute" "$OUTE" tray "$@" 2>&1)"; RC=$?
  return 0
}
# arquivo existe e tem o texto (sem regex)
file_has() {
  local file="$1" text="$2"
  grep -qF -- "$text" "$file" 2>/dev/null
  return $?
}

# --- fora do macOS (uname falso: o teste vale também rodando no Mac)
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/uname" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -s || $# == 0 ]] && { echo "${FAKE_UNAME:-Linux}"; exit 0; }
exec /usr/bin/uname "$@"
SH
# swift falso: `build` deixa o binário em $F_SWIFT_BIN (ou falha com FAKE_SWIFT_RC); `--show-bin-path` diz onde
cat > "$BIN/swift" <<'SH'
#!/usr/bin/env bash
echo "swift $*" >> "$F_CALLS"
case " $* " in
  *" --show-bin-path "*) echo "$F_SWIFT_BIN"; exit 0 ;;
esac
[[ "${FAKE_SWIFT_RC:-0}" == 0 ]] || { echo "error: falha de compilação (falsa)" >&2; exit "$FAKE_SWIFT_RC"; }
mkdir -p "$F_SWIFT_BIN"; printf '#!/bin/sh\nexit 0\n' > "$F_SWIFT_BIN/OuteTray"; chmod +x "$F_SWIFT_BIN/OuteTray"
SH
for tool in launchctl codesign; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$F_CALLS"\nexit 0\n' "$tool" > "$BIN/$tool"
done
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" F_CALLS="$TMP/calls" F_SWIFT_BIN="$TMP/swift-bin" OUTE_HOST=teste OUTE_INSTANCE=teste
unset OUTE_AGENT_STUDIO_URL
H="$TMP/home"; APP="$H/Applications/OuteTray.app"; PLIST="$H/Library/LaunchAgents/pro.oute.tray.plist"; HOSTS="$H/.oute/tray-hosts"

run_tray install
check "install fora do macOS: rc != 0" [ "$RC" -ne 0 ]
check "install fora do macOS: diz que é só no macOS" has 'oute: o tray é só no macOS'
check "install fora do macOS: não cai no 'comando desconhecido'" hasnt 'comando desconhecido'
check "install fora do macOS: nada criado no HOME" bash -c '[ ! -e "$1" ] && [ ! -e "$2" ] && [ ! -e "$3" ] && [ ! -e "$4" ]' _ "$HOSTS" "$APP" "$PLIST" "$F_CALLS"

run_tray uninstall
check "uninstall fora do macOS: rc != 0" [ "$RC" -ne 0 ]
check "uninstall fora do macOS: diz que é só no macOS" has 'oute: o tray é só no macOS'

for args in "" "instalar" "install sobra"; do
  # shellcheck disable=SC2086
  run_tray $args
  check "oute tray $args: uso e rc 2" bash -c '[ "$1" -eq 2 ] && grep -q "^uso: oute tray install | oute tray uninstall" <<<"$2"' _ "$RC" "$OUT"
done

# --- no macOS (uname, swift, launchctl e codesign falsos): o que o install deixa no HOME
export FAKE_UNAME=Darwin
TOKEN="$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')"
mkdir -p "$H/.oute"; printf 'export AGENT_STUDIO_READ_TOKEN=%s\n' "$TOKEN" > "$H/.oute/agent.env"

run_tray install
check "install: rc 0" [ "$RC" -eq 0 ]
check "install: o .app tem o binário compilado, executável" [ -x "$APP/Contents/MacOS/OuteTray" ]
check "install: sem ícone no Dock (LSUIElement)" file_has "$APP/Contents/Info.plist" '<key>LSUIElement</key><true/>'
check "install: identificador do pacote" file_has "$APP/Contents/Info.plist" '<key>CFBundleIdentifier</key><string>pro.oute.tray</string>'
check "install: LaunchAgent aponta para o binário do .app" file_has "$PLIST" "<string>$APP/Contents/MacOS/OuteTray</string>"
check "install: LaunchAgent abre no login" file_has "$PLIST" '<key>RunAtLoad</key><true/>'
check "install: LaunchAgent carregado na sessão do usuário" file_has "$F_CALLS" "launchctl bootstrap gui/$(id -u) $PLIST"
check "install: sem endereço no .env, o LaunchAgent não leva ambiente" bash -c '! grep -q EnvironmentVariables "$1"' _ "$PLIST"
check "install: tray-hosts criado com este host como local" file_has "$HOSTS" 'teste=local'
check "install: tray-hosts criado com o alias do oute-server" file_has "$HOSTS" 'oute-server=oute-server'
check "install: o token não é copiado para lugar nenhum" bash -c '! grep -rlF -- "$1" "$2" | grep -v "/\.oute/agent\.env$" | grep -q .' _ "$TOKEN" "$H"
check "install: o token não aparece na saída" hasnt_str "$TOKEN"

# de novo, com a tabela editada e o endereço trocado
printf 'teste=local\noute-server=bardi@servidor\n' > "$HOSTS"; : > "$F_CALLS"
OUTE_AGENT_STUDIO_URL='https://studio.exemplo.ts.net/?a=1&b=<2>' run_tray install
check "install de novo: rc 0" [ "$RC" -eq 0 ]
check "install de novo: tray-hosts editado não é sobrescrito" bash -c '[ "$(cat "$1")" = "$(printf "teste=local\noute-server=bardi@servidor")" ]' _ "$HOSTS"
check "install de novo: para o tray antes de carregar" bash -c '[ "$(grep -n "^launchctl bootout gui/" "$1" | head -1 | cut -d: -f1)" -lt "$(grep -n "^launchctl bootstrap " "$1" | head -1 | cut -d: -f1)" ]' _ "$F_CALLS"
check "install de novo: um LaunchAgent só" bash -c '[ "$(ls "$1" | wc -l)" -eq 1 ]' _ "$H/Library/LaunchAgents"
check "install de novo: endereço do agent-studio no ambiente do app, escapado" file_has "$PLIST" '<key>OUTE_AGENT_STUDIO_URL</key><string>https://studio.exemplo.ts.net/?a=1&amp;b=&lt;2&gt;</string>'

# compilação que falha: nada é trocado nem carregado
: > "$F_CALLS"; cp "$PLIST" "$TMP/plist.antes"
FAKE_SWIFT_RC=1 run_tray install
check "swift build falha: rc != 0 e motivo" bash -c '[ "$1" -ne 0 ] && grep -q "oute: o tray não compilou" <<<"$2"' _ "$RC" "$OUT"
check "swift build falha: o .app e o LaunchAgent de antes ficam" bash -c '[ -x "$1/Contents/MacOS/OuteTray" ] && cmp -s "$2" "$3"' _ "$APP" "$PLIST" "$TMP/plist.antes"
check "swift build falha: launchctl não é chamado" bash -c '! grep -q "^launchctl" "$1"' _ "$F_CALLS"

run_tray uninstall
check "uninstall: rc 0" [ "$RC" -eq 0 ]
check "uninstall: tira o .app e o LaunchAgent" bash -c '[ ! -e "$1" ] && [ ! -e "$2" ]' _ "$APP" "$PLIST"
check "uninstall: descarrega o LaunchAgent" file_has "$F_CALLS" "launchctl bootout gui/$(id -u)/pro.oute.tray"
check "uninstall: tray-hosts editado fica" [ -s "$HOSTS" ]
check "uninstall: o agent.env fica" file_has "$H/.oute/agent.env" "$TOKEN"
run_tray uninstall
check "uninstall de novo (nada instalado): rc 0" [ "$RC" -eq 0 ]

rm -f "$HOSTS"; run_tray install; run_tray uninstall
check "uninstall: tray-hosts que ninguém editou sai junto" [ ! -e "$HOSTS" ]
unset FAKE_UNAME

OUT="$("$OUTE" --help 2>&1)"
check "o oute --help lista o tray" has '^  tray install|uninstall '

OUT="$(bash -n "$OUTE" 2>&1)"; RC=$?
check "bash -n scripts/oute" [ "$RC" -eq 0 ]

check_end
