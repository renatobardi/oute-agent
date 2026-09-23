# oute-agent

Runtime container para agentes de código (herdr + Pi + Claude Code + Codex + Goose), com roteamento de modelo em 2 etapas (Jev escolhe o perfil, OpenRouter escolhe o modelo), memória compartilhada via ai-memory e segredos no Vaultwarden. Roda em ARM: MacBook (Apple Silicon) e VPC Oracle Cloud.

Arquitetura e decisões: Project "Oute Agent" no Claude (`arquitetura/01-runtime-container.md`, `arquitetura/02-roteamento-modelos.md`). Backlog: issues deste repo.

## Layout

```
docker/          Dockerfile (multi-arch), compose.yaml, entrypoint.sh
config/litellm/  policy.yaml (FONTE do router, editar aqui), jev_hook.py
                 router.yaml, config.yaml, candidates.json, catalog.json  <- GERADOS por `oute router-sync` (fora do git)
config/ssh/      sshd_config
scripts/         oute (CLI do host), oute-secrets.sh (Vaultwarden -> env), router_sync.py, release
secrets/         README com a convenção do vault (sem valores)
```

## Pré-requisitos (fora do repo)

**Contas / serviços**
- **Vaultwarden** (`vault.oute.pro`): pasta `oute-agent` com o item `openrouter` (campo `OPENROUTER_API_KEY`); demais itens em `secrets/README.md`. API key da conta (client_id/secret).
- **OpenRouter**: guardrail "oute-agent guardrail - core" aplicado à key do oute-agent — allowlist de provedores, ZDR, sem treino, orçamento. O `config/litellm/policy.yaml` **espelha** esse guardrail; se mudar um, mude o outro. Numa conta nova, recrie o guardrail antes do primeiro `up`.
- **GitHub**: chave SSH do host cadastrada (clone do repo privado).

**No host**
- Docker + Compose (Mac: Docker Desktop/OrbStack). `docker-buildx` recomendado.
- `jq`, `crontab`. `bw` opcional (sem ele, usa o `bw` da própria imagem).
- `~/.oute/bw_client.env` com `BW_CLIENTID` / `BW_CLIENTSECRET` (`chmod 600`).
- `~/.ssh/id_ed25519.pub` (entra no container).
- `.env` a partir de `.env.example`: `OUTE_HOSTNAME`, `OUTE_UID=$(id -u)`, `OUTE_VAULT_HOST_IP` (IP Tailscale do vault).
- opcional: `rclone` com remote `oci` (bucket `oute-shared`).

## Deploy novo

```bash
git clone git@github.com:renatobardi/oute-agent.git && cd oute-agent
cp .env.example .env && $EDITOR .env      # OUTE_HOSTNAME, OUTE_UID=$(id -u)
./scripts/oute build                       # ~6 min (arm64)
./scripts/oute up                          # master password 1x; router-sync + cron diário + compose up
./scripts/oute attach                      # ssh -> herdr (detach: Ctrl+B q)
```

`oute up` faz, em ordem: segredos do Vaultwarden (sessão em cache em `~/.oute/bw_session`) → mount do storage → `router-sync` (catálogo do OpenRouter conforme guardrail; se falhar, usa o anterior) → instala o cron diário do router-sync → `docker compose up`.

Comandos: `oute build | up | down | restart | attach | ssh [cmd] | shell | logs [svc] | follow [svc] | status | router-sync [--dry-run] | schedule | lock | version`.

Dentro do container: `pi`, `claude`, `codex`, `goose`, `gh`, `oci`, `gcloud`, `aws`, `firebase`, `ai-memory`, `herdr`.

## Roteamento de modelos

- `claude` e `codex`: assinatura própria (login na 1ª vez, persiste no volume `oute-home`). Fora do OpenRouter.
- `pi`, `goose` e qualquer cliente OpenAI-compatible → `http://jev-router:4000/v1`:
  - `model: jev-router` → **Jev** (Decisions API) escolhe o perfil (`reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`) → **OpenRouter** escolhe o modelo dentro do perfil (`models` ≤ 3 + `provider.sort` ao vivo, com fallback).
  - `model: <perfil>` → pula o Jev (ex.: `/model coder` no Pi).
- Editar perfis/provedores: `config/litellm/policy.yaml` → `oute router-sync --dry-run` → `oute router-sync`.
- Log: `docker logs oute-jev-router 2>&1 | grep 'jev-router\]'` (`chosen=… via=jev|cheapest`, `served … model=…`).

## Memória

`ai-memory` (akitaonrails) como serviço em `http://ai-memory:49374`; entrypoint instala hooks + MCP nos agentes de `OUTE_AGENTS`. Web UI: `/web`.

## Storage comum

`/data/shared` ← `~/.oute/shared` no host ← `rclone mount oci:oute-shared` (feito por `oute up` se o remote existir).

## Versionamento e retenção

SemVer, fonte única em `VERSION`. `scripts/release x.y.z` faz bump + fecha o `CHANGELOG.md` + commit + tag `vx.y.z` (push manual). A imagem recebe a tag `ghcr.io/renatobardi/oute-agent:x.y.z`; `oute version` mostra repo × imagem rodando. Retenção: só a versão corrente e a anterior (imagens, cache de build).
