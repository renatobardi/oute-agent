#!/usr/bin/env bash
# count-claude.sh <model> <file> — tokens de entrada que o modelo cobra por <file> como mensagem de usuário.
# Sem API paga: usa `claude -p` (assinatura), sem tools, sem settings (sem hooks, sem MCP), 1 turno, resposta "OK".
# Imprime: input_tokens + cache_creation_input_tokens + cache_read_input_tokens. O custo do arquivo é esse número
# menos a linha de base (o mesmo comando com um arquivo que só tem "x").
set -euo pipefail
model="$1"; file="$2"
cd "$(dirname "$0")/t"   # diretório descartável, com .ai-memory.toml de escopo spike-458
timeout 300 claude -p --model "$model" --system-prompt "Reply with the single word OK." --tools "" \
  --setting-sources "" --strict-mcp-config --disable-slash-commands --no-session-persistence --max-turns 1 \
  --output-format json < "$file" \
  | jq -r '.usage | (.input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))'
