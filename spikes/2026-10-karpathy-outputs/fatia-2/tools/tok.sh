#!/usr/bin/env bash
# tok.sh <arquivo>… — tokens de cada arquivo (menos a linha de base) em Haiku 4.5, Sonnet 5.5 e Opus 5.5, e o200k_base.
# Saída TSV: arquivo  o200k  haiku  sonnet  opus.  Precisa de COUNT_T (com one.txt) e COUNT_PY (python com tiktoken==0.12.0).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
MODELS=(claude-haiku-4-5-20251001 claude-sonnet-5-5 claude-opus-5-5)
declare -A BASE
for m in "${MODELS[@]}"; do BASE[$m]="$("$here/count-claude.sh" "$m" "$COUNT_T/one.txt")"; done
for f in "$@"; do
  o="$("$COUNT_PY" -c 'import sys,tiktoken; print(len(tiktoken.get_encoding("o200k_base").encode(open(sys.argv[1]).read())))' "$f")"
  row="$f\t$o"
  for m in "${MODELS[@]}"; do row+="\t$(( $("$here/count-claude.sh" "$m" "$f") - BASE[$m] ))"; done
  printf "$row\n"
done
