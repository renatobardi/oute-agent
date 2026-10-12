#!/usr/bin/env bash
# Testes da lista de pedidos da outbox (#815, `oute.canal.snapshot`): o verbo `oute-emit snapshot` (o que sai ao coletor)
# e o `oute approve` do host (quando sai, o que leva e o que não sai). O agent-studio que usa a lista tem os casos dele
# em tests/agent-studio-proposals.test.sh. Bash puro: `docker` e `oute-emit` do host são falsos; o receptor OTLP é o de
# tests/lib/otlp.sh, e o `oute-emit` de verdade roda com HOME temporário.
# Uso: tests/oute-approve-snapshot.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
# credenciais reais nunca chegam ao scripts/oute daqui (docker é falso, mas o script lê o ambiente)
for v in $(compgen -e | grep -E '^(OCI_|GH_TOKEN$|GITHUB_TOKEN$|AGENT_STUDIO_|BW_|OTEL_)' || true); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTE="$ROOT/scripts/oute"
TMP="$(mktemp -d)"
trap 'guarda_stop; rcv_stop; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/otlp.sh"
CHECK_OUT=30
# guarda (#815): o container tem OTEL_* reais; nada deste teste pode sair para outro endpoint que não o receptor dele
guarda_start "$TMP/guarda"

ID1=20261012-010101-pedido-um
ID2=20261012-020202-pedido-dois

# ---------------------------------------------------------------- 1. o verbo do oute-emit (o que vai ao coletor)
rcv_start "$TMP/rcv"
emit() {
  local args=("$@")
  ( env -u CLAUDECODE HOME="$TMP/home" OTEL_RESOURCE_ATTRIBUTES="host.name=oute-mac,oute.instance=oute-agent" \
    "$ROOT/docker/oute-emit" "${args[@]}" )
  return $?
}
mkdir -p "$TMP/home"
emit snapshot "$ID2" "$ID1"
emit snapshot
emit snapshot "nao-e-id"
emit snapshot "$ID1" "$ID1" "$ID2"
# mais ids que o teto (1000): nenhuma lista sai, nenhum pedido some por falta de lista inteira
big=(); for i in $(seq 1 1001); do big+=("20261012-$(printf '%06d' "$i")-x"); done
emit snapshot "${big[@]}"
rcv_stop

snaps() {
  ev '.name == "oute.canal.snapshot"'
  return 0
}
check "verbo: um evento por chamada válida (3 de 5: a com id inválido e a com teto estourado não saem)" \
  test "$(snaps | grep -c . || true)" = 3
check "verbo: a lista vem ordenada e sem repetição, em JSON no atributo oute.canal.ids" \
  bash -c 'jq -e --arg a "$2" --arg b "$3" "select((.attrs[\"oute.canal.ids\"] | fromjson) == [\$a, \$b] and .attrs[\"oute.canal.count\"] == \"2\")" <<<"$1" >/dev/null' _ "$(snaps | head -1)" "$ID1" "$ID2"
check "verbo: a origem do evento é a do host (host.name) e o agente é human" \
  bash -c 'jq -e "select(.res[\"host.name\"] == \"oute-mac\" and .attrs[\"oute.agent\"] == \"human\")" <<<"$1" >/dev/null' _ "$(snaps | head -1)"
check "verbo: lista vazia sai (a outbox sem pedido também é um fato)" \
  bash -c 'jq -e "select((.attrs[\"oute.canal.ids\"] | fromjson) == [])" <<<"$1" >/dev/null' _ "$(snaps | sed -n 2p)"
check "verbo: sem endpoint o verbo sai 0 e em silêncio, e não grava spool de lista sem destino" \
  bash -c 'env -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_EXPORTER_OTLP_LOGS_ENDPOINT HOME="$1/h2" OTEL_RESOURCE_ATTRIBUTES=host.name=x "$2" snapshot '"$ID1"' >/dev/null 2>&1; [ $? = 0 ] && ! ls "$1/h2/.oute/emit/spool" 2>/dev/null | grep -q .' _ "$TMP" "$ROOT/docker/oute-emit"

