#!/usr/bin/env bash
# Oute Agent — entrypoint
# serve: segredos (Vaultwarden) -> integrações -> ai-memory hooks -> sshd + herdr server
set -euo pipefail

log() { printf '[oute] %s\n' "$*" >&2; }

MODE="${1:-serve}"

# ---------------------------------------------------------------- 1. segredos
# Vaultwarden é mandatório, mas quem fala com ele é o HOST (`oute up`). O container recebe só os valores
# da pasta oute-agent em /run/secrets/agent_env — nenhum acesso ao cofre (#6: agentes em yolo + injeção de
# prompt não podem ler segredos de outros projetos nem do oute-admin).
SECRETS_FILE=/run/secrets/agent_env
if [[ "$MODE" == "serve" ]]; then
  [[ -s "$SECRETS_FILE" ]] || { log "FALHA: $SECRETS_FILE ausente (rode ./scripts/oute up no host)"; exit 1; }
  # o arquivo é 0600 do usuário do host e o container tem uid próprio (lab#181): lê via sudo, uma vez
  secrets="$(cat "$SECRETS_FILE" 2>/dev/null || sudo cat "$SECRETS_FILE")" \
    || { log "FALHA: não consegui ler $SECRETS_FILE"; exit 1; }
  # só linhas `export NOME=...` (formato do oute-secrets export); qualquer outra coisa é recusada
  if grep -qvE '^export [A-Za-z_][A-Za-z0-9_]*=' <<<"$secrets"; then
    log "FALHA: $SECRETS_FILE com formato inesperado"; exit 1
  fi
  # shellcheck disable=SC1090
  . <(printf '%s\n' "$secrets")
  log "segredos carregados ($(grep -c . <<<"$secrets") variáveis da pasta oute-agent)"
  unset secrets
  # resíduo das versões <= 0.6.x: sessão/estado do bw no volume home
  rm -rf "$HOME/.oute/bw_session" "$HOME/.config/Bitwarden CLI" 2>/dev/null || true
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
    # PEM colado em custom field do Vaultwarden perde as quebras de linha: reconstrói (64 col.);
    # só o trecho BEGIN..END (o PEM do console da OCI traz "OCI_API_KEY" depois do END)
    local flat kind body
    flat="$(tr '\r\n' '  ' <<<"$OCI_KEY_PEM")"
    kind="$(grep -oE 'BEGIN [A-Z ]*PRIVATE KEY' <<<"$flat" | head -1 | sed 's/^BEGIN //')"; kind="${kind:-PRIVATE KEY}"
    body="$(sed -E 's/.*-----BEGIN [A-Z ]+-----//; s/-----END [A-Z ]+-----.*//' <<<"$flat" | tr -d ' \t')"
    ( umask 077; printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\nOCI_API_KEY\n' "$kind" "$(fold -w64 <<<"$body")" "$kind" > "$HOME/.oci/oci_api_key.pem" )
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

  # OCI Object Storage (S3): remote "oci" do rclone só por env (item oci-storage do vault; ADR-03)
  if [[ -n "${OCI_S3_ACCESS_KEY:-}" ]]; then
    export RCLONE_CONFIG_OCI_TYPE=s3 RCLONE_CONFIG_OCI_PROVIDER=Other \
      RCLONE_CONFIG_OCI_ACCESS_KEY_ID="$OCI_S3_ACCESS_KEY" RCLONE_CONFIG_OCI_SECRET_ACCESS_KEY="$OCI_S3_SECRET_KEY" \
      RCLONE_CONFIG_OCI_ENDPOINT="$OCI_S3_ENDPOINT" RCLONE_CONFIG_OCI_REGION="$OCI_S3_REGION" \
      RCLONE_CONFIG_OCI_FORCE_PATH_STYLE=true RCLONE_CONFIG_OCI_NO_CHECK_BUCKET=true
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
  # modelos = perfis gerados por `oute router-sync` (config/litellm/candidates.json)
  local models='[{"id":"jev-router","name":"Jev router (auto)","contextWindow":200000,"maxTokens":32000}]'
  [[ -s /etc/oute/candidates.json ]] && models="$(cat /etc/oute/candidates.json)"
  jq -n --arg url "$OUTE_ROUTER_URL" --argjson models "$models" '{
    providers: { oute: { baseUrl: $url, apiKey: "$OUTE_ROUTER_KEY", api: "openai-completions",
                         headers: { "X-Oute-Agent": "pi" }, models: $models } }
  }' > "$HOME/.pi/agent/models.json"
  # força provider/model default (merge, preserva o resto do settings.json)
  local sj="$HOME/.pi/agent/settings.json"; [[ -s "$sj" ]] || echo '{}' > "$sj"
  jq '. + {defaultProvider:"oute", defaultModel:"jev-router"}' "$sj" > "$sj.tmp" && mv "$sj.tmp" "$sj"

  # ai-memory: hooks + MCP em cada agente (idempotente)
  if command -v ai-memory >/dev/null; then
    local url="${AI_MEMORY_SERVER_URL:-http://ai-memory:49374}"
    local tok=(); [[ -n "${AI_MEMORY_AUTH_TOKEN:-}" ]] && tok=(--auth-token "$AI_MEMORY_AUTH_TOKEN")
    IFS=',' read -ra AGENTS <<< "${OUTE_AGENTS:-pi,claude-code,codex}"
    for a in "${AGENTS[@]}"; do
      ai-memory install-mcp   --client "$a" --apply --server-url "$url/mcp" "${tok[@]}" >/dev/null 2>&1 || log "ai-memory mcp: $a não suportado"
      ai-memory install-hooks --agent  "$a" --apply --server-url "$url"     "${tok[@]}" >/dev/null 2>&1 || log "ai-memory hooks: $a não suportado"
    done
  fi

  # Codex: sandbox_mode + [otel] mesclados de forma ESTRUTURAL (tomlkit), preservando o que o ai-memory
  # escreve (mcp_servers). Antes era sed entre marcadores e apagava a seção do ai-memory (0.5.3–0.5.7).
  mkdir -p "$HOME/.codex"
  python3 /usr/local/lib/oute/codex_config.py "$HOME/.codex/config.toml" "${OUTE_HOST:-${OUTE_HOSTNAME:-oute}}" "${OUTE_AGENT_YOLO:-1}" \
    || log "AVISO: falha ao mesclar ~/.codex/config.toml"
  # Claude Code yolo (ADR-01): sem prompts de permissão DENTRO do container (fronteira = container).
  # Merge via jq: preserva hooks do ai-memory e o resto do settings.json. OUTE_AGENT_YOLO=0 desliga.
  mkdir -p "$HOME/.claude"; local cs="$HOME/.claude/settings.json"; [[ -s "$cs" ]] || echo '{}' > "$cs"
  if [[ "${OUTE_AGENT_YOLO:-1}" == 1 ]]; then
    jq '.permissions = ((.permissions // {}) + {defaultMode:"bypassPermissions"}) | .skipDangerousModePermissionPrompt = true' "$cs" > "$cs.tmp"
  else
    jq 'del(.permissions.defaultMode) | del(.skipDangerousModePermissionPrompt)' "$cs" > "$cs.tmp"
  fi
  mv "$cs.tmp" "$cs"

  # o ai-memory deixa um .bak-<ts> a cada --apply: fica o MAIS ANTIGO (original, única cópia do que
  # havia antes de qualquer edição automática) + os 2 mais recentes (atual + anterior, #12)
  local base; for base in "$HOME/.codex/config.toml" "$HOME/.codex/hooks.json"; do
    # `|| true`: home novo (sem .bak) -> ls sai 2 e, com pipefail + set -e, derrubava o entrypoint (loop de restart, #3)
    { ls -1t "$base".bak-* 2>/dev/null || true; } | sed '1,2d;$d' | xargs -r rm -f
  done
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

  # Acesso ao HOST (lab#178): usuário oute-ops (sem lxd/docker/sudo; sudo só p/ allowlist), chave própria
  # do container, aceita no host só vindo de 172.19.0.5. Pública -> lab: servers/oute-server/access/oute-ops.pub
  local key="$HOME/.ssh/oute-ops_ed25519"
  [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N '' -C "${OUTE_INSTANCE:-oute-agent}@${OUTE_HOST:-${OUTE_HOSTNAME:-oute}}" -f "$key"
  mkdir -p "$HOME/.ssh/config.d"; chmod 700 "$HOME/.ssh"
  cat > "$HOME/.ssh/config.d/oute-host.conf" <<EOF
# gerado pelo entrypoint (lab#178) — não editar
Host oute-server oute-host
  HostName ${OUTE_NET_GATEWAY:-172.19.0.1}
  HostKeyAlias oute-server
  User oute-ops
  IdentityFile $key
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  # Include no topo: no ssh_config vale o primeiro valor encontrado -> este bloco ganha de qualquer Host antigo
  touch "$HOME/.ssh/config"
  grep -qxF 'Include ~/.ssh/config.d/*.conf' "$HOME/.ssh/config" \
    || { printf '%s\n\n' 'Include ~/.ssh/config.d/*.conf'; cat "$HOME/.ssh/config"; } > "$HOME/.ssh/config.tmp"
  [[ -f "$HOME/.ssh/config.tmp" ]] && mv "$HOME/.ssh/config.tmp" "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config" "$HOME/.ssh/config.d/oute-host.conf"
  log "chave do container p/ o host (oute-ops): $(cat "$key.pub")"
}

# ---------------------------------------------------------------- run
case "$MODE" in
  serve)
    setup_integrations
    setup_agents
    setup_ssh
    # env pros logins ssh
    # declare -px cita os valores (espaços, vírgulas, '=' não quebram o source)
    declare -px | grep -E '^declare -x (OPENROUTER|GH_|OUTE_|AI_MEMORY|GOOGLE_APP|AWS_|LITELLM|RCLONE_CONFIG_|OTEL_|CLAUDE_CODE_)' \
      > "$HOME/.oute_env"
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
