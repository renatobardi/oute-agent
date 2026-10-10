#!/usr/bin/env bash
# Teste do teto de tamanho dos prompts fixos (#753): cada prompt que entra em toda sessão ou em toda etapa do dispatcher
# tem um teto em bytes em docs/prompts-teto.md, e o PR que passa dele falha aqui.
# Bash puro, sem rede. A conferência é a função `confere`, também exercitada com uma tabela e uma árvore de exemplo.
# Uso: tests/prompts-teto.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"

# prompts_fixos <raiz>: os arquivos de prompt fixo que precisam de teto, um caminho relativo por linha
prompts_fixos() {
  local raiz="$1" f
  for f in AGENTS.md docker/agent-notes.md docker/swarm-worker.md docker/swarm.md; do
    [[ ! -e "$raiz/$f" ]] || printf '%s\n' "$f"
  done
  for f in "$raiz"/docker/swarm/*.md; do
    [[ ! -e "$f" ]] || printf 'docker/swarm/%s\n' "$(basename "$f")"
  done
  return 0
}

# teto_de <tabela> <caminho>: o teto da linha `| \`caminho\` | <bytes> | …`; vazio se o arquivo não está na tabela
teto_de() {
  local tabela="$1" arq="$2"
  awk -F'|' -v a="$arq" '{ f=$2; gsub(/[ `]/, "", f); t=$3; gsub(/ /, "", t); if (f == a && t ~ /^[0-9]+$/) { print t; exit } }' "$tabela"
  return 0
}

# confere <raiz> <tabela>: imprime uma linha por problema (sem teto, acima do teto, na tabela e sem arquivo); sai 0 sem problema
confere() {
  local raiz="$1" tabela="$2" f teto tam n=0 listados
  while IFS= read -r f; do
    teto="$(teto_de "$tabela" "$f")"
    if [[ -z "$teto" ]]; then echo "sem teto na tabela: $f"; n=$((n + 1)); continue; fi
    tam="$(wc -c < "$raiz/$f" | tr -d ' ')"
    if (( tam > teto )); then echo "acima do teto: $f tem $tam bytes, teto $teto"; n=$((n + 1)); fi
  done < <(prompts_fixos "$raiz")
  listados="$(awk -F'|' '{ f=$2; gsub(/[ `]/, "", f); t=$3; gsub(/ /, "", t); if (f != "" && t ~ /^[0-9]+$/) print f }' "$tabela")"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -e "$raiz/$f" ]]; then echo "na tabela e sem arquivo: $f"; n=$((n + 1)); fi
  done <<<"$listados"
  [[ "$n" -eq 0 ]]
  return $?
}

TABELA="$ROOT/docs/prompts-teto.md"
OUT="$(confere "$ROOT" "$TABELA" 2>&1)"; RC=$?
check "os prompts fixos do repo estão dentro do teto de docs/prompts-teto.md" [ "$RC" -eq 0 ]
[[ "$RC" -eq 0 ]] || printf '%s\n' "$OUT" | sed 's/^/     | /'
check "a tabela tem o AGENTS.md, as notas, o worker e o núcleo do dispatcher" bash -c \
  'for f in AGENTS.md docker/agent-notes.md docker/swarm-worker.md docker/swarm.md; do grep -qF "| \`$f\` |" "$1" || exit 1; done' _ "$TABELA"
check "a regra de regra nova tirar ou fundir outra está escrita na tabela" grep -qF 'entra tirando ou fundindo outra' "$TABELA"
check "a regra está também no AGENTS.md" grep -qF 'entra tirando ou fundindo outra' "$ROOT/AGENTS.md"

# a conferência em si, numa árvore de exemplo
EX="$TMP/ex"; mkdir -p "$EX/docker/swarm"
head -c 100 /dev/zero | tr '\0' a > "$EX/AGENTS.md"
head -c 50 /dev/zero | tr '\0' a > "$EX/docker/swarm.md"
head -c 30 /dev/zero | tr '\0' a > "$EX/docker/swarm/triagem.md"
cat > "$TMP/tabela.md" <<'T'
| Arquivo | Teto (bytes) |
|---|---|
| `AGENTS.md` | 100 |
| `docker/swarm.md` | 60 |
| `docker/swarm/triagem.md` | 30 |
T
OUT="$(confere "$EX" "$TMP/tabela.md" 2>&1)"; RC=$?
check "exemplo: no teto exato passa, sem mensagem" bash -c '[ "$1" -eq 0 ] && [ -z "$2" ]' _ "$RC" "$OUT"

head -c 101 /dev/zero | tr '\0' a > "$EX/AGENTS.md"
OUT="$(confere "$EX" "$TMP/tabela.md" 2>&1)"; RC=$?
check "exemplo: um byte acima do teto falha e diz o arquivo" bash -c '[ "$1" -ne 0 ] && grep -qxF "acima do teto: AGENTS.md tem 101 bytes, teto 100" <<<"$2"' _ "$RC" "$OUT"
head -c 100 /dev/zero | tr '\0' a > "$EX/AGENTS.md"

head -c 10 /dev/zero | tr '\0' a > "$EX/docker/swarm/nova.md"
OUT="$(confere "$EX" "$TMP/tabela.md" 2>&1)"; RC=$?
check "exemplo: etapa nova sem teto na tabela falha" bash -c '[ "$1" -ne 0 ] && grep -qxF "sem teto na tabela: docker/swarm/nova.md" <<<"$2"' _ "$RC" "$OUT"
rm -f "${EX:?}/docker/swarm/nova.md"

rm -f "${EX:?}/docker/swarm/triagem.md"
OUT="$(confere "$EX" "$TMP/tabela.md" 2>&1)"; RC=$?
check "exemplo: linha da tabela sem arquivo falha" bash -c '[ "$1" -ne 0 ] && grep -qxF "na tabela e sem arquivo: docker/swarm/triagem.md" <<<"$2"' _ "$RC" "$OUT"

check_end
