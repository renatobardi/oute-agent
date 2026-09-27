# CONTEXT.md — oute-agent

Resumo para agentes. **O canônico são os ADRs em `docs/adr/`**, mantidos pelo Bardi; os estudos (`estudos/*`) seguem no Project "Oute Agent" do claude.ai. Este arquivo é derivado dos ADRs e atualizado junto. Em conflito, valem os ADRs: pergunte.

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
- **ADR-06, addons:** `addons/<tipo>/` deste repo, montado read-only; o entrypoint linka cada addon em `~/.claude/skills` e `~/.agents/skills`. Primitivo fica na imagem e só cita addon com plano B.
- **Plugins herdr:** próprios (`oute-*`), nada do marketplace em runtime (ADR-05, em estudo).
- **ADR-07, AI-DLC:** todo trabalho segue 12 fases (`strat` `intent` `spec` `arch` `design` `plan` `build` `qa` `ship` `ops` `learn` `iter`) + faixa transversal `ctx`, cada uma com contribuição da IA, **gate humano** (Bardi) e outcome. Skill de fluxo = `oute-aidlc-<fase>-<id>`; issue com label `aidlc:<fase>` e template `aidlc`. Adendo: `learn` e `iter` fecham o **ciclo** numa issue global em `oute-agent` (aberta pela `iter`, fechada pela `learn`); o roadmap é essa issue aberta.

## Glossário
- **Jev:** roteador de perfis (`typesafe/jev-1.13`), consultado por request.
- **perfil:** `reasoning`, `coder`, `coder-fast`, `long-context`, `cheap`, `vision`.
- **oute-ops:** usuário restrito do host usado pelo container (`ssh oute-server`).
- **canal de aprovação:** `oute-propose` → `~/outbox` → `oute approve` no host → `~/inbox`.
- **origem:** máquina (`OUTE_HOST`, padrão = hostname) + instância (`OUTE_INSTANCE`, padrão `oute-agent`); a instância só precisa ser única dentro da máquina.
- **lab:** repo `renatobardi/lab`, dono de tudo que muda no host oute-server.
- **primitivo:** peça sem a qual o runtime não cumpre suas garantias: canal de aprovação, worktree por sessão, swarm e seus prompts (`oute-propose`, `oute-task`, `oute-swarm`…). Vai na imagem. Pode citar um addon, mas sempre com plano B: nunca depende dele. Pode ser promovido a addon ou rebaixado, caso a caso.
- **addon:** tudo que é nosso e se instala por cima dos agentes/herdr: skill, persona, script, plugin herdr. Evite usar "plugin" como guarda-chuva.
- **skill:** addon de instrução empacotada que Claude, Codex e Pi carregam sob demanda. Uma só para os três: não depende de recurso exclusivo de um harness. Pode compor outra skill citando-a pelo nome, com um plano B inline para quando ela não estiver disponível.
- **prefixo `oute-`:** todo addon leva esse prefixo, inclusive plugin herdr. Skill de fluxo: `oute-aidlc-<fase>-<id>` (`oute-aidlc-qa-pr-audit`); utilitária: `oute-<id>`.
- **AI-DLC:** o ciclo de entrega do projeto (ADR-07), de `strat` a `iter`, voltando por `learn`.
- **fase:** etapa do AI-DLC, pela abreviação (`spec`, `qa`…). `ctx` não é fase: é a faixa transversal (contexto compartilhado, governança).
- **gate humano:** decisão do Bardi que fecha uma fase (aprovar a rodada, merge, release, lição). Agente não fecha fase com gate.
- **outcome:** o que a fase entrega para liberar a próxima.
- **skill importada:** fork sem volta de uma skill de terceiros, transformada para o nosso uso. Guarda a procedência (origem, commit, licença) e nunca sincroniza com o upstream. Se a licença não permitir, o original é só referência e o texto é todo nosso. Exceção: as do Matt Pocock (`oute-aidlc-*`) entram sem procedência (ADR-06, adendo).
- **persona:** addon com prompt de papel (revisor, arquiteto…), instalado como subagente onde a ferramenta suporta. "agente" continua sendo Claude, Codex ou Pi.
- **script:** addon determinístico, sem LLM; o agente ou o humano o chama e o resultado é sempre o mesmo.
- **worker:** só a sessão do swarm por issue (uma aba do herdr). Não usar para scripts.
- **lição:** fato com evidência que vira regra escrita, só com aprovação do Bardi. Origem: uma rodada do swarm (**kaizen**, proposta pela coordenadora) ou um insight. Lição é sempre regra; o que pede trabalho é melhoria. O label `kaizen` marca toda issue de lição, de qualquer origem (o corpo diz qual).
- **insight:** padrão observado num período, em mais de uma rodada ou fonte (telemetria, issues, rodadas, canal de aprovação), com evidência. Sozinho não muda nada: no gate, o Bardi o torna lição, melhoria ou o descarta.
- **melhoria:** insight que vira issue de trabalho (não regra).
- **ciclo:** período entre dois gates de `learn`. Abre no gate da `iter` (o Bardi decide foco e temas) e fecha no gate da `learn` seguinte (o Bardi escolhe lições e melhorias). Contém zero ou mais rodadas e sessões avulsas. Não confundir com rodada.
- **rodada:** uma execução do swarm (`oute-swarm`), da triagem ao fechamento, com id `swarm-<data>-<hora>`.
- **nível da lição:** onde a regra vale. `repo` (AGENTS.md do repo alvo), `swarm` (prompts da coordenadora/worker), `agentes` (notas globais do container), `skill` (addon `oute-*`). Se valeria num repo diferente, não é `repo`.
- **plugin:** só no sentido nativo de cada ferramenta (plugin do Claude Code, plugin herdr). Um plugin herdr é um tipo de addon.

## Backlog
Issues em `renatobardi/oute-agent`, com o label de fase `aidlc:<fase>` e os labels `tema`, `infra`, `agentes`, `seguranca`, `ci`, `bug`, `debito`, `observabilidade`, `spike` e `later`.
