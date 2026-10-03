---
name: oute-aidlc-ctx-router
description: Diz qual fase do AI-DLC e qual skill ou primitivo usar na situação atual. Roteador sobre as skills oute-aidlc-* e os primitivos do oute-agent.
disable-model-invocation: true
---

# oute-aidlc-ctx-router

Fase: `ctx` (AI-DLC, ADR-07) · Outcome: próxima fase e skill escolhidas · Gate: Bardi confirma o caminho.

Você não lembra de todas as skills; pergunte aqui. Cada fase termina num **gate humano** do Bardi: não avance uma fase com gate sem o ok dele. O mapa canônico é o ADR-07 e a seção "Fluxo AI-DLC" do `AGENTS.md`.

## Fases e o que usar

| Fase | Quando | Skill / primitivo |
|---|---|---|
| `strat` | tema novo, pergunta de viabilidade, esforço grande e nebuloso | `oute-aidlc-strat-opportunity` (tema → oportunidade/viabilidade → issue com a Intenção), `oute-aidlc-strat-research` (leitura de fontes primárias), `oute-aidlc-strat-wayfinder` (mapa de decisões para o que não cabe numa sessão) |
| `intent` | afiar um plano ou ideia | `oute-aidlc-intent-grill` (sem codebase); `oute-aidlc-intent-grilling` é a base |
| `spec` | a conversa já tem o que construir | `oute-aidlc-spec-issue` → issue pelo template `aidlc` |
| `arch` | ideia que toca o codebase ou decisão difícil de desfazer | `oute-aidlc-arch-grill` (grava ADR e `CONTEXT.md`), `oute-aidlc-arch-deepen` (manutenção: onde aprofundar módulos) |
| `design` | forma de um módulo, pergunta de design que o papel não resolve | `oute-aidlc-design-modules`, `oute-aidlc-design-prototype` |
| `plan` | quebrar spec em trabalho, issues que chegaram cruas, refactor | `oute-aidlc-plan-tickets`, `oute-aidlc-plan-triage` (só issues que você não criou), `oute-aidlc-plan-refactor`; em lote: `oute-swarm` §1 |
| `build` | implementar uma issue | `oute-task` (worktree), `oute-aidlc-build-implement` (usa `oute-aidlc-build-tdd`), `oute-aidlc-build-conflicts` |
| `qa` | PR aberto, antes do merge | `oute-aidlc-qa-pr-audit` (chama `oute-aidlc-qa-security-audit`; esta também roda sozinha sobre um diff); merge só com pedido do Bardi |
| `ship` | release e deploy | `oute-aidlc-ship-release` (checklist: precisa de release, CHANGELOG, versão) → Bardi roda `scripts/release` e faz o deploy → `oute-aidlc-ship-verify` (versão, serviços e telemetria em cada host, pelo canal de aprovação) |
| `ops` | algo quebrado, lento ou intermitente; saúde, custo e telemetria dos agentes | `oute-aidlc-ops-diagnose`; `oute-aidlc-ops-observe` (lê a telemetria do ADR-04) |
| `learn` | relatos de problema, fim de rodada, fim de ciclo | `oute-aidlc-learn-feedback` (relato → issues), `oute-swarm` §4.1 (kaizen, uma rodada), `oute-aidlc-learn-insights` (fecha o ciclo: telemetria, issues, rodadas, canal e ai-memory → insights → lições e melhorias) |
| `iter` | fim de ciclo, fim de sessão | `oute-aidlc-iter-roadmap` (abre o próximo ciclo: foco, issues numa task list, limpeza do backlog); fim de sessão: o que ficou pendente vira issue com `aidlc:<fase>` |
| `ctx` | termos, regras, configuração do repo; ADR criado ou alterado | `oute-aidlc-ctx-domain`, `oute-aidlc-ctx-setup`, `oute-aidlc-ctx-sync` (confere `CONTEXT.md`, `AGENTS.md` e notas contra os ADRs) |

## Fluxo principal: ideia → merge

1. **Afiar:** `oute-aidlc-arch-grill` quando há codebase; `oute-aidlc-intent-grill` quando não há.
2. **Pergunta que precisa de código para responder?** `oute-aidlc-design-prototype` numa sessão separada; o que aprender volta como nota ou handoff do **ai-memory** (`memory_handoff_*`, com `workspace` e `project`), nunca por outro mecanismo.
3. **Cabe numa sessão?**
   - **Não:** `oute-aidlc-spec-issue` → `oute-aidlc-plan-tickets` → uma sessão por ticket (`oute-task` ou `oute-swarm`).
   - **Sim:** `oute-aidlc-build-implement` aqui mesmo.
4. PR com `Closes #n` só com todos os critérios; senão `Refs #n` + `## Falta`. O critério de pós-deploy (fase `ship`: só se verifica depois da release e do deploy nos hosts) não conta para `Closes` × `Refs`: vai no `## Falta` com a marca `(ship)`.
5. `oute-aidlc-qa-pr-audit` no PR. Merge, release e deploy: Bardi.

Mantenha os passos 1 a 3 na mesma janela de contexto. Se ela encher antes do passo 3, faça handoff pelo ai-memory e continue numa sessão nova.

## Entradas laterais

- **Issues chegando cruas** → `oute-aidlc-plan-triage`, que entrega issues `ready`.
- **Algo quebrado** → `oute-aidlc-ops-diagnose`; se o achado for "não há seam para travar o bug", segue para `oute-aidlc-arch-deepen`.
- **Esforço grande demais para uma sessão** → `oute-aidlc-strat-wayfinder`; quando o mapa clarear, entra no fluxo em `oute-aidlc-spec-issue`.

## Pré-requisito

`oute-aidlc-ctx-setup` configura o tracker, os labels e o layout de docs do repo. No oute-agent já está feito (`docs/agents/`).
