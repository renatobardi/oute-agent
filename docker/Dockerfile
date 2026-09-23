# syntax=docker/dockerfile:1.7
# Oute Agent runtime — multi-arch (linux/arm64 primário, linux/amd64 opcional)
FROM ubuntu:24.04

ARG TARGETARCH
ARG NODE_MAJOR=22
ARG OUTE_USER=oute
ARG OUTE_UID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=America/Sao_Paulo

# --- base + ferramentas ------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-server sudo \
      build-essential pkg-config libssl-dev \
      python3 python3-pip python3-venv pipx \
      jq ripgrep fd-find fzf unzip zip tmux vim less htop tzdata locales \
      fuse3 \
    && rm -rf /var/lib/apt/lists/*

# Node (agentes npm: pi, claude-code, codex, firebase-tools, bitwarden cli)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*

# uv (python tooling)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# --- usuário -----------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u ${OUTE_UID} -s /bin/bash ${OUTE_USER} \
    && echo "${OUTE_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${OUTE_USER} \
    && mkdir -p /workspace /data/shared /data/ai-memory /run/sshd \
    && chown -R ${OUTE_USER}:${OUTE_USER} /workspace /data

# --- agentes e CLIs (npm) ----------------------------------------------------
RUN npm install -g --no-fund --no-audit \
      @mariozechner/pi-coding-agent \
      @anthropic-ai/claude-code \
      @openai/codex \
      firebase-tools \
      @bitwarden/cli \
    && npm cache clean --force

# --- binários ----------------------------------------------------------------
# herdr
RUN curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh
# goose (Block)
RUN curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh \
      | GOOSE_BIN_DIR=/usr/local/bin CONFIGURE=false bash
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
    && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip
# gcloud
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm || echo x86_64) \
    && curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${ARCH}.tar.gz" \
      | tar -xz -C /opt \
    && /opt/google-cloud-sdk/install.sh --quiet --usage-reporting=false --path-update=false \
    && ln -s /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud \
    && ln -s /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil
# oci cli
RUN pipx install --global oci-cli 2>/dev/null || PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install oci-cli
# ai-memory (Akita) — binário da release
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo aarch64 || echo x86_64) \
    && curl -fsSL "https://github.com/akitaonrails/ai-memory/releases/latest/download/ai-memory-linux-${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/ai-memory

# --- ssh ---------------------------------------------------------------------
COPY config/ssh/sshd_config /etc/ssh/sshd_config

# --- entrypoint --------------------------------------------------------------
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/oute-secrets.sh /usr/local/bin/oute-secrets
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/oute-secrets

USER ${OUTE_USER}
WORKDIR /workspace
ENV HOME=/home/${OUTE_USER} \
    PATH=/home/${OUTE_USER}/.local/bin:$PATH \
    AI_MEMORY_DATA_DIR=/data/ai-memory \
    OUTE_ROUTER_URL=http://jev-router:4000/v1

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
