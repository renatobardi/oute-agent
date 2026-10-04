#!/usr/bin/env bash
# count-claude.sh <modelo> <arquivo> — igual ao da fatia 1: tokens de entrada que o modelo cobra por <arquivo> como
# mensagem de usuário, via `claude -p` da assinatura (sem API paga, sem tools, sem settings). Imprime
# input + cache_creation + cache_read; o custo do arquivo é isso menos a linha de base (arquivo com "x").
# Precisa de um diretório descartável COUNT_T (padrão: t/ ao lado) com one.txt = "x".
set -euo pipefail
model="$1"; file="$(realpath "$2")"
cd "${COUNT_T:-$(dirname "$0")/t}"
timeout 300 claude -p --model "$model" --system-prompt "Reply with the single word OK." --tools "" \
  --setting-sources "" --strict-mcp-config --disable-slash-commands --no-session-persistence --max-turns 1 \
  --output-format json < "$file" \
  | jq -r '.usage | (.input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))'
