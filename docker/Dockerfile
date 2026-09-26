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

# Node (agentes npm: pi, claude-code, codex, firebase-tools, bitwarden cli)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*

# uv (python tooling)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# --- usuário -----------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd -g ${OUTE_UID} ${OUTE_USER} \
    && useradd -m -u ${OUTE_UID} -g ${OUTE_UID} -s /bin/bash -p "*" ${OUTE_USER} \
    && echo "${OUTE_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${OUTE_USER} \
    && mkdir -p /workspace /data/shared /data/ai-memory /run/sshd \
    && chown -R ${OUTE_USER}:${OUTE_USER} /workspace /data

# --- agentes e CLIs (npm) ----------------------------------------------------
RUN --mount=type=cache,target=/root/.npm \
    npm install -g --no-fund --no-audit \
      @earendil-works/pi-coding-agent \
      @anthropic-ai/claude-code \
      @openai/codex \
      firebase-tools \
      @bitwarden/cli@${BW_CLI_VERSION}

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
# oci cli
RUN --mount=type=cache,target=/root/.cache \
    pipx install --global oci-cli 2>/dev/null || PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install oci-cli
# ai-memory (Akita) — binário da release, versão fixa (igual à imagem do servidor no compose)
ARG AI_MEMORY_VERSION=2.4.1
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo aarch64 || echo x86_64) \
    && curl -fsSL "https://github.com/akitaonrails/ai-memory/releases/download/v${AI_MEMORY_VERSION}/ai-memory-linux-${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/ai-memory

# --- ssh ---------------------------------------------------------------------
COPY config/ssh/sshd_config /etc/ssh/sshd_config

# --- entrypoint --------------------------------------------------------------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/codex_config.py /usr/local/lib/oute/codex_config.py
COPY scripts/oute-secrets.sh /usr/local/bin/oute-secrets
# canal de aprovação: o agente propõe, o humano aprova no host (`oute approve`)
COPY docker/oute-propose docker/oute-inbox /usr/local/bin/
COPY docker/agent-notes.md /usr/local/lib/oute/agent-notes.md
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/oute-secrets /usr/local/bin/oute-propose /usr/local/bin/oute-inbox

USER ${OUTE_USER}
WORKDIR /workspace
ENV HOME=/home/${OUTE_USER} \
    PATH=/home/${OUTE_USER}/.local/bin:$PATH \
    AI_MEMORY_DATA_DIR=/data/ai-memory \
    OUTE_ROUTER_URL=http://jev-router:4000/v1

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
