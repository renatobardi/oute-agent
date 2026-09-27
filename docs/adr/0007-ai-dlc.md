# ADR-07 — AI-DLC: ciclo de entrega AI-native

Status: **aceito** (2026-09-27). Base: plano AI-Native Software Delivery Lifecycle do Bardi; estudo de aderência `estudos/ai-dlc-aderencia.md` (Project).

## Contexto
- IA só no passo de código não é um SDLC AI-native: é o SDLC antigo com código mais rápido. O ciclo vai de estratégia a operação e volta como aprendizado.
- Princípio: **a IA acelera, o humano responde.** Em cada fase: o que a IA faz, que contexto precisa, o que o humano decide.
- O oute-agent já cobria bem spec, arquitetura, plan, build e qa (issues autocontidas, ADRs, triagem do swarm, `oute-task`, auditoria de PR). Strategy, deploy verificado, operação, aprendizado de uso e iteração estavam implícitos ou ausentes, e as skills não diziam a que fase serviam.

## Decisão
Todo o trabalho no oute-agent segue as 12 fases abaixo. Projeto solo: o Bardi ocupa todos os papéis humanos; o **gate humano** de cada fase é dele. Agente nenhum fecha uma fase que tem gate sem o ok explícito.

| # | Fase | Abrev. | IA contribui | Gate humano (Bardi) | Outcome |
|---|---|---|---|---|---|
| 01 | Strategy & Opportunity | `strat` | analisa insumos, oportunidades, viabilidade | direção e prioridade | oportunidade aceita, ligada a um tema |
| 02 | Problem & Intent | `intent` | sintetiza pesquisa, necessidade, dados | valida problema e critério de sucesso | problema, intenção e critério de sucesso |
| 03 | Functional Specification | `spec` | redige requisitos e critérios de aceite | aprova escopo | issue com critérios de aceite e fora de escopo |
| 04 | Architecture Evaluation | `arch` | acha capacidades existentes, confere ADRs e padrões, explora opções | decide trade-offs | ADR aceito / reuso decidido |
| 05 | Technical Design | `design` | opções de desenho, interfaces, dados, segurança | aprova a abordagem | desenho pronto para implementar |
| 06 | Plan & Refine | `plan` | quebra o trabalho, dependências, riscos | prioriza e aprova a rodada | issues `ready` com dependências |
| 07 | Build | `build` | código, testes, docs | revisa | PR com código, testes, docs e CHANGELOG |
| 08 | Testing & QA | `qa` | gates, auditoria, análise de resultado | merge (só sob pedido) | PR auditado e mergeado |
| 09 | Deploy (Release) | `ship` | prepara release, checa, automatiza | release, tag e deploy | release publicada e deploy verificado |
| 10 | Operate & Observe | `ops` | lê telemetria, acha anomalia, diagnostica | confiabilidade e segurança | hosts saudáveis, telemetria completa |
| 11 | Feedback & Learn | `learn` | analisa uso, custo, incidentes, rodadas | escolhe as lições | lições e melhorias priorizadas |
| 12 | Iterate | `iter` | sintetiza aprendizados em propostas | decide o próximo ciclo | backlog/roadmap atualizado |
| — | Contexto compartilhado e governança | `ctx` | mantém glossário, ADRs, regras, memória coerentes | decide o que vira regra | `CONTEXT.md`, ADRs e `AGENTS.md` coerentes |

`ctx` não é fase: é a faixa transversal (shared context + enablers) que alimenta todas.

### Regras
- **Nome de skill de fluxo:** `oute-aidlc-<fase>-<id>`, com `<fase>` da tabela (ex.: `oute-aidlc-qa-pr-audit`). Skill utilitária, fora do fluxo, segue `oute-<id>` (ADR-06).
- **Toda skill de fluxo abre o corpo com uma linha** `Fase: <abrev> · Outcome: <outcome> · Gate: <gate>`.
- **Issues:** label `aidlc:<fase>` com a fase em que a issue está; issue nova pelo template `.github/ISSUE_TEMPLATE/aidlc.md` (Intenção, Contexto, Critérios de aceite, Fora de escopo).
- **Primitivos do swarm** declaram a fase que cobrem: triagem = `plan`, worker = `build`, auditoria do PR = `qa`, retrospectiva kaizen = `learn`. Seguem primitivos (ADR-06).
- **Contexto compartilhado:** canônico = repo (`docs/adr/`, `CONTEXT.md`, `AGENTS.md`). O Project do claude.ai guarda estudos e status; o ai-memory guarda sessões e handoff.
- **Loop:** `learn` alimenta `iter`, que abre o próximo `strat`/`intent`. Métricas, incidentes e lições voltam ao mesmo backlog.

## Opções consideradas
- **Manter o SDLC implícito:** o fluxo já funcionava de spec a qa, mas sem nome de fase, sem outcome e sem loop de volta.
- **Adotar o fluxo das skills de engenharia do Matt Pocock como está:** cobre de `intent` a `qa`, não tem gate humano por fase e não cobre `ship`, `ops`, `learn` nem `iter`. As skills entram como fork adaptado, dentro desta taxonomia.

## Consequências
- `oute-pr-audit` vira `oute-aidlc-qa-pr-audit`; os marcadores dos comentários migram para `<!-- oute-aidlc-qa-pr-audit -->` e `<!-- oute-aidlc-qa-pr-audit:merge -->`.
- Fases sem skill (`strat`, `ship`, `ops`, `learn` de uso/custo, `iter`) viram issues próprias.
- O catálogo de skills por fase fica no `AGENTS.md` (seção "Fluxo AI-DLC") e acompanha as skills que entram.
