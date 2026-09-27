---
name: oute-aidlc-strat-opportunity
description: Leva um tema cru a oportunidade e viabilidade e, com o ok do Bardi, a uma issue pelo template aidlc com a seção Intenção (problema, para quem, critério de sucesso) preenchida.
disable-model-invocation: true
---

# oute-aidlc-strat-opportunity

Fase: `strat` (AI-DLC, ADR-07) · Outcome: parecer de oportunidade/viabilidade e, se aprovado, issue `aidlc:intent` com a Intenção preenchida · Gate: Bardi decide seguir, pesquisar mais ou arquivar.

Chegou um **tema**: uma ideia, incômodo ou pergunta de "vale a pena?", ainda sem problema nomeado. Esta skill é a triagem de **oportunidade** antes de qualquer spec: decide se o tema merece trabalho e, se merece, entrega o problema e o critério de sucesso por escrito. Ela para na Intenção. Critérios de aceite são da fase `spec` (`oute-aidlc-spec-issue`); afiar a intenção por entrevista é da `intent` (`oute-aidlc-intent-grill`).

## Passos

### 1. Tema
Escreva o tema numa frase. Leia `CONTEXT.md`, os ADRs de `docs/adr/` que ele toca e procure trabalho já existente: `gh issue list --state all --search "<termos>"`.
Pronto quando: o tema está numa frase e você sabe se já há issue sobre ele. Se há issue aberta cobrindo o tema, pare aqui: mostre-a ao Bardi e proponha comentar nela em vez de abrir outra.

### 2. Oportunidade
Responda com evidência, não com impressão:
- **Quem** sofre (Bardi, um agente, um host, um usuário do produto) e **o quê**, em termos do glossário do `CONTEXT.md`.
- **Evidência:** issues, relatos, telemetria (ADR-04: bucket + Langfuse), incidentes de rodada, lições do swarm. Cite a fonte de cada uma.
- **Custo de não fazer:** o que acontece se o tema ficar parado.

Fato externo que precisa de fonte primária (doc oficial, código, spec de terceiro) vai para `oute-aidlc-strat-research`; sem ela, leia as fontes você mesmo, em sequência, e cite.
Pronto quando: cada afirmação tem fonte, ou está marcada como **hipótese**.

### 3. Viabilidade
- **Encaixe:** o tema respeita os ADRs e as regras do `AGENTS.md` (hosts pelo repo `lab`, CI só pelo Bardi, `scripts/oute` em bash 3.2, ai-memory sem mudança de comportamento sem decisão, telemetria nunca apagada)? Onde conflita, diga qual ADR e se o caminho é mudar o ADR (`oute-aidlc-arch-grill`).
- **Tamanho:** cabe numa sessão? Se claramente não, o próximo passo é `oute-aidlc-strat-wayfinder`, não uma issue.
- **Alternativas**, sempre com "não fazer" entre elas, e o risco principal de cada uma.
- **Dúvidas abertas** que só o Bardi responde.

Pronto quando: há pelo menos duas alternativas (uma é "não fazer") e cada dúvida aberta está listada.

### 4. Parecer (gate do Bardi)
Mostre ao Bardi, curto:
- oportunidade (quem, o quê, evidência) e viabilidade (encaixe, tamanho, alternativas);
- **recomendação:** `seguir`, `pesquisar mais` (o quê e com qual skill) ou `arquivar` (por quê);
- se `seguir`: o rascunho da issue do passo 5, completo.

Pergunte as dúvidas abertas uma por vez, com a sua resposta recomendada. Se a intenção ainda está vaga depois delas, proponha `oute-aidlc-intent-grill` antes de criar a issue.
Pronto quando: o Bardi escolheu `seguir`, `pesquisar mais` ou `arquivar`. A issue só nasce com `seguir`. Com `arquivar`, nada é criado, a não ser que ele peça registro (issue com o label `later`).

### 5. Issue
Monte o corpo pelo template `.github/ISSUE_TEMPLATE/aidlc.md`, na mesma ordem de seções:
- **Intenção:** o problema, para quem, e o **critério de sucesso**: observável depois da entrega por alguém que não é o autor (um comando, um número, um comportamento visível). "Ficar melhor" não é critério; "a rodada fecha sem handoff sobrando no `memory_handoff_list`" é.
- **Contexto:** a evidência do passo 2 e o resumo da viabilidade do passo 3 (ADRs tocados, alternativa escolhida e as descartadas).
- **Critérios de aceite:** `- [ ] (fase spec)`. Não escreva: é o gate da `spec`.
- **Fora de escopo:** o que ficou de fora no parecer.
- **Fase / gate:** `intent`; gate: Bardi valida a Intenção; próximo passo: `oute-aidlc-intent-grill` ou `oute-aidlc-spec-issue`.

Grave o corpo num arquivo temporário e crie com os labels do template:

```bash
gh issue create --title "<título>" --label aidlc:intent --label needs-triage --body-file <arquivo>
```

Some o label de tema quando houver (`infra`, `agentes`, `seguranca`, `ci`, `observabilidade`…).
Pronto quando: a issue existe, a Intenção tem problema, público e critério de sucesso, e você deu o link ao Bardi.
