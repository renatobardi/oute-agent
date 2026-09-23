# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Versionamento: [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Added
- `oute router-sync`: consulta o OpenRouter (`/providers`, `/models`, `/models/user`, `/models/{id}/endpoints`) e gera `router.yaml`, `config.yaml`, `candidates.json` e `catalog.json` a partir de `config/litellm/policy.yaml` (espelho do guardrail: allowlist de provedores, perfis com padrões de modelo). Pi lista os perfis gerados.

- Roteamento em 2 etapas: Jev escolhe o **perfil**; o OpenRouter escolhe o **modelo** dentro dele (`models` = até 3 modelos elegíveis do perfil — limite do OpenRouter, `provider.sort` por perfil, `partition: none`, fallback automático). Perfis também podem ser pedidos direto (`/model coder` no Pi).
- `router-sync` roda em todo `oute up` (se falhar, mantém o último catálogo) e diariamente via `oute schedule` (crontab 04:00).

### Changed
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
