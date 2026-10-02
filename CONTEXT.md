# CONTEXT.md — oute-agent

Resumo para agentes. **O canônico são os ADRs em `docs/adr/`**, mantidos pelo Bardi; os estudos (`estudos/*`) seguem no Project "Oute Agent" do claude.ai. Este arquivo é derivado dos ADRs e atualizado junto. Em conflito, valem os ADRs: pergunte.

## Componentes (docker compose, rede `oute` 172.19.0.0/16)
| serviço | papel |
|---|---|
| `agent` | Ubuntu 24.04 com herdr, sshd (`127.0.0.1:2222`), Claude Code (principal), Codex (reserva), CLIs (gh, oci, gcloud, aws, rclone, ai-memory). IP fixo `172.19.0.5`, uid/gid 10001 |
| `jev-router` | LiteLLM + hook do Jev, roteava o Pi (já fora, #217) para o OpenRouter; sem cliente, **sai** na #218 (ADR-02) |
| `ai-memory` | memória compartilhada entre agentes (hooks + MCP), dados no volume `oute-memory` |
| `otel-collector` | telemetria → bucket OCI (tudo) + Langfuse (só metadados, até ser desligado; ADR-08), com fila em disco por destino |
| `agent-studio` | só no oute-server (profile do compose): recebe OTLP/HTTP JSON do collector de cada host, grava tudo no DuckDB e o estado no SurrealDB; API só leitura para tray, tela e `ops-observe` (ADR-08) |
| `surrealdb` | só no oute-server: estado derivado (rodadas, sessões, pedidos, aprovações), sem porta publicada (ADR-08) |
| `volume-init` | one-shot: dono 10001 nos volumes |

Host: `scripts/oute` (Mac ou oute-server). Só o host lê o Vaultwarden; o container recebe os valores da pasta `oute-agent` em `/run/secrets/agent_env`.

## Decisões (ADRs)
- **ADR-01, runtime:** o container é a fronteira de isolamento, e os agentes rodam em **yolo** dentro dele. Acesso ao host só como **`oute-ops`** (leitura + allowlist de sudo). Ações com root no host passam pelo **canal de aprovação**: o agente propõe com `oute-propose` e o humano aprova no host com `oute approve`/`oute watch`. Configs dos agentes só com edição estrutural. claude/codex vão para o home sem `curl | sh`: a entrada tem versão e sha256 fixos no `Dockerfile` e o resto é auto-update do fornecedor (#199, #200; `scripts/agent-pins` na release). Uma sessão = uma worktree (`oute-task`). Sessões paralelas por issue: `oute-swarm <repo>` (coordenadora triando, ok do Bardi, uma aba do herdr por issue, merge só sob pedido).
- **ADR-02, seleção de agente e modelo** (aceito, #215): **Claude** é o agente principal e o **Codex** a reserva, os dois por assinatura. Cada sessão abre com o modelo da **fase**, por uma tabela fixa em `config/`: Opus (`strat` `intent` `arch` `spec`), Sonnet (`build` `qa` `design` `plan` `ship` `iter`), Haiku (`ops` `ctx` `learn`), com ids exatos. Precedência: `--model`/`--agent` > exceção por label (`kaizen`, `docs` → Haiku) > label `aidlc:<fase>` > **Jev** (só sem label; chamado direto na TypeSafe; confiança < 0,6 → Sonnet). A **reserva** abre o Codex da mesma linha quando o Claude está indisponível ou com cota ≥ 90%. Pi, jev-router, LiteLLM e OpenRouter saem; o roteamento Jev + OpenRouter e o A/B ficam no Histórico do ADR.
- **ADR-03, storage:** OCI Object Storage (compartment `oute-agent`). `oute-shared`, montado via rclone em `/data/shared`, e `oute-observability`, para telemetria. Credencial de serviço com menor privilégio; a de admin nunca vai ao container.
- **ADR-04, observabilidade:** um OTel Collector só. Bucket = tudo, com conteúdo, **nunca apagado**. Langfuse = só metadados (allowlist), substituído pelo agent-studio (ADR-08). Todo registro leva a origem **`host.name` + `oute.instance`** e o agente **`oute.agent`** (claude | codex | router; `pi` só em registro anterior à #217). Toda ferramenta nova precisa emitir nesse padrão (bucket + agent-studio, ADR-08). Adendo (#124): **eventos operacionais** do swarm e do canal vão como logs só ao bucket, com conteúdo escrito pelo agente e **sem a saída do host**; `oute.agent` = quem causou o evento, com o valor `human`. Sessões (#128): `oute.task.*` (aberta, reaberta, removida) e a identidade da sessão no `OTEL_RESOURCE_ATTRIBUTES` das conversas.
- **ADR-08, agent-studio** (aceito, #151): substitui o Langfuse e o "sem spool" do ADR-04. Garantia: todo registro aceito pelo collector chega a todos os destinos **pelo menos uma vez** (fila em disco de 1 GB por destino, retry sem limite; a ingestão deduplica). O **agent-studio** (Python, processo único, só no oute-server) recebe OTLP/HTTP JSON com token, grava a telemetria completa no **DuckDB** (`spans`/`logs`/`metrics`, colunas fixas + JSON, pela hora do fato) e o estado derivado no **SurrealDB**; 2xx só depois do commit. O Mac chega por `agent-studio.oute.pro`, só na tailnet. O bucket é o backup (nada muda nele). O **tray** no Mac lê a API (só leitura) a cada 15 s; aprovar abre o Terminal no `oute approve <id>` (ADR-01 não muda). Ferramenta nova: consumo ao **bucket + agent-studio**.
- **Memória (estudo ai-memory × worktrees):** o ai-memory é a **memória única** dos agentes; a auto memory nativa do Claude Code está desligada.
  - ai-memory **2.4.1**, com hooks em `--project-strategy repo-root` (worktrees e subpastas caem no projeto do repo);
  - Claude com MCP **session-aware** e servidor em `per_session`;
  - Codex passa `workspace`/`project` explícitos;
  - repo com `.ai-memory.toml`.
- **ADR-06, addons:** `addons/<tipo>/` deste repo, montado read-only; o entrypoint linka cada addon em `~/.claude/skills` e `~/.agents/skills`. Primitivo fica na imagem e só cita addon com plano B.
- **Plugins herdr:** próprios (`oute-*`), nada do marketplace em runtime (ADR-05, em estudo).
- **ADR-07, AI-DLC:** todo trabalho segue 12 fases (`strat` `intent` `spec` `arch` `design` `plan` `build` `qa` `ship` `ops` `learn` `iter`) + faixa transversal `ctx`, cada uma com contribuição da IA, **gate humano** (Bardi) e outcome. Skill de fluxo = `oute-aidlc-<fase>-<id>`; issue com label `aidlc:<fase>` e template `aidlc`. Adendo: `learn` e `iter` fecham o **ciclo** numa issue global em `oute-agent` (aberta pela `iter`, fechada pela `learn`); o roadmap é essa issue aberta.

## Glossário
- **Jev:** classificador da TypeSafe (`jev-1.13.0`) que dá a fase de uma sessão sem label, com uma confiança. Evite "roteador": o roteamento por perfil saiu (ADR-02, Histórico).
- **agente principal:** o Claude Code; toda sessão abre nele, salvo reserva ou `--agent`.
- **reserva:** abrir a sessão no Codex, na linha da mesma fase, porque o Claude está indisponível ou com cota ≥ 90%. Evite "fallback" para isso.
- **tabela de fase:** mapa fase → modelo Claude e modelo/esforço do Codex (ADR-02). Só fases são chave; o resto é exceção por label.
- **exceção por label:** label de tipo (`kaizen`, `docs`) que escolhe o modelo antes da fase.
- **origem da escolha:** de onde veio o modelo da sessão: `manual`, `label` ou `jev`.
- **pedido:** script que um agente propõe pelo canal de aprovação, com id `<data>-<hora>-<slug>`. Termina **executado** (com rc), **recusado** ou fica **pendente**. Evite "proposta", "job".
- **sessão:** uma worktree + um branch abertos pelo `oute-task`, de rodada (worker ou coordenadora) ou avulsa. Começa quando a worktree é criada e termina quando o `oute-task clean` a remove; id `oute.task.id`. Contém uma ou mais conversas. Evite "sessão" para a conversa do agente.
- **marca da sessão:** o arquivo `oute-task` no git-dir da worktree (id, repo, slug e rodada) e, por extensão, as chaves `oute.task.*`/`oute.swarm.*` que o `oute-task` e o shim põem no `OTEL_RESOURCE_ATTRIBUTES` das conversas (ADR-04, #128).
- **conversa:** uma sessão do agente no sentido do harness (`session.id` do Claude/Codex). Termina no fim do processo, no `/clear` ou no restore do herdr.
- **sessão avulsa:** sessão fora de uma rodada. Evite "worker" (só a sessão de rodada).
- **evento operacional:** fato de um primitivo (rodada, pedido) registrado como log OTel no bucket, com origem e `oute.agent`. Não é consumo de modelo. Evite "telemetria do swarm" como sinônimo de consumo.
- **agent-studio:** o serviço que recebe a telemetria de todos os hosts e a guarda (DuckDB + SurrealDB), com API só leitura e tela; só no oute-server, `agent-studio.oute.pro` na tailnet (ADR-08). Substitui o Langfuse. Não confundir com `studio.oute.pro` (outro app).
- **tray:** app de barra de menu no Mac (Swift, `MenuBarExtra`) que mostra máquinas, pedidos pendentes, custo, erros e alertas lendo a API do agent-studio; não age: aprovar/recusar abre o Terminal no `oute approve <id>` (ADR-08).
- **spool:** arquivos locais onde o `oute-emit` guarda o evento que não conseguiu entregar (`~/.oute/emit/spool/`, até 50 MB) e reenvia na próxima chamada ou na subida. Não confundir com a **fila em disco** do collector (uma por destino).
- **`oute.event.id`:** id fixo de cada evento do `oute-emit`, derivado do próprio fato (tipo, rodada/pedido, hora do fato, chave, ocorrência); o mesmo ao vivo, no spool e no backfill. É a chave de dedupe da ingestão.
- **hora do fato:** `timeUnixNano` do registro; o agent-studio grava e consulta por ela, nunca pela hora de chegada.
- **`human`:** valor de `oute.agent` quando quem age é o Bardi (decidir um pedido).
- **oute-ops:** usuário restrito do host usado pelo container (`ssh oute-server`).
- **canal de aprovação:** `oute-propose` → `~/outbox` → `oute approve` no host → `~/inbox`.
- **origem:** máquina (`OUTE_HOST`, padrão = hostname) + instância (`OUTE_INSTANCE`, padrão `oute-agent`); a instância só precisa ser única dentro da máquina.
- **lab:** repo `renatobardi/lab`, dono de tudo que muda no host oute-server.
- **primitivo:** peça sem a qual o runtime não cumpre suas garantias: canal de aprovação, worktree por sessão, swarm e seus prompts (`oute-propose`, `oute-task`, `oute-swarm`…). Vai na imagem. Pode citar um addon, mas sempre com plano B: nunca depende dele. Pode ser promovido a addon ou rebaixado, caso a caso.
- **addon:** tudo que é nosso e se instala por cima dos agentes/herdr: skill, persona, script, plugin herdr. Evite usar "plugin" como guarda-chuva.
- **skill:** addon de instrução empacotada que Claude e Codex carregam sob demanda. Uma só para os dois: não depende de recurso exclusivo de um harness. Pode compor outra skill citando-a pelo nome, com um plano B inline para quando ela não estiver disponível.
- **prefixo `oute-`:** todo addon leva esse prefixo, inclusive plugin herdr. Skill de fluxo: `oute-aidlc-<fase>-<id>` (`oute-aidlc-qa-pr-audit`); utilitária: `oute-<id>`.
- **AI-DLC:** o ciclo de entrega do projeto (ADR-07), de `strat` a `iter`, voltando por `learn`.
- **fase:** etapa do AI-DLC, pela abreviação (`spec`, `qa`…). `ctx` não é fase: é a faixa transversal (contexto compartilhado, governança).
- **gate humano:** decisão do Bardi que fecha uma fase (aprovar a rodada, merge, release, lição). Agente não fecha fase com gate.
- **outcome:** o que a fase entrega para liberar a próxima.
- **skill importada:** fork sem volta de uma skill de terceiros, transformada para o nosso uso. Guarda a procedência (origem, commit, licença) e nunca sincroniza com o upstream. Se a licença não permitir, o original é só referência e o texto é todo nosso. Exceção: as do Matt Pocock (`oute-aidlc-*`) entram sem procedência (ADR-06, adendo).
- **persona:** addon com prompt de papel (revisor, arquiteto…), instalado como subagente onde a ferramenta suporta. "agente" continua sendo Claude ou Codex.
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
