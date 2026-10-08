#!/usr/bin/env bash
# Testes do docker compose config do docker/compose.yaml: resolução com e sem profile agent-studio, no CI (gates).
# Uso: tests/compose-config.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/compose-config.sh"
trap 'rm -rf "$TMP"' EXIT

# sem docker compose no CI: falha
if ! docker compose version >/dev/null 2>&1; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    bad "docker compose config: sem docker compose (CI falha)"
    check_end
    exit
  else
    echo "# docker compose config: pulado (sem docker compose neste host)"
    exit 0
  fi
fi

# ---- 1. resolver sem profile (só agent, otel-collector, ai-memory; sem agent-studio, surrealdb)
OUT="$(compose_config "" 2>"$TMP/cfg.err")" || OUT=""
check "config sem profile: resolve"                      test -n "$OUT"
check "config sem profile: agent está presente"          jqe '.services.agent != null' <<<"$OUT"
check "config sem profile: otel-collector está presente" jqe '.services."otel-collector" != null' <<<"$OUT"
check "config sem profile: ai-memory está presente"      jqe '.services."ai-memory" != null' <<<"$OUT"
check "config sem profile: agent-studio ausente"         jqe '.services."agent-studio" == null' <<<"$OUT"
check "config sem profile: surrealdb ausente"            jqe '.services.surrealdb == null' <<<"$OUT"

# ---- 2. resolver com profile agent-studio (agent, otel-collector, ai-memory, agent-studio, surrealdb)
OUT="$(compose_config "agent-studio" 2>"$TMP/cfg.err")" || OUT=""
check "config com --profile agent-studio: resolve"                       test -n "$OUT"
check "config com --profile agent-studio: agent está presente"           jqe '.services.agent != null' <<<"$OUT"
check "config com --profile agent-studio: otel-collector está presente"  jqe '.services."otel-collector" != null' <<<"$OUT"
check "config com --profile agent-studio: ai-memory está presente"       jqe '.services."ai-memory" != null' <<<"$OUT"
check "config com --profile agent-studio: agent-studio presente"         jqe '.services."agent-studio" != null' <<<"$OUT"
check "config com --profile agent-studio: surrealdb presente"            jqe '.services.surrealdb != null' <<<"$OUT"

# ---- 2b. dados do agent-studio e do SurrealDB (#570): volume docker por padrão, pasta do host quando o .env aponta
vol() { jq -e --arg s "$1" --arg t "$2" --arg ty "$3" --arg src "$4" \
  '.services[$s].volumes[] | select(.target == $t) | .type == $ty and .source == $src' >/dev/null; }
check "dados: por padrão o DuckDB fica no volume docker oute-agent-studio"   vol agent-studio /data/agent-studio volume oute-agent-studio <<<"$OUT"
check "dados: por padrão o SurrealDB fica no volume docker oute-surrealdb"   vol surrealdb /data/surrealdb volume oute-surrealdb <<<"$OUT"
OUT="$(compose_config "agent-studio" OUTE_AGENT_STUDIO_DIR=/srv/oute/duckdb OUTE_SURREALDB_DIR=/srv/oute/surrealdb 2>"$TMP/cfg.err")" || OUT=""
check "dados: OUTE_AGENT_STUDIO_DIR monta a pasta do host no DuckDB"         vol agent-studio /data/agent-studio bind /srv/oute/duckdb <<<"$OUT"
check "dados: OUTE_SURREALDB_DIR monta a pasta do host no SurrealDB"         vol surrealdb /data/surrealdb bind /srv/oute/surrealdb <<<"$OUT"
check "dados: o volume-init acerta o dono da mesma pasta do SurrealDB"       vol volume-init /v/surrealdb bind /srv/oute/surrealdb <<<"$OUT"

# ---- 2c. collector com teto de memória (#570): acima do memory_limiter (512 MiB), para ele recusar dado antes do OOM
check "collector: mem_limit de 768 MiB por padrão"       jqe '.services."otel-collector".mem_limit == "805306368"' <<<"$OUT"
OUT="$(compose_config "" OUTE_OTELCOL_MEM=1g 2>"$TMP/cfg.err")" || OUT=""
check "collector: OUTE_OTELCOL_MEM troca o teto"         jqe '.services."otel-collector".mem_limit == "1073741824"' <<<"$OUT"

