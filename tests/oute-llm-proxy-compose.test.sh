#!/usr/bin/env bash
# Testes do llm-proxy no docker/compose.yaml (#459, ADR-08 adendo): o ai-memory só alcança o OpenRouter pelo proxy, a
# chave da memória é só do proxy (nem o agent nem o ai-memory a recebem), nenhuma porta publicada, e o agent não está na
# rede do proxy. Texto do compose (sem Docker) e, com `docker compose` no host, o compose resolvido.
# Uso: tests/oute-llm-proxy-compose.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
. "$ROOT/tests/lib/compose-config.sh"
trap 'rm -rf "${TMP:?}"' EXIT

COMPOSE="$ROOT/docker/compose.yaml"
nocomment() { grep -v '^ *#'; }
AGENT="$(compose_service agent | nocomment)"; MEM="$(compose_service ai-memory | nocomment)"
PROXY="$(compose_service llm-proxy | nocomment)"; COL="$(compose_service otel-collector | nocomment)"
check "compose: os quatro serviços achados"            test -n "$AGENT" -a -n "$MEM" -a -n "$PROXY" -a -n "$COL"
check "proxy: só no profile llm-proxy"                 grep -qx '    profiles: \[llm-proxy\]' <<<"$PROXY"
check "proxy: sem porta publicada"                     bash -c '! grep -qE "^    ports:" <<<"$0"' "$PROXY"
check "proxy: nas redes llm e saida (a única com rota para fora)" grep -qx '    networks: \[llm, saida\]' <<<"$PROXY"
check "proxy: a chave vem de OPENROUTER_MEMORY_API_KEY" grep -q 'LLM_PROXY_API_KEY: \${OPENROUTER_MEMORY_API_KEY:-}' <<<"$PROXY"
check "proxy: sistema de arquivos só leitura, sem capabilities" bash -c 'grep -qx "    read_only: true" <<<"$0" && grep -q "cap_drop: \[ALL\]" <<<"$0"' "$PROXY"
check "proxy: consumo ao collector pela rede (OTLP)"   grep -q 'OTEL_EXPORTER_OTLP_ENDPOINT: ' <<<"$PROXY"
check "chave da memória só aparece no llm-proxy"       test "$(nocomment < "$COMPOSE" | grep -c 'OPENROUTER_MEMORY_API_KEY')" = 1
check "agent: sem a chave da memória nem variável do proxy" bash -c '! grep -qE "OPENROUTER_MEMORY|LLM_PROXY|LLM_API_KEY" <<<"$0"' "$AGENT"
check "ai-memory: sem chave de LLM do OpenRouter"      bash -c '! grep -qE "OPENROUTER|LLM_API_KEY|LLM_PROXY_API_KEY" <<<"$0"' "$MEM"
check "ai-memory: o LLM aponta para o proxy"           grep -qE 'AI_MEMORY_LLM_BASE_URL: \$\{AI_MEMORY_LLM_BASE_URL:-[a-z]+://llm-proxy:8440/api/v1\}' <<<"$MEM"
check "ai-memory: LLM segue desligado (sem provedor novo)" grep -q 'AI_MEMORY_LLM_PROVIDER: \${AI_MEMORY_LLM_PROVIDER:-}' <<<"$MEM"
check "compose: nenhum endereço do OpenRouter fora do proxy" bash -c '! grep -v "^ *#" "$0" | grep -q "openrouter.ai"' "$COMPOSE"
check "agent: nas redes oute e memoria (não alcança o proxy)" bash -c 'n="$(sed -n "/^    networks:/,/^    [a-z]/p" <<<"$0")"; grep -q "^      oute:$" <<<"$n" && grep -q "^      memoria:$" <<<"$n" && ! grep -qE "^ +networks:.*llm|^      (llm|saida):" <<<"$n"' "$AGENT"
check "ai-memory: só nas redes memoria e llm (sem oute, sem saida)" grep -qx '    networks: \[memoria, llm\]' <<<"$MEM"
check "collector nas redes oute e llm"                 grep -qx '    networks: \[oute, llm\]' <<<"$COL"
# #564: a rede de cada declaração do bloco `networks:` do compose, uma linha `nome internal|externa`
nets() {
  sed -n '/^networks:/,$p' "$COMPOSE" | nocomment \
    | awk '/^  [a-z]+:$/ {if (n) print n, i; n=$1; sub(":", "", n); i="externa"} /^    internal: true$/ {i="internal"} END {if (n) print n, i}' | sort -u
  return 0
}
check "redes llm e memoria declaradas como internal"   bash -c 'grep -qx "llm internal" <<<"$0" && grep -qx "memoria internal" <<<"$0"' "$(nets)"
check "rede saida declarada, não interna"              grep -qx 'saida externa' <<<"$(nets)"
check "nenhuma porta do proxy em 0.0.0.0"              bash -c '! grep -E "^ +- \"0\.0\.0\.0:" "$0"' "$COMPOSE"
check "Dockerfile copia o proxy para a imagem"         grep -q '^COPY docker/oute-llm-proxy /usr/local/bin/' "$ROOT/docker/Dockerfile"
check "o proxy é executável (100755)"                  test "$(git -C "$ROOT" ls-files -s docker/oute-llm-proxy | cut -c1-6)" = 100755

