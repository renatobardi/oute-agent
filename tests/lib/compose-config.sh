# Funções para testar docker compose config do docker/compose.yaml.
# compose_config <profile> [var=valor…]: rodando `docker compose config` com a profile (ou vazio), variáveis fictícias,
# e as opcionais passadas, imprime JSON resolvido. Requer docker compose.
COMPOSE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_ROOT="$(cd "$COMPOSE_LIB/../.." && pwd)"
compose_config() {
  local profile="$1"; shift
  cd "$COMPOSE_ROOT"
  env -u COMPOSE_PROFILES \
    OUTE_SSH_AUTHORIZED_KEYS=/dev/null \
    OUTE_AGENT_ENV_FILE=/dev/null \
    AGENT_STUDIO_INGEST_TOKEN=i \
    AGENT_STUDIO_READ_TOKEN=r \
    AGENT_STUDIO_SURREAL_PASS=s \
    "$@" \
    docker compose --project-directory . -f docker/compose.yaml \
    ${profile:+--profile "$profile"} \
    config --format json
}