# ---- 2d. métricas do próprio agent-studio a cada 5 min (#570): eram 10% das linhas de métricas do banco
OUT="$(compose_config "agent-studio" 2>"$TMP/cfg.err")" || OUT=""
check "agent-studio: exporta as próprias métricas a cada 5 min" jqe '.services."agent-studio".environment.OTEL_METRIC_EXPORT_INTERVAL == "300000"' <<<"$OUT"

# ---- 2e. limites de todos os containers (#570): nenhum serviço sobe sem teto de memória e de CPU. O oute-agent era o
# único que podia comer os 4 cores e os 15 GB livres do oute-server (sem swap): um vazamento numa sessão derrubava os vizinhos.
OUT="$(compose_config "" COMPOSE_PROFILES=agent-studio,llm-proxy 2>"$TMP/cfg.err")" || OUT=""
check "limites: todo serviço tem mem_limit e cpus"       jqe '[.services | to_entries[] | select(.key != "volume-init") | select((.value.mem_limit // 0) == 0 or (.value.cpus // 0) == 0) | .key] == []' <<<"$OUT"
lim() { jq -e --arg s "$1" --arg m "$2" --argjson c "$3" '.services[$s] | (.mem_limit | tostring) == $m and .cpus == $c' >/dev/null; }
check "limites: oute-agent 10g e 3 cpus"                 lim agent 10737418240 3 <<<"$OUT"
check "limites: agent-studio 6g e 2 cpus"                lim agent-studio 6442450944 2 <<<"$OUT"
check "limites: surrealdb 2g e 1 cpu"                    lim surrealdb 2147483648 1 <<<"$OUT"
check "limites: collector 768m e 1 cpu"                  lim otel-collector 805306368 1 <<<"$OUT"
check "limites: ai-memory 512m e 1 cpu"                  lim ai-memory 536870912 1 <<<"$OUT"
check "limites: llm-proxy 128m e 0,5 cpu"                lim llm-proxy 134217728 0.5 <<<"$OUT"
check "oute-agent: /dev/shm de 2g"                       jqe '.services.agent.shm_size == "2147483648"' <<<"$OUT"
check "oute-agent: no máximo 4096 processos"             jqe '.services.agent.pids_limit == 4096' <<<"$OUT"
OUT="$(compose_config "" OUTE_AGENT_MEM=8g OUTE_AGENT_CPUS=2 2>"$TMP/cfg.err")" || OUT=""
check "limites: OUTE_AGENT_MEM e OUTE_AGENT_CPUS trocam o teto" jqe '.services.agent | (.mem_limit | tostring) == "8589934592" and .cpus == 2' <<<"$OUT"

# ---- 2f. subnets fixas das redes (#707): sem subnet, o alocador do Docker pega a primeira faixa livre do pool padrão
# e podia dar a uma rede do projeto a 172.19.0.0/16 da rede oute (derrubou o deploy da 0.7.45). O teste confere
# cruzamento de verdade (CIDR → intervalo em jq), não só igualdade. NETDEFS: a.b.c.d/p → {lo, hi} em inteiro.
NETDEFS='def toint: split(".") | (.[0] | tonumber) * 16777216 + (.[1] | tonumber) * 65536 + (.[2] | tonumber) * 256 + (.[3] | tonumber);
def p2: if . <= 0 then 1 else 2 * (. - 1 | p2) end;
def cidr: split("/") as $s | ($s[0] | toint) as $lo | {lo: $lo, hi: ($lo + ((32 - ($s[1] | tonumber)) | p2) - 1)};
def crosses($o): cidr as $a | ($o | cidr) as $b | $a.lo <= $b.hi and $b.lo <= $a.hi;'

# subnets_ok <rótulo>: confere, no $OUT corrente, as três garantias da #707 — rede fora da oute sem subnet (alocação
# automática), subnet cruzando a 172.19.0.0/16 e subnet cruzando outra rede do compose
subnets_ok() {
  local rotulo="$1"
  check "subnets ($rotulo): toda rede fora a oute tem subnet fixa" \
    jqe '[.networks | to_entries[] | select(.key != "oute") | select((.value.ipam.config[0].subnet // "") == "")] == []' <<<"$OUT"
  check "subnets ($rotulo): nenhuma rede fora a oute cruza a 172.19.0.0/16" \
    jqe "$NETDEFS"' [.networks | to_entries[] | select(.key != "oute") | (.value.ipam.config[0].subnet // "") | crosses("172.19.0.0/16")] | any | not' <<<"$OUT"
  check "subnets ($rotulo): nenhuma subnet cruza outra rede" \
    jqe "$NETDEFS"' [.networks | to_entries[] | {n: .key, s: (.value.ipam.config[0].subnet // "")}] as $N
      | [$N[] as $a | $N[] as $b | select($a.n < $b.n) | ($a.s | crosses($b.s))] | any | not' <<<"$OUT"
  return 0
}

