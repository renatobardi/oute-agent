# Issues de build recomendadas (spike #458, fatia 3)

**Estado:** recomendação do autor do relatório. **Nenhuma issue foi criada.** O Bardi escolhe quais viram issue.

**Como ler o esforço.** O esforço é uma **estimativa do autor**, sem medida, em três tamanhos:
- **P:** um PR só de texto (prompt, skill ou doc), sem teste novo;
- **M:** um PR com código ou teste novo;
- **G:** mais de um PR, ou um gate de `arch` antes.

A coluna "Release" segue o `AGENTS.md` ("Precisa de release: mudança na imagem"). Arquivo de `docker/` vai na imagem.

## A lista, na ordem proposta

| Ordem | Issue proposta | Fase | O que muda | Esforço | Release | Depende de | Evidência |
|---|---|---|---|---|---|---|---|
| 1 | **PT controlado no repo, com o pt-BR da saída como regra escrita** | `build` | `pt-controlado.md` vira doc do repo; `docker/agent-notes.md` e `docker/swarm-worker.md` ganham três regras: saída ao Bardi em pt-BR, fonte que o Bardi abre, recomendação rotulada | P | sim | decisão do par "fazer merge × mergear" | [`pt-controlado.md`](pt-controlado.md), regras 1, 10 e 11; fatia 2, P1 e P4 |
| 2 | **Pedido de merge com a decisão no topo** | `build` | `docker/swarm.md` §3: o pedido abre com a decisão e as opções; cada achado traz a decisão que ele pede; nenhuma recomendação que a auditoria não fez | M | sim | 1 | fatia 2, P1; fatia 1, PR #457 |
| 3 | **Script do canal com `# RESUMO` e `# CUIDADO:`** | `build` | regra do script em `docker/agent-notes.md`; exemplos das skills que propõem pedido (`ship-verify`) | M | sim | 1 | fatia 2, P2 |
| 4 | **Quem escreve para o Bardi quando a sessão é Haiku** | `spec` | decisão entre subagente Sonnet para o texto final e mudança da tabela do seletor | decisão do Bardi; depois P | não (`config/` entra com `git pull`) | nenhuma | [`output-contract.md`](output-contract.md), "Conflito com a tabela do seletor" |
| 5 | **Auditoria: decisão do Bardi no topo e forma curta sem achado** | `build` | gabarito da `oute-aidlc-qa-pr-audit` | P | não (skill entra com `git pull`) | 1 | fatia 1: 447 palavras no #445, sem achado; decisão enterrada no #457 |
| 6 | **ADR de idioma** | `arch` | o rascunho vira ADR em `docs/adr/`; `CONTEXT.md` ganha o resumo | P de texto; gate de `arch` do Bardi | não | nenhuma | [`adr-rascunho-idioma.md`](adr-rascunho-idioma.md) |
| 7 | **Regressão com poder de prova** | `build` | consertar a tarefa `worktree`, que falha na linha de base; tarefas novas para grupos de regra hoje sem medida; uma tarefa que confere a língua da saída | G | sim | nenhuma | fatia 2, P4: 3 grupos de regra de cerca de 53; `worktree` 0 de 6 |
| 8 | **Conferência de referência por máquina** | `build` | o `refcheck.py` do spike vira comando do container, chamado pela auditoria e pelo dispatcher antes de pedir merge | M | sim | 2 | fatia 2, P1: 15 de 19 referências do Haiku não existem para o Bardi |
| 9 | **`agent-notes.md` em inglês enxuto** | `build` | troca do arquivo pela variante d, com a regra 10 corrigida ("Espere"), a regra 37 corrigida e a regra do pt-BR | M | sim | 1, 6 e 7 | fatia 2, P4: −23% de tokens; 53 de 53 regras |
| 10 | **Watch: uma linha `[ci]` por head quando tudo passa** | `build` | `docker/oute-swarm` e os testes do tema `watch` | M | sim | nenhuma | [`lado-maquina.md`](lado-maquina.md): 523 das 546 linhas `[ci]` são de check que passou |
| 11 | **Dois trechos ambíguos nos prompts de hoje** | `build` | `docker/swarm.md:88` ("cada uma uma linha claro") e `addons/skills/oute-aidlc-qa-pr-audit/SKILL.md:253` (a fatia 1 a descreveu como "regra que se contradiz": a correção do `Refs` manda "remover a seção ou manter como está") | P | sim (o `swarm.md`) | nenhuma | fatia 1, "Limites desta medição"; relido nesta fatia |
| 12 | **Caixa de entrada do dono, no `frentes-engenharia`** | `spec`, naquele repo | topo com contagem por tipo; tabela "o que só você faz"; classificar só quando a fonte sustenta; a tabela de conferência fica fora do que o dono lê | P | não se aplica | 1 | fatia 2, P5 |

## O que o spike não recomenda criar agora

| Item | Motivo |
|---|---|
| Resumo de rodada como página | o Bardi preferiu a página no P3 ([comentário](https://github.com/renatobardi/oute-agent/issues/458#issuecomment-5979659271)), numa amostra. Falta definir como a página chega a ele e corrigir os defeitos que a revisão do P3 apontou. É a candidata mais forte a 13ª issue; a escolha é do Bardi |
| Prompts do swarm e skills em inglês | dependem da issue 7 e da leitura de fidelidade dos 6 arquivos que ninguém conferiu |
| ASD-STE100 a 80% nos prompts | custa mais que o inglês direto e não mostrou ganho ([`lado-maquina.md`](lado-maquina.md)) |
| Vídeo | veredito "descartar por ora" (fatia 2) |
| Tradução do histórico | o rascunho do ADR propõe só o que for novo |

## Issue que já existe

- **#475** (aberta): `gh issue view <n> --comments` não imprime o título nem o corpo. É o achado 5 da fatia 2. Não entra na lista: já é issue.

## Notas da ordem

- **O lado humano vem primeiro** (issues 1 a 5). É a prioridade do Bardi para o texto que ele lê, e nenhuma delas depende da regressão.
- **A issue 1 é a base das outras.** Ela põe por escrito o que hoje é implícito.
- **A issue 9 é a única troca de idioma da lista.** Ela espera a 7, porque a regressão de hoje não prova que a troca não piora.
- **A issue 4 é uma decisão, não um trabalho.** A evidência é de uma amostra por protótipo (P1 e P2).
