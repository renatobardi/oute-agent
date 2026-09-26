# AGENTS.md — repositório oute-agent

Instruções para agentes (Claude Code, Codex, Pi) trabalhando **neste repositório**. As regras gerais (worktree por sessão, canal de aprovação, escopo de memória, issues) vêm das notas globais do container; aqui só o que é específico do oute-agent. Contexto e decisões: `CONTEXT.md`.

## O que é
Runtime em container para agentes de código (herdr + Pi + Claude Code + Codex), com roteamento de modelos (jev-router → OpenRouter), memória compartilhada (ai-memory), storage no OCI e observabilidade (bucket OCI + Langfuse). Roda no `oute-server` (Oracle Cloud, arm64) e no Mac (Apple Silicon).

## Mapa do repo
- `docker/`: `Dockerfile`, `compose.yaml`, `entrypoint.sh` e os comandos do container (`oute-propose`, `oute-inbox`, `oute-task`, `oute-swarm` + `swarm.md`/`swarm-worker.md`, `comandos.md` (guia do `oute help`) + `oute-container`, `agent-wrap.sh`, `agent-notes.md`, `codex_config.py`).
- `scripts/oute`: CLI do **host** (up/down/pull/approve/watch…). `scripts/release`: bump de versão + tag.
- `config/litellm/`: `policy.yaml` é a fonte do roteador; os demais arquivos são gerados pelo `oute router-sync` e ficam fora do git. `config/otel/`: pipelines do collector.
- `VERSION`, `CHANGELOG.md` (Keep a Changelog, seção `[Unreleased]`), `README.md`.

## Regras
- **Entrega por PR.** Release (`scripts/release x.y.z` + tag) e deploy nos hosts são do Bardi.
- **Precisa de release:** mudança na imagem (Dockerfile, entrypoint, arquivos copiados). **Não precisa:** `scripts/oute`, `config/`, `docker/compose.yaml`, que entram com `git pull` (+ `oute down/up`).
- Toda mudança visível entra no `CHANGELOG.md`, em `[Unreleased]`.
- `scripts/oute` roda também no **bash 3.2 do macOS**: nada de `mapfile`, `timeout`, `${var,,}`; array vazio com `set -u` só como `${a[@]+"${a[@]}"}`.
- Configs dos agentes (`~/.codex/config.toml`, `~/.claude/settings.json`, notas) só com edição **estrutural** (tomlkit, jq, bloco gerenciado). Nunca `sed` em arquivo que outra ferramenta também escreve.
- Scripts executáveis com modo `100755` (o CI recusa sem).
- **Nunca** publicar porta de container em `0.0.0.0`. Segredos só pelo Vaultwarden, lidos pelo host. Nada de BW_* no container.
- Telemetria no bucket `oute-observability` **nunca é apagada**. Ferramenta nova só entra se mandar consumo ao bucket + Langfuse.
- Comportamento do **ai-memory** não muda sem decisão explícita do Bardi. Servidor e cliente sempre na mesma versão.
- Mudanças no host oute-server (usuários, sudoers, nginx, firewall, systemd) são do repo `renatobardi/lab`, não daqui.

## Validar antes do PR
- `bash -n` em todo script alterado; `docker compose --project-directory . -f docker/compose.yaml config` com as envs necessárias.
- Collector: `otelcol-contrib validate --config=config/otel/collector.yaml --config=config/otel/langfuse.yaml`.
- Script do host: pensar no caminho do Mac (bash 3.2, sem `timeout`, Docker Desktop).