for pr in "" "agent-studio"; do
  OUT="$(compose_config "$pr" 2>"$TMP/cfg.err")" || OUT=""
  subnets_ok "profile '${pr:-nenhum}'"
done
OUT="$(compose_config "" COMPOSE_PROFILES=agent-studio,llm-proxy 2>"$TMP/cfg.err")" || OUT=""
subnets_ok "profiles agent-studio e llm-proxy"
# valores exatos: 172.16.x é privado e fica fora do pool padrão do Docker (que aloca /16s de 172.17.0.0/12 a 172.31),
# então rede de outro projeto não disputa a faixa; /24 chega para os 2-3 containers de cada rede
check "subnets: studio 172.16.0.0/24"               jqe '.networks.studio.ipam.config[0].subnet == "172.16.0.0/24"' <<<"$OUT"
check "subnets: memoria 172.16.1.0/24"              jqe '.networks.memoria.ipam.config[0].subnet == "172.16.1.0/24"' <<<"$OUT"
check "subnets: llm 172.16.2.0/24"                  jqe '.networks.llm.ipam.config[0].subnet == "172.16.2.0/24"' <<<"$OUT"
check "subnets: saida 172.16.3.0/24"                jqe '.networks.saida.ipam.config[0].subnet == "172.16.3.0/24"' <<<"$OUT"
check "subnets: a rede oute segue 172.19.0.0/16"    jqe '.networks.oute.ipam.config[0].subnet == "172.19.0.0/16"' <<<"$OUT"

# ---- 2g. OUTE_NET_SUBNET diferente do padrão (#230 + #707): a rede oute muda, as outras seguem fixas e nada se cruza
OUT="$(compose_config "agent-studio" OUTE_NET_SUBNET=10.200.0.0/16 OUTE_NET_GATEWAY=10.200.0.1 OUTE_NET_IP_RANGE=10.200.128.0/17 2>"$TMP/cfg.err")" || OUT=""
check "subnets: OUTE_NET_SUBNET troca a subnet da rede oute" \
  jqe '.networks.oute.ipam.config[0].subnet == "10.200.0.0/16"' <<<"$OUT"
check "subnets: OUTE_NET_IP_RANGE acompanha a subnet nova" \
  jqe '.networks.oute.ipam.config[0].ip_range == "10.200.128.0/17"' <<<"$OUT"
check "subnets: com OUTE_NET_SUBNET próprio, a memoria segue 172.16.1.0/24" \
  jqe '.networks.memoria.ipam.config[0].subnet == "172.16.1.0/24"' <<<"$OUT"
check "subnets: com OUTE_NET_SUBNET próprio, a rede oute não cruza as fixas" \
  jqe "$NETDEFS"' [.networks | to_entries[] | select(.key != "oute") | (.value.ipam.config[0].subnet // "") | crosses("10.200.0.0/16")] | any | not' <<<"$OUT"
subnets_ok "com OUTE_NET_SUBNET próprio"

# ---- 3. caso negativo: compose inválido
echo "services:" > "$TMP/broken.yaml"
echo "  agent:" >> "$TMP/broken.yaml"
echo "    image: oute-agent" >> "$TMP/broken.yaml"
echo "    networks: [oute, missing-network]" >> "$TMP/broken.yaml"
OUT="$(cd "$TMP" && env -u COMPOSE_PROFILES \
  OUTE_SSH_AUTHORIZED_KEYS=/dev/null \
  OUTE_AGENT_ENV_FILE=/dev/null \
  AGENT_STUDIO_INGEST_TOKEN=i \
  AGENT_STUDIO_READ_TOKEN=r \
  AGENT_STUDIO_SURREAL_PASS=s \
  docker compose --project-directory . -f broken.yaml config 2>&1)" && rc=0 || rc=$?
check "config com erro na estrutura: falha (rc != 0)" test "$rc" != 0

check_end
