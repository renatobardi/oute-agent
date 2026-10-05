#!/usr/bin/env bash
# Testes das instruções do resumo do ciclo (#509): as skills da sessão avulsa (oute-aidlc-learn-insights e
# oute-aidlc-iter-roadmap) citam os comandos do `oute-swarm step … ciclo` que existem de verdade, o link da página do
# ciclo tem o formato que o agent-studio aceita, e o texto não manda nada ao host. Bash puro.
# Uso: tests/ciclo-skills.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/check.sh"
SWARM="$ROOT/docker/oute-swarm"
LEARN="$ROOT/addons/skills/oute-aidlc-learn-insights/SKILL.md"
ITER="$ROOT/addons/skills/oute-aidlc-iter-roadmap/SKILL.md"

for f in "$LEARN" "$ITER"; do
  n="$(basename "$(dirname "$f")")"
  check "$n: cita step dir, review e publish do tipo ciclo, com --cycle" bash -c 'f="$1"; grep -qF "oute-swarm step dir ciclo --cycle" "$f" && grep -qF "oute-swarm step review ciclo --cycle" "$f" && grep -qF "oute-swarm step publish ciclo --cycle" "$f"' _ "$f"
  check "$n: o link da página do ciclo é /ciclo?id= com o # codificado" grep -qF 'https://agent-studio.oute.pro/ciclo?id=' "$f"
  check "$n: o texto da etapa é só o que veio das fontes, sem segredo nem saída de host" bash -c 'grep -qF "sem segredo" "$1" && grep -qF "saída de host" "$1"' _ "$f"
done
check "learn-insights: a revisão é a próxima depois da maior que existe na pasta" grep -qF 'a próxima depois da maior revisão' "$LEARN"
check "iter-roadmap: publica a r1 do ciclo novo; a learn escreve a seguinte" grep -qF 'ciclo.r1.md' "$ITER"
check "os comandos que as skills citam existem no oute-swarm" bash -c '"$1" --help | grep -qF "oute-swarm step dir ciclo --cycle" && grep -qF "ciclo)" "$1"' _ "$SWARM"
check "o guia (comandos.md) cita o step dir ciclo" grep -qF 'oute-swarm step dir ciclo --cycle' "$ROOT/docker/comandos.md"
check "o dispatcher passa o ciclo da triagem no step publish (swarm.md)" grep -qF -e '--cycle <dono>/<repo>#<n>' "$ROOT/docker/swarm.md"
check_end
