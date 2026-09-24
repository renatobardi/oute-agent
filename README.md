# oute-agent

Runtime em container para agentes de código — **herdr + Pi + Claude Code + Codex + Goose** — com roteamento de modelo em 2 etapas (Jev escolhe o perfil, OpenRouter escolhe o modelo), memória compartilhada (ai-memory), storage comum no OCI, observabilidade completa (bucket OCI + Langfuse) e segredos só no Vaultwarden. Roda em ARM: VPC Oracle Cloud (`oute-server`) e MacBook (Apple Silicon).

Decisões de arquitetura (ADRs) ficam no Project "Oute Agent" no Claude: `arquitetura/01-runtime-container.md`, `02-roteamento-modelos.md`, `03-storage-oci.md`, `04-observabilidade.md`. Backlog: issues deste repo. Histórico: `CHANGELOG.md`.

## Serviços (compose)

| serviço | imagem | papel | rede |
|---|---|---|---|
| `agent` | `ghcr.io/renatobardi/oute-agent:<VERSION>` | Ubuntu 24.04 + agentes/CLIs, sshd, herdr | `127.0.0.1:2222` (nunca `0.0.0.0`) |
| `jev-router` | `berriai/litellm` + `jev_hook.py` | proxy OpenAI-compatible; Jev → perfil → preset do OpenRouter | interna |
| `ai-memory` | `akitaonrails/ai-memory` | memória compartilhada entre agentes (MCP + hooks) | interna |
| `otel-collector` | `otel/opentelemetry-collector-contrib` | telemetria → bucket OCI + Langfuse | interna |

## Layout

```
docker/          Dockerfile, compose.yaml, entrypoint.sh
config/litellm/  policy.yaml (FONTE do router), jev_hook.py
                 router.yaml, config.yaml, candidates.json, catalog.json  <- GERADOS por `oute router-sync` (fora do git)
config/otel/     collector.yaml (bucket OCI), langfuse.yaml (só metadados), none.yaml
config/ssh/      sshd_config
scripts/         oute (CLI do host), oute-secrets.sh (Vaultwarden -> env), router_sync.py, oci-bootstrap.sh, release
secrets/         README com a convenção do vault (sem valores)
```

## Pré-requisitos (fora do repo)

**Contas / serviços**
- **Vaultwarden** (`vault.oute.pro`) — única fonte de segredos (ver `secrets/README.md`):
  - pasta `oute-agent` (vira env do container): `openrouter`, `oci-storage` (criado pelo `oci-bootstrap`), `langfuse` (opcional), `github`, `aws`, `gcp`…
  - pasta `oute-admin` (**nunca** vai pro container): `oci-admin` (API key admin da OCI, só pro `oci-bootstrap`).
- **OpenRouter**: guardrail "oute-agent guardrail - core" na key (allowlist de provedores, ZDR, sem treino, orçamento). `config/litellm/policy.yaml` **espelha** o guardrail.
- **OCI**: tenancy com API key admin (1x, pro `oci-bootstrap`).
- **Langfuse Cloud** (opcional): projeto + API keys no item `langfuse`.
- **GitHub**: chave SSH do host (repo privado).

**No host**
- Docker + Compose + **buildx** (Ubuntu: `apt install docker-buildx`; Mac: Docker Desktop/OrbStack).
- `jq`, `crontab`; `bw` opcional (sem ele, usa o da imagem).
- `~/.oute/bw_client.env` com `BW_CLIENTID` / `BW_CLIENTSECRET` (`chmod 600`); `~/.ssh/id_ed25519.pub`.
- `.env` a partir de `.env.example` (`OUTE_HOSTNAME`, `OUTE_UID=$(id -u)`, `OUTE_VAULT_HOST_IP`…).
- Storage: `rclone` **do rclone.org** + FUSE (Linux: `fuse3` + `user_allow_other` em `/etc/fuse.conf`; Mac: FUSE-T).

## Deploy novo

```bash
git clone git@github.com:renatobardi/oute-agent.git && cd oute-agent
cp .env.example .env && $EDITOR .env
./scripts/oute build                                  # 1ª vez ~8 min; depois reaproveita cache
DRY_RUN=1 ./scripts/oute oci-bootstrap                # 1x por tenancy: mostra o plano
OUTE_OCI_BUDGET_EMAIL=voce@x ./scripts/oute oci-bootstrap
./scripts/oute up                                     # master password 1x
./scripts/oute attach                                 # ssh -> herdr (detach: Ctrl+B q)
```

`oute up`, em ordem: lê o vault (1 leitura, `bw sync`) → monta `oci:oute-shared` → `router-sync` (catálogo do OpenRouter conforme guardrail; se falhar, usa o anterior; publica presets) → cron diário do router-sync → `docker compose up` → espera o sshd → limpa imagem antiga solta.

