# oute-agent

Runtime em container para agentes de código — **herdr + Claude Code + Codex** — com os dois agentes por assinatura e o modelo da sessão escolhido pela fase (ADR-02), memória compartilhada (ai-memory), storage comum no OCI, observabilidade completa (bucket OCI + agent-studio, ADR-08) e segredos só no Vaultwarden. Roda em ARM: VPC Oracle Cloud (`oute-server`) e MacBook (Apple Silicon).

Decisões de arquitetura (ADRs) ficam em [`docs/adr/`](docs/adr/): `0001-runtime-container.md`, `0002-roteamento-modelos.md`, `0003-storage-oci.md`, `0004-observabilidade.md`, `0006-addons.md`, `0007-ai-dlc.md`, `0008-agent-studio.md` (o 0005, plugins herdr, está em estudo). Resumo com glossário: `CONTEXT.md`. Backlog: issues deste repo. Histórico: `CHANGELOG.md`.

## Serviços (compose)

| serviço | imagem | papel | rede |
|---|---|---|---|
| `agent` | `ghcr.io/renatobardi/oute-agent:<VERSION>` | Ubuntu 24.04 + agentes/CLIs, sshd, herdr | `127.0.0.1:2222` (nunca `0.0.0.0`) |
| `ai-memory` | `akitaonrails/ai-memory` | memória compartilhada entre agentes (MCP + hooks) | interna |
| `otel-collector` | `otel/opentelemetry-collector-contrib` | telemetria → bucket OCI + agent-studio (tudo, com conteúdo; fila em disco por destino) | interna |
| `agent-studio` | `ghcr.io/renatobardi/oute-agent:<VERSION>` (mesma imagem, outro comando) | **só no oute-server** (profile `agent-studio`): recebe OTLP/HTTP JSON do collector de cada host, grava a telemetria no DuckDB e o estado no SurrealDB; API só leitura e tela (ADR-08) | `127.0.0.1:8430` (nunca `0.0.0.0`); os outros hosts chegam por `agent-studio.oute.pro`, só na tailnet |
| `surrealdb` | `surrealdb/surrealdb` (fixado por digest) | **só no oute-server** (mesmo profile): estado derivado do agent-studio (rodadas, sessões, pedidos, aprovações) | interna, sem porta publicada |
| `volume-init` | `ghcr.io/renatobardi/oute-agent:<VERSION>` | one-shot: dono 10001 nos volumes | — |

## Layout

```
docker/          Dockerfile, compose.yaml, entrypoint.sh, addons-link; agent-studio/ (código do agent-studio, vai na imagem)
addons/skills/   skills oute-* (ADR-06): montadas read-only em /opt/oute/addons e linkadas no boot; entram com git pull + oute down/up
config/otel/     collector.yaml (bucket OCI), agent-studio.yaml (tudo → agent-studio, ADR-08), none.yaml (pipeline extra desligado)
config/agent-studio/  config.toml (preços e alertas do agent-studio)
config/ssh/      sshd_config
tests/           *.test.sh (bash puro; rodam no CI de PR); lib/ = apoio compartilhado entre os testes
scripts/         oute (CLI do host), oute-secrets.sh (Vaultwarden -> env), oci-bootstrap.sh, release
secrets/         README com a convenção do vault (sem valores)
tray/            tray do Mac (ADR-08 §10): pacote SwiftPM com o TrayCore (lógica sem tela, `swift test`) e o app de barra de menu; é do host, não da imagem
```

## Pré-requisitos (fora do repo)

