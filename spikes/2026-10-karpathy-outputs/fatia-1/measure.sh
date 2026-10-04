#!/usr/bin/env bash
# measure.sh <repo> <variants-dir> — pergunta 7 do spike #458: tokens de cada arquivo em cada variante e modelo.
# Saída: TSV "arquivo variante medida valor". Medidas: bytes, palavras (wc -w), o200k (tiktoken, offline) e, por
# modelo Claude da tabela do seletor, tokens = contagem do arquivo − linha de base (count-claude.sh).
set -euo pipefail
repo="$1"; var="$2"; here="$(cd "$(dirname "$0")" && pwd)"
FILES=(docker/swarm.md docker/swarm-worker.md docker/agent-notes.md AGENTS.md
  addons/skills/oute-aidlc-qa-pr-audit/SKILL.md addons/skills/oute-aidlc-ops-observe/SKILL.md
  addons/skills/oute-aidlc-ship-verify/SKILL.md)
[[ -z "${ONLY:-}" ]] || read -r -a FILES <<<"$ONLY"   # ONLY="arq1 arq2": só esses arquivos
MODELS=(claude-haiku-4-5-20251001 claude-sonnet-5-5 claude-opus-5-5)
declare -A BASE
for m in "${MODELS[@]}"; do BASE[$m]="$("$here/count-claude.sh" "$m" "$here/t/one.txt")"; printf 'baseline\t-\t%s\t%s\n' "$m" "${BASE[$m]}"; done
for f in "${FILES[@]}"; do
  for v in a-pt b-en-concise c-en-ste80; do
    if [[ $v = a-pt ]]; then p="$repo/$f"; else p="$var/$v/$f"; fi
    printf '%s\t%s\tbytes\t%s\n' "$f" "$v" "$(wc -c < "$p")"
    printf '%s\t%s\twords\t%s\n' "$f" "$v" "$(wc -w < "$p")"
    printf '%s\t%s\to200k\t%s\n' "$f" "$v" "$("$here/venv/bin/python" -c 'import sys,tiktoken; print(len(tiktoken.get_encoding("o200k_base").encode(open(sys.argv[1]).read())))' "$p")"
    for m in "${MODELS[@]}"; do
      n="$("$here/count-claude.sh" "$m" "$p")"
      printf '%s\t%s\t%s\t%s\n' "$f" "$v" "$m" "$(( n - BASE[$m] ))"
    done
  done
done
