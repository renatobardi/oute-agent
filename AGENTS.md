# AGENTS.md — repositório oute-agent

Instruções para agentes (Claude Code, Codex, Pi) trabalhando **neste repositório**. As regras gerais (worktree por sessão, canal de aprovação, escopo de memória, issues) vêm das notas globais do container; aqui só o que é específico do oute-agent. Contexto e decisões: `CONTEXT.md`.

## O que é
Runtime em container para agentes de código (herdr + Pi + Claude Code + Codex), com roteamento de modelos (jev-router → OpenRouter), memória compartilhada (ai-memory), storage no OCI e observabilidade (bucket OCI + agent-studio, ADR-08; o Langfuse roda em paralelo até ser desligado). Roda no `oute-server` (Oracle Cloud, arm64) e no Mac (Apple Silicon).

## Mapa do repo
- `docker/`: `Dockerfile`, `compose.yaml`, `entrypoint.sh` e os comandos do container (`oute-propose`, `oute-inbox`, `oute-emit` (eventos operacionais ao bucket, ADR-04), `oute-task`, `oute-swarm` + `swarm.md`/`swarm-worker.md`, `comandos.md` (guia do `oute help`) + `oute-container`, `agent-wrap.sh`, `agent-notes.md`, `codex_config.py`). `docker/agent-studio/`: o agent-studio (ADR-08; Python, vai na imagem, serviço próprio no compose, só no oute-server).
- `addons/<tipo>/`: addons (ADR-06). Hoje só `addons/skills/oute-*` (skill de fluxo: `oute-aidlc-<fase>-<id>`, ADR-07) (`SKILL.md` com `name` = pasta). Montado read-only em `/opt/oute/addons`; o `docker/addons-link` (chamado pelo entrypoint) cria os links em `~/.claude/skills` e `~/.agents/skills`. Skill entra com `git pull` + `oute down/up`, sem release.
- `tests/`: testes em bash puro (`tests/*.test.sh`), rodados pelo workflow `pr` em todo PR. `tests/lib/`: apoio compartilhado (receptor OTLP falso).
- `scripts/oute`: CLI do **host** (up/down/pull/approve/watch…). `scripts/release`: bump de versão + tag.
- `config/litellm/`: `policy.yaml` é a fonte do roteador; os demais arquivos são gerados pelo `oute router-sync` e ficam fora do git. `config/otel/`: pipelines do collector.
- `.github/ISSUE_TEMPLATE/aidlc.md`: template de issue (AI-DLC).
- `VERSION`, `CHANGELOG.md` (Keep a Changelog, seção `[Unreleased]`), `README.md`.

## Regras
- **Entrega por PR.** Release (`scripts/release x.y.z` + tag) e deploy nos hosts são do Bardi.
- **Precisa de release:** mudança na imagem (Dockerfile, entrypoint, arquivos copiados). **Não precisa:** `scripts/oute`, `config/`, `docker/compose.yaml`, que entram com `git pull` (+ `oute down/up`).
- Toda mudança visível entra no `CHANGELOG.md`, em `[Unreleased]`.
- `scripts/oute` roda também no **bash 3.2 do macOS**: nada de `mapfile`, `timeout`, `${var,,}`; array vazio com `set -u` só como `${a[@]+"${a[@]}"}`.
- Configs dos agentes (`~/.codex/config.toml`, `~/.claude/settings.json`, notas) só com edição **estrutural** (tomlkit, jq, bloco gerenciado). Nunca `sed` em arquivo que outra ferramenta também escreve.
- Scripts executáveis com modo `100755` (o CI recusa sem).
- **Workflows de CI (`.github/workflows/`) só pelo Bardi.** O `GH_TOKEN` dos agentes não tem o escopo `workflow`, de propósito: agente nenhum cria ou altera CI (o GitHub recusa o push e, na API, responde 404). O agente deixa o arquivo pronto e publica no PR um link para o editor web já preenchido (`https://github.com/<dono>/<repo>/new/<branch>?filename=<caminho>&value=<conteúdo url-encoded>`); o Bardi commita pela interface web. O resto do PR segue normal, com o workflow no `## Falta` até entrar. Não peça o escopo `workflow` para contornar, e o canal de aprovação também não serve (o host não tem credencial do GitHub). Workflow disparado só em `pull_request` é validado por um PR descartável (commit vazio, fechado sem merge).
- **Nunca** publicar porta de container em `0.0.0.0`. Segredos só pelo Vaultwarden, lidos pelo host. Nada de BW_* no container.
- Telemetria no bucket `oute-observability` **nunca é apagada**. Ferramenta nova só entra se mandar consumo ao bucket + agent-studio (ADR-08).
- Comportamento do **ai-memory** não muda sem decisão explícita do Bardi. Servidor e cliente sempre na mesma versão.
- Mudanças no host oute-server (usuários, sudoers, nginx, firewall, systemd) são do repo `renatobardi/lab`, não daqui.