# compose resolvido, quando o host tem `docker compose` (o CI de PR tem; sem ele, só o texto acima)
if docker compose version >/dev/null 2>&1; then
  KEY="chave-$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
  CFG="$(compose_config llm-proxy OPENROUTER_MEMORY_API_KEY="$KEY" 2>"$TMP/cfg.err")" || CFG=""
  check "compose config: resolve com o profile llm-proxy" test -n "$CFG"
  check "compose config: o proxy recebe a chave"        jqe --arg k "$KEY" '.services."llm-proxy".environment.LLM_PROXY_API_KEY == $k' <<<"$CFG"
  check "compose config: agent sem a chave (nem o valor)" bash -c '! jq -c ".services.agent" <<<"$0" | grep -qF -- "$1"' "$CFG" "$KEY"
  check "compose config: ai-memory sem a chave (nem o valor)" bash -c '! jq -c ".services.\"ai-memory\"" <<<"$0" | grep -qF -- "$1"' "$CFG" "$KEY"
  check "compose config: collector sem a chave"         bash -c '! jq -c ".services.\"otel-collector\"" <<<"$0" | grep -qF -- "$1"' "$CFG" "$KEY"
  check "compose config: proxy sem porta publicada"     jqe '.services."llm-proxy".ports == null' <<<"$CFG"
  check "compose config: proxy nas redes llm e saida"   jqe '.services."llm-proxy".networks | keys == ["llm", "saida"]' <<<"$CFG"
  check "compose config: agent nas redes memoria e oute" jqe '.services.agent.networks | keys == ["memoria", "oute"]' <<<"$CFG"
  check "compose config: ai-memory aponta ao proxy"     jqe '.services."ai-memory".environment.AI_MEMORY_LLM_BASE_URL | endswith("llm-proxy:8440/api/v1")' <<<"$CFG"
  check "compose config: ai-memory só em redes internas (#564)" jqe '.services."ai-memory".networks | keys == ["llm", "memoria"]' <<<"$CFG"
  check "compose config: toda rede do ai-memory é internal, e só o proxy tem saida" jqe '. as $r | (.services."ai-memory".networks | keys | all(. as $n | $r.networks[$n].internal == true)) and ([.services[] | select(.networks | has("saida"))] | length == 1)' <<<"$CFG"
  OFF="$(compose_config "" 2>"$TMP/cfg.err")" || OFF=""
  check "compose config sem o profile: proxy ausente"   jqe '.services."llm-proxy" == null and .services."ai-memory" != null' <<<"$OFF"
  check "compose config: redes llm e memoria internas, saida não" jqe '.networks.llm.internal == true and .networks.memoria.internal == true and .networks.saida.internal != true' <<<"$CFG"
else
  echo "# compose config: pulado (sem docker compose neste host)"
fi

check_end
