# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Versionamento: [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

## [0.7.7] - 2026-09-25

### Changed
- **ai-memory 2.4.1** (servidor e cliente juntos; era 2.4.0): log do servidor sem o `reconciliation pass` a cada 30 s, slugs de regra com acentos dobrados (`retenção` → `retencao`), handoff sem rótulos `tool file`, `memory_consolidate` manual corrige job `failed`. **Migração de schema V67, só para frente**: backup do volume `oute-memory` antes de subir.
- Hooks do ai-memory instalados com **`--project-strategy repo-root`**: o projeto da memória passa a ser o repo principal, então subdiretórios e git worktrees caem no mesmo projeto (antes, `basename(cwd)` criava um projeto por worktree ou por `cd subdir`). Para repos em `/workspace/<repo>` o nome não muda; nada existente é movido.

### Added
- **`oute watch [host]`**: atalho de `oute approve --watch`. Com host (ex.: `oute watch oute-server`), abre a espera de aprovação naquele host via `ssh -t` (roda como o usuário do ssh, fora do container).

## [0.7.6] - 2026-09-25

### Added
- **Canal de aprovação** para ações no host: o agente propõe com **`oute-propose "título" [--root]`** (script pela entrada padrão → `~/outbox/`) e lê o resultado com **`oute-inbox [--wait] <id>`**; o humano revisa e executa (ou recusa) no host com **`oute approve [--watch]`** — fora do container, então o agente não aprova a si mesmo. O script é copiado para o host antes de exibido (o que roda = o que foi visto), caracteres de controle neutralizados na tela, `--root` destacado em vermelho, registro em `~/.oute/approve/approve.log`, saída devolvida em `~/inbox/<id>.out` (`# rc:`; recusa = 126). Os agentes aprendem o canal por um bloco gerenciado em `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` e `~/.pi/agent/AGENTS.md`.

## [0.7.5] - 2026-09-25

