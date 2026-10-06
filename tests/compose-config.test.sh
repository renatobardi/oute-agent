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
