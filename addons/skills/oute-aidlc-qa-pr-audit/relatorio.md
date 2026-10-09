# Modelo do relatório da `oute-aidlc-qa-pr-audit`

Arquivo de apoio do `SKILL.md` desta pasta (passo 12). Leia-o ao escrever o relatório; a conferência antes de publicar (head, `oute-refcheck`, `gh pr comment`) está no passo 12 do `SKILL.md`. "Passo N" é o passo do `SKILL.md`.

**Ordem do relatório (#482):** o Bardi lê primeiro o que decide. O relatório abre com a ação recomendada e, se houver, a "Decisão do Bardi" com as opções numeradas; depois vêm o head, os gates e os achados. O texto ao Bardi segue `docs/pt-controlado.md`: pt-BR, frase curta, fonte que ele abre, recomendação rotulada. A forma muda; o que a auditoria confere (passos 2 a 11) não muda.

**Decisão do Bardi.** Escreva o bloco quando o relatório pede uma escolha dele: ajustar ou aceitar um BLOCKING, aceitar um SHOULD-FIX sem issue, resolver um UNCERTAIN que só ele resolve, ou decidir entre `Closes` e `Refs` quando o critério é ambíguo. Cada opção é numerada e diz o que acontece. Se a recomendação não tem fonte, rotule-a "recomendação do autor". Sem escolha para ele: escreva "Decisão do Bardi: nenhuma" e nada mais.

**Forma curta.** Vale só quando os cinco contadores dos achados são 0 (CRITICAL, BLOCKING, SHOULD-FIX, NIT e UNCERTAIN), o trust gate está livre e a ação é `merge como está`. Qualquer achado, ou um gate que não rodou, leva a forma completa. Na forma curta continuam obrigatórios, com a mesma evidência da forma completa:
- o marcador, a ação recomendada e a linha "Decisão do Bardi: nenhuma";
- o head auditado (e a base) e a linha "Reaproveitado do head";
- a tabela de gates, o CI no head, o SonarCloud e "falha na base, passa no head";
- o eixo Spec: a tabela dos critérios de aceite e a linha `Closes × Refs`;
- uma linha "Conferido, sem achado" que lista, uma a uma, as seções que a forma completa tem: superfície sensível e supply chain, eixo Standards, registro de alegações, checklist funcional (as 8 frentes) e prós e contras. Cada item traz o que foi conferido, em uma frase; "nada" sozinho não vale.

Se ao escrever a linha "Conferido, sem achado" você não consegue dizer o que conferiu em algum item, a conferência não foi feita: faça-a, ou use a forma completa com UNCERTAIN.

Forma completa:

```markdown
<!-- oute-aidlc-qa-pr-audit -->
## oute-aidlc-qa-pr-audit: PR #<N> — <título>

**Ação recomendada:** <merge como está | ajustar antes do merge | perguntar ao autor | decisão do Bardi | não fazer merge>: <justificativa em uma ou duas linhas>
**Decisão do Bardi:** nenhuma | <a pergunta, em uma frase>
1. <opção: o que acontece se o Bardi escolher>
2. <opção>
<recomendação: opção N (fonte) | "recomendação do autor": opção N>

**Trust gate:** livre | bloqueado por <achado>
**Head auditado:** `<HEAD_SHA>` (base `<BASE_SHA>`, `<baseRefName>`)
**Reaproveitado do head `<PREV_SHA>`:** <arquivos com blob igual, comparados por `git rev-parse <head>:<arquivo>`> (relatório anterior: <link do comentário>) | nada (<primeira auditoria | motivo>)
**Regras lidas de:** `AGENTS.md` @ base (+ <outras fontes>)
**Achados:** CRITICAL <n> · BLOCKING <n> · SHOULD-FIX <n> · NIT <n> · UNCERTAIN <n>

### Gates (worktree própria, sem segredos no ambiente)
| gate | comando | resultado |
|---|---|---|
| <nome> | `<comando>` | passou / falhou (rc, trecho) / não rodou: <motivo> |

- **CI no head:** <check: estado> …; pendente/pulado não conta como aprovado
- **SonarCloud (`oute-sonar pr <N>`):** <saída, gate, commit analisado = `HEAD_SHA`? / "SonarCloud não verificado": motivo>
- **Falha na base, passa no head:** <teste: sim/não/não se aplica>

### Achados
| # | severidade | eixo | achado | evidência | correção |
|---|---|---|---|---|---|
| 1 | BLOCKING | Standards | <o quê> | <arquivo:linha, regra citada, comando> | <ajuste mínimo> |

### Eixo Spec — issue #<n>
| critério de aceite | veredito | evidência |
|---|---|---|
| <texto do critério> | atendido / parcial / ausente / não verificável aqui / não verificável aqui (ship) | <arquivo:linha, comando> |

- **Faltando ou parcial:** <itens ou "nada">
- **Além do pedido:** <itens ou "nada">
- **Implementado errado:** <itens ou "nada">
- **Closes × Refs:** o PR usa `<Closes|Refs> #n`; <correto | divergente: motivo>

### Superfície sensível e supply chain
- <arquivo: o que muda e por que é ou não aceitável> | "nada tocado"
- <dependência/action/workflow: nome, pin, lockfile, permissões> | "nada novo"

### Eixo Standards
- **Violações duras:** <regra (arquivo) → trecho> | "nenhuma"
- **Slop:** <item → evidência> | "nenhum"
- **Julgamento (smells e interpretação):** <possível <smell> → trecho> | "nenhum"

### Registro de alegações
| alegação (origem) | evidência independente | veredito |
|---|---|---|
| "<texto>" (corpo/commit) | <comando, arquivo:linha> | confirmada / refutada / não verificada: <o que faltou> |

### Checklist funcional
| frente | resultado |
|---|---|
| segurança (<oute-aidlc-qa-security-audit | checklist inline>) | ok / achado #n / não se aplica: <motivo> |
| correção e regressão | … |
| invariantes | … |
| compatibilidade | … |
| escopo | … |
| testes | … |
| docs e CHANGELOG | … |
| atribuição | … |

### Prós e contras
- **Prós:** <o que o PR faz bem>
- **Contras:** <riscos e custos que ficam>

### Correção sugerida e limites
**Correção sugerida:** <ajuste mínimo, ou "nenhuma">
**Não verificado aqui:** <o que ficou de fora e quem pode verificar>

<sub>Auditoria por <agente>; o relatório não substitui a decisão do Bardi.</sub>
```

Forma curta (só nas condições acima):

```markdown
<!-- oute-aidlc-qa-pr-audit -->
## oute-aidlc-qa-pr-audit: PR #<N> — <título>

**Ação recomendada:** merge como está: <justificativa em uma linha>
**Decisão do Bardi:** nenhuma
**Trust gate:** livre
**Head auditado:** `<HEAD_SHA>` (base `<BASE_SHA>`, `<baseRefName>`)
**Reaproveitado do head `<PREV_SHA>`:** <como na forma completa>
**Achados:** CRITICAL 0 · BLOCKING 0 · SHOULD-FIX 0 · NIT 0 · UNCERTAIN 0

### Gates
<a tabela de gates, o CI no head, o SonarCloud e "falha na base, passa no head", como na forma completa>

### Eixo Spec — issue #<n>
<a tabela dos critérios, como na forma completa>
- **Closes × Refs:** o PR usa `<Closes|Refs> #n`; correto

**Conferido, sem achado:** superfície sensível e supply chain: <o que foi lido>. Standards: <o que foi conferido>. Alegações: <n confirmadas, como>. Checklist funcional: <as 8 frentes, uma frase cada>. Prós e contras: <uma frase>.
**Não verificado aqui:** <o que ficou de fora e quem pode verificar | nada>

<sub>Auditoria por <agente>; o relatório não substitui a decisão do Bardi.</sub>
```

Na forma completa, nenhuma seção é omitida: se não há o que dizer, escreva "nada" ou "não se aplica" e o motivo.