### Added
- **Origem da telemetria = máquina + instância.** Todo registro (bucket e Langfuse) leva `host.name` = máquina e `oute.instance` = instância, além de `oute.agent`. A instância só precisa ser única dentro da máquina (#22).
  - `OUTE_HOST` é opcional: sem ele vale o antigo `OUTE_HOSTNAME` e, se nenhum estiver definido, o hostname da máquina.
  - `OUTE_INSTANCE` tem default `oute-agent`.
  - Os dois são normalizados para `[a-z0-9_-]`, até 40 caracteres.
  - Bucket particionado: `otel/<sinal>/host=<máquina>/instance=<instância>/year=…`. Os objetos antigos, sem `host=/instance=`, ficam onde estão; nada é movido nem apagado.
  - No Langfuse, a máquina vira o **Environment** nativo e máquina/instância vão para a metadata do trace.
  - `oute version` mostra a origem.
- **`oute` sem argumento** abre o herdr (sobe a stack antes, se o agent não estiver rodando). **`oute install`** cria o link no PATH (`~/.local/bin`, `/opt/homebrew/bin` ou `/usr/local/bin`, o primeiro que estiver no PATH e for gravável) — no Mac e no oute-server basta digitar `oute`. O script resolve symlinks para achar a raiz do repo. `oute help` mostra o uso; comando desconhecido avisa.

## [0.7.4] - 2026-09-25

### Fixed
- **Entrypoint em loop de restart num home novo** (1ª subida em host novo, visto no Mac, #3): a retenção dos `.bak` do ai-memory fazia `ls` de glob sem match, que sai 2; com `pipefail` + `set -e` o entrypoint morria antes do sshd. No oute-server não aparecia porque os `.bak` já existiam.
- `oute up` para com mensagem clara se a chave pública de `OUTE_SSH_AUTHORIZED_KEYS` (default `~/.ssh/id_ed25519.pub`) não existir — antes o Docker criava um diretório vazio no lugar.
- `oute pull` mostra o erro real do vault (antes dizia só "GHCR_TOKEN ausente", mesmo quando faltava o `bw_client.env`).
- Mac: README com rede alternativa (`OUTE_NET_SUBNET`/`OUTE_NET_GATEWAY`/`OUTE_AGENT_IP`) quando `172.19.0.0/16` já está em uso, e rclone do rclone.org (o do Homebrew não faz `mount` no macOS).
- `oute up`/`pull` falhavam na 0.7.3 com `EACCES ... Bitwarden CLI/data.json.lock`: o `bw` do host roda via `docker run` da imagem, agora com uid 10001, mas o estado em `~/.oute/bwcli` é do usuário do host. O `bw` (e o `oci-bootstrap`) passam a rodar com `--user` do host, `HOME=/tmp` e `BITWARDENCLI_APPDATA_DIR=/bwcli`. Só script do host — a imagem 0.7.3 não muda.

## [0.7.3] - 2026-09-25

### Security
- **Container com uid/gid próprios (10001)** (lab#181). Antes o usuário do container tinha o uid do host (1001 = `ubuntu` no oute-server): tudo que um agente gravava em bind mount virava arquivo do `ubuntu`. Agora o uid é fixo na imagem e não existe no host; `OUTE_UID` sai do `.env`, do compose e do CI (`oute up` avisa se a linha ainda existir). Serviço one-shot **`volume-init`** migra os volumes `oute-home`, `oute-workspace` e `oute-memory` (chown só quando a raiz ainda não é 10001). O entrypoint lê `/run/secrets/agent_env` (0600 do host) via `sudo`.
- **`/data/shared` sem diretório do host gravável** (lab#181): só o mount rclone do bucket vem do host (dono 10001, grupo do usuário do host, umask 002; FUSE de usuário é nosuid/nodev). Sem mount, vira o volume docker `oute-shared` em vez de `~/.oute/shared`.

### Fixed
- **Mac** (#3): `oute` quebrava no bash 3.2 do macOS com array vazio + `set -u` (`rclone mount` sem `--allow-other`, `oute ssh` sem tty) e o `wait_sshd` dependia de `timeout(1)`, que o macOS não tem. A mesma imagem do ghcr serve no Mac, sem rebuild por uid.

## [0.7.2] - 2026-09-25

### Added
- **Identificador do agente na telemetria** (`oute.agent`): o collector marca `claude` (service `claude-code`), `codex` (`codex_*`) e `router` (`jev-router`) no resource de traces, logs e métricas (bucket e Langfuse). No jev-router o hook grava o **cliente real** no span `jev.decision` a partir do header `X-Oute-Agent` — o Pi manda `pi` (header no `models.json`); sem header = `unknown`. No Langfuse vira `metadata.agent` do trace. Log do router: `served agent=… profile=…`.

### Fixed
- `oute pull` travava: sem `bw` nativo no host, o `bw` roda via `docker run` da imagem da versão ATUAL — que ainda não foi baixada (o pull precisa do bw para ler o token do ghcr). Agora usa a imagem local da versão atual ou a mais nova disponível, com `--pull never`.

## [0.7.1] - 2026-09-25

### Security
- Acesso do container ao host como **`oute-ops`** (lab#178): rede `oute` com subnet fixa `172.19.0.0/16` e agent em `172.19.0.5` (o sshd do host só aceita o oute-ops desse IP); chave própria `~/.ssh/oute-ops_ed25519` gerada no boot; `~/.ssh/config.d/oute-host.conf` (incluído no topo do `~/.ssh/config`) faz `ssh oute-server` entrar como oute-ops via gateway `172.19.0.1`. A pública sai no log do boot.

## [0.7.0] - 2026-09-25

### Security
- **Container dos agentes sem acesso ao Vaultwarden** (#6, passo 1). Antes recebia `BW_SESSION` (+ `BW_PASSWORD` se definida), o estado do `bw` (`~/.oute/bwcli`) e a API key (`bw_client`) — com agentes em yolo, qualquer um podia ler o cofre inteiro (segredos de todos os projetos e a pasta `oute-admin`). Agora o `oute up` resolve só a pasta `oute-agent` no host e monta os valores como docker secret (`~/.oute/agent.env`, 0600, read-only em `/run/secrets/agent_env`). Saem do agent: `BW_*`, volume `bwcli`, secret `bw_client`, `extra_hosts` do vault; `BW_SESSION` sai do `.oute_env`; resíduos do bw no volume home são apagados no boot. O `bw` continua na imagem só para o host usar via `docker run`.

### Added
- **A/B Jev × `openrouter/auto`** (#15): `OUTE_AB_MODE=off|split|auto` no jev-router. No `split`, cada conversa (hash da 1ª mensagem) cai num braço de forma estável; o braço `auto` usa `openrouter/auto` com `allowed_models` = mesmo pool de modelos dos perfis elegíveis (tools/vision/max_tokens), ZDR e `data_collection: deny`, `session_id` por conversa. Span `jev.decision` ganha `oute.ab_arm`/`oute.ab_mode`; trace `ab-auto` no Langfuse. `router-sync` gera o modelo `or-auto`.

### Fixed
- `oute router-sync --check-guardrail` reiniciava jev-router e agent; agora só checa e devolve o código (0 alinhado, 2 divergente, 1 não verificado).
- `.gitignore`: `__pycache__/` e `*.pyc` (um `.pyc` entrou por engano na 0.6.1).

## [0.6.1] - 2026-09-25

### Added
- `router-sync` detecta divergência `policy.yaml` × guardrail do OpenRouter (#16): com a Management API key (`OPENROUTER_MGMT_KEY`, pasta `oute-admin` do vault — nunca vai ao container dos agentes) compara `providers_allow` com `allowed_providers`/`ignored_providers` e ZDR do guardrail nomeado em `policy.yaml: guardrail`. Sync normal só avisa; `oute router-sync --check-guardrail` sai 2 se divergir. Sem a key, avisa que não verificou.
- Ponte do Mac (#9): `.githooks/pre-commit` reaplica +x no índice e no disco; `scripts/fix-bridge` (+x, remove `.git/*.lock` órfão se não houver git rodando, ativa `core.hooksPath`); `scripts/exec-files` = lista única dos executáveis; `scripts/release` e o CI recusam script sem modo 100755.

## [0.6.0] - 2026-09-25

### Added
- **Agentes em modo yolo dentro do container por padrão** (`OUTE_AGENT_YOLO=1`): Claude Code com `permissions.defaultMode=bypassPermissions` (+ `skipDangerousModePermissionPrompt`), Codex com `approval_policy="never"` (já tinha `sandbox_mode=danger-full-access`). Merge estrutural, preserva hooks do ai-memory. A fronteira é o container; acesso ao host segue restrito (ver ADR-01).

## [0.5.9] - 2026-09-24

## [0.5.8] - 2026-09-24

### Fixed
- **Codex sem ai-memory desde a 0.5.3/0.5.4** (sem MCP e sem captura de sessões): o entrypoint editava `~/.codex/config.toml` com `sed` apagando intervalos entre marcadores, e a seção `[mcp_servers.ai-memory]` gravada pelo ai-memory caía dentro do intervalo. Agora `docker/codex_config.py` mescla só `sandbox_mode` e `[otel]` via `tomlkit` (pacote `python3-tomlkit`) e preserva o resto; migra os blocos antigos no primeiro boot.
- Backups `.bak-*` que o ai-memory cria a cada boot no `~/.codex`: mantém o mais antigo (original) + os 2 mais recentes.
- Codex só roda hooks com aprovação persistida (`[hooks.state]…trusted_hash` no `config.toml`); o `sed` antigo apagou a aprovação e os hooks pararam em silêncio desde a 0.5.4. Reaprovado via TUI; agora preservado pelo merge estrutural.

## [0.5.7] - 2026-09-24

### Removed
- **Goose** fora do stack (#4): não funciona com o ai-memory (sem hooks, não está nos harnesses suportados). Regra do projeto: agente só entra se atender memória (ai-memory hooks + MCP) e telemetria (bucket + Langfuse). Removidos binário, config do entrypoint e `goose` de `OUTE_AGENTS`.

## [0.5.6] - 2026-09-24

### Changed
- Imagens de terceiros com versão fixa (antes `:latest`/`:main-latest`): LiteLLM por digest (`1.103.0`, o que já rodava — `OUTE_LITELLM_IMAGE`), servidor ai-memory `2.4.0` (`OUTE_AI_MEMORY_VERSION`) e cliente ai-memory no Dockerfile `ARG AI_MEMORY_VERSION=2.4.0` (baixava `releases/latest`). Upgrade passa a ser deliberado.

## [0.5.5] - 2026-09-24

### Changed
- Compose: rotação do stdout dos containers (`json-file`, 10 MB × 3). Telemetria não muda — vai inteira ao bucket, sem expiração.
- CI (#20): actions nas majors Node 24 — `checkout@v7`, `setup-buildx-action@v4`, `login-action@v4`, `build-push-action@v7`. Retenção do ghcr reescrita com `gh api` (o `delete-package-versions@v5`, última versão, ainda é Node 20) e runner fixo em `ubuntu-24.04` (o `ubuntu-latest` migra para 26 em 19/10).

### Fixed
- Langfuse: tokens de Claude Code e Codex apareciam zerados. Atributos crus (`input_tokens`, `cache_read_tokens`, `codex.turn.token_usage.*`) mapeados para `gen_ai.usage.*`; `session_task.turn` do Codex vira generation com modelo; `session.id` → `langfuse.session.id` (aba Sessions) (#19).
- Langfuse: ruído do Codex — allowlist de spans (`codex.exec`, `session_*`, `run_sampling_request`, tools, hooks, `thread/start`, `turn/start`). Antes 1 exec gerava ~7 traces e milhares de spans `fs.*`/`append_items`. Tudo continua no bucket.

### Changed
- `oute pull` aplica retenção local: mantém só a versão atual e a anterior do agent (mesma regra do ghcr) e, sem `OUTE_BUILD_LOCAL=1`, limpa todo o build cache (sobrava 5,5 GB de builds antigos sem uso).

## [0.5.4] - 2026-09-24

### Fixed
- Codex não executava nada no container (`bwrap: No permissions to create a new namespace`): entrypoint grava `sandbox_mode = "danger-full-access"` no topo do `~/.codex/config.toml`. O container já é a fronteira de isolamento; liberar user namespaces enfraqueceria o container inteiro (#5).
- CI: cache de camadas trocado de `type=gha` para registry (`ghcr.io/renatobardi/oute-agent-cache:buildcache`). O cache do Actions é isolado por ref e cada tag é um ref novo — nunca havia hit (build sempre ~5 min).

## [0.5.3] - 2026-09-24

### Added
- Codex exporta **traces** (`[otel.trace_exporter.otlp-http]` → collector) além dos logs (#19). No Langfuse: span events mantidos **só para o Codex** (é onde ele põe modelo/tools), com allowlist de atributos (prompt/saída nunca saem); tokens e conteúdo completos seguem no bucket (logs). Custo do Codex não existe por request (assinatura).

### Security
- `oute pull` faz `docker logout ghcr.io` logo após o pull: o token de leitura não fica em texto puro no `~/.docker/config.json` (só no vault).

## [0.5.2] - 2026-09-24

### Added
- **CI da imagem** (#2): `.github/workflows/image.yml` — na tag `v*` (ou manual) builda arm64 nativo em `ubuntu-24.04-arm`, cache de camadas `type=gha`, push em `ghcr.io/renatobardi/oute-agent:x.y.z`; job de retenção mantém 2 versões no ghcr (#12). Tag precisa bater com `VERSION`.
- `oute pull`: login no ghcr com `GHCR_TOKEN` (vault, item `github`, só `read:packages`) e pull da imagem da versão atual. `oute up` usa a imagem local ou puxa do ghcr (`--no-build`; build local só com `OUTE_BUILD_LOCAL=1`).

### Changed
- Cache do build local: retenção padrão 24h (era 72h — duas gerações completas levaram o disco a 85%).

### Fixed
- Dockerfile: `ARG OUTE_VERSION` movido para o fim (antes do `LABEL`). Declarado no topo, virava env de todos os `RUN` e cada bump de versão refazia a imagem inteira (~7 min).

## [0.5.1] - 2026-09-24

### Fixed
- `oute build`: retenção do cache por idade (`prune -a --filter until=72h`, `OUTE_BUILD_CACHE_TTL`) — teto por tamanho (`--max-used-space`) apagava também o cache recente e o rebuild voltava a 7 min. `oute up` apaga a imagem antiga que ficou solta após recriar o container.

### Changed
- Dieta da imagem, só cortes seguros (#11): dpkg sem man/doc/info e sem traduções além de en/pt; sem cache de pip/npm na imagem (`PIP_NO_CACHE_DIR`, cache mounts do BuildKit pra npm e pipx — rebuild baixa rápido, nada entra na camada); aws-cli sem `examples/`; gcloud sem `.install/.backup`. Nenhuma ferramenta removida.
- `oute build` mantém o cache de build em vez de apagar tudo: rebuild que só muda entrypoint/scripts reaproveita apt/npm/oci-cli (#8). Sem attestation de proveniência (`BUILDX_NO_DEFAULT_ATTESTATIONS=1`). Avisa se faltar `docker-buildx`.

## [0.5.0] - 2026-09-24

### Added
- **Observabilidade, fase 1** (#13, ADR-04): serviço `otel-collector` (OTel Collector contrib, só rede interna). Claude Code (métricas/eventos/traces com conteúdo), Codex (`[otel]` gerenciado no `config.toml`) e jev-router (callback `otel` do LiteLLM) exportam OTLP. Tudo vai pro bucket OCI `oute-observability` (gzip, lotes de 5 min, partição por hora UTC); traces com **só metadados** (allowlist de atributos, sem span events) vão pro Langfuse Cloud quando o vault tem o item `langfuse`.

### Fixed
- `oute-secrets export` sempre faz `bw sync`: item criado no vault depois da sessão em cache (ex.: `langfuse`) passa a ser visto no próximo `up`.
- otel-collector → OCI: `AWS_REQUEST_CHECKSUM_CALCULATION`/`AWS_RESPONSE_CHECKSUM_VALIDATION=when_required` (OCI rejeita `aws-chunked` do SDK AWS v2 com 501).

### Added
- Observabilidade fase 2 (#13): `jev.decision` enriquecido com o que o OpenRouter realmente fez — consulta `GET /api/v1/generation?id=gen-…` em background (retries 2/4/8/16 s) e grava modelo servido, provedor, custo (US$), latência e tokens nativos. Custo aparece no Langfuse (span tipo generation). Sem porta pública (decisão: pull via API em vez de Broadcast).

### Changed
- jev-router emite span próprio `jev.decision` (perfil, via, preset, modelos, sinais, tokens, `gen_ai.response.id` = id da geração no OpenRouter) — o LiteLLM não repassa metadata customizada pros spans dele. Trace nomeado `jev:<perfil>` no Langfuse.
- Langfuse: spans internos do LiteLLM (`auth`, `router`, `self`, `proxy_pre_call`, `raw_gen_ai_request`…) filtrados do painel; continuam no bucket.
- `oute ssh <cmd>` aloca TTY quando há terminal: `pi -p` via ssh não fica mais esperando stdin.
- `oute up` lê o vault uma vez só (`oute-secrets export`) em vez de uma chamada por variável.
- `.oute_env` gerado com `declare -px` (valores citados).
- rclone no host sem `NOTICE: Config file … not found` (`RCLONE_CONFIG=/dev/null`; remote só por env).

## [0.4.0] - 2026-09-23

### Added
- Storage comum no **OCI Object Storage** (#1, ADR-03): `oute oci-bootstrap` provisiona compartment `oute-agent`, buckets `oute-shared` (versionado, versões antigas > 30d apagadas) e `oute-observability` (Infrequent 30d → Archive 90d), usuário de serviço só-S3 com policy de menor privilégio, Customer Secret Key gravada direto no Vaultwarden (`oci-storage`) e budget US$1/mês. Credencial admin fica na pasta `oute-admin` do vault, nunca exportada pro container. `DRY_RUN=1` mostra sem executar.
- `oute up` monta `oci:oute-shared` em `~/.oute/shared` (remote `oci` só por env, sem `rclone.conf`); `oute down` desmonta. Dentro do container, `rclone` já enxerga o remote `oci`.
- `oute storage [ls|lsl|about] [path]`: lista o bucket direto no OCI, sem o mount.

### Changed
- `OCI_KEY_PEM` aceita PEM colado numa linha só (custom field do Vaultwarden perde quebras de linha); é reconstruído.

### Fixed
- `oute up` espera o sshd do container responder (banner SSH, até 60s) antes de retornar; `attach` logo após o `up` não dá mais `Connection reset`.

### Security
- sshd do container publicado só em `127.0.0.1` por padrão (`OUTE_SSH_BIND`); antes ficava em `0.0.0.0:2222`, exposto no IP público do oute-server porque o Docker publica portas por fora do ufw (#17).

## [0.3.0] - 2026-09-23

### Added
- Perfis publicados como **presets do OpenRouter** (`@preset/oute-reasoning`, `@preset/oute-coder`, ...) pelo `router-sync` — só quando mudam (cada publicação é uma versão). Utilizáveis fora do container com a key do OpenRouter. Preset reforça `zdr` + `data_collection: deny`. O LiteLLM passa a mandar o `@preset/...`; se a publicação falhar, volta ao `models`+`provider.sort` injetado pelo hook. `--no-presets` desliga.

## [0.2.0] - 2026-09-23

### Added
- `oute router-sync`: consulta o OpenRouter (`/providers`, `/models`, `/models/user`, `/models/{id}/endpoints`) e gera `router.yaml`, `config.yaml`, `candidates.json` e `catalog.json` a partir de `config/litellm/policy.yaml` (espelho do guardrail: allowlist de provedores, perfis com padrões de modelo). Pi lista os perfis gerados.

- Roteamento em 2 etapas: Jev escolhe o **perfil**; o OpenRouter escolhe o **modelo** dentro dele (`models` = até 3 modelos elegíveis do perfil — limite do OpenRouter, `provider.sort` por perfil, `partition: none`, fallback automático). Perfis também podem ser pedidos direto (`/model coder` no Pi).
- `router-sync` roda em todo `oute up` (se falhar, mantém o último catálogo) e diariamente às 04:00 (crontab do host, instalado pelo próprio `up`).

### Changed
- `oute build` limpa build cache e imagens órfãs ao terminar (pico de disco no oute-server; parte da issue #12).
- Allowlist do guardrail revista: modelos abertos (Kimi, DeepSeek, GLM, Qwen, gpt-oss, Llama) via hosts neutros (Fireworks, Together, DeepInfra, Baseten, Groq, Cerebras); saem Tencent, Sakana, NVIDIA, Meta. Perfis priorizam GLM, Kimi, DeepSeek e Grok; cada padrão contribui com 1 modelo (perfil mistura famílias).
- Arquivos gerados do router (`router.yaml`, `config.yaml`, `candidates.json`, `catalog.json`) saem do git; fonte única é `policy.yaml`.
- Candidatos do router viram **perfis** (`reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`) resolvidos pra modelos elegíveis no guardrail; Anthropic/OpenAI/Google/DeepSeek saem (fora da allowlist).

### Added
- Runtime container (Ubuntu 24.04 arm64): herdr, Pi, Claude Code, Codex, Goose, ai-memory, gh, oci, gcloud, aws, firebase-tools, rclone, bw, sshd.
- Compose com 3 serviços: `agent`, `jev-router` (LiteLLM + hook Jev via OpenRouter), `ai-memory`.
- Segredos exclusivamente via Vaultwarden (`oute-secrets`).
- CLI de host `scripts/oute` (build/up/attach/ssh/shell/logs/status/sync-shared/version).
- Versionamento: `VERSION`, `CHANGELOG.md`, `scripts/release`, label OCI na imagem.

- Sessão do Vaultwarden em cache (`~/.oute/bw_session`, 0600) compartilhada host↔container via volume `bwcli`; master password só quando a sessão expira. `oute lock` apaga.

### Fixed
- `oute build` não exige mais `BW_PASSWORD` (só `up`).
- `bw` fixado em 2026.8.0 (2026.9.0 quebra com Vaultwarden 1.37.x, vaultwarden#7750).
- `extra_hosts` para `vault.oute.pro` (vhost só no listener Tailscale; Docker não herda /etc/hosts).
- `OUTE_UID` como build arg (bind mounts em hosts com uid ≠ 1000).
- `useradd -p '*'`: conta sem senha mas não bloqueada (sshd com `UsePAM no` recusava a chave como "invalid user").
- ai-memory roda com `OUTE_UID` (volume compartilhado) e aceita `Host: ai-memory` (`AI_MEMORY_ALLOWED_HOSTS`).
- `oute ssh cmd` roda em login shell (carrega `~/.oute_env`); `oute logs` sem follow, `oute follow` com.
- Jev chamado pela Decisions API do OpenRouter (`/api/alpha/decisions`, `typesafe/jev-1.13`) — chat completions dava 400.
- `~/.oute_env` carregado via `.profile` (o `.bashrc` retorna cedo em shell não-interativo).
- Hook loga `chosen=… via=jev|cheapest` e o motivo quando o Jev falha.
- Locales en_US/pt_BR gerados na imagem.
- Pi: pacote `@earendil-works/pi-coding-agent` (o `@mariozechner/*` está deprecated, parado em 0.73); provider `oute` em `~/.pi/agent/models.json` apontando pro jev-router, default `jev-router` forçado no `settings.json` (merge). `OPENAI_API_KEY` não é mais exportada globalmente (fazia o Pi cair no provider openai).
- Host key do sshd persistida em `~/.oute/ssh` (volume `oute-home`); `oute down` não invalida mais o `known_hosts`.
- `oute` usa o `bw` da imagem quando o host não tem node; `oute-secrets` não refaz `config server` logado e erra claro em `get`.
