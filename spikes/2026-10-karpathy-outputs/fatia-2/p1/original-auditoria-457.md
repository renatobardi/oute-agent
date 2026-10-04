<!-- oute-aidlc-qa-pr-audit -->
## oute-aidlc-qa-pr-audit: PR #457 — dispatcher com Claude ou Codex (#213)

**Ação recomendada:** merge NÃO feito: critério de ensaio com o Codex não cumprido (decisão do Bardi, deixada para ele)
**Trust gate:** livre
**Head auditado:** `4b2cb9e69e4f5bf50e31cb9f03bf64cb86d3838b` (base `5109c4439a63758e75bc37c792b9aea0f36361fa`, `main`)
**Reaproveitado do head:** nada (primeira auditoria)
**Achados:** CRITICAL 0 · BLOCKING 0 · SHOULD-FIX 1 · NIT 0 · UNCERTAIN 1

### Caminho padrão (Claude) — prova por teste
- Renderizei o `swarm.md` da base e o do head (com a regra de trechos para o Claude) com as mesmas substituições: `cmp` idêntico, 0 marcadores `@@` restantes. O prompt do dispatcher em Claude não mudou, byte a byte.
- Testes do head (ambiente `env -i`): dispatcher 91 ok, agente 36, prompts 176, watch 54, sessoes 120, eventos 69, seletor 43, check-lib 38, parallel-lib 45; todos rc 0.
- Testes da `main` (watch, sessoes, eventos, seletor) rodados contra o código do head: passam sem edição (54/120/69/43). Com os da main de `agente` e `prompts` e o `tests/lib/swarm.sh` da main, falham 8 + 1 casos, todos do `--agent codex` (que agora exige `HERDR_PANE_ID` e abre o dispatcher no Codex); o PR declara só 2 casos migrados e altera também o `tests/lib/swarm.sh` (`opn`), o que explica a diferença.
- O prompt do Codex rendido não contém `Monitor` nem `run_in_background`.

### Gates e CI
- CI no head: `checks` pass, SonarCloud pass (gate OK, commit = head), CodeRabbit pass. Mergeável, `CLEAN`.

### Superfície sensível
- `docker/oute-swarm` e `docker/swarm.md` (vão na imagem): leitura completa. O `watch --deliver` digita na tela do dispatcher só com ele `idle`/`done`, campo achado e vazio, e confere o campo antes do Enter; o texto dos eventos é dado e o `swarm.md` do Codex diz isso. Sem rede, segredo ou privilégio novos.

### Eixo Spec — issue #213
- Atendidos por leitura e teste: abertura com `--agent codex` e `agent=` no `meta`; agente como padrão das sessões; `watch` fora do agente sem laço próprio; fechamento 4.3 sem ai-memory pulando com aviso; `swarm.md` sem ferramenta exclusiva do Claude no prompt do Codex; testes em `tests/`; fragmento do changelog.
- **Ausente: "ensaio de uma rodada curta com o Codex, registrado na issue"** (precisa de sessão real do Codex no herdr).
- **Closes × Refs:** o PR usa `Refs #213` com `## Falta`; correto.

### Achados
| # | severidade | achado |
|---|---|---|
| 1 | UNCERTAIN | Entrega do `watch` ao Codex, `dispatcher_pane` fixo na abertura e subagentes no agente da rodada só se confirmam no ensaio real. Resolve: rodar uma rodada curta com `--agent codex`. |
| 2 | SHOULD-FIX (julgamento) | `blocked` não recebe entrega e o campo com texto também adia (decisões declaradas no PR, divergem da issue). Aceitável, mas o Bardi deve confirmar. |

### Prós e contras
- **Prós:** caminho padrão provado idêntico; maioria dos ramos de erro testada.
- **Contras:** ensaio com o Codex pendente; falta teste de `herdr agent list` falhando.

**Decisão:** não mergeado, por ordem da condução da rodada (o merge só valia com o ensaio cumprido). Fica aberto para o Bardi.

<sub>Auditoria por claude (dispatcher swarm-1004-0013); o relatório não substitui a decisão do Bardi.</sub>

