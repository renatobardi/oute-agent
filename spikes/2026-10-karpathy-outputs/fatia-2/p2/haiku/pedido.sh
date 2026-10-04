# oute-propose
# titulo: Rotação do volume SurrealDB: apaga, sobe a stack e remonta estado
# como: user
# agente: claude
# criado: 2026-10-03T23:09:05Z

# RESUMO
# O que faz:
# - Valida que só `oute-surrealdb` e `oute-volume-init` usam o volume (linha 18-21)
# - Para `oute-agent-studio` (linha 24)
# - Para e remove containers que usam o volume (linhas 27-28)
# - Apaga o volume `oute-agent_oute-surrealdb` (linha 31)
# - Verifica que o volume do DuckDB permanece intacto (linha 35)
# - Sobe a stack com `oute up` (linha 37)
# - Espera `oute-surrealdb` ficar saudável (linhas 40-43)
# - Remonta o estado do agent-studio (linha 45)
# O que NÃO toca: volume do DuckDB, variáveis do agent
# O que muda: volume SurrealDB recriado, SurrealDB reinicia, estado remontado

set -euo pipefail
VOL=oute-agent_oute-surrealdb
echo "O volume $VOL estava preso por outro container (oute-volume-init parado)."
echo "Este pedido: apaga só esse volume, sobe a stack (oute up lê services.env com a senha nova) e remonta estado."
echo "NÃO muda o DuckDB nem recria o agent."
cd "$HOME/oute-agent"
if docker volume inspect "$VOL" >/dev/null 2>&1; then
  echo "Containers que usam o volume:"
  USERS="$(docker ps -a --filter "volume=$VOL" --format '{{.Names}}')"
  echo "${USERS:-  (nenhum)}"
  for c in $USERS; do
    case "$c" in
      oute-surrealdb|oute-volume-init) ;;
      *) echo "ERRO: container inesperado usando o volume: $c; parei sem apagar nada" >&2; exit 1 ;;
    esac
  done
  echo "Parando oute-agent-studio..."
  docker stop oute-agent-studio >/dev/null 2>&1 || echo "  (já parado)"
  # CUIDADO: Para e remove containers que usam o volume. Se a validação acima passou, só containers esperados serão afetados.
  for c in $USERS; do
    echo "Parando e removendo $c..."
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm "$c" >/dev/null
  done
  # CUIDADO: Apaga o volume oute-agent_oute-surrealdb. Só containers validados acima podem usá-lo; a validação garante que nenhum container inesperado será afetado.
  echo "Apagando o volume $VOL..."
  docker volume rm "$VOL" >/dev/null
else
  echo "Volume $VOL já não existe; sigo"
fi
docker volume inspect oute-agent_oute-agent-studio >/dev/null && echo "ok: volume do DuckDB intacto"
echo "Subindo a stack (oute up)..."
oute up
echo "Esperando SurrealDB ficar saudável (até 120 s)..."
i=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' oute-surrealdb 2>/dev/null)" = healthy ]; do
  i=$((i+1)); [ "$i" -le 60 ] || { echo "ERRO: SurrealDB não ficou saudável" >&2; docker ps -a --format '{{.Names}}\t{{.Status}}' | grep oute-; exit 1; }
  sleep 2
done
echo "Remontando estado (esperado depois: rodadas=35 workers=130 sessoes=118 pedidos=55 conversas=158)..."
oute studio rebuild-state
echo "Containers no fim:"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep oute-
