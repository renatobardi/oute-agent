#!/usr/bin/env bash
# run-variant.sh <nome> <agent-notes.md> <dir-de-trabalho> [rodadas] — P4 do spike #458.
# Roda o `oute-regression` (4 tarefas em Haiku) com <agent-notes.md> como as notas gerenciadas do agente, num
# CLAUDE_CONFIG_DIR descartável: nada do ~/.claude real é tocado (a credencial entra por link simbólico, só leitura de
# fato) e as notas reais ficam como estão. Sem hooks do ai-memory, sem telemetria, sem evento no bucket (oute-emit dublê).
# P4_TASKS: tarefas (padrão: as 4). Decisão do Bardi (gate da fatia 1): OUTE_REGRESSION_MAX_PCT mais alto só para este teste.
set -euo pipefail
name="$1"; notes="$(realpath "$2")"; work="$3"; rounds="${4:-3}"
repo="$(git rev-parse --show-toplevel)"
cfg="$work/cfg-$name"; shim="$work/shim"
rm -rf "${cfg:?}"; mkdir -p "$cfg" "$shim"
ln -sf "$HOME/.claude/.credentials.json" "$cfg/.credentials.json"
echo '{"autoMemoryEnabled":false,"permissions":{"defaultMode":"bypassPermissions"}}' > "$cfg/settings.json"
{ echo '<!-- oute:managed:ops-handoff -->'; cat "$notes"; echo '<!-- /oute:managed:ops-handoff -->'; } > "$cfg/CLAUDE.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$shim/oute-emit"; chmod +x "$shim/oute-emit"
t0=$(date +%s)
env -u CLAUDE_CODE_ENABLE_TELEMETRY -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_RESOURCE_ATTRIBUTES \
  PATH="$shim:$PATH" CLAUDE_CONFIG_DIR="$cfg" OUTE_REGRESSION_MAX_PCT="${OUTE_REGRESSION_MAX_PCT:-95}" \
  OUTE_REGRESSION_DIR="$repo/docker/regression" \
  oute-regression --rounds "$rounds" $(for t in ${P4_TASKS:-root select worktree emit}; do printf -- "--task %s " "$t"; done) --json \
  > "$work/result-$name.json" 2> "$work/result-$name.txt" || echo "rc=$?" >> "$work/result-$name.txt"
echo "segundos=$(( $(date +%s) - t0 ))" >> "$work/result-$name.txt"
rm -rf "${cfg:?}"
