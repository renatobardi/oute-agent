# oute-propose
# titulo: rotação SurrealDB: corrige o passo 2 (volume preso pelo volume-init), sobe e remonta
# como: user
# agente: claude
# criado: 2026-10-03T23:09:05Z

set -euo pipefail
VOL=oute-agent_oute-surrealdb
echo "o passo 2 falhou: o volume $VOL estava preso por outro container (o one-off oute-volume-init, parado)."
echo "este pedido: solta e apaga SÓ esse volume, sobe a stack (oute up, sem ler o vault: o services.env já tem a senha nova) e remonta o estado."
echo "NÃO toca no DuckDB nem recria o agent (o ambiente dele não mudou)."
cd "$HOME/oute-agent"
if docker volume inspect "$VOL" >/dev/null 2>&1; then
  echo "containers que usam o volume:"
  USERS="$(docker ps -a --filter "volume=$VOL" --format '{{.Names}}')"
  echo "${USERS:-  (nenhum)}"
  for c in $USERS; do
    case "$c" in
      oute-surrealdb|oute-volume-init) ;;
      *) echo "ERRO: container inesperado usando o volume: $c; parei sem apagar nada" >&2; exit 1 ;;
    esac
  done
  echo "parando o agent-studio..."
  docker stop oute-agent-studio >/dev/null 2>&1 || echo "  (já parado)"
  for c in $USERS; do
    echo "parando e removendo $c..."
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm "$c" >/dev/null
  done
  echo "apagando o volume $VOL..."
  docker volume rm "$VOL" >/dev/null
else
  echo "volume $VOL já não existe; sigo"
fi
docker volume inspect oute-agent_oute-agent-studio >/dev/null && echo "ok: volume do DuckDB intacto"
echo "subindo a stack (oute up)..."
oute up
echo "esperando o SurrealDB ficar saudável (até 120 s)..."
i=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' oute-surrealdb 2>/dev/null)" = healthy ]; do
  i=$((i+1)); [ "$i" -le 60 ] || { echo "ERRO: SurrealDB não ficou saudável" >&2; docker ps -a --format '{{.Names}}\t{{.Status}}' | grep oute-; exit 1; }
  sleep 2
done
echo "remontando o estado (esperado em 'depois': pelo menos rodadas=35 workers=130 sessoes=118 pedidos=55 conversas=158)..."
oute studio rebuild-state
echo "containers no fim:"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep oute-
