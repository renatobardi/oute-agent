# oute-agent

Runtime container para agentes de código (herdr + Pi + Claude Code + Codex + Goose), com roteamento de modelo via Jev/OpenRouter, memória compartilhada via ai-memory e segredos no Vaultwarden. Roda em ARM: MacBook (Apple Silicon) e VPC Oracle Cloud (LXC).

Arquitetura e decisões: Project "Oute Agent" no Claude (`arquitetura/01-runtime-container.md`).

## Layout

```
docker/     Dockerfile (multi-arch), compose.yaml, entrypoint.sh
config/     litellm (jev-router: config.yaml, router.yaml, jev_hook.py), ssh, herdr, ai-memory
scripts/    oute (CLI do host), oute-secrets.sh (Vaultwarden -> env)
secrets/    README com a convenção do vault (sem valores)
```

## Pré-requisitos no host

- Docker (Mac: Docker Desktop/OrbStack; LXC: `security.nesting=true`)
- `bw` (Bitwarden CLI) + `jq`
- `~/.oute/bw_client.env` com `BW_CLIENTID` / `BW_CLIENTSECRET` (API key do Vaultwarden), `chmod 600`
- `~/.ssh/id_ed25519.pub`
- opcional: `rclone` com remote `oci` (bucket `oute-shared`)

## Uso

```bash
cp .env.example .env            # ajuste OUTE_HOSTNAME etc.
./scripts/oute build            # ~10 min na primeira vez (arm64)
./scripts/oute up               # pede master password do Vaultwarden
./scripts/oute attach           # ssh -p 2222 oute@localhost -> herdr
./scripts/oute logs agent
```

Dentro do container: `pi`, `claude`, `codex`, `goose`, `gh`, `oci`, `gcloud`, `aws`, `firebase`, `ai-memory`, `herdr`.

## Versionamento

SemVer, fonte única em `VERSION`. `scripts/release x.y.z` faz bump + fecha o `CHANGELOG.md` + commit + tag `vx.y.z` (push manual). A imagem recebe `org.opencontainers.image.version` e a tag `ghcr.io/renatobardi/oute-agent:x.y.z`. `oute version` mostra repo vs imagem rodando.

## Roteamento LLM (híbrido)

- `claude` e `codex`: assinatura própria (login na primeira vez, persiste no volume `oute-home`).
- `pi`, `goose` e qualquer cliente OpenAI-compatible: `model: jev-router` em `http://jev-router:4000/v1` — o hook consulta Jev (`typesafe/jev-latest` via OpenRouter) com a política de `config/litellm/router.yaml` e reescreve o modelo por request. Sem chave/erro → mais barato elegível.

## Memória

`ai-memory` (akitaonrails) como serviço em `http://ai-memory:49374`; entrypoint instala hooks + MCP em todos os agentes de `OUTE_AGENTS`. Web UI: `/web`.

## Storage comum

`/data/shared` ← `~/.oute/shared` no host ← `rclone mount oci:oute-shared` (feito por `oute up` se o remote existir).
