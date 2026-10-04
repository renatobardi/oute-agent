#!/usr/bin/env bash
# fidelity.sh <repo> <variants-dir> — conferência por máquina de que as variantes não perderam contrato:
# por arquivo e variante, diferenças no multiconjunto de referências #N, no conjunto de trechos entre crases,
# e a contagem de títulos e de linhas de tabela. 0 = igual à fonte em pt.
set -euo pipefail
repo="$1"; var="$2"
for f in docker/swarm.md docker/swarm-worker.md docker/agent-notes.md AGENTS.md addons/skills/oute-aidlc-qa-pr-audit/SKILL.md addons/skills/oute-aidlc-ops-observe/SKILL.md addons/skills/oute-aidlc-ship-verify/SKILL.md; do
  for v in b-en-concise c-en-ste80; do
    s="$repo/$f"; o="$var/$v/$f"
    refs="$(diff <(grep -o '#[0-9]\+' "$s" | sort) <(grep -o '#[0-9]\+' "$o" | sort) | grep -c '^[<>]' || true)"
    ticks="$(diff <(grep -o '`[^`]*`' "$s" | sort -u) <(grep -o '`[^`]*`' "$o" | sort -u) | grep -c '^[<>]' || true)"
    printf '%s\t%s\trefs_diff=%s\tcrases_diff=%s\ttitulos=%s/%s\ttabela=%s/%s\n' "$f" "$v" "$refs" "$ticks" \
      "$(grep -c '^#' "$s" || true)" "$(grep -c '^#' "$o" || true)" "$(grep -c '^ *|' "$s" || true)" "$(grep -c '^ *|' "$o" || true)"
  done
done
