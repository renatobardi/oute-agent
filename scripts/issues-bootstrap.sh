#!/usr/bin/env bash
# Cria labels + issues do backlog pós-v0.1.0 em renatobardi/oute-agent. Idempotente (pula título já existente).
# uso: gh auth status && ./scripts/issues-bootstrap.sh
set -euo pipefail
R=renatobardi/oute-agent

lbl() { gh label create "$1" --repo "$R" --color "$2" --description "$3" 2>/dev/null || true; }
lbl tema        0E8A16 "Tema de arquitetura (bloco de trabalho)"
lbl infra       1D76DB "Infra, compose, Dockerfile, host"
lbl agentes     5319E7 "Pi, Claude Code, Codex, Goose, herdr"
lbl seguranca   B60205 "Segredos, Vaultwarden, acesso"
lbl ci          FBCA04 "GitHub Actions, build, release"
lbl bug         D93F0B "Algo quebrado"
lbl debito      C2E0C6 "Débito técnico / follow-up"

issue() { # titulo, labels, corpo
  if gh issue list --repo "$R" --search "\"$1\" in:title" --state all --json title -q '.[].title' | grep -qxF "$1"; then
    echo "skip: $1"; return
  fi
  gh issue create --repo "$R" --title "$1" --label "$2" --body "$3" >/dev/null && echo "ok:   $1"
}

issue "Tema 2 — Storage comum (OCI Object Storage + rclone)" "tema,infra" "$(cat <<'EOF'
Decidido no ADR-01: bucket `oute-shared` no OCI Object Storage, montado via rclone em `~/.oute/shared` no host → `/data/shared` no container, nos dois hosts (Mac e VPC).

**Escopo**
- [ ] Criar bucket + credenciais S3-compat (Customer Secret Key) no OCI; guardar no Vaultwarden (item `oci`, campos `OCI_S3_ACCESS_KEY` / `OCI_S3_SECRET_KEY`).
- [ ] `oute up`: gerar `~/.config/rclone/rclone.conf` a partir do vault (remote `oci`) antes do `mount_shared`.
- [ ] Decidir `rclone mount` (vfs-cache full) vs `bisync`; documentar layout de `/data/shared`.
- [ ] Systemd/launchd pra manter o mount após reboot.
- [ ] ADR-02 no Project.

Ref: `arquitetura/01-runtime-container.md` (Project).
EOF
)"

issue "CI: build multi-arch e push da imagem no ghcr em tag v*" "ci" "$(cat <<'EOF'
Hoje cada host faz `oute build` (~6 min). Objetivo: `git push origin vX.Y.Z` → GitHub Actions builda `linux/arm64` (+ `amd64` opcional) e publica `ghcr.io/renatobardi/oute-agent:X.Y.Z` e `:latest`.

- [ ] `.github/workflows/release.yml` com `docker/build-push-action`, QEMU pra arm64 (ou runner arm nativo).
- [ ] `OUTE_VERSION` e `OUTE_UID` como build-args (uid default 1000; hosts com uid ≠ 1000 continuam buildando local ou usamos `--user` no compose).
- [ ] `oute up` faz `pull` se a imagem da versão existir no ghcr, senão build.
- [ ] Permissão `packages: write` no workflow; repo privado → ghcr privado, `docker login ghcr.io` no host via `GH_TOKEN` do vault.
EOF
)"

issue "Testar runtime no MacBook (Apple Silicon)" "infra" "$(cat <<'EOF'
Validado só no oute-server até agora.

- [ ] Docker Desktop ou OrbStack; `bw` nativo (`npm i -g @bitwarden/cli@2026.8.0`) ou o wrapper da imagem.
- [ ] `.env`: `OUTE_HOSTNAME=oute-mac`, `OUTE_UID=$(id -u)` (macOS = 501 → rebuild da camada de usuário).
- [ ] Mac está na tailnet: `vault.oute.pro` resolve pro IP Tailscale sozinho? Se não, `OUTE_VAULT_HOST_IP` cobre.
- [ ] Bind mount de `~/.ssh/id_ed25519.pub` e `~/.oute/*` com uid 501.
- [ ] Anotar diferenças Mac × VPC no README.
EOF
)"

issue "ai-memory: MCP para Pi e Goose não é instalado pelo install-mcp" "agentes,debito" "$(cat <<'EOF'
Log do entrypoint:
```
[oute] ai-memory mcp: pi não suportado
[oute] ai-memory mcp: goose não suportado
[oute] ai-memory hooks: goose não suportado
```
Hooks do Pi funcionam (handoff entre sessões confirmado). Falta o MCP (busca na memória como tool).

