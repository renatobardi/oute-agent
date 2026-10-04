#!/usr/bin/env bash
# p2check.sh <original.sh> <novo.sh> — o script novo muda só comentário e texto de `echo`? Compara os dois sem as
# linhas de comentário e sem linha em branco e com cada `echo "…"` reduzido a `echo ""` (o texto dentro do echo pode mudar; o resto não). Saída: bash -n,
# diff (vazio = igual) e contagem de linhas de comando.
set -uo pipefail
norm() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' | sed -E 's/echo "[^"]*"/echo ""/g; s/echo '"'"'[^'"'"']*'"'"'/echo ""/g'; }
bash -n "$2" && echo "bash -n: ok" || echo "bash -n: FALHOU"
d="$(diff <(norm "$1") <(norm "$2"))"
if [[ -z "$d" ]]; then echo "diff dos comandos: vazio (iguais)"; else echo "diff dos comandos:"; echo "$d"; fi
echo "linhas de comando (sem comentário): original $(grep -vc '^[[:space:]]*#' "$1"), novo $(grep -vc '^[[:space:]]*#' "$2")"
