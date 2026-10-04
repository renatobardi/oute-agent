**Decisão: fazer merge do PR #457 (dispatcher com Codex, `Refs #213`) ou não? Opções: 1) fazer merge agora e rodar o ensaio com o Codex depois (recomendada); 2) rodar o ensaio antes e só então fazer merge.** As duas opções vêm do resumo do ciclo (`p3-437-cycle.md`, ação 4 do Bardi). A recomendação da auditoria é só "merge NÃO feito" por falta do ensaio (https://github.com/renatobardi/oute-agent/pull/457#issuecomment-5976361202); o resumo do ciclo não marca nenhuma opção. Por isso a opção 1 vem do peso dos fatos abaixo e é incerta: o caminho padrão está provado e o risco fica no Codex.

**Estado atual do PR (conferido agora):** `gh pr view 457` mostra o PR já com `state: MERGED`, por `renatobardi`, em 2026-10-04T09:15:38Z, commit `e83eb5e`. O pedido abaixo vale só se esse merge não for o que você quer manter. Se foi você, falta apenas o ensaio (achado 1).

## O que decidir em cada achado

**Achado 1 (UNCERTAIN): o ensaio com o Codex não foi feito.**
- A issue #213 pede "ensaio de uma rodada curta com o Codex, registrado na issue" (critério de aceite, #213). O ensaio precisa de sessão real do Codex no herdr.
- O PR declara que não fez o ensaio, porque o container da sessão não abre dispatcher real (corpo do PR #457, seção `## Falta`). Por isso o PR usa `Refs #213` e não `Closes`; a auditoria confirma que está correto.
- Três pontos só se confirmam no ensaio: a entrega do `watch` ao Codex, o `dispatcher_pane` fixo na abertura e os subagentes no agente da rodada (auditoria, achado 1).
- Limite conhecido do PR: se o herdr restaurar a sessão com outro id de pane, o `watch` adia até alguém reabrir (corpo do PR #457, `## Falta`). Incerto; o ensaio resolve.
- Para resolver: rodar uma rodada curta com `oute-swarm <repo> --agent codex` e registrar na #213.

**Achado 2 (SHOULD-FIX, julgamento): duas regras de entrega divergem da issue. Você confirma ou pede mudança.**
- A entrega do `watch` não digita com o dispatcher em `blocked`. A issue lista `idle`, `done` e `blocked` (#213, corpo do PR #457). O código aceita só `idle|done` (`docker/oute-swarm:789-790@4b2cb9e`).
- Motivo do PR: com uma permissão aberta, digitar pode escolher uma opção. Os eventos esperam na fila até o dispatcher voltar (corpo do PR #457, "Decisões a conferir").
- A entrega também adia quando o campo tem texto, para não digitar por cima do Bardi (`docker/oute-swarm:795@4b2cb9e`). A issue não pede isso.
- A auditoria chama as duas regras de aceitáveis, mas pede que o Bardi confirme (auditoria, achado 2).
- Se quiser `blocked` na entrega: o PR precisa mudar o código e os testes antes do merge. Se aceitar como está: nada a mudar.
- Pergunta a mais do PR: a linha "Sem ai-memory" do §4.3 existe só no prompt do Codex. Pôr nos dois agentes custa uma linha no `swarm.md`, mas muda o prompt do caminho padrão (corpo do PR #457).

## Por que a opção 1 é razoável
- O prompt do dispatcher em Claude não mudou. A auditoria renderizou o `swarm.md` da base e o do head com as mesmas substituições: `cmp` idêntico e 0 marcadores `@@` restantes (auditoria, caminho padrão).
- O CI do head está verde: `checks` pass, SonarCloud pass (gate OK, commit igual ao head) e CodeRabbit pass (auditoria, Gates e CI). Conferi agora: `checks` e `SonarCloud Code Analysis` em `SUCCESS` (`gh pr view 457`). O CodeRabbit não apareceu nessa saída; não verificado.
- A auditoria não achou nenhum achado CRITICAL nem BLOCKING (auditoria, linha "Achados": CRITICAL 0, BLOCKING 0, SHOULD-FIX 1, NIT 0, UNCERTAIN 1).

## Por que a opção 2 também vale
- Os dois achados tocam só o caminho do Codex. O ensaio é o único jeito de confirmar a entrega do `watch` nele (achado 1).
- O ensaio não cabe no container do PR (corpo do PR #457, `## Falta`).
- A auditoria também lista como contra a falta de teste para `herdr agent list` falhando (auditoria, Prós e contras). O PR diz que o ramo usa as mesmas linhas do `tell`, já cobertas lá (corpo do PR #457).

## Superfície sensível
- Os arquivos `docker/oute-swarm` e `docker/swarm.md` vão na imagem, então a mudança pede release (AGENTS.md, seção Regras).
- A auditoria leu os dois por inteiro. O `watch --deliver` digita só com o dispatcher `idle` ou `done`, com campo achado e vazio, e confere o campo antes do Enter. O texto dos eventos é dado, e o `swarm.md` do Codex diz isso. Não há rede, segredo nem privilégio novos (auditoria, Superfície sensível).

## Para conferir
- Head auditado `4b2cb9e69e4f5bf50e31cb9f03bf64cb86d3838b`, base `5109c4439a63758e75bc37c792b9aea0f36361fa` (`main`). Conferi os dois com `git rev-parse` no ref local `refs/spike/pr457`.
- Testes do head, em `env -i`, todos com rc 0 (auditoria): dispatcher 91 ok, agente 36, prompts 176, watch 54, sessoes 120, eventos 69, seletor 43, check-lib 38, parallel-lib 45. Não rodei de novo; não verificado por mim.
- Testes da `main` de `watch`, `sessoes`, `eventos` e `seletor`, rodados contra o código do head, passam sem edição: 54, 120, 69 e 43 (auditoria).
- Divergência dos casos: com os testes da `main` de `agente` e `prompts` e o `tests/lib/swarm.sh` da `main`, falham 8 + 1 casos. Todos são do `--agent codex`, que agora exige `HERDR_PANE_ID` e abre o dispatcher no Codex (auditoria).
- O PR declara só 2 casos migrados e também altera `tests/lib/swarm.sh` (`opn`). Isso explica a diferença (auditoria, corpo do PR #457). Os números 8 + 1 não foram refeitos por mim; não verificado.
- O corpo do PR conta 54, 120, 69, 43 e 176 casos verdes da `main` contra o head, exceto os 2 migrados. A auditoria dá 176 para o `prompts` do head e diz que os da `main` falham 1 caso nele; a diferença entre as duas contagens não está explicada. Incerto.
- O diff do PR mexe em 8 arquivos, 394 linhas a mais e 43 a menos (`git diff --stat 5109c44 refs/spike/pr457`).
- O prompt do Codex rendido não contém `Monitor` nem `run_in_background` (auditoria).
- Critérios da #213 atendidos por leitura e teste: abertura com `--agent codex` e `agent=` no `meta`; agente padrão das sessões; `watch` sem laço próprio; §4.3 sem ai-memory pulando com aviso; `swarm.md` sem ferramenta exclusiva do Claude no prompt do Codex; testes em `tests/`; fragmento do changelog (auditoria, Eixo Spec).
- Auditoria feita por claude (dispatcher `swarm-1004-0013`); o relatório não substitui a decisão do Bardi.
