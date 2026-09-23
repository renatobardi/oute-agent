#!/usr/bin/env bash
# Oute Agent — entrypoint
# serve: segredos (Vaultwarden) -> integrações -> ai-memory hooks -> sshd + herdr server
set -euo pipefail

log() { printf '[oute] %s\n' "$*" >&2; }

MODE="${1:-serve}"

# ---------------------------------------------------------------- 1. segredos
# Vaultwarden é mandatório. Sem ele, o container não sobe em modo serve.
if [[ "$MODE" == "serve" ]]; then
  log "carregando segredos do Vaultwarden (${BW_SERVER:-vault.oute.pro})"
  SECRETS_ENV="$(oute-secrets export)" || { log "FALHA ao obter segredos do Vaultwarden"; exit 1; }
  eval "$SECRETS_ENV"; unset SECRETS_ENV
fi

# ---------------------------------------------------------------- 2. integrações
setup_integrations() {
  mkdir -p "$HOME/.config" "$HOME/.ssh" "$HOME/.oci" "$HOME/.aws" "$HOME/.config/gcloud"

  # GitHub
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s' "$GH_TOKEN" | gh auth login --with-token 2>/dev/null || true
    gh auth setup-git 2>/dev/null || true
    git config --global user.name  "${GIT_USER_NAME:-Renato Bardi}"
    git config --global user.email "${GIT_USER_EMAIL:-renato.bardi@outlook.com}"
  fi

  # Oracle Cloud
  if [[ -n "${OCI_KEY_PEM:-}" ]]; then
    printf '%s' "$OCI_KEY_PEM" > "$HOME/.oci/oci_api_key.pem"; chmod 600 "$HOME/.oci/oci_api_key.pem"
    cat > "$HOME/.oci/config" <<EOF
[DEFAULT]
user=${OCI_USER_OCID}
fingerprint=${OCI_FINGERPRINT}
tenancy=${OCI_TENANCY_OCID}
region=${OCI_REGION:-sa-saopaulo-1}
key_file=$HOME/.oci/oci_api_key.pem
EOF
    chmod 600 "$HOME/.oci/config"
  fi

  # AWS
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    cat > "$HOME/.aws/credentials" <<EOF
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF
    printf '[default]\nregion=%s\n' "${AWS_DEFAULT_REGION:-sa-east-1}" > "$HOME/.aws/config"
    chmod 600 "$HOME/.aws/credentials"
  fi

  # GCP + Firebase (service account JSON)
  if [[ -n "${GCP_SA_JSON:-}" ]]; then
    printf '%s' "$GCP_SA_JSON" > "$HOME/.config/gcloud/sa.json"; chmod 600 "$HOME/.config/gcloud/sa.json"
    export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/sa.json"
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" -q 2>/dev/null || true
  fi
  # firebase-tools usa GOOGLE_APPLICATION_CREDENTIALS ou FIREBASE_TOKEN
}

