#!/usr/bin/env bash
# Testes da pasta de dados do agent-studio no `oute up` (#570): OUTE_AGENT_STUDIO_DIR e OUTE_SURREALDB_DIR (no .env ou no
# ambiente) tiram o DuckDB e o SurrealDB do disco do sistema. Pasta errada não pode subir: o Docker criaria uma pasta
# vazia no lugar e o agent-studio subiria com um banco novo, como se o histórico tivesse sumido. Por isso o `oute up`
# para antes, com o motivo: caminho relativo, pasta que não existe ou pasta de outro dono.
# Roda só as funções do agent-studio do scripts/oute (tests/lib/agent-studio.sh); sem Docker e sem rede.
# Uso: tests/oute-studio-dados.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT

FUNCS="$(studio_oute_funcs)"
ME="$(id -u)"
CRED=(OUTE_AGENT_STUDIO=1 AGENT_STUDIO_INGEST_TOKEN=i AGENT_STUDIO_SURREAL_PASS=s AGENT_STUDIO_READ_TOKEN=r)
SHOW='echo "duck=${OUTE_AGENT_STUDIO_DIR:-} surreal=${OUTE_SURREALDB_DIR:-} perfis=${COMPOSE_PROFILES:-}"'
mkdir -p "$TMP/duck" "$TMP/surreal"

studio_oute_up "$SHOW" "${CRED[@]}" CONTAINER_UID="$ME"
check "sem as variáveis: sobe com os volumes docker"            test "$RC" = 0
check "sem as variáveis: nada é exportado"                      has_line "duck= surreal= perfis=agent-studio"

studio_oute_up "$SHOW" "${CRED[@]}" CONTAINER_UID="$ME" OUTE_AGENT_STUDIO_DIR="$TMP/duck" OUTE_SURREALDB_DIR="$TMP/surreal"
check "pastas certas no ambiente: sobe"                          test "$RC" = 0
check "pastas certas no ambiente: as duas vão ao compose"        has_line "duck=$TMP/duck surreal=$TMP/surreal perfis=agent-studio"

printf 'OUTE_AGENT_STUDIO_DIR=%s\nOUTE_SURREALDB_DIR=%s\n' "$TMP/duck" "$TMP/surreal" > "$TMP/.env"
studio_oute_up "$SHOW" "${CRED[@]}" CONTAINER_UID="$ME"
check "pastas certas no .env: sobe e exporta para o compose"     test "$RC" = 0
check "pastas certas no .env: as duas vão ao compose"            has_line "duck=$TMP/duck surreal=$TMP/surreal perfis=agent-studio"
rm -f "$TMP/.env"

studio_oute_up "$SHOW" "${CRED[@]}" CONTAINER_UID="$ME" OUTE_AGENT_STUDIO_DIR="$TMP/nao-existe"
check "pasta que não existe: para"                               test "$RC" != 0
check "pasta que não existe: diz a variável e o motivo"          has "OUTE_AGENT_STUDIO_DIR.*não existe"
check "pasta que não existe: o profile não liga"                 hasnt "perfis=agent-studio"
check "pasta que não existe: não é criada"                       test ! -e "$TMP/nao-existe"

studio_oute_up "$SHOW" "${CRED[@]}" CONTAINER_UID="$ME" OUTE_SURREALDB_DIR="dados/surreal"
check "caminho relativo: para"                                   test "$RC" != 0
check "caminho relativo: diz a variável e o motivo"              has "OUTE_SURREALDB_DIR.*caminho absoluto"

studio_oute_up "$SHOW" "${CRED[@]}" CONTAINER_UID=10001 OUTE_AGENT_STUDIO_DIR="$TMP/duck"
check "pasta de outro dono: para"                                test "$RC" != 0
check "pasta de outro dono: diz a variável e o dono esperado"    has "OUTE_AGENT_STUDIO_DIR.*dono.*10001"

studio_oute_up "$SHOW" CONTAINER_UID="$ME" OUTE_AGENT_STUDIO_DIR="$TMP/nao-existe"
check "host sem agent-studio: a variável não é conferida"        test "$RC" = 0
check_end
