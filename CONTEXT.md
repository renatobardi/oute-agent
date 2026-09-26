# CONTEXT.md — oute-agent

Resumo para agentes. **O canônico são os ADRs no Project "Oute Agent" do claude.ai** (arquitetura/01–04, estudos/*), mantidos pelo Bardi; este arquivo é derivado deles e atualizado junto. Em conflito, vale o Project: pergunte.

## Componentes (docker compose, rede `oute` 172.19.0.0/16)
| serviço | papel |
|---|---|
| `agent` | Ubuntu 24.04 com herdr, sshd (`127.0.0.1:2222`), Pi, Claude Code, Codex, CLIs (gh, oci, gcloud, aws, rclone, ai-memory). IP fixo `172.19.0.5`, uid/gid 10001 |
| `jev-router` | LiteLLM (fixado por digest) + hook do Jev: roteia o Pi (e clientes OpenAI-compatible) para o OpenRouter |
| `ai-memory` | memória compartilhada entre agentes (hooks + MCP), dados no volume `oute-memory` |
| `otel-collector` | telemetria → bucket OCI (tudo) + Langfuse (só metadados) |
| `volume-init` | one-shot: dono 10001 nos volumes |

Host: `scripts/oute` (Mac ou oute-server). Só o host lê o Vaultwarden; o container recebe os valores da pasta `oute-agent` em `/run/secrets/agent_env`.

## Decisões (ADRs)
- **ADR-01, runtime:** o container é a fronteira de isolamento, e os agentes rodam em **yolo** dentro dele. Acesso ao host só como **`oute-ops`** (leitura + allowlist de sudo). Ações com root no host passam pelo **canal de aprovação**: o agente propõe com `oute-propose` e o humano aprova no host com `oute approve`/`oute watch`. Configs dos agentes só com edição estrutural. Uma sessão = uma worktree (`oute-task`). Sessões paralelas por issue: `oute-swarm <repo>` (coordenadora triando, ok do Bardi, uma aba do herdr por issue, merge só sob pedido).
- **ADR-02, roteamento:** em 2 etapas. O **Jev** (Decisions API do OpenRouter) escolhe o **perfil**; o OpenRouter escolhe o modelo dentro dele (≤ 3 modelos, `provider.sort`). Os perfis são publicados como presets `@preset/oute-<perfil>` (ZDR, `data_collection: deny`). O guardrail do OpenRouter é a fonte de verdade, espelhado em `config/litellm/policy.yaml` e checado com `oute router-sync --check-guardrail`. Claude/Codex usam assinatura própria, fora do router.
- **ADR-03, storage:** OCI Object Storage (compartment `oute-agent`). `oute-shared`, montado via rclone em `/data/shared`, e `oute-observability`, para telemetria. Credencial de serviço com menor privilégio; a de admin nunca vai ao container.
- **ADR-04, observabilidade:** um OTel Collector só. Bucket = tudo, com conteúdo, **nunca apagado**. Langfuse = só metadados (allowlist). Todo registro leva a origem **`host.name` + `oute.instance`** e o agente **`oute.agent`** (claude | codex | pi | router). Toda ferramenta nova precisa emitir nesse padrão.
- **Memória (estudo ai-memory × worktrees):** o ai-memory é a **memória única** dos agentes; a auto memory nativa do Claude Code está desligada.
  - ai-memory **2.4.1**, com hooks em `--project-strategy repo-root` (worktrees e subpastas caem no projeto do repo);
  - Claude com MCP **session-aware** e servidor em `per_session`;
  - Codex e Pi passam `workspace`/`project` explícitos;
  - repo com `.ai-memory.toml`.
- **Plugins herdr:** próprios (`oute.*`), nada do marketplace em runtime (ADR-05, em estudo).

## Glossário
- **Jev:** roteador de perfis (`typesafe/jev-1.13`), consultado por request.
- **perfil:** `reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`.
- **oute-ops:** usuário restrito do host usado pelo container (`ssh oute-server`).
- **canal de aprovação:** `oute-propose` → `~/outbox` → `oute approve` no host → `~/inbox`.
- **origem:** máquina (`OUTE_HOST`, padrão = hostname) + instância (`OUTE_INSTANCE`, padrão `oute-agent`); a instância só precisa ser única dentro da máquina.
- **lab:** repo `renatobardi/lab`, dono de tudo que muda no host oute-server.

## Backlog
Issues em `renatobardi/oute-agent`, com os labels `tema`, `infra`, `agentes`, `seguranca`, `ci`, `bug`, `debito`, `observabilidade`, `spike` e `later`.
