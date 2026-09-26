# oute-agent

Runtime em container para agentes de código — **herdr + Pi + Claude Code + Codex** — com roteamento de modelo em 2 etapas (Jev escolhe o perfil, OpenRouter escolhe o modelo), memória compartilhada (ai-memory), storage comum no OCI, observabilidade completa (bucket OCI + Langfuse) e segredos só no Vaultwarden. Roda em ARM: VPC Oracle Cloud (`oute-server`) e MacBook (Apple Silicon).

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
- `jq`, `crontab`; `bw` opcional (sem ele, usa o da imagem). Se instalar nativo, **`@bitwarden/cli@2026.8.0`** — ≥ 2026.9.0 não desbloqueia no Vaultwarden 1.37.x (#7).
- `~/.oute/bw_client.env` com `BW_CLIENTID` / `BW_CLIENTSECRET` (`chmod 600`); `~/.ssh/id_ed25519.pub`.
- `.env` a partir de `.env.example` (`OUTE_HOST` opcional, `OUTE_VAULT_HOST_IP`…).
- Storage: `rclone` **do rclone.org** + FUSE (Linux: `fuse3` + `user_allow_other` em `/etc/fuse.conf`; Mac: FUSE-T ou macFUSE). Opcional: sem mount, `/data/shared` é um volume docker local.

**Mac (Apple Silicon)** — mesma imagem do ghcr (arm64), sem rebuild:
- Docker Desktop ou OrbStack; Mac na tailnet (o `bw` da imagem acha o vault via `OUTE_VAULT_HOST_IP`, IP Tailscale do oute-server).
- `.env`: `OUTE_HOST=oute-mac` (opcional; sem ele vale o hostname do Mac). Nada de uid: o do container é fixo (10001) e o Docker do Mac mapeia os bind mounts.
- `~/.oute/bw_client.env` (API key do Vaultwarden) e uma chave pública em `OUTE_SSH_AUTHORIZED_KEYS` (default `~/.ssh/id_ed25519.pub`).
- Se `172.19.0.0/16` já estiver em uso por outra rede docker: `OUTE_NET_SUBNET=172.29.0.0/16`, `OUTE_NET_GATEWAY=172.29.0.1`, `OUTE_AGENT_IP=172.29.0.5` no `.env` (o IP fixo só importa no oute-server).
- Bucket: rclone **do rclone.org** + FUSE-T; o do Homebrew não faz `mount` no macOS.
- Diferenças × oute-server: sem FUSE instalado o bucket não é montado (fica o volume local); `ssh oute-server` de dentro do container não se aplica (o gateway é a VM do Docker, não o servidor); crontab do router-sync depende do Mac estar ligado às 04:00.

## Deploy novo

```bash
git clone git@github.com:renatobardi/oute-agent.git && cd oute-agent
cp .env.example .env && $EDITOR .env
./scripts/oute pull                                   # imagem da versão do VERSION, feita pelo CI (ou OUTE_BUILD_LOCAL=1 + oute build)
DRY_RUN=1 ./scripts/oute oci-bootstrap                # 1x por tenancy: mostra o plano
OUTE_OCI_BUDGET_EMAIL=voce@x ./scripts/oute oci-bootstrap
./scripts/oute up                                     # master password 1x
./scripts/oute attach                                 # ssh -> herdr (detach: Ctrl+B q)
./scripts/oute install                                # 1x por host: link no PATH -> depois é só `oute`
```

`oute up`, em ordem: lê o vault (1 leitura, `bw sync`) e grava `~/.oute/agent.env` → monta `oci:oute-shared` → `router-sync` (catálogo do OpenRouter conforme guardrail; se falhar, usa o anterior; publica presets) → cron diário do router-sync → garante a imagem (local ou `pull` do ghcr; nunca builda escondido) → `docker compose up` → espera o sshd → limpa imagem antiga solta.

### Release e deploy

```bash
# Mac
./scripts/release x.y.z && git push && git push origin vx.y.z     # tag dispara o CI (.github/workflows/image.yml)
# oute-server, depois que o CI terminar (Actions → image)
cd ~/oute-agent && git pull --tags && ./scripts/oute pull && ./scripts/oute down && ./scripts/oute up
```
CI: runner `ubuntu-24.04-arm` (nativo), cache de camadas no GitHub (`type=gha`), push em `ghcr.io/renatobardi/oute-agent:x.y.z`, retenção de 2 versões no ghcr. A imagem é a mesma para todos os hosts (uid do container fixo em 10001).

## Comandos

| comando | faz |
|---|---|
| `oute pull` | baixa do ghcr a imagem da versão atual (feita pelo CI) |
| `oute build` | build local (fallback); mantém o cache usado nas últimas 24h |
| `oute up` / `down` / `restart` / `status` | ciclo de vida da stack |
| `oute` (sem argumento) | sobe a stack se não estiver rodando e abre o herdr |
| `oute approve [--watch]` | revisa e executa (ou recusa) os scripts propostos pelos agentes — ver **Canal de aprovação** |
| `oute install` | link `oute` no PATH (`~/.local/bin`, `/opt/homebrew/bin` ou `/usr/local/bin`) |
| `oute attach` / `ssh [cmd]` / `shell` | herdr, ssh no container, `docker exec` |
| `oute logs [svc]` / `follow [svc]` | logs |
| `oute router-sync [--dry-run]` / `schedule` | regenera perfis/presets / agenda diário 04:00 |
| `oute oci-bootstrap` | provisiona storage OCI (idempotente, `DRY_RUN=1`) |
| `oute storage [ls\|lsl\|about] [path]` | lista o bucket direto no OCI (`OUTE_BUCKET=oute-observability` p/ telemetria) |
| `oute sync-shared` | (re)monta o bucket |
| `oute lock` / `version` | apaga sessão do vault / versão repo × imagem |

Dentro do container: `pi`, `claude`, `codex`, `herdr`, `gh`, `oci`, `gcloud`, `aws`, `firebase`, `rclone`, `ai-memory`.

## Roteamento de modelos (ADR-02)

- `claude` e `codex`: assinatura própria (login 1x, persiste no volume `oute-home`). Fora do OpenRouter.
- `pi` e qualquer cliente OpenAI-compatible → `http://jev-router:4000/v1`:
  - `model: jev-router` → **Jev** (Decisions API) escolhe o perfil (`reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`) → preset **`@preset/oute-<perfil>`** no OpenRouter escolhe o modelo (até 3 + `provider.sort`, com fallback, ZDR).
  - `model: <perfil>` → pula o Jev.
- Editar perfis/provedores: `config/litellm/policy.yaml` → `oute router-sync --dry-run` → `oute router-sync`.
- Log: `docker logs oute-jev-router 2>&1 | grep 'jev-router\]'` → `chosen=… via=jev|cheapest` e `served … model=<real> provider=… cost=…`.

## Observabilidade (ADR-04)

`otel-collector` (sem porta publicada) recebe OTLP de Claude Code (métricas, eventos, traces), Codex (eventos) e jev-router.
- **Origem = máquina + instância** em todo registro: `host.name` (`OUTE_HOST`; sem ele, o hostname da máquina) e `oute.instance` (`OUTE_INSTANCE`, default `oute-agent`), além de `oute.agent` (claude | codex | pi | router). A instância só precisa ser única dentro da máquina (#22). `oute version` mostra a origem.
- **Tudo, com conteúdo** → bucket OCI `oute-observability/otel/{traces,metrics,logs}/host=<máquina>/instance=<instância>/year=…/hour=…/` (gzip, lotes de 5 min). Até a 0.7.4 não havia `host=/instance=` no caminho; esses objetos ficam onde estão.
- **Só metadados** → Langfuse Cloud (EU), se o vault tiver `langfuse`: allowlist de atributos, sem span events, sem spans internos do LiteLLM. Prompt/resposta nunca saem. **Environment** do Langfuse = máquina (seletor no topo); `metadata.host`, `metadata.instance` e `metadata.agent` no trace.
- Span **`jev.decision`** (trace `jev:<perfil>`): perfil e via do Jev, modelos candidatos, sinais, tokens e — via `GET /api/v1/generation` do OpenRouter, em background — **modelo servido, provedor, custo (US$) e latência**.
- Conferir: Langfuse → Tracing (`name = jev.decision`); `OUTE_BUCKET=oute-observability ./scripts/oute storage lsl`.

## Storage comum (ADR-03)

`/data/shared` (container) ← `~/.oute/shared` (host) ← `rclone mount oci:oute-shared` (`oute up` monta, `oute down` desmonta). Remote `oci` só por env (item `oci-storage`), sem `rclone.conf` com segredo.
No mount, dono = usuário do container (10001) e grupo = usuário do host (os dois gravam). Sem mount (sem rclone/FUSE/credencial), `/data/shared` vira o volume docker `oute-shared` — o container nunca recebe um diretório comum da home do host (lab#181).
Custo: Always Free (20 GB + 50 mil requests/mês); budget US$1/mês com alerta. Log: `~/.oute/rclone.log`.

## Memória

`ai-memory` em `http://ai-memory:49374`; o entrypoint instala hooks + MCP nos agentes de `OUTE_AGENTS`. Web UI: `/web`.

## Canal de aprovação (ações no host)

Os agentes não têm privilégio no host (`ssh oute-server` = `oute-ops`, só leitura + allowlist). Quando algo precisa rodar no host, o agente **propõe** e você **aprova** — sem copiar comando da tela.

```
container (agente)                              host (você, fora do alcance do container)
oute-propose "título" [--root] <<'SH' … SH  ─►  oute approve [--watch]
   → ~/outbox/<id>.sh                            mostra o script inteiro (caracteres de controle neutralizados),
                                                 pergunta [s]im / [N]ão agora / [r]ecusar, roda (sudo se --root)
oute-inbox --wait <id>                       ◄─  saída + código em ~/inbox/<id>.out
```
- Mac: aba do terminal com `oute approve --watch` ao lado do herdr. oute-server: `ssh -t oute-server 'oute approve --watch'`. **Nunca dentro do herdr** — ele roda no container, e o agente poderia aprovar a si mesmo.
- O que roda é exatamente o que foi mostrado (o script é copiado para o host antes de exibir). Registro em `~/.oute/approve/approve.log` e cópia de cada script/saída em `~/.oute/approve/runs/`.
- Os agentes sabem do canal por um bloco gerenciado em `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` e `~/.pi/agent/AGENTS.md` (o resto desses arquivos não é tocado).
- Mudança permanente no oute-server continua no fluxo do repo `lab` (PR); o canal é para diagnóstico, ajuste pontual e rodar o deploy de PR mergeado.

## Segurança

- Nenhuma porta de container em `0.0.0.0` (Docker ignora ufw): sshd do container em `127.0.0.1:2222` (`OUTE_SSH_BIND`).
- Usuário do container com **uid/gid próprios (10001)**, que não existem no host (lab#181): arquivo criado pelo container não vira arquivo do `ubuntu`. Do host, o container só grava no mount do bucket; o resto é volume docker ou bind read-only.
- Segredos só no Vaultwarden, lidos **só pelo host**: o container dos agentes não tem sessão, API key nem estado do `bw` — recebe apenas os valores da pasta `oute-agent` em `/run/secrets/agent_env` (gerado pelo `oute up` em `~/.oute/agent.env`, 0600). Pastas de outros projetos e `oute-admin` ficam fora do alcance dos agentes. Usuário de serviço OCI só com S3 nos 2 buckets.
- OpenRouter: guardrail com ZDR e sem treino; presets reforçam `zdr` + `data_collection: deny`.

## Build, versionamento e retenção

SemVer, fonte única em `VERSION`. `scripts/release x.y.z` faz bump + fecha o `CHANGELOG.md` + commit + tag (push manual); a tag dispara o CI que publica `ghcr.io/renatobardi/oute-agent:x.y.z`. `oute version` mostra repo × imagem.
Build com BuildKit (CI ou local): `ARG OUTE_VERSION` só no fim (bump não invalida cache), cache mounts pra npm/pip, imagem sem doc/man/locale extras. Retenção: ghcr com 2 versões (corrente + anterior); no host, `oute up` apaga imagem solta e o build local mantém só o cache das últimas 24h.
Backup do host: boot volume do oute-server com policy semanal na OCI (inclui `/var/lib/docker`).