**Contas / serviços**
- **Vaultwarden** (`vault.oute.pro`) — única fonte de segredos (ver `secrets/README.md`):
  - pasta `oute-agent` (vira env do container): `oci-storage` (criado pelo `oci-bootstrap`), `agent-studio` (só a credencial de leitura, ADR-08 §6), `github`, `aws`, `gcp`…
  - pasta `oute-services` (**nunca** vai pro container `agent`; só aos serviços, #256): `agent-studio` (credencial de ingestão e senha do SurrealDB).
  - pasta `oute-admin` (**nunca** vai pro container): `oci-admin` (API key admin da OCI, só pro `oci-bootstrap`).
- **OCI**: tenancy com API key admin (1x, pro `oci-bootstrap`).
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
- Se `172.19.0.0/16` já estiver em uso por outra rede docker: `OUTE_NET_SUBNET=172.29.0.0/16`, `OUTE_NET_GATEWAY=172.29.0.1`, `OUTE_AGENT_IP=172.29.0.5` no `.env` (o IP fixo só importa no oute-server). O `OUTE_NET_IP_RANGE` é derivado automaticamente (a metade alta da /16; ex.: `172.29.128.0/17`) e pode ser explícito se a subnet não for /16.
- Bucket: rclone **do rclone.org** + FUSE-T; o do Homebrew não faz `mount` no macOS.
- Diferenças × oute-server: sem FUSE instalado o bucket não é montado (fica o volume local); `ssh oute-server` de dentro do container não se aplica (o gateway é a VM do Docker, não o servidor).

## Deploy novo

```bash
git clone git@github.com:renatobardi/oute-agent.git && cd oute-agent
cp .env.example .env && $EDITOR .env
./scripts/oute secrets refresh                        # master password: lê o vault e grava ~/.oute/agent.env
./scripts/oute pull                                   # imagem da versão do VERSION, feita pelo CI (ou OUTE_BUILD_LOCAL=1 + oute build)
DRY_RUN=1 ./scripts/oute oci-bootstrap                # 1x por tenancy: mostra o plano
OUTE_OCI_BUDGET_EMAIL=voce@x ./scripts/oute oci-bootstrap
./scripts/oute up                                     # usa ~/.oute/agent.env, sem senha
./scripts/oute attach                                 # ssh -> herdr (detach: Ctrl+B q)
./scripts/oute install                                # 1x por host: link no PATH -> depois é só `oute`
```

`oute up`, em ordem: carrega `~/.oute/agent.env` (o vault só é lido, com a master password, se o arquivo não existe ou com `--refresh-secrets`) → monta `oci:oute-shared` → tira os restos do roteador de modelos que saiu na #218 (entrada diária no crontab do host e container antigo; host sem eles não muda) → garante a imagem (local ou `pull` do ghcr; nunca builda escondido) → `docker compose up` → espera o sshd → limpa imagem antiga solta.

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
| `oute up [--refresh-secrets]` / `down` / `restart` / `status` | ciclo de vida da stack; `status` mostra também o disco livre do Docker e o tamanho da fila do collector |
| `oute secrets refresh` | relê o Vaultwarden (master password), regrava `~/.oute/agent.env` e tranca a sessão |
| `oute` (sem argumento) | sobe a stack se não estiver rodando e abre o herdr |
| `oute watch [host]` | atalho de `approve --watch`; com host (ex.: `oute watch oute-server`), abre a espera naquele host via ssh |
| `oute approve [--watch]` | revisa e executa (ou recusa) os scripts propostos pelos agentes — ver **Canal de aprovação** |
| `oute tray install` / `uninstall` | **só no macOS**: compila o tray (`tray/`), monta `~/Applications/OuteTray.app` (sem ícone no Dock), cria `~/.oute/tray-hosts` se não houver e abre no login por um LaunchAgent; `uninstall` desfaz — ver **Tray no Mac** |
| `oute install` | link `oute` no PATH (`~/.local/bin`, `/opt/homebrew/bin` ou `/usr/local/bin`) |
| `oute attach` / `ssh [cmd]` / `shell` | herdr, ssh no container, `docker exec` |
| `oute logs [svc]` / `follow [svc]` | logs |
| `oute oci-bootstrap` | provisiona storage OCI (idempotente, `DRY_RUN=1`) |
| `oute storage [ls\|lsl\|about] [path]` | lista o bucket direto no OCI (`OUTE_BUCKET=oute-observability` p/ telemetria) |
| `oute sync-shared` | (re)monta o bucket |
| `oute memory-backup [--check <arquivo>]` | backup do volume `oute-memory` (`ai-memory backup`) em `backups/ai-memory/` do `oute-shared`, com retenção por origem; `--check` restaura num tmp e confere o banco; ver **Backup da memória** |
| `oute studio replay --from <ISO> --to <ISO> [--signal s] [--host h] [--legacy]` | **só no oute-server**: reenvia o bucket de telemetria à ingestão do agent-studio (remonta o DuckDB e, junto, o SurrealDB); ver **Observabilidade** |
| `oute lock` / `version` | tranca o vault e apaga a sessão em cache das versões antigas / versão repo × imagem |

Dentro do container: `claude`, `codex`, `herdr`, `gh`, `oci`, `gcloud`, `aws`, `firebase`, `rclone`, `ai-memory`.

`claude` e `codex` ficam no home (`~/.local/bin`, volume `oute-home`), instalados na subida pelo `oute-agents-install` sem `curl | sh` (#199): o claude a partir da reserva da imagem (`claude install`), o codex pelo `install.sh` da release fixa, conferido por sha256, e se atualizam sozinhos sem release: o Claude Code em segundo plano, o Codex com `codex update` quando avisa. O Pi saiu do stack (#217): `pi`, `oute-task` e `oute-swarm spawn` pedidos com o Pi só respondem com erro; o `~/.pi` antigo fica no volume, sem ser tocado. A imagem traz só uma cópia de reserva em `/opt/oute/agents`, fora do PATH, com versão fixa no `Dockerfile` (#200), usada pelo shim enquanto o agente não está no home (primeira subida, sem rede).

## Agentes e modelos (ADR-02)

- `claude` (principal) e `codex` (reserva): assinatura própria (login 1x, persiste no volume `oute-home`). Nenhum proxy de modelo no stack: o roteador de modelos saiu na #218 (ADR-02, Histórico).
- Modelo da sessão pela fase do AI-DLC (ADR-02): o `oute-task` e o `oute-swarm spawn` leem o label `aidlc:<fase>` da issue e abrem com o modelo da tabela `config/select/models.toml` (`--agent`/`--model` > `spike`/`kaizen`/`docs` (o `kaizen` não vale com fase de código: `build`, `qa`, `design`, `plan`, `ship`, `iter`, #409) > fase > Sonnet); `oute-select --json` mostra a escolha sem abrir sessão. Sem label de fase e com o texto da tarefa (o prompt), o Jev classifica a fase direto na TypeSafe (teto de 3 s; só o texto sai da máquina) e a tabela dá o modelo; confiança < 0,6, falha, sem a chave (`OUTE_TYPESAFE_API_KEY`, opcional) ou sem texto: Sonnet com aviso, como com o `gh` fora do ar (#257). A reserva no Codex entra na fatia seguinte (#258).
- Plugin herdr não chama API de LLM: quem fala com modelo é o agente da sessão.

## Observabilidade (ADR-04, ADR-08)

`otel-collector` (sem porta publicada) recebe OTLP de Claude Code (métricas, eventos, traces) e Codex (eventos).
- **Origem = máquina + instância** em todo registro: `host.name` (`OUTE_HOST`; sem ele, o hostname da máquina) e `oute.instance` (`OUTE_INSTANCE`, default `oute-agent`), além de `oute.agent` (claude | codex; `pi` e `router` só em registro até 2026-09-30, #217 e #218). A instância só precisa ser única dentro da máquina (#22). `oute version` mostra a origem.
- **Tudo, com conteúdo** → bucket OCI `oute-observability/otel/{traces,metrics,logs}/host=<máquina>/instance=<instância>/year=…/hour=…/` (gzip, lotes de 5 min). Até a 0.7.4 não havia `host=/instance=` no caminho; esses objetos ficam onde estão.
- **Tudo, com conteúdo** → **agent-studio** (ADR-08), se o vault tiver o item `agent-studio`: pipeline `config/otel/agent-studio.yaml`, lotes de segundos, OTLP/HTTP JSON com a credencial de ingestão (pasta `oute-services` do vault; o `agent` só tem a de leitura). O serviço roda só no oute-server (`OUTE_AGENT_STUDIO=1` no `.env`), grava a telemetria no DuckDB e o estado derivado (rodadas, sessões, pedidos) no SurrealDB, e responde 2xx só depois do commit. O collector do oute-server fala com ele pela rede docker; o do Mac, por `https://agent-studio.oute.pro`, só na tailnet. API só leitura e tela no mesmo endereço. O bucket continua sendo o arquivo frio e o backup.
- **Fila em disco do collector** (volume `oute-otel-queue`): o collector guarda o que ainda não chegou ao destino e retenta sem prazo. **Reserva de 4 GB por host**: 2 GB de disco por fila de 1 GB (o bbolt chega a ~1,7× o limite e não encolhe), duas filas (bucket e agent-studio). O `oute up` avisa, sem bloquear, quando o disco livre do Docker (no Mac, o da VM do Docker Desktop) não comporta a reserva descontado o que a fila já ocupa; o `oute status` mostra o disco livre e o tamanho da fila.
- **Eventos operacionais** (`oute-emit`: rodadas do swarm, pedidos do canal, sessões do `oute-task`): logs OTel ao bucket e ao agent-studio.
- **Ferramenta nova** só entra no stack se mandar consumo ao **bucket + agent-studio**, com a origem e `oute.agent` (ADR-08 §11).
- **Remontar o agent-studio a partir do bucket** (#159, ADR-08 §7), no oute-server: `oute studio replay --from 2026-10-01 --to 2026-10-02` (UTC, pela partição do bucket, com 1 h de folga de cada lado; `--signal`, `--host`, `--legacy` para objetos sem `host=`). Reenvia os objetos pela ingestão do serviço no ar, com dedupe: rodar de novo não duplica, e o SurrealDB volta junto. Resumo por sinal (objetos lidos, gravados × repetidos, falharam); objeto ilegível é listado e pulado, com código ≠ 0. **Objetos com mais de 90 dias estão em Archive (ADR-03): restaure-os antes**, com a credencial de admin do OCI (`oci os object restore --bucket-name oute-observability --name <objeto>`, ~1 h) e rode o replay de novo.
- Conferir: `OUTE_BUCKET=oute-observability ./scripts/oute storage lsl`; a tela do agent-studio (`agent-studio.oute.pro`, na tailnet).

### Backup da memória (#369)
O volume `oute-memory` (wiki, banco e config do ai-memory) não tem backup próprio: `oute memory-backup` roda o `ai-memory backup` no container `agent` e grava `backups/ai-memory/<host>-<instância>-<AAAAMMDDTHHMMSSZ>.tar.gz` (UTC) no `oute-shared`. O tarball tem conteúdo de conversa e o config do cliente: fica só no bucket privado, e o comando nunca o põe em log nem em saída (só nome, tamanhos e contagens).
- **Saída e códigos:** imprime o tamanho do tarball e do banco e avisa se o banco passa de `OUTE_MEMORY_WARN_MB` (padrão 500). Sai ≠ 0 se o backup falhar ou se o arquivo não chegar ao bucket (sem mount ou sem credencial: diz que ficou só local, em `/data/shared/backups/ai-memory/` do container). `OUTE_MEMORY_BACKUP_WAIT` (padrão 60 s) é a espera pelo envio do mount.
- **Retenção:** ficam os `OUTE_MEMORY_BACKUP_KEEP` (padrão 8) mais recentes da mesma origem (host + instância); arquivo de outra origem nunca é apagado.
- **Conferir um backup:** `oute memory-backup --check <arquivo local | nome no bucket>` restaura num diretório temporário do container (nunca no volume) e confere que o banco abre, está íntegro e tem páginas. Antes de restaurar de verdade, rode o `--check`.
- **Restaurar:** `ai-memory restore` recusa rodar com outro ai-memory vivo, então com a stack parada: `oute storage copy backups/ai-memory/<nome> <pasta>` (baixa o tarball), `oute down`, e um one-off que reusa o volume: `docker compose --project-directory <repo> -f docker/compose.yaml run --rm --no-deps -v <pasta>:/in agent ai-memory restore --from /in/<nome> --force`, e `oute up`. O agendamento (timer semanal) é do repo `lab`.

## Storage comum (ADR-03)

`/data/shared` (container) ← `~/.oute/shared` (host) ← `rclone mount oci:oute-shared` (`oute up` monta, `oute down` desmonta). Remote `oci` só por env (item `oci-storage`), sem `rclone.conf` com segredo.
No mount, dono = usuário do container (10001) e grupo = usuário do host (os dois gravam). Sem mount (sem rclone/FUSE/credencial), `/data/shared` vira o volume docker `oute-shared` — o container nunca recebe um diretório comum da home do host (lab#181).
No Mac, `oute up` confere antes de montar: se o rclone não tem a tag `cmount` (o do Homebrew) ou não há FUSE-T/macFUSE, imprime `o rclone do Homebrew não faz 'mount' no macOS` e/ou `FUSE-T (ou macFUSE) não está instalado` com a correção, não chama `rclone mount`, termina em `/data/shared fica local` e segue com código 0. Os caminhos do FUSE conferidos vêm de `OUTE_FUSE_PATHS` (separados por `:`).
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
- Mac: aba do terminal com `oute watch` ao lado do herdr. oute-server: `oute watch` no servidor, ou do Mac `oute watch oute-server`. **Nunca dentro do herdr** — ele roda no container, e o agente poderia aprovar a si mesmo.
- O que roda é exatamente o que foi mostrado (o script é copiado para o host antes de exibir). Registro em `~/.oute/approve/approve.log` e cópia de cada script/saída em `~/.oute/approve/runs/`.
- Os agentes sabem do canal por um bloco gerenciado em `~/.claude/CLAUDE.md` e `~/.codex/AGENTS.md` (o resto desses arquivos não é tocado).
- Mudança permanente no oute-server continua no fluxo do repo `lab` (PR); o canal é para diagnóstico, ajuste pontual e rodar o deploy de PR mergeado.


## Tray no Mac

App de barra de menu (Swift, `MenuBarExtra`; ADR-08 §10) que mostra, sem abrir o terminal, o que o `GET /v1/tray` do agent-studio devolve: máquinas, pedidos pendentes, decisões pendentes do swarm, custo de hoje (estimado marcado), erros da última hora e alertas. Na barra ficam dois números: pedidos pendentes e alertas (`?` quando o agent-studio não sabe dizer). **Não age:** "Aprovar…" e "Recusar…" abrem o Terminal no `oute approve <id>`, onde você lê o script e decide como sempre.

```bash
oute tray install     # compila, monta ~/Applications/OuteTray.app e abre no login
oute tray uninstall   # desfaz (a tabela ~/.oute/tray-hosts editada fica)
```

- Precisa do Swift no Mac (`xcode-select --install`) e do macOS 13 ou mais novo. Sem App Store nem assinatura de desenvolvedor.
- Lê a cada 15 s, só `GET`, com a credencial de leitura (`AGENT_STUDIO_READ_TOKEN`) lida do `~/.oute/agent.env` a cada início; o tray não copia nem registra o valor. Endereço: `OUTE_AGENT_STUDIO_URL` do `.env` (lido no `install`) ou `https://agent-studio.oute.pro`; só `https`.
- Leitura que falha (rede, 401, 500) mantém o último menu e mostra "sem leitura há X".
- Pedido novo vira notificação do macOS (nenhuma na primeira leitura).
- `~/.oute/tray-hosts` diz como chegar a cada máquina, uma linha `<host>=local` ou `<host>=<alias ssh>`. Pedido de host `local` abre `oute approve <id>`; de outro host, `ssh -t <alias> 'bash -lc "oute approve <id>"'`. O alias sai só dessa tabela, nunca do texto da API; host fora dela ou id fora do formato `AAAAMMDD-HHMMSS-slug` deixa o item desabilitado.
- Visual (Kubo, #473): símbolos SF Symbols sem cor, pintados pelo sistema. O âmbar do Gate aparece só no pedido pendente e na decisão pendente do swarm; erro e alerta usam o mesmo símbolo, sem cor. A regra fica em `tray/Sources/TrayCore/MenuSymbol.swift`.
- Logo (#563): a barra de menu mostra a sakura do Kubo sem cor, pintada pelo sistema. O ícone do app, que o macOS também mostra na notificação de pedido novo, é a sakura com a pétala rosa do agent-studio. O `oute tray install` grava o ícone chamando o binário com `--write-icon`; o desenho fica em `tray/Sources/TrayCore/Sakura.swift` e é o mesmo do sprite do agent-studio (`tests/oute-tray.test.sh` confere).
- Testes: `swift test` em `tray/` (o `TrayCore`) e `tests/oute-tray.test.sh` (o `oute tray`, com `swift` e `launchctl` falsos).

## Segurança

- Nenhuma porta de container em `0.0.0.0` (Docker ignora ufw): sshd do container em `127.0.0.1:2222` (`OUTE_SSH_BIND`).
- Usuário do container com **uid/gid próprios (10001)**, que não existem no host (lab#181): arquivo criado pelo container não vira arquivo do `ubuntu`. Do host, o container só grava no mount do bucket; o resto é volume docker ou bind read-only.
- Segredos só no Vaultwarden, lidos **só pelo host**: o container dos agentes não tem sessão, API key nem estado do `bw` — recebe apenas os valores da pasta `oute-agent` em `/run/secrets/agent_env` (gerado em `~/.oute/agent.env`, 0600, que é também o cache do host). Sem sessão do Vaultwarden em disco: o vault só é aberto com a master password digitada (`oute secrets refresh`, `up --refresh-secrets`, `oci-bootstrap`) e trancado (`bw lock`) em seguida (#21). Pastas de outros projetos e `oute-admin` ficam fora do alcance dos agentes, e segredo de serviço (pasta `oute-services` → `~/.oute/services.env`: ingestão do agent-studio, root do SurrealDB) vai só aos serviços, nunca ao `agent` (#256); o SurrealDB fica numa rede docker que o `agent` não alcança. Usuário de serviço OCI só com S3 nos 2 buckets.

## Build, versionamento e retenção

SemVer, fonte única em `VERSION`. `scripts/release x.y.z` faz bump + fecha o `CHANGELOG.md` + commit + tag (push manual); a tag dispara o CI que publica `ghcr.io/renatobardi/oute-agent:x.y.z`. `oute version` mostra repo × imagem.
Build com BuildKit (CI ou local): `ARG OUTE_VERSION` só no fim (bump não invalida cache), cache mounts pra npm/pip, imagem sem doc/man/locale extras. Retenção: ghcr com 2 versões (corrente + anterior); no host, `oute up` apaga imagem solta e o build local mantém só o cache das últimas 24h.
Backup do host: boot volume do oute-server com policy semanal na OCI (inclui `/var/lib/docker`).
