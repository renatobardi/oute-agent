#!/usr/bin/env bash
# Testes do `oute tray` (#260) no Linux: o tray é do Mac, então aqui só se confere o que roda fora dele. O que é
# do macOS (compilar, montar o .app, LaunchAgent) fica na validação do Mac (`swift build && swift test` no PR).
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

[[ "$(uname -s)" != Darwin ]] || die "este teste é do caminho fora do macOS; no Mac vale o checklist da #260"

# roda `oute tray [args…]` num HOME só do teste
run_tray() {
  mkdir -p "$TMP/home"
  OUT="$(HOME="$TMP/home" OUTE_HOME="$TMP/home/.oute" "$OUTE" tray "$@" 2>&1)"; RC=$?
  return 0
}

run_tray install
check "install fora do macOS: rc != 0" [ "$RC" -ne 0 ]
check "install fora do macOS: diz que é só no macOS" has 'oute: o tray é só no macOS'
check "install fora do macOS: não cai no 'comando desconhecido'" hasnt 'comando desconhecido'
check "install fora do macOS: nada criado em ~/.oute" bash -c '[ ! -e "$1/home/.oute/tray-hosts" ] && [ ! -e "$1/home/Library" ]' _ "$TMP"

check_end