- [ ] Ver se ai-memory 2.4 tem `--client` genérico / config manual pra Pi (`~/.pi/agent/mcp.json`?) e Goose (`~/.config/goose/config.yaml` extensions).
- [ ] Escrever a config no entrypoint.
- [ ] Confirmar endpoint de health do ai-memory (`/health` responde vazio; usar `ai-memory status` no healthcheck?).
EOF
)"

issue "Validar hooks do ai-memory no Claude Code e no Codex" "agentes" "$(cat <<'EOF'
`install-hooks --agent claude-code|codex --apply` rodou sem erro, mas só o Pi foi testado de verdade.

- [ ] Sessão no Claude Code → encerrar → nova sessão lembra do contexto?
- [ ] Mesmo teste no Codex.
- [ ] Handoff cruzado: começar no Claude Code, continuar no Pi.
- [ ] Ver web UI do ai-memory (`/web`) — expor via `oute ssh -L 49374:ai-memory:49374`.
EOF
)"

issue "Segredos: identidade de máquina (OpenBao/AppRole) em vez de master password" "seguranca,tema" "$(cat <<'EOF'
Hoje: Vaultwarden + `BW_SESSION` em cache (`~/.oute/bw_session`). Funciona, mas exige a master password humana na 1ª vez e o cache é um segredo em disco.

Proposta: OpenBao (fork do Vault) como LXC no oute-server, AppRole por host (Mac, VPC), segredos do runtime lá; Vaultwarden fica só pra uso humano. Alternativa mais leve: sops+age com chave por máquina no repo.

- [ ] Avaliar OpenBao no lab (LXC, vhost tailnet-only, backup).
- [ ] `oute-secrets` com backend plugável (`bw` | `bao` | `sops`).
- [ ] ADR.
EOF
)"

issue "bw CLI fixado em 2026.8.0 — liberar quando Vaultwarden suportar user-key-id" "seguranca,debito" "$(cat <<'EOF'
`bw` ≥ 2026.9.0 crasha no unlock contra Vaultwarden 1.37.x (`KeyIdBackfillError`, 404 em `/api/accounts/key-management/user-key-id`). Pinado via `ARG BW_CLI_VERSION=2026.8.0` no Dockerfile.

- [ ] Acompanhar dani-garcia/vaultwarden#7750 / PR #7693.
- [ ] Quando o Vaultwarden do oute-server for atualizado com o fix, remover o pin (ou subir pra versão testada).
EOF
)"

issue "oute-server: instalar docker-buildx (warning no compose build)" "infra,debito" "$(cat <<'EOF'
`Docker Compose is configured to build using Bake, but buildx isn't installed` a cada build. Funciona, mas usa o builder legado.

- [ ] `sudo apt install docker-buildx` (ou plugin oficial) no oute-server.
- [ ] Registrar no repo `lab` (inventory/host_services) se for convenção de lá.
EOF
)"

issue "Ponte Mac: scripts perdem +x e sobra .git/*.lock" "debito" "$(cat <<'EOF'
Quando arquivos são gravados via Claude/ponte no Mac: modo 644 (scripts perdem executável) e `.git/index.lock` / `HEAD.lock` ficam pra trás.

- [ ] Hook `core.fileMode` + `git update-index --chmod=+x` nos scripts, ou um `make fmt` que reaplica `chmod +x scripts/* docker/entrypoint.sh`.
- [ ] Pre-commit simples: falha se `scripts/*` sem +x.
EOF
)"

issue "Router: revisar catálogo de modelos e custos em router.yaml/config.yaml" "agentes,debito" "$(cat <<'EOF'
Os ids em `config/litellm/config.yaml` (ex.: `anthropic/claude-sonnet-4.5`, `openai/gpt-5`) e os custos em `router.yaml` foram chutados no scaffold. Validar contra o catálogo real do OpenRouter e ajustar as descrições que o Jev lê.

- [ ] `curl https://openrouter.ai/api/v1/models` e conferir ids/preços.
- [ ] Testar 5–6 prompts de complexidades diferentes e ver `chosen=… via=jev` no log.
- [ ] Considerar expor `oute router-log` (tail do jev-router filtrado).
EOF
)"

echo "pronto: https://github.com/$R/issues"