# ---------------------------------------------------------------- 3. agentes
setup_agents() {
  # Pi -> jev-router via provider custom (~/.pi/agent/models.json). Codex/Claude Code ficam com assinatura própria.
  mkdir -p "$HOME/.pi/agent"
  export OUTE_ROUTER_KEY="${LITELLM_MASTER_KEY:-sk-oute-local}"
  cat > "$HOME/.pi/agent/models.json" <<EOF
{
  "providers": {
    "oute": {
      "baseUrl": "${OUTE_ROUTER_URL}",
      "apiKey": "\$OUTE_ROUTER_KEY",
      "api": "openai-completions",
      "models": [
        { "id": "jev-router",    "name": "Jev router (auto)", "contextWindow": 200000,  "maxTokens": 32000 },
        { "id": "claude-sonnet", "name": "Claude Sonnet",     "contextWindow": 200000,  "maxTokens": 64000 },
        { "id": "claude-opus",   "name": "Claude Opus",       "contextWindow": 200000,  "maxTokens": 32000 },
        { "id": "gpt-5",         "name": "GPT-5",             "contextWindow": 400000,  "maxTokens": 128000 },
        { "id": "gemini-pro",    "name": "Gemini Pro",        "contextWindow": 1000000, "maxTokens": 65000 },
        { "id": "qwen-coder",    "name": "Qwen Coder",        "contextWindow": 262000,  "maxTokens": 65000 }
      ]
    }
  }
}
EOF
  [[ -f "$HOME/.pi/agent/settings.json" ]] || printf '{ "defaultProvider": "oute", "defaultModel": "jev-router" }\n' > "$HOME/.pi/agent/settings.json"

  # Goose -> jev-router
  mkdir -p "$HOME/.config/goose"
  cat > "$HOME/.config/goose/config.yaml" <<EOF
GOOSE_PROVIDER: openai
GOOSE_MODEL: jev-router
OPENAI_HOST: ${OUTE_ROUTER_URL%/v1}
EOF
  export OPENAI_API_KEY="${LITELLM_MASTER_KEY:-sk-oute-local}"

  # ai-memory: hooks + MCP em cada agente (idempotente)
  if command -v ai-memory >/dev/null; then
    local url="${AI_MEMORY_SERVER_URL:-http://ai-memory:49374}"
    local tok=(); [[ -n "${AI_MEMORY_AUTH_TOKEN:-}" ]] && tok=(--auth-token "$AI_MEMORY_AUTH_TOKEN")
    IFS=',' read -ra AGENTS <<< "${OUTE_AGENTS:-pi,claude-code,codex,goose}"
    for a in "${AGENTS[@]}"; do
      ai-memory install-mcp   --client "$a" --apply --server-url "$url/mcp" "${tok[@]}" >/dev/null 2>&1 || log "ai-memory mcp: $a não suportado"
      ai-memory install-hooks --agent  "$a" --apply --server-url "$url"     "${tok[@]}" >/dev/null 2>&1 || log "ai-memory hooks: $a não suportado"
    done
  fi
}

# ---------------------------------------------------------------- 4. ssh
setup_ssh() {
  if [[ -f /etc/oute/authorized_keys ]]; then
    cp /etc/oute/authorized_keys "$HOME/.ssh/authorized_keys"
    chmod 700 "$HOME/.ssh"; chmod 600 "$HOME/.ssh/authorized_keys"
  else
    log "AVISO: /etc/oute/authorized_keys ausente — ssh vai recusar tudo"
  fi
  # host key persistida no volume oute-home: sobrevive a down/rebuild, known_hosts do cliente não quebra
  mkdir -p "$HOME/.oute/ssh"
  [[ -f "$HOME/.oute/ssh/ssh_host_ed25519_key" ]] || ssh-keygen -q -t ed25519 -N '' -f "$HOME/.oute/ssh/ssh_host_ed25519_key"
  sudo mkdir -p /etc/ssh/keys
  sudo cp "$HOME/.oute/ssh/ssh_host_ed25519_key" /etc/ssh/keys/ && sudo chmod 600 /etc/ssh/keys/ssh_host_ed25519_key && sudo chown root:root /etc/ssh/keys/ssh_host_ed25519_key
}

# ---------------------------------------------------------------- run
case "$MODE" in
  serve)
    setup_integrations
    setup_agents
    setup_ssh
    # env pros logins ssh
    env | grep -E '^(OPENROUTER|GH_|OUTE_|AI_MEMORY|OPENAI|GOOGLE_APP|AWS_|LITELLM|BW_SESSION)' \
      | sed 's/^/export /' > "$HOME/.oute_env"
    # .bashrc do Ubuntu dá return em shell não-interativo; .profile cobre login (ssh cmd / bash -l)
    for rc in "$HOME/.profile" "$HOME/.bashrc"; do
      grep -q '.oute_env' "$rc" 2>/dev/null || printf '%s\n%s\n' '[ -f ~/.oute_env ] && . ~/.oute_env' "$(cat "$rc" 2>/dev/null)" > "$rc"
    done

    log "iniciando herdr server"
    herdr server start >/dev/null 2>&1 || herdr server >/dev/null 2>&1 &
    log "iniciando sshd :2222"
    exec sudo /usr/sbin/sshd -D -e
    ;;
  shell) exec bash -l ;;
  *)     exec "$@" ;;
esac
