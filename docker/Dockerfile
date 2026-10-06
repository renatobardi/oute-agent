# syntax=docker/dockerfile:1.7
# Oute Agent runtime — multi-arch (linux/arm64 primário, linux/amd64 opcional)
FROM ubuntu:24.04

ARG TARGETARCH
ARG NODE_MAJOR=22
# bw >= 2026.9.0 quebra com Vaultwarden 1.37.x (dani-garcia/vaultwarden#7750); liberar quando o fix sair
ARG BW_CLI_VERSION=2026.8.0
ARG OUTE_USER=oute
# uid/gid próprios do container (lab#181): não coincidem com nenhum usuário do host (ubuntu=1001, oute-ops=992).
# Fixo em todos os hosts -> a mesma imagem do ghcr serve no oute-server e no Mac (#3), sem rebuild por uid.
ARG OUTE_UID=10001

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=America/Sao_Paulo \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    npm_config_update_notifier=false \
    npm_config_fund=false

# dieta (#11), só cortes seguros: dpkg não instala man/doc/info nem traduções além de en/pt
# (copyright é mantido por licença). Vale pra todo apt-get daqui pra frente.
RUN printf '%s\n' \
      'path-exclude=/usr/share/man/*' 'path-exclude=/usr/share/info/*' \
      'path-exclude=/usr/share/doc/*' 'path-include=/usr/share/doc/*/copyright' \
      'path-exclude=/usr/share/locale/*' 'path-include=/usr/share/locale/en*' 'path-include=/usr/share/locale/pt*' \
      'path-include=/usr/share/locale/locale.alias' \
      > /etc/dpkg/dpkg.cfg.d/01-oute-slim

# --- base + ferramentas ------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-server sudo \
      build-essential pkg-config libssl-dev \
      python3 python3-pip python3-venv python3-tomlkit pipx \
      jq ripgrep fd-find fzf unzip zip tmux vim less htop tzdata locales \
      fuse3 \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *\(en_US.UTF-8\|pt_BR.UTF-8\)/\1/' /etc/locale.gen && locale-gen

# Node (agentes npm: claude-code, codex, firebase-tools, bitwarden cli)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*

# uv (python tooling)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# --- usuário -----------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g ${OUTE_UID} ${OUTE_USER} \
    && useradd -m -u ${OUTE_UID} -g ${OUTE_UID} -s /bin/bash -p "*" ${OUTE_USER} \
    && echo "${OUTE_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${OUTE_USER} \
    && mkdir -p /workspace /data/shared /data/ai-memory /data/agent-studio /run/sshd \
    && chown -R ${OUTE_USER}:${OUTE_USER} /workspace /data

# --- agentes e CLIs (npm) ----------------------------------------------------
RUN --mount=type=cache,target=/root/.npm \
    npm install -g --no-fund --no-audit \
      firebase-tools \
      @bitwarden/cli@${BW_CLI_VERSION}
# claude/codex (#195): só uma cópia de reserva, fora do PATH. Cada agente vai para o home (oute-agents-install, na
# subida) e se atualiza sozinho lá; o shim usa esta cópia enquanto isso não acontece.
# Versões fixas (#200) e sha256 publicados pelos fornecedores (#199, ADR-01); conferir na release
# (oute-aidlc-ship-release, `scripts/agent-pins`):
# - CLAUDE_CODE_SHA256_*: `checksum` do binário no manifest.json da versão (downloads.claude.ai), que é o mesmo binário
#   do pacote npm por plataforma; o build confere o bin/claude.exe. O oute-agents-install instala o claude no home a
#   partir desta cópia (`claude install`).
# - CODEX_INSTALLER_SHA256: `digest` do asset install.sh da release rust-v<versão> do openai/codex. O oute-agents-install
#   baixa esse instalador e confere antes de rodar.
ARG CLAUDE_CODE_VERSION=2.1.285
ARG CLAUDE_CODE_SHA256_ARM64=24fac77749bed3d91365d6b6915aa4b824e14318ecb6bc17adbc192f01c9173d
ARG CLAUDE_CODE_SHA256_AMD64=33dad1ec615a2e08cc78b494f05c110e49916de2c79d78ec8799ebf46b233d29
ARG CODEX_VERSION=0.159.2
ARG CODEX_INSTALLER_SHA256=150e3cf675682efeaac115aa3747add3f27887896d04ce6d0b56478d8b428bf6
RUN --mount=type=cache,target=/root/.npm \
    npm install -g --prefix /opt/oute/agents --no-fund --no-audit \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
    && case "$TARGETARCH" in \
         arm64) sum="$CLAUDE_CODE_SHA256_ARM64" ;; \
         amd64) sum="$CLAUDE_CODE_SHA256_AMD64" ;; \
         *) echo "TARGETARCH sem sha256 do claude: $TARGETARCH" >&2; exit 1 ;; \
       esac \
    && echo "$sum  /opt/oute/agents/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe" | sha256sum -c -