# ---------------------------------------------------------------- 2. o `oute approve` do host (quando manda a lista)
# docker falso: `ps` mostra o container enquanto $F_UP existir; `exec` roda o comando local com o HOME do container e
# falha se $F_EXECFAIL existir (container de pé mas sem resposta). `oute-emit` falso só grava os argumentos.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ps) [[ -e "$F_UP" ]] && echo abc123; exit 0 ;;
  exec) shift; [[ "$1" == -i ]] && shift; shift
        [[ -e "$F_EXECFAIL" ]] && { echo "Error response from daemon" >&2; exit 1; }
        HOME="$F_CTR_HOME" exec "$@" ;;
  *) exit 9 ;;
esac
SH
cat > "$BIN/oute-emit" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$F_EMITS"
SH
chmod +x "$BIN/docker" "$BIN/oute-emit"
export PATH="$BIN:$PATH" OUTE_HOST=teste OUTE_INSTANCE=teste
export F_UP="$TMP/up" F_EXECFAIL="$TMP/execfail" F_CTR_HOME="$TMP/ctr" F_EMITS="$TMP/emits"
export OUTE_APPROVE_TTY="$TMP/answer"

# cada pedido pendente pergunta: a resposta vai pelo arquivo de OUTE_APPROVE_TTY, "n" = fica pendente
reset() {
  rm -rf "${TMP:?}/host" "${TMP:?}/ctr" "${F_EMITS:?}" "${F_EXECFAIL:?}"; mkdir -p "$TMP/host" "$TMP/ctr/outbox"
  touch "$F_UP"; printf 'n\nn\nn\nn\n' > "$OUTE_APPROVE_TTY"
  return 0
}
# o pedido de teste de verdade não tem o que o host lê: o arquivo some quando o container o some
outbox_put() {
  local id="$1" titulo="$2"
  printf '# oute-propose\n# titulo: %s\n# como: user\n\ntrue\n' "$titulo" > "$TMP/ctr/outbox/$id.sh"
  return 0
}
approve_once() {
  HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve </dev/null >"$TMP/approve.log" 2>&1
  RC=$?
  return 0
}
emits() {
  cat "$F_EMITS" 2>/dev/null
  return 0
}

reset; outbox_put "$ID1" "um"; outbox_put "$ID2" "dois"
approve_once
check "host: approve sem pendente sai 0 e manda a lista da outbox (2 ids) ao container" \
  bash -c '[ "$1" = 0 ] && grep -qxF "snapshot $2 $3" <<<"$4"' _ "$RC" "$ID1" "$ID2" "$(emits)"

check "host: a lista ficou em approve/snapshot.last (hora e hash)" \
  bash -c 'grep -qE "^[0-9]+ [0-9a-f]{16}$" "$1/.oute/approve/snapshot.last"' _ "$TMP/host"

approve_once
check "host: segunda volta sem mudança e dentro dos 300 s não manda de novo" \
  test "$(emits | grep -c snapshot)" = 1

outbox_put 20261012-030303-pedido-tres "tres"
approve_once
check "host: lista mudou (pedido novo na outbox): manda de novo, com os três ids" \
  bash -c 'grep -qxF "snapshot $2 $3 20261012-030303-pedido-tres" <<<"$(tail -1 "$1")"' _ "$F_EMITS" "$ID1" "$ID2"

rm -f "${TMP:?}"/ctr/outbox/*.sh
: > "$F_EMITS"
approve_once
check "host: outbox vazia manda a lista vazia (snapshot sem ids), para o agent-studio tirar os pendentes sem arquivo" \
  bash -c 'grep -qxF "snapshot" <<<"$1"' _ "$(emits)"

reset; outbox_put "$ID1" "um"; : > "$F_EMITS"; touch "$F_EXECFAIL"
approve_once
check "host: container de pé mas sem resposta: nenhuma lista sai (a lista vazia tiraria os pedidos reais)" \
  test -z "$(emits)"
rm -f "${F_EXECFAIL:?}"

guarda_check
check_end