## Comandos

| comando | faz |
|---|---|
| `oute build` | constrói a imagem; mantém até `OUTE_BUILD_CACHE` (5gb) de cache |
| `oute up` / `down` / `restart` / `status` | ciclo de vida da stack |
| `oute attach` / `ssh [cmd]` / `shell` | herdr, ssh no container, `docker exec` |
| `oute logs [svc]` / `follow [svc]` | logs |
| `oute router-sync [--dry-run]` / `schedule` | regenera perfis/presets / agenda diário 04:00 |
| `oute oci-bootstrap` | provisiona storage OCI (idempotente, `DRY_RUN=1`) |
| `oute storage [ls\|lsl\|about] [path]` | lista o bucket direto no OCI (`OUTE_BUCKET=oute-observability` p/ telemetria) |
| `oute sync-shared` | (re)monta o bucket |
| `oute lock` / `version` | apaga sessão do vault / versão repo × imagem |

Dentro do container: `pi`, `claude`, `codex`, `goose`, `herdr`, `gh`, `oci`, `gcloud`, `aws`, `firebase`, `rclone`, `ai-memory`.

## Roteamento de modelos (ADR-02)

- `claude` e `codex`: assinatura própria (login 1x, persiste no volume `oute-home`). Fora do OpenRouter.
- `pi`, `goose` e qualquer cliente OpenAI-compatible → `http://jev-router:4000/v1`:
  - `model: jev-router` → **Jev** (Decisions API) escolhe o perfil (`reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`) → preset **`@preset/oute-<perfil>`** no OpenRouter escolhe o modelo (até 3 + `provider.sort`, com fallback, ZDR).
  - `model: <perfil>` → pula o Jev.
- Editar perfis/provedores: `config/litellm/policy.yaml` → `oute router-sync --dry-run` → `oute router-sync`.
- Log: `docker logs oute-jev-router 2>&1 | grep 'jev-router\]'` → `chosen=… via=jev|cheapest` e `served … model=<real> provider=… cost=…`.

## Observabilidade (ADR-04)

`otel-collector` (sem porta publicada) recebe OTLP de Claude Code (métricas, eventos, traces), Codex (eventos) e jev-router.
- **Tudo, com conteúdo** → bucket OCI `oute-observability/otel/{traces,metrics,logs}/year=…/hour=…/` (gzip, lotes de 5 min).
- **Só metadados** → Langfuse Cloud (EU), se o vault tiver `langfuse`: allowlist de atributos, sem span events, sem spans internos do LiteLLM. Prompt/resposta nunca saem.
- Span **`jev.decision`** (trace `jev:<perfil>`): perfil e via do Jev, modelos candidatos, sinais, tokens e — via `GET /api/v1/generation` do OpenRouter, em background — **modelo servido, provedor, custo (US$) e latência**.
- Conferir: Langfuse → Tracing (`name = jev.decision`); `OUTE_BUCKET=oute-observability ./scripts/oute storage lsl`.

## Storage comum (ADR-03)

`/data/shared` (container) ← `~/.oute/shared` (host) ← `rclone mount oci:oute-shared` (`oute up` monta, `oute down` desmonta). Remote `oci` só por env (item `oci-storage`), sem `rclone.conf` com segredo.
Custo: Always Free (20 GB + 50 mil requests/mês); budget US$1/mês com alerta. Log: `~/.oute/rclone.log`.

## Memória

`ai-memory` em `http://ai-memory:49374`; o entrypoint instala hooks + MCP nos agentes de `OUTE_AGENTS`. Web UI: `/web`.

## Segurança

- Nenhuma porta de container em `0.0.0.0` (Docker ignora ufw): sshd do container em `127.0.0.1:2222` (`OUTE_SSH_BIND`).
- Segredos só no Vaultwarden; credencial admin da OCI numa pasta que nunca vai pro container; usuário de serviço OCI só com S3 nos 2 buckets.
- OpenRouter: guardrail com ZDR e sem treino; presets reforçam `zdr` + `data_collection: deny`.

## Build, versionamento e retenção

SemVer, fonte única em `VERSION`. `scripts/release x.y.z` faz bump + fecha o `CHANGELOG.md` + commit + tag (push manual). Imagem `ghcr.io/renatobardi/oute-agent:x.y.z`; `oute version` mostra repo × imagem.
Build com BuildKit: cache mantido até `OUTE_BUILD_CACHE` (rebuild sem mudança ~2 s), cache mounts pra npm/pip, imagem sem doc/man/locale extras. Retenção: só a versão corrente (a anterior quando houver CI/registry); `oute up` apaga imagem solta.
Backup do host: boot volume do oute-server com policy semanal na OCI (inclui `/var/lib/docker`).