## Fluxo AI-DLC (ADR-07)
Todo trabalho segue as fases do ADR-07. Cada fase tem um **gate humano** do Bardi: agente não fecha fase com gate. Issue nova pelo template `aidlc` e com o label `aidlc:<fase>`; ao mudar de fase, troque o label.

| Fase | Primitivos e skills |
|---|---|
| `strat` | `oute-aidlc-strat-opportunity`, `oute-aidlc-strat-research`, `oute-aidlc-strat-wayfinder` |
| `intent` | `oute-aidlc-intent-grill` (base: `oute-aidlc-intent-grilling`) |
| `spec` | issue pelo template `aidlc`, `oute-aidlc-spec-issue` |
| `arch` | `docs/adr/`, `CONTEXT.md`, `oute-aidlc-arch-grill`, `oute-aidlc-arch-deepen` |
| `design` | `oute-aidlc-design-modules`, `oute-aidlc-design-prototype` |
| `plan` | `oute-swarm` §1 (triagem + ok do Bardi), `oute-aidlc-plan-tickets`, `oute-aidlc-plan-triage`, `oute-aidlc-plan-refactor` |
| `build` | `oute-task`, worker do swarm, `oute-aidlc-build-implement`, `oute-aidlc-build-tdd`, `oute-aidlc-build-conflicts` |
| `qa` | `oute-aidlc-qa-pr-audit` (chama `oute-aidlc-qa-security-audit`), `tests/`, CI `pr` |
| `ship` | `oute-aidlc-ship-release` (checklist antes da release), `scripts/release` + deploy nos hosts (Bardi), `oute-aidlc-ship-verify` (pós-deploy pelo canal de aprovação) |
| `ops` | telemetria ADR-04 (bucket + Langfuse; agent-studio pelo ADR-08, #157), canal de aprovação, `oute-aidlc-ops-observe`, `oute-aidlc-ops-diagnose` |
| `learn` | `oute-swarm` §4.1 (kaizen, por rodada), `oute-aidlc-learn-insights` (fecha o ciclo: insights entre rodadas e fontes → lições e melhorias), `oute-aidlc-learn-feedback` |
| `iter` | `oute-aidlc-iter-roadmap` (abre o próximo ciclo: foco, issues e limpeza do backlog), issues de fim de sessão |
| `ctx` | `CONTEXT.md`, `AGENTS.md`, ai-memory, `oute-aidlc-ctx-router`, `oute-aidlc-ctx-domain`, `oute-aidlc-ctx-setup` |

Skill de fluxo nova entra nesta tabela no mesmo PR. Por onde começar: `oute-aidlc-ctx-router`. Utilitária: `oute-skill-writing` (escrever e editar skills).

## Validar antes do PR
- `bash -n` em todo script alterado; `docker compose --project-directory . -f docker/compose.yaml config` com as envs necessárias.
- Linker de addons: `tests/addons-link.test.sh`.
- Collector: `otelcol-contrib validate --config=config/otel/collector.yaml --config=config/otel/langfuse.yaml`.
- Script do host: pensar no caminho do Mac (bash 3.2, sem `timeout`, Docker Desktop).

## Agent skills

### Issue tracker

GitHub Issues de `renatobardi/oute-agent`, via `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Defaults, exceto ready-for-agent → `ready` (label já existente). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` na raiz. See `docs/agents/domain.md`.
