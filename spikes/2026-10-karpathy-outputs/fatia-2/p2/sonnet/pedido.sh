# oute-propose
# titulo: Rotação do SurrealDB: apaga o volume oute-agent_oute-surrealdb, sobe a stack e remonta o estado
# como: user
# agente: claude
# criado: 2026-10-03T23:09:05Z
# RESUMO (os números de linha são os do pedido original, sem este bloco)
# O que o pedido faz, na ordem em que roda:
#   1. Confere os containers que usam o volume; para sem apagar nada se achar outro além de dois (linhas 15-22).
#   2. Para o `oute-agent-studio` (linha 24).
#   3. Para e remove esses containers (linhas 25-29).
#   4. Apaga o volume `oute-agent_oute-surrealdb` (linha 31).
#   5. Roda `oute up`, sem ler o vault (linhas 10 e 37).
#   6. Espera o SurrealDB ficar saudável, até 120 s (linhas 38-43).
#   7. Roda `oute studio rebuild-state` e lista os containers (linhas 45-47).
# NÃO toca no volume do DuckDB nem recria o agent (linhas 11 e 35).
# No host: o volume do SurrealDB some e volta pelo `oute up`; os containers apagados vêm de novo pelo `oute up` (não verificado no script).

set -euo pipefail
VOL=oute-agent_oute-surrealdb
echo "O passo 2 falhou. Outro container prendia o volume $VOL: o one-off oute-volume-init, parado."
echo "Este pedido solta e apaga SÓ esse volume. Depois sobe a stack com oute up e remonta o estado. O oute up não lê o vault: o services.env já tem a senha nova."
echo "O pedido NÃO toca no DuckDB e NÃO recria o agent. O ambiente do agent não mudou."
cd "$HOME/oute-agent"
if docker volume inspect "$VOL" >/dev/null 2>&1; then
  echo "Containers que usam o volume:"
  USERS="$(docker ps -a --filter "volume=$VOL" --format '{{.Names}}')"
  echo "${USERS:-  (nenhum)}"
  for c in $USERS; do
    case "$c" in
      oute-surrealdb|oute-volume-init) ;;
      *) echo "ERRO: o container $c usa o volume e não era esperado. O script parou e não apagou nada." >&2; exit 1 ;;
    esac
  done
  # CUIDADO: para o oute-agent-studio (linha 24). O agent-studio fica fora do ar até o oute up; se ele já estiver parado, o script segue (|| echo).
  echo "Parando o agent-studio..."
  docker stop oute-agent-studio >/dev/null 2>&1 || echo "  (já parado)"
  # CUIDADO: para e remove cada container da lista, só oute-surrealdb e oute-volume-init (linhas 25-29). O container removido não volta sem o oute up; a lista foi limitada a esses dois nomes nas linhas 18-21.
  for c in $USERS; do
    echo "Parando e removendo $c..."
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm "$c" >/dev/null
  done
  # CUIDADO: apaga o volume oute-agent_oute-surrealdb (linha 31). O apagamento não se desfaz e o script não faz cópia antes; só a lista dos containers (linhas 18-21) protege.
  echo "Apagando o volume $VOL..."
  docker volume rm "$VOL" >/dev/null
else
  echo "O volume $VOL já não existe. O script segue."
fi
docker volume inspect oute-agent_oute-agent-studio >/dev/null && echo "ok: o volume do DuckDB está intacto"
echo "Subindo a stack (oute up)..."
oute up
echo "Esperando o SurrealDB ficar saudável (até 120 s)..."
i=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' oute-surrealdb 2>/dev/null)" = healthy ]; do
  i=$((i+1)); [ "$i" -le 60 ] || { echo "ERRO: o SurrealDB não ficou saudável em 120 s." >&2; docker ps -a --format '{{.Names}}\t{{.Status}}' | grep oute-; exit 1; }
  sleep 2
done
# CUIDADO: roda oute studio rebuild-state (linha 45). O que ele sobrescreve não está neste script (não verificado); se ele falhar, o volume apagado não volta.
echo "Remontando o estado. Esperado depois: pelo menos rodadas=35 workers=130 sessoes=118 pedidos=55 conversas=158."
oute studio rebuild-state
echo "Containers no fim:"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep oute-
