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
AUDIT="$ROOT/addons/skills/oute-aidlc-qa-pr-audit/SKILL.md"
check "qa-pr-audit: guarda o caminho do AUD num arquivo e lê com cat num comando próprio (#582)" bash -c 'grep -qF "echo \"\$AUD\" > " "$1" && grep -qF "cat \"\$HOME/.oute-aud-<N>\"" "$1"' _ "$AUDIT"
check "qa-pr-audit: o arquivo do caminho tem o número do PR e o nome fixo saiu (#684)" bash -c 'grep -qF "echo \"\$AUD\" > \"\$HOME/.oute-aud-<N>\"" "$1" && grep -qF "(o arquivo do PR auditado)" "$1" && ! grep -qF "oute-aud-path" "$1"' _ "$AUDIT"
check "qa-pr-audit: remove com o caminho literal, worktree primeiro e rm -rf depois" bash -c 'grep -qF "git worktree remove --force /tmp/tmp.AbC123/head" "$1" && grep -qF "rm -rf /tmp/tmp.AbC123" "$1"' _ "$AUDIT"
check "qa-pr-audit: proíbe rm -rf com \$(…) e glob em /tmp" grep -qF 'Nunca `rm -rf` com `$(…)` nem glob em `/tmp`' "$AUDIT"
check "qa-pr-audit: o passo 13 remete à mesma limpeza" grep -qF 'depois `rm -rf <caminho>`, como no passo 6' "$AUDIT"
check "qa-pr-audit: oute-refcheck e gh pr comment encadeados com &&" grep -qF 'oute-refcheck <arquivo do relatório> && gh pr comment <N> --body-file <arquivo do relatório>' "$AUDIT"
check "qa-pr-audit: não publica com quebrada ou nao-abre" grep -qF 'não publica se a saída do `oute-refcheck` tiver `quebrada` ou `nao-abre`' "$AUDIT"
check "qa-pr-audit: referência de arquivo leva o caminho completo desde a raiz" grep -qF 'caminho completo desde a raiz do repo' "$AUDIT"
# skill dividida (#754): o corpo fica com o caminho de toda auditoria; o passo 14 e o modelo do relatório vão para arquivos da pasta
AUDIT_DIR="$ROOT/addons/skills/oute-aidlc-qa-pr-audit"
check "qa-pr-audit: o corpo da skill fica abaixo de 50000 bytes (#754)" bash -c '[ "$(wc -c < "$1")" -lt 50000 ]' _ "$AUDIT"
check "qa-pr-audit: passo 14 e modelo do relatório são arquivos da pasta, com o marcador (#754)" bash -c 'grep -qF "gh pr merge <N> --squash --match-head-commit" "$1/merge.md" && grep -qF "<!-- oute-aidlc-qa-pr-audit:merge -->" "$1/merge.md" && grep -qF "<!-- oute-aidlc-qa-pr-audit -->" "$1/relatorio.md"' _ "$AUDIT_DIR"
check "qa-pr-audit: o corpo não repete o passo 14 nem o modelo (#754)" bash -c '! grep -qF -e "--match-head-commit" -e "oute-aidlc-qa-pr-audit:merge -->" -e "### Prós e contras" "$1"' _ "$AUDIT"
check "qa-pr-audit: o corpo manda ler merge.md e relatorio.md (#754)" bash -c 'grep -qF "\`merge.md\`" "$1" && grep -qF "\`relatorio.md\`" "$1"' _ "$AUDIT"
check "qa-pr-audit: a skill mantém o passo 13 com as três condições do pedido de merge (#754)" bash -c 'grep -qF "Na dúvida sobre qualquer uma das três" "$1"' _ "$AUDIT"
check_end
