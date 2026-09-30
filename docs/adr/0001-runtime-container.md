# ADR-01 — Runtime container do Oute Agent

Status: aceito · 2026-09-22 · adendos: sandbox 2026-09-24 · yolo + acesso ao host 2026-09-25 · segredos sem acesso ao cofre (0.7.0) · host via `oute-ops` (0.7.1 + lab#178) · uid próprio 10001 (0.7.3, lab#181) · canal de aprovação `oute approve` (0.7.6) · 2026-09-25 · sessão do cofre não fica no host (#21, decisão 2026-09-26, implementada no PR #43, sem release ainda) · Pi fora do stack (#217, 2026-09-30, ADR-02) · agentes no home sem `curl | sh` (#199/#200, 2026-09-30)

## Contexto
Um único container Docker que roda em (a) LXC no VPC Oracle Cloud (ARM) e (b) MacBook (Apple Silicon), servindo de "casa" para agentes de código operados via terminal.

## Decisões

| Tema | Decisão | Motivo |
|---|---|---|
| Base | Ubuntu 24.04, imagem multi-arch (arm64 primário, amd64 build opcional) | Compat. binários dos agentes; mesmo artefato nas duas máquinas |
| Multiplexador | **herdr** server em background, sessões persistentes | Sobrevive a desconexão; agentes se orquestram entre panes |
| Acesso | **sshd dentro do container** (porta 2222, só chave pública, sem senha) | Um hop; `oute` (sem argumento) abre o herdr de qualquer lugar |
| Agentes | **Claude Code** (principal) e **Codex** (reserva), por assinatura (+ extensível). Goose removido na 0.5.7; Pi removido na #217 (ADR-02) | Regra de entrada: funcionar com o ai-memory (hooks + handoff) **e** mandar consumo ao bucket + Langfuse (ver `estudos/memoria-diagnostico.md`) |
| Roteamento LLM | *(substituído: ADR-02)* Seleção de agente e modelo por sessão, pela fase. O roteamento híbrido (Pi via **jev-router** → OpenRouter) saiu com o Pi (#217); o jev-router sai na #218 | Ver ADR-02 (Histórico) |
| Memória | **ai-memory** (Akita) como serviço, hooks+MCP instalados em todos os agentes, dados em volume | Handoff entre agentes, SQLite embutido, arm64 nativo |
| Storage comum | **OCI Object Storage** (bucket `oute-shared`) montado via **rclone** em `/data/shared` nos dois hosts | Já está na cloud dele, free tier, S3-compat |
| Segredos | **Vaultwarden (vault.oute.pro) obrigatório, lido só pelo HOST.** O `oute up` resolve a pasta `oute-agent` e grava `~/.oute/agent.env` (0600); o container recebe só esses valores via docker secret em `/run/secrets/agent_env`. **O container não tem sessão, API key nem estado do `bw`** (0.7.0). **Decisão 2026-09-26 (#21): o host também não guarda sessão** — `agent.env` é o cache; o vault só é aberto quando um segredo muda (`--refresh-secrets`) ou em comando admin, com senha digitada e sessão descartada | Fonte única; agentes em yolo não alcançam segredos de outros projetos nem o `oute-admin`; nenhuma chave viva do cofre em disco/backup |
| Acesso ao host | **Só como `oute-ops`** (lab#178): IP fixo do agent `172.19.0.5` (rede `oute` com subnet `172.19.0.0/16`), chave própria `~/.ssh/oute-ops_ed25519`, `ssh oute-server` → gateway `172.19.0.1`. Sem `lxd`/`docker`/`sudo`; sudo só para uma allowlist | Yolo exige fronteira real entre container e host |
| Ações privilegiadas no host | **Canal de aprovação**: o agente propõe (`oute-propose`), o humano aprova e executa fora do container (`oute approve`) | O agente faz o trabalho sem ganhar privilégio; ninguém copia comando da tela |
| Usuário do container | uid/gid **10001** fixos, que não existem no host (0.7.3) | Nada que o agente grava vira arquivo de usuário do host |
| Integrações | gh, oci-cli, gcloud, aws-cli v2, firebase-tools pré-instalados; credenciais vêm da pasta `oute-agent` | |
| Sandbox dos agentes | **O container é a fronteira de isolamento.** Codex com `sandbox_mode = "danger-full-access"` | Ver adendo 2026-09-24 |
| Aprovações dos agentes | **Yolo dentro do container por padrão** (`OUTE_AGENT_YOLO=1`): Claude Code `bypassPermissions`, Codex `approval_policy = "never"` | Ver adendo 2026-09-25 |
| Config dos agentes | Edição **estrutural** apenas (tomlkit para `~/.codex/config.toml`, jq para JSON; `~/.ssh/config` só ganha um `Include` no topo; notas dos agentes num bloco gerenciado entre marcadores). Nunca `sed`/texto | ai-memory e os próprios agentes escrevem nos mesmos arquivos (bug 0.5.3–0.5.8) |
| Versões de terceiros | Fixadas: LiteLLM por digest, ai-memory `2.4.0` (servidor e cliente), otel-collector `0.161.0`; upgrade deliberado | Reprodutibilidade |
| Repo | Monorepo `renatobardi/oute-agent`; addons (skills etc.) em `addons/`, montado read-only (ADR-06) | |

## Topologia (compose)

```
rede oute: 172.19.0.0/16, gateway 172.19.0.1 (= host visto do container)
volume-init    one-shot (root)          chown dos volumes para 10001 quando preciso
agent          herdr + sshd + CLIs      172.19.0.5 · :2222 (ssh, bind 127.0.0.1)   vols: workspace, home, shared · secret: agent_env
jev-router     litellm + hook Jev       :4000 (interno)               env do host: OPENROUTER_API_KEY
ai-memory      akitaonrails/ai-memory   :49374 (interno)              vol: oute-memory
otel-collector                          (interno)                     → bucket oute-observability + Langfuse (ADR-04)
```

Só o `agent` expõe porta ao host (bind 127.0.0.1). Logs stdout com rotação (10 MB × 3).

## Volumes
- `oute-workspace` → `/workspace` (repos clonados)
- `oute-home` → `/home/oute` (config dos agentes, herdr, chave `oute-ops`, `~/outbox` e `~/inbox` do canal de aprovação)
- `oute-memory` → `/data/ai-memory`
- `/data/shared`: bind do mount rclone `~/.oute/shared` quando montado; senão volume `oute-shared`

## Fluxo de boot
**Host (`oute up`):**
1. Com `~/.oute/agent.env` presente, **não abre o vault** (#21). Sem ele, ou com `--refresh-secrets` / `oute secrets refresh`, lê o vault com a master password digitada; a sessão fica só no processo e é trancada (`bw lock`) em seguida. Sem `bw` nativo, o `bw` roda via `docker run` da imagem oute-agent **local** (a atual ou a mais nova, `--pull never`), com o uid do host.
2. Grava `~/.oute/agent.env`: uma linha `export NOME=<%q>` por variável da pasta `oute-agent`, sem `BW_*`.
3. Exporta para o compose só o que jev-router e otel-collector usam, mais a origem (`OUTE_HOST`, `OUTE_INSTANCE`).
4. `router-sync` → `compose up`.

**Container (entrypoint):**
1. Carrega `/run/secrets/agent_env` (via sudo; recusa linha fora do formato) e apaga os restos do `bw` no volume home.
2. `gh auth login --with-token`, grava `~/.oci/config`, `~/.aws/credentials`, `GOOGLE_APPLICATION_CREDENTIALS`, remote `oci` do rclone por env.
3. `ai-memory install-mcp/hooks` para cada agente (idempotente) → `codex_config.py` (sandbox, approval, otel) → `jq` no `~/.claude/settings.json` (yolo) → bloco gerenciado do canal de aprovação nas notas dos agentes → retenção de `.bak-*`.
4. sshd: host key persistida; chave `oute-ops_ed25519` gerada se faltar; `~/.ssh/config.d/oute-host.conf` (Host `oute-server`/`oute-host` → `172.19.0.1`, User `oute-ops`, `HostKeyAlias oute-server`) incluído no topo do `~/.ssh/config`.
5. Sobe `sshd` e `herdr server`.

## Adendo 2026-09-24 — sandbox do Codex (#5)
- **Sintoma:** `bwrap: No permissions to create a new namespace`. O container não tem user namespace não privilegiado.
- **Escolha:** `danger-full-access`, porque o isolamento é o próprio container. Liberar userns foi rejeitado, porque afrouxaria o container inteiro. **Validado na 0.5.4.**

## Adendo 2026-09-25 — yolo no container, acesso restrito ao host (Bardi)
- **Decisão:** agentes sem prompts de aprovação **dentro do container** (0.6.0, `OUTE_AGENT_YOLO=1`; `0` reverte no próximo boot).
- **Achado:** o container entrava no host como `ubuntu` (grupo `lxd`, equivale a root). Resolvido pelo adendo "host via oute-ops" abaixo.
- Sem sudo total/NOPASSWD para os agentes. O risco principal é injeção de prompt vinda de conteúdo não confiável. Operações destrutivas continuam com o Bardi.

## Adendo 2026-09-25 — container sem acesso ao cofre (#6, passo 1, v0.7.0)
- **Achado:** até a 0.6.x o container recebia `BW_SESSION` (+ `BW_PASSWORD`, se definida), o estado do `bw` e a API key; com o yolo, **qualquer agente podia ler o cofre inteiro**: todos os projetos e o `oute-admin`.
- **Correção:**
  - O host resolve só a pasta `oute-agent` e monta os valores como docker secret.
  - Saem do agent: `BW_*`, o volume `bwcli`, o secret `bw_client` e o `extra_hosts` do vault.
  - Os restos do `bw` são apagados no boot, e a sessão antiga foi descartada com `oute lock`.
- **Validado:** 0 variáveis `BW_*`, `bw status` = `unauthenticated`, `/run/secrets` só com `agent_env`; integrações ok.
- **Resíduo aceito:** `vault.oute.pro` ainda resolve no container (DNS split do host); sem credenciais, não serve para nada.
- **Próximo:** #21 — ver adendo 2026-09-26. OpenBao só se surgir necessidade de auditoria, credenciais dinâmicas ou vários hosts.

## Adendo 2026-09-26 — sessão do cofre não fica no host (#21, passo 2; implementado no PR #43)
- **Problema real:** `~/.oute/bw_session` + `~/.oute/bwcli/` = chave viva para o cofre inteiro (todos os projetos + `oute-admin`), em disco permanentemente e copiada nos backups (restic → Google Drive, boot volume OCI). Alcançável por root/ubuntu no host e por quem restaurar backup; o agente não (oute-ops). A sessão só era cacheada por conveniência (cron `router-sync`, `oute pull`, rclone) — e tudo que esses caminhos precisam já está em `agent.env`.
- **Conta de máquina no Vaultwarden (ideia original) descartada:** encolhe o que a chave abre, mas mantém chave viva + master password em arquivo, adiciona org/coleção/usuário/migração de itens, e a coleção teria exatamente o conteúdo de `agent.env` — ganho ≈ zero para esses segredos.
- **Decisão:** eliminar a chave, não encolher. `agent.env` é o cache do host. Vault aberto só em `oute up --refresh-secrets` (ou 1º `up`), `oci-bootstrap` e `router-sync --check-guardrail`, com master password digitada e sessão descartada em seguida (`bw lock`, nada gravado). Cron/pull/rclone lêem só de `agent.env`. Reboot do host não depende disso (`restart: unless-stopped` + `agent.env` em disco).
- **Resíduo aceito:** `agent.env` em texto (0600) no host e nos backups — inerente, é o que o container consome. Rotação/expiração de segredos é tema separado.
- A conta do vault usa e-mail fictício e só guarda projetos (não é cofre pessoal).

## Adendo 2026-09-25 — host via `oute-ops` (lab#178, PR lab#179; oute-agent 0.7.1)
- **Lado do host (repo lab, `scripts/ops/install-oute-ops.sh`, idempotente, rodado do Mac):**
  - Usuário de sistema `oute-ops` (uid 992), só com o grupo próprio.
  - A chave fica em `/etc/ssh/authorized_keys.d/oute-ops` (root 0644), não na home do usuário, para que o agente não consiga trocar a própria chave. Opções: `restrict,pty,from="172.19.0.5/32"`, drop-in `99-oute-ops.conf` com `DisableForwarding`.
  - `/etc/sudoers.d/oute-ops` com `env_reset`, `!setenv`, `noexec` e NOPASSWD só para:
    - `systemctl start` e `status` (`--no-pager`) de `oute-backup-{daily,weekly}`;
    - `nginx -t`;
    - `systemctl reload nginx`;
    - `certbot certificates`;
    - `nft list ruleset`;
    - o wrapper `lab-journal UNIT [N]`, com units fixas.
  - **Deploy no host não entra no sudo:** ele copia conteúdo do repo, que o agente pode editar, e isso equivaleria a root.
  - `/home/ubuntu` (750) e `~/.oute` (700) ficam fechados; os arquivos de backup e as units passaram para root:root.
  - A chave antiga do container foi removida do `ubuntu`, e o sudoers `claude-readonly` também, os dois com backup.
- **Lado do container (0.7.1):** subnet e IP fixos, chave própria, `ssh oute-server` entra como `oute-ops`.
- **Validado de dentro do container:**
  - `id` = `oute-ops` (só o grupo próprio).
  - `sudo -n nginx -t` ok.
  - `docker ps` negado; `cat /home/ubuntu/.oute/bw_session` negado.
  - Login como `ubuntu` com a chave antiga: `Permission denied (publickey)`.
- **Incidente no caminho:** `oute pull` travava porque o `bw` do host rodava da imagem da versão ainda não baixada (ovo e galinha). Corrigido em `972d8b8`: usa imagem local e `--pull never`.
- **Achados do lab para issues próprias:** chaves de deploy no `ubuntu` sem restrição; uid do container = uid do `ubuntu` (1001), com `.oute/shared` montado com escrita (resolvido na 0.7.3); `/mnt/lxd` pertence a `ubuntu:ubuntu`.

## Adendo 2026-09-25 — uid próprio do container (lab#181, 0.7.3/0.7.4)
- uid/gid 10001 fixos na imagem; `volume-init` migra os volumes; o entrypoint lê o secret 0600 do host via `sudo cat`.
- `/data/shared` só recebe do host o mount rclone (dono 10001, grupo do usuário do host); sem mount, vira volume docker.
- A mesma imagem do ghcr serve no oute-server e no Mac, sem rebuild por uid.

## Adendo 2026-09-25 — canal de aprovação `oute approve` (Bardi; 0.7.6)
- **Problema:** o agente descobre o que precisa rodar com root no host e o Bardi tinha que copiar comandos da tela do herdr. Isso é ruim de usar e pior de auditar. Dar sudo ao agente foi rejeitado (ver adendo do yolo).
- **Decisão:** o agente **propõe** e o humano **aprova**, fora do container.
  - Container: `oute-propose "título" [--root]` (script pela entrada padrão) grava `~/outbox/<id>.sh` com rename atômico; `oute-inbox [--wait] <id>` lê o resultado.
  - Host: `oute approve [--watch]`. Copia o script para `~/.oute/approve/runs/` **antes** de exibir (o que roda = o que foi visto), mostra com os caracteres de controle neutralizados (ESC, CR, C1), destaca `--root` e pergunta `[s]im / [N]ão agora / [r]ecusar`. Roda com `sudo bash` (`--root`) ou como o usuário do host, devolve saída + `# rc:` em `~/inbox/<id>.out` (recusa = 126) e registra em `~/.oute/approve/approve.log`.
  - **Nunca dentro do herdr**: ele roda no container, e o agente poderia aprovar o próprio pedido. No Mac, uma aba com `oute approve --watch`; no servidor, `ssh -t oute-server 'oute approve --watch'`.
  - Os agentes aprendem o canal por um bloco gerenciado (`<!-- oute:managed:ops-handoff -->`) em `~/.claude/CLAUDE.md` e `~/.codex/AGENTS.md` (até a #217, também no arquivo equivalente do Pi).
  - Mudança permanente no oute-server continua no fluxo do repo `lab` (PR); o canal serve para diagnóstico, ajuste pontual e para rodar o deploy de um PR já mergeado.
- **Risco residual:** fadiga de aprovação. Mitigação: um objetivo por pedido e script curto; `--root` sempre em destaque.

## Adendo 2026-09-30 — agentes no home sem `curl | sh` (#199, #200)
- **Problema:** o `oute-agents-install` (#195) rodava `curl … | sh` dos instaladores oficiais (`claude.ai/install.sh`, `chatgpt.com/codex/install.sh`) sem conferir nada, como `oute` (sudo sem senha no container). E a reserva npm da imagem ia sem versão: o build da `v0.7.26` pegou um `@openai/codex` publicado 23 s antes, ainda 404 no registry, e a tag ficou sem imagem.
- **SonarCloud do PR #196** (18 achados): os de segurança são os 2 do `Dockerfile:64`, a reserva npm (dependência sem versão travada; `npm install` sem `--ignore-scripts`). O `curl | sh` não foi apontado. Os outros 16 são estilo (14 no teste, 2 no `Dockerfile`). Revisão um a um no PR desta mudança.
- **Decisão: trocar, não aceitar.** Os dois fornecedores publicam sha256 da versão: o Claude no `manifest.json` de cada versão (`downloads.claude.ai`), o Codex no `digest` de cada asset da release do GitHub (e no `codex-package_SHA256SUMS`).
  - **Versões fixas** em `ARG`s do `Dockerfile`: `CLAUDE_CODE_VERSION`, `CODEX_VERSION`, e os sha256 `CLAUDE_CODE_SHA256_ARM64/AMD64` e `CODEX_INSTALLER_SHA256`. A reserva npm usa essas versões; o build confere o binário do claude contra o sha256 do manifest (é o mesmo binário do pacote npm da plataforma).
  - **claude:** `claude install` da reserva conferida, o que o `install.sh` oficial faz depois de baixar e conferir o binário. Sem script baixado.
  - **codex:** o `install.sh` da release `rust-v<CODEX_VERSION>` (asset do GitHub), conferido contra `CODEX_INSTALLER_SHA256` antes de rodar. Sha256 diferente ou pin ausente: não roda, avisa, e vale a reserva.
  - Os dois instalam a versão **mais recente** e ela é conferida pelo código do fornecedor (manifest do Claude, `SHA256SUMS` do Codex), como no auto-update. Fixar a versão da cópia do home desligaria o auto-update (o `claude install <versão>` e o `CODEX_RELEASE=<versão>` travam), e tirar o auto-update está fora de escopo (#195).
  - A release confere os pins com `scripts/agent-pins` (passo 6 da `oute-aidlc-ship-release`).
- **Resíduo aceito:** o que entra depois do pin (instalação da mais recente e auto-update) é código e checksum do fornecedor, por TLS; o pin só ancora a entrada. O `postinstall` do pacote npm do claude continua rodando no build (é o que copia o binário nativo; o sha256 conferido em seguida cobre o resultado).

## LXD
Container LXC precisa `security.nesting=true` e `security.syscalls.intercept.mknod=true` para Docker dentro. (Hoje o oute-agent roda direto no Docker do host oute-server — exceção registrada no lab.)

## Não decidido / próximos temas
- Layout do `/data/shared` e políticas de sync (rclone mount vs bisync)
- ~~Repo `oute-agent-plugins` (taxonomia de skills)~~ → decidido no ADR-06 (addons em `addons/`, sem repo separado)
- Várias instâncias por máquina (#22)
