#!/usr/bin/env bash
# Hook de pkill/killall do Claude Code (#538): docker/oute-guard-kill lê o JSON do PreToolUse e recusa (saída 2, mensagem
# em stderr) o comando que mata processo por nome; o resto passa (saída 0). Script que usa pkill por dentro não é
# visto pelo hook (só o comando digitado chega a ele). Sem rede, sem Docker.
# Prova vermelha (corpo do PR): GUARD aponta para um script que sempre sai 0.
# Uso: tests/guard-kill.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null || die "precisa de jq"
GUARD="${GUARD:-$ROOT/docker/oute-guard-kill}"

# hook <comando>: o JSON do hook com o comando; stderr em $OUT, código em $RC
hook() { OUT="$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | "$GUARD" 2>&1 >/dev/null)"; RC=$?; }
blocked() { hook "$1"; [[ "$RC" -eq 2 ]]; }
passes() { hook "$1"; [[ "$RC" -eq 0 && -z "$OUT" ]]; }

for c in 'pkill -f "gh pr checks"' 'pkill gh' 'killall node' 'sudo pkill -9 -f x' 'sudo -n killall x' 'cd /tmp && pkill -f x' \
         'sleep 1; killall sleep' 'echo a | pkill -f a' 'echo $(pkill -f x)' '  pkill -f x' 'command pkill x' 'true || pkill x'; do
  check "recusa: $c" blocked "$c"
done
hook 'pkill -f x'
check "mensagem manda usar o PID ou o id da tarefa"  bash -c 'echo "$1" | grep -q "kill <PID>" && echo "$1" | grep -q "id da tarefa"' _ "$OUT"
for c in 'kill 1234' 'kill -TERM "$pid"' 'pgrep -f x' 'echo pkill' 'grep -n pkill docker/oute-task' 'bash tests/oute-task.test.sh' \
         'ls /tmp/pkill-notes' 'git commit -m "fix: sem pkill -f"' 'skillall x'; do
  check "passa: $c" passes "$c"
done
# entradas fora do formato: o hook nunca atrapalha o agente
OUT="$(printf '' | "$GUARD" 2>&1)"; RC=$?;                 check "stdin vazio: passa"           test "$RC" -eq 0
OUT="$(printf 'não é json' | "$GUARD" 2>&1)"; RC=$?;       check "stdin que não é JSON: passa"  test "$RC" -eq 0
OUT="$(echo '{"tool_input":{}}' | "$GUARD" 2>&1)"; RC=$?;  check "sem comando no JSON: passa"   test "$RC" -eq 0
# script chamado pelo agente que usa pkill por dentro segue funcionando: o hook só vê o comando digitado
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '#!/usr/bin/env bash\npkill() { echo "pkill interno $*"; }\npkill -f nada\n' > "$T/limpa.sh"
check "script com pkill por dentro: o comando digitado passa" passes "bash $T/limpa.sh"
OUT="$(bash "$T/limpa.sh")"; check "script com pkill por dentro: roda igual" has_line "pkill interno -f nada"

check_end
