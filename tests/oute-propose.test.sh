#!/usr/bin/env bash
# Testes do oute-propose: o cabeçalho do pedido, com a sessão (# sessao:) que o watch do oute-swarm usa para marcar o [canal] (#455).
# Bash puro, sem host nem rede. Uso: tests/oute-propose.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPOSE="${PROPOSE:-$ROOT/docker/oute-propose}"
TMP="$(mktemp -d)"; trap 'guarda_stop; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/otlp.sh"
guarda_start "$TMP/guarda"

H="$TMP/home"; mkdir -p "$H" "$TMP/bin"
# oute-emit falso: o pedido não manda evento de verdade
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/oute-emit"; chmod +x "$TMP/bin/oute-emit"
git init -q "$TMP/wt" 2>/dev/null
# propose <dir> <título>: roda o oute-propose em <dir> com HOME do teste; o id sai em $ID, o arquivo em $F.
# $RODADA (se não vazia) vai como OUTE_SWARM_ID; sem ela a variável não existe no ambiente do oute-propose
propose() {
  local dir="$1" titulo="$2"
  ID="$(cd "$dir" && env -u CLAUDECODE -u CODEX_THREAD_ID -u OUTE_SWARM_ID ${RODADA:+OUTE_SWARM_ID="$RODADA"} PATH="$TMP/bin:$PATH" HOME="$H" "$PROPOSE" "$titulo" <<<'echo oi' 2>/dev/null)"
  F="$H/outbox/$ID.sh"
  return 0
}
hdr() { local campo="$1"; sed -n "s/^# $campo: //p;/^\$/q" "$F" | head -1; return 0; }

# 1. worktree com marca do oute-task: o slug vai no cabeçalho
printf 'id=abc\nrepo=oute-agent\nslug=455-canal-sessao\nround=swarm-x\n' > "$TMP/wt/.git/oute-task"
propose "$TMP/wt" "pedido com marca"
check "sessao: o slug da marca entra no cabeçalho"        [ "$(hdr sessao)" == "455-canal-sessao" ]
check "sessao: o cabeçalho segue com titulo e criado"     bash -c '[ "$(sed -n "s/^# titulo: //p" "$1")" == "pedido com marca" ] && grep -q "^# criado: " "$1"' _ "$F"
check "sessao: linha em branco separa o script"           bash -c 'sed -n "/^\$/{n;p;q}" "$1" | grep -qx "echo oi"' _ "$F"

# 2. a marca é filtrada: nada além de [A-Za-z0-9._-] no cabeçalho
printf 'slug=a b;$(x)\n' > "$TMP/wt/.git/oute-task"
propose "$TMP/wt" "marca suja"
check "sessao: caracteres fora de [A-Za-z0-9._-] caem"    [ "$(hdr sessao)" == "abx" ]

# 3. sem marca ou fora de worktree: o campo não é gravado (o watch atribui pelo título)
rm -f "$TMP/wt/.git/oute-task"
propose "$TMP/wt" "sem marca"
check "sessao: sem marca, sem o campo"                    bash -c '! grep -q "^# sessao:" "$1"' _ "$F"
mkdir -p "$TMP/fora"
propose "$TMP/fora" "fora de repo"
check "sessao: fora de repo git, sem o campo"             bash -c '! grep -q "^# sessao:" "$1" && [ -s "$1" ]' _ "$F"

# 4. rodada (#843, ADR-10): OUTE_SWARM_ID vira `# rodada:` no cabeçalho; o `oute approve --dark` do host só olha pedido com ela
RODADA=swarm-1012-2122
propose "$TMP/fora" "com rodada"
check "rodada: OUTE_SWARM_ID entra no cabeçalho"          [ "$(hdr rodada)" == "swarm-1012-2122" ]
check "rodada: a linha fica antes do script (no cabeçalho)" bash -c 'sed -n "1,/^\$/p" "$1" | grep -qx "# rodada: swarm-1012-2122"' _ "$F"
check "rodada: o script segue depois da linha em branco"  bash -c 'sed -n "/^\$/{n;p;q}" "$1" | grep -qx "echo oi"' _ "$F"
RODADA='sw;$(x) a'
propose "$TMP/fora" "rodada suja"
check "rodada: só [A-Za-z0-9._-] no cabeçalho"            [ "$(hdr rodada)" == "swxa" ]
RODADA=';;;'
propose "$TMP/fora" "rodada toda suja"
check "rodada: vazia depois do filtro, sem a linha"       bash -c '! grep -q "^# rodada:" "$1"' _ "$F"
RODADA=""
propose "$TMP/fora" "sem rodada"
check "rodada: sem a variável, sem a linha"               bash -c '! grep -q "^# rodada:" "$1" && [ -s "$1" ]' _ "$F"
check "rodada: sem a variável, o cabeçalho é o de sempre" bash -c 'sed -n "1,/^\$/p" "$1" | sed "/^# criado: /d" | diff -q - <(printf "# oute-propose\n# titulo: sem rodada\n# como: user\n# agente: desconhecido\n\n") >/dev/null' _ "$F"

guarda_check
guarda_stop
check_end