# --- binários ----------------------------------------------------------------
# herdr
RUN curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh
# rclone
RUN curl -fsSL https://rclone.org/install.sh | bash
# gh
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*
# aws cli v2
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo aarch64 || echo x86_64) \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip \
    && rm -rf /usr/local/aws-cli/v2/*/dist/awscli/examples
# gcloud
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm || echo x86_64) \
    && curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${ARCH}.tar.gz" \
      | tar -xz -C /opt \
    && /opt/google-cloud-sdk/install.sh --quiet --usage-reporting=false --path-update=false \
    && ln -s /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud \
    && ln -s /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil \
    && rm -rf /opt/google-cloud-sdk/.install/.backup
# screenshot de UI e leitura de PDF (#472): Firefox ESR com versão e sha256 fixos (SHA256SUMS da release em
# ftp.mozilla.org; conferir na release junto dos outros pins) + libs de execução + poppler-utils (pdftotext/pdftoppm).
# O chromium do Ubuntu 24.04 é um shim de snap, e o Chrome for Testing não publica linux-arm64: por isso o Firefox.
ARG FIREFOX_VERSION=140.17.0esr
ARG FIREFOX_SHA256_ARM64=dd579f48405a7065f0f643ddb71a8de0f48a9d984c2783dee2ca173081850084
ARG FIREFOX_SHA256_AMD64=86d049070ad80b74d8e674793e22d28923b4a7a1da06b4d65402f91c67a10314
RUN apt-get update && apt-get install -y --no-install-recommends \
      fonts-dejavu-core fonts-liberation libasound2t64 libdbus-glib-1-2 \
      libgtk-3-0t64 libpci3 libx11-xcb1 libxcomposite1 \
      libxcursor1 libxdamage1 libxi6 libxrandr2 \
      libxt6t64 libxtst6 poppler-utils xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && case "$TARGETARCH" in \
         arm64) arch=aarch64; sum="$FIREFOX_SHA256_ARM64" ;; \
         amd64) arch=x86_64; sum="$FIREFOX_SHA256_AMD64" ;; \
         *) echo "TARGETARCH sem sha256 do firefox: $TARGETARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL --proto '=https' -o /tmp/firefox.tar.xz \
         "https://ftp.mozilla.org/pub/firefox/releases/${FIREFOX_VERSION}/linux-${arch}/en-US/firefox-${FIREFOX_VERSION}.tar.xz" \
    && echo "$sum  /tmp/firefox.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/oute && tar -xJf /tmp/firefox.tar.xz -C /opt/oute && rm -f /tmp/firefox.tar.xz \
    && /opt/oute/firefox/firefox --version
# oci cli
RUN --mount=type=cache,target=/root/.cache \
    pipx install --global oci-cli 2>/dev/null || PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install oci-cli
# ai-memory (Akita) — binário da release, versão fixa (igual à imagem do servidor no compose)
ARG AI_MEMORY_VERSION=2.5.2
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo aarch64 || echo x86_64) \
    && curl -fsSL "https://github.com/akitaonrails/ai-memory/releases/download/v${AI_MEMORY_VERSION}/ai-memory-linux-${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/ai-memory

# agent-studio (ADR-08, #185): ingestão OTLP -> DuckDB; serviço próprio no compose, só no oute-server.
# venv isolado, dependências fixadas por hash (requirements.txt gerado do requirements.in pelo uv), só wheels
# (nenhum setup.py roda no build)
COPY docker/agent-studio/requirements.txt /opt/agent-studio/requirements.txt
RUN uv venv /opt/agent-studio/venv --python /usr/bin/python3 \
    && uv pip install --no-cache --only-binary :all: --python /opt/agent-studio/venv/bin/python --require-hashes -r /opt/agent-studio/requirements.txt
COPY docker/agent-studio/agent_studio /opt/agent-studio/app/agent_studio

# --- ssh ---------------------------------------------------------------------
COPY config/ssh/sshd_config /etc/ssh/sshd_config

# --- entrypoint --------------------------------------------------------------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/codex_config.py /usr/local/lib/oute/codex_config.py
# addons (ADR-06): o entrypoint linka as skills do mount read-only /opt/oute/addons nas pastas dos agentes
COPY docker/addons-link /usr/local/lib/oute/addons-link
COPY scripts/oute-secrets.sh /usr/local/bin/oute-secrets
# canal de aprovação: o agente propõe, o humano aprova no host (`oute approve`)
COPY docker/oute-propose docker/oute-inbox /usr/local/bin/
# eventos operacionais do swarm e do canal (ADR-04, #124): emissor único, python3 stdlib, ao bucket e ao agent-studio (ADR-08)
COPY docker/oute-emit /usr/local/bin/
# proxy do LLM do ai-memory (#459, ADR-08): python3 stdlib, serviço llm-proxy do compose; consumo ao collector
COPY docker/oute-llm-proxy /usr/local/bin/
# agentes no home pelo instalador oficial de cada um (#195)
COPY docker/oute-agents-install /usr/local/bin/
COPY docker/agent-notes.md /usr/local/lib/oute/agent-notes.md
# uma sessão de agente = uma worktree + um branch (oute-task; wrapper interativo de claude/codex)
COPY docker/oute-task /usr/local/bin/
# seletor de modelo por sessão (ADR-02, #219): python3 stdlib; a tabela vem do mount /opt/oute/select (config/select)
COPY docker/oute-select /usr/local/bin/
# leitura do SonarCloud (#226): bash + curl + jq, só GET; o token vem do agent_env (SONAR_TOKEN)
COPY docker/oute-sonar /usr/local/bin/
# cota das assinaturas Claude e Codex (#346): bash + curl + jq, só GET, nunca escreve nem renova credencial
COPY docker/oute-quota /usr/local/bin/
# screenshot de UI (#472): bash; o Firefox fica em /opt/oute/firefox
COPY docker/oute-shot /usr/local/bin/
# conferência de referência de um texto (#485): python3 stdlib, só `gh api` (GET) e `git`
COPY docker/oute-refcheck /usr/local/bin/
# regressão dos agentes, nível 1 (#366): bash + jq, tarefas headless em Haiku; as tarefas ficam em /usr/local/lib/oute/regression
COPY docker/oute-regression /usr/local/bin/
COPY docker/regression/ /usr/local/lib/oute/regression/
# sessões paralelas coordenadas (oute-swarm; prompts do dispatcher e das sessões)
COPY docker/oute-swarm /usr/local/bin/
COPY docker/swarm.md docker/swarm-worker.md docker/step-review.md /usr/local/lib/oute/
# guia de comandos: `oute help` no container (o mesmo arquivo que o `oute help` do host)
COPY docker/comandos.md /usr/local/lib/oute/comandos.md
COPY docker/oute-container /usr/local/bin/oute
COPY docker/agent-wrap.sh /usr/local/lib/oute/agent-wrap.sh
COPY docker/shims/oute-agent-shim /usr/local/lib/oute/shims/oute-agent-shim
# trava do `gh pr merge` de PR de rodada aberta (#538) e a do pkill/killall (hook do Claude + regras do Codex)
COPY docker/shims/gh /usr/local/lib/oute/shims/gh
COPY docker/oute-guard-kill docker/codex-kill.rules /usr/local/lib/oute/
# trava do `git` no checkout principal de /workspace/<repo>: checkout, switch, commit, merge e rebase recusados (#651)
COPY docker/shims/git /usr/local/lib/oute/shims/git
# `pi` continua como shim só para responder que o Pi saiu do stack (#217), mesmo com o binário antigo em ~/.local/bin
RUN cd /usr/local/lib/oute/shims && chmod 755 oute-agent-shim gh git && chmod 755 /usr/local/lib/oute/oute-guard-kill \
    && for a in claude codex pi; do ln -sf oute-agent-shim "$a"; done
RUN chmod +x /usr/local/lib/oute/addons-link /usr/local/bin/entrypoint.sh /usr/local/bin/oute-secrets \
      /usr/local/bin/oute-propose /usr/local/bin/oute-inbox /usr/local/bin/oute-emit /usr/local/bin/oute-agents-install \
      /usr/local/bin/oute-task /usr/local/bin/oute-select /usr/local/bin/oute-sonar /usr/local/bin/oute-quota /usr/local/bin/oute-regression \
      /usr/local/bin/oute-shot /usr/local/bin/oute-refcheck /usr/local/bin/oute-swarm /usr/local/bin/oute

USER ${OUTE_USER}
WORKDIR /workspace
ENV HOME=/home/${OUTE_USER} \
    PATH=/usr/local/lib/oute/shims:/home/${OUTE_USER}/.local/bin:$PATH \
    AI_MEMORY_DATA_DIR=/data/ai-memory \
    OUTE_CODEX_VERSION=${CODEX_VERSION} \
    OUTE_CODEX_INSTALLER_SHA256=${CODEX_INSTALLER_SHA256}

# ARG da versão só aqui no fim: ARG declarado antes de um RUN vira env dele e o bump de versão
# invalidava o cache de todos os passos pesados (release = rebuild completo de ~7 min)
ARG OUTE_VERSION=0.0.0-dev
LABEL org.opencontainers.image.title="oute-agent" \
      org.opencontainers.image.version="${OUTE_VERSION}" \
      org.opencontainers.image.source="https://github.com/renatobardi/oute-agent" \
      org.opencontainers.image.licenses="MIT"
ENV OUTE_VERSION=${OUTE_VERSION}

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
