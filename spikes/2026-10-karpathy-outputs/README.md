# Spike #458: saída por público (relatório final, fatia 3)

**Estado:** relatório entregue no branch `spike/karpathy-outputs`, sem PR e sem merge. Nenhum arquivo de produção mudou. **A decisão sobre o que adotar é do Bardi.** Tudo o que este relatório recomenda leva o rótulo "recomendação do autor".

## 1. Resumo

1. **O Bardi lê ou decide em 14 pontos.** Em 12 deles o texto sai de um agente. O contrato de cada ponto está em [`output-contract.md`](output-contract.md).
2. **Lado humano:** o PT controlado com a decisão no topo funciona quando o Sonnet escreve. O Haiku não dá conta. No P3 o Bardi preferiu a página ao texto (uma amostra). Os cinco protótipos ficaram com o veredito **Ajustar**; o vídeo, **Descartar por ora**.
3. **O maior risco é a fidelidade.** No P1, os dois modelos puseram uma recomendação que a fonte não faz. A máquina só confere que a referência existe; só um revisor confere que ela sustenta a frase.
4. **Lado máquina:** o inglês reduz os tokens em 13% e a reescrita enxuta em 23%, mas nenhuma troca está provada. A regressão cobre 3 grupos de regra de cerca de 53.
5. **Plano:** 12 issues recomendadas, o lado humano primeiro ([`issues-de-build.md`](issues-de-build.md)). Nenhuma foi criada.

## 2. Mapa dos pontos de supervisão

O mapa completo, com o diagrama e a fonte de cada ponto, está no [comentário da fatia 1](https://github.com/renatobardi/oute-agent/issues/458#issuecomment-5978841358). O diagrama do fluxo de hoje e do proposto está em [`report.html`](report.html).

| # | Ponto | Texto | Quem escreve hoje |
|---|---|---|---|
| 1 | Proposta do ciclo | livre | sessão `iter` (Sonnet) |
| 2 | Triagem da rodada | livre | dispatcher (Sonnet) |
| 3 | Pergunta com opções | livre | dispatcher (Sonnet) |
| 4 | Corpo do PR | livre | worker, no modelo da fase |
| 5 | Relatório de auditoria | livre, com gabarito | dispatcher (Sonnet) |
| 6 | Pedido de merge | livre | dispatcher (Sonnet) |
| 7 | Proposta só GitHub e relatório de spike | livre | worker, no modelo da fase |
| 8 | Script no `oute watch` | livre (comentários e `echo`) | worker, no modelo da fase |
| 9 | Lições kaizen | livre | dispatcher (Sonnet) |
| 10 | Resumo de fim de rodada | livre | dispatcher (Sonnet) |
| 11 | Saída do `scripts/oute` | fixo no código | ninguém |
| 12 | Tray, telas e alertas do agent-studio | fixo no código | ninguém |
| 13 | Insights do ciclo | livre | sessão `learn` (Haiku) |
| 14 | Relatórios de ship e ops | livre | `ship` (Sonnet); `ops` (Haiku) |

"Quem escreve hoje" vem da tabela do seletor (`config/select/models.toml:18-31`). O dispatcher abre na fase `plan` (`CONTEXT.md`, ADR-02).

**Correção da fatia 1:** ela contou 11 pontos de texto livre e deixou o ponto 8 fora das duas listas. O ponto 8 é texto livre: o agente escreve os comentários e os `echo` do script. Com ele são 12.

## 3. Protótipos e vereditos

Cada protótipo usou uma saída real e uma amostra só. O detalhe está no [comentário da fatia 2](https://github.com/renatobardi/oute-agent/issues/458#issuecomment-5979128893). Os artefatos estão em [`fatia-2/`](fatia-2/README.md).

| Protótipo | Entrada real | Veredito | O que funcionou | O que falhou |
|---|---|---|---|---|
| **P1** pedido de merge | [auditoria do #457](https://github.com/renatobardi/oute-agent/pull/457#issuecomment-5976361202) | **Ajustar** | a decisão e as opções abrem o texto; o Sonnet citou 10 referências e as 10 existem | os dois modelos recomendaram o que a auditoria não recomenda; o Sonnet perdeu uma condição |
| **P2** script do watch | pedido `20261003-230905` do canal | **Ajustar** (Sonnet); **não** (Haiku) | nenhum comando mudou; o Sonnet manteve 18 de 18 fatos | um `CUIDADO` do Sonnet exagera; o Haiku perdeu 2 fatos, mudou 2 e tranquilizou em vez de avisar |
| **P3** resumo em texto, diagrama e página | [resumo do ciclo na #437](https://github.com/renatobardi/oute-agent/issues/437#issuecomment-5976459420) | **Ajustar** | texto e página mantêm 47 de 47 fatos | o diagrama perdeu 5 de 29 fatos; a página foi lida com os defeitos da revisão sem corrigir |
| **P4** notas em inglês | `docker/agent-notes.md` | **Ajustar** | a variante enxuta gasta 23% menos tokens e mantém 53 de 53 regras | a regressão não separa as variantes; 2 pontos de ambiguidade nova |
| **P5** caixa de entrada do dono | FE#67 (privada) | **Ajustar** | topo com contagem; 53 de 54 fatos mantidos | o artefato ficou 2,2 vezes maior; uma classificação sem base na fonte |
| **Vídeo** | só pesquisa | **Descartar por ora** | as ferramentas existem | o ganho sobre uma página é pequeno e a conferência é mais lenta |

Os vereditos são os da fatia 2. O Bardi aceitou a fatia 2 no [gate](https://github.com/renatobardi/oute-agent/issues/458#issuecomment-5979533284); ele não decidiu o que adotar.

## 4. Métricas antes e depois

### Lado humano

Fonte: [`fatia-2/medidas/forma.tsv`](fatia-2/medidas/forma.tsv), [`tokens.tsv`](fatia-2/medidas/tokens.tsv), [`deltas-tokens.tsv`](fatia-2/medidas/deltas-tokens.tsv). Tokens no Sonnet 5.5.

| Artefato | Palavras | Tokens | Contra o original | Frases acima de 25 palavras |
|---|---|---|---|---|
| P1, auditoria original | 523 | 1560 | linha de base | 2% |
| P1, Sonnet | 1068 | 2916 | +87% | 0% |
| P1, Haiku | 617 | 2017 | +29% | 4% |
| P3, resumo original | 369 | 1147 | linha de base | 3% |
| P3, texto (Sonnet) | 972 | 2782 | +143% | 0% |
| P3, diagrama | não se aplica | 2314 | +102% | não se aplica |
| P3, página | não se aplica | 5640 | +392% | não se aplica |

- **O texto controlado é mais longo, não mais curto.** A fonte por linha e as opções numeradas pesam.
- **Isso não contraria a meta.** No lado humano o custo não é restrição (issue #458, "Prioridades").
- **O ganho de leitura tem uma medida humana, do P3.** O Bardi comparou o texto e a página e respondeu "a página" ([comentário](https://github.com/renatobardi/oute-agent/issues/458#issuecomment-5979659271)).
- **Os limites dessa medida:** uma amostra, um leitor, sem tempo cronometrado. O comentário não diz que parte da página ajudou. Vale como preferência declarada.
- **Nos outros protótipos o ganho de leitura não foi medido.**

### Lado máquina

Fonte: [`fatia-1/tokens.tsv`](fatia-1/tokens.tsv) (`python3 fatia-1/table.py fatia-1/tokens.tsv`) e [`fatia-2/medidas/tokens.tsv`](fatia-2/medidas/tokens.tsv).

| Variante | Sete arquivos, Sonnet e Opus | Sete arquivos, Haiku | `agent-notes.md`, Sonnet e Opus |
|---|---|---|---|
| a, pt de hoje | 67887 | 51081 | 2292 |
| b, inglês conciso | 59003 (−13,1%) | 44517 (−12,9%) | 1962 (−14%) |
| c, STE a 80% | 62847 (−7,4%) | 47883 (−6,3%) | 2107 (−8%) |
| d, enxuta | não medido | não medido | 1761 (−23%) |

A recomendação por tipo de texto está em [`lado-maquina.md`](lado-maquina.md).

## 5. Riscos

Em ordem de gravidade. A fidelidade vem primeiro.

1. **Recomendação que a fonte não faz.** Aconteceu nos dois modelos do P1. A regra de citar a fonte não impediu. Resposta proposta: a regra 11 de [`pt-controlado.md`](pt-controlado.md).
2. **Citação que existe e não sustenta a frase.** O `refcheck.py` não pega isso. No P1, o Opus achou 2 afirmações do Sonnet e 4 do Haiku cuja fonte não confere. Só um revisor de outro modelo pega.
3. **Condição perdida na reescrita.** O Sonnet perdeu "o merge só valia com o ensaio cumprido" (P1). O Haiku trocou "pelo menos" por valor exato (P2). Resposta proposta: a regra 12.
4. **Aviso que tranquiliza.** Os dois avisos do Haiku no P2 não dizem que o apagamento não se desfaz. Resposta proposta: a regra 9 e a classe A do contrato.
5. **Sessão em Haiku que escreve para o Bardi.** A tabela do seletor abre em Haiku as fases `ops`, `ctx` e `learn` e as exceções `kaizen` e `docs`. A evidência contra o Haiku é de uma amostra por protótipo.
6. **Saída em inglês para o Bardi.** Se um prompt mudar para inglês, nada hoje garante o pt-BR da saída. Não foi medido.
7. **Troca de prompt sem prova.** A regressão cobre 3 grupos de regra de cerca de 53.
8. **Uma amostra por protótipo.** Nenhum veredito vale para além da entrada usada.

## 6. As 14 perguntas

| # | Pergunta | Resposta | Onde está |
|---|---|---|---|
| 1 | Onde o Bardi lê ou aprova? | Em 14 pontos. Nos 10 últimos PRs não há pedido do Bardi escrito no GitHub. A conversa na aba não fica registrada: **não medida**. | seção 2; fatia 1 |
| 2 | Que degrau em cada ponto? | **Ponto 10: página (degrau 3).** O Bardi comparou o texto e a página do P3 e preferiu a página ([comentário](https://github.com/renatobardi/oute-agent/issues/458#issuecomment-5979659271)). É uma amostra, sem tempo cronometrado. Degrau 3 também no ponto 12, que já é página. Degrau 1 (texto) nos outros 12 pontos; a página nos pontos 7 e 13, que também são relatórios longos, é recomendação do autor por analogia, sem medida. Degrau 4 em nenhum. | [`output-contract.md`](output-contract.md) |
| 3 | Regras de PT controlado; o modelo cumpre? | 15 regras. O Sonnet cumpre o limite de 25 palavras por frase nas duas amostras e passa do limite de parágrafo numa. O Haiku não cumpre. A voz passiva não tem medida confiável. | [`pt-controlado.md`](pt-controlado.md) |
| 4 | O glossário vira dicionário? | Sim. 9 dos 50 termos do `CONTEXT.md` já trazem "Evite". O Sonnet usou 0 termos a evitar nas três amostras; o Haiku usou 3 numa. | [`pt-controlado.md`](pt-controlado.md), "Dicionário" |
| 5 | Padrão de aviso | Proposta: `# RESUMO` no topo e `# CUIDADO:` com o comando e depois a perda. A garantia "comandos iguais" se confere por máquina. Se o padrão melhora a decisão do Bardi: **não medido**. | regra 9; P2 |
| 6 | Fidelidade: como citar e como conferir | Proposta: citar `arquivo:linha@sha`, `#N`, link de comentário ou o comando. Três conferências: a referência existe (máquina); o script não mudou (máquina); a fonte sustenta a frase (revisor de outro modelo). | regras 10 a 12; seção 5 |
| 7 | Três variantes, tokens | b −13,1%, c −7,4% no Sonnet e no Opus. Codex e `claude-fable-5-1`: **não medidos**. | seção 4; fatia 1 |
| 8 | Qualidade por variante | **Sem resposta com prova.** A regressão não separa as variantes (p = 0,448 entre a e d). A hipótese do STE fica sem prova, a favor ou contra. | [`lado-maquina.md`](lado-maquina.md) |
| 9 | Onde o texto entre agentes é gordo | Em dois lugares: as linhas `[ci]` de check que passou (523 de 546) e a auditoria sem achado (447 palavras no #445). O `tell` não é gordo (média de 69 palavras). Páginas do ai-memory: **não medidas**. | [`lado-maquina.md`](lado-maquina.md) |
| 10 | Casos de borda | Regra proposta: se o Bardi lê ou aprova, vale o lado humano. Os sete casos da pergunta ficam em pt-BR. | [`adr-rascunho-idioma.md`](adr-rascunho-idioma.md), decisão 2 |
| 11 | Duas línguas sem divergir | Proposta: não ter duas línguas. Um documento, uma língua. A conferência entre versões seria leitura, sem script. | rascunho do ADR, decisão 1 |
| 12 | O que é contrato | Proposta de lista: labels (53), nomes `oute.*`, tabelas do estado, tags do watch, `PRONTO`, `BLOQUEADO`, `Closes`, `Refs`, `## Falta`, marcador e severidades da auditoria. | rascunho do ADR, decisão 5 |
| 13 | Legado | Proposta: só o que for novo. Nada do histórico é traduzido. | rascunho do ADR, decisão 6 |
| 14 | O que muda, em que ordem | 12 issues, o lado humano primeiro. O que se aproveita no `frentes-engenharia` está na seção 8. | seção 7; [`issues-de-build.md`](issues-de-build.md) |

## 7. Plano de incorporação

Recomendação do autor. O esforço é **estimativa do autor**, sem medida: P = um PR só de texto; M = um PR com código ou teste; G = mais de um PR ou gate de `arch`. A tabela completa, com dependência e evidência, está em [`issues-de-build.md`](issues-de-build.md).

| Ordem | Mudança | Onde | Esforço |
|---|---|---|---|
| 1 | PT controlado no repo e pt-BR da saída como regra escrita | doc, `docker/agent-notes.md`, `docker/swarm-worker.md` | P |
| 2 | Pedido de merge com a decisão no topo | `docker/swarm.md` §3 | M |
| 3 | Script do canal com `# RESUMO` e `# CUIDADO:` | `docker/agent-notes.md`, skills que propõem pedido | M |
| 4 | Quem escreve para o Bardi quando a sessão é Haiku | decisão; depois `config/select/models.toml` ou prompt | decisão do Bardi; depois P |
| 5 | Auditoria com a decisão no topo e forma curta sem achado | skill `oute-aidlc-qa-pr-audit` | P |
| 6 | ADR de idioma | `docs/adr/`, `CONTEXT.md` | P, com gate de `arch` |
| 7 | Regressão com poder de prova | `docker/oute-regression`, `docker/regression/` | G |
| 8 | Conferência de referência por máquina | comando novo no container | M |
| 9 | `agent-notes.md` em inglês enxuto | `docker/agent-notes.md` | M |
| 10 | Uma linha `[ci]` por head quando tudo passa | `docker/oute-swarm` | M |
| 11 | Dois trechos ambíguos nos prompts de hoje | `docker/swarm.md:88`, `addons/skills/oute-aidlc-qa-pr-audit/SKILL.md:253` | P |
| 12 | Caixa de entrada do dono | `frentes-engenharia` | P |

CI: nenhuma mudança proposta. Template de issue: nenhuma mudança proposta.

## 8. O que vale para o `frentes-engenharia`

Fonte: fatia 1 (10 issues lidas) e P5 (FE#67). O repo é privado: aqui só há medidas.

1. **A issue que serve de caixa de entrada do dono** ganha um topo com a contagem por tipo. Abaixo dele vem a tabela "o que só você faz". No P5 o artefato separou 8 ações só do dono, 3 decisões, 7 divergências de spec e 43 itens de dívida.
2. **Classificar só quando a fonte sustenta.** O P5 pôs um dono na dívida técnica que o original não declara.
3. **A tabela de conferência fica fora do que o dono lê.** Ela fez o artefato crescer 2,2 vezes (1595 para 3594 palavras).
4. **Citar arquivo e linha.** Nenhuma das 10 issues lidas cita arquivo com linha nem SHA (fatia 1).
5. **As 8 issues de agente para agente** são do lado máquina. Para elas vale [`lado-maquina.md`](lado-maquina.md), sem prova nova naquele repo.

Se o rascunho do ADR vale naquele repo: **em aberto**.

## 9. Como conferi

- **Fatias 1 e 2:** os números vêm dos arquivos `.tsv` do branch. Os comandos estão nos comentários das duas fatias e em [`fatia-1/`](fatia-1/README.md) e [`fatia-2/`](fatia-2/README.md).
- **Reconferi contra a fonte, nesta fatia:**
  - o total da fatia 1 (`python3 fatia-1/table.py fatia-1/tokens.tsv`: 67887, 59003, 62847; Haiku 51081, 44517, 47883);
  - os tokens do P1, do P3 e do P4 em `fatia-2/medidas/tokens.tsv`;
  - a forma do P1 e do P3 em `fatia-2/medidas/forma.tsv`;
  - a regressão em `fatia-2/medidas/p4-resumo.tsv`;
  - as referências do P1 em `fatia-2/medidas/refcheck-p1-*.sum` (10 com 0 falhas; 19 com 15 falhas).
- **Medidas novas desta fatia**, com o comando ao lado:
  - termos a evitar por artefato: [`pt-controlado.md`](pt-controlado.md), "O que foi medido sobre o dicionário";
  - `tell`, eventos do watch e handoffs: [`lado-maquina.md`](lado-maquina.md), "Onde o texto entre agentes é gordo";
  - termos de contrato: [`adr-rascunho-idioma.md`](adr-rascunho-idioma.md), decisão 5.
- **Este relatório passou pelas próprias ferramentas** (`fatia-2/tools/textstats.py` e `refcheck.py`). O resultado está em [`fatia-3-medidas.md`](fatia-3-medidas.md).
- **Revisor de outro modelo:** um subagente Sonnet 5.5 conferiu os sete arquivos contra a fonte (133.683 tokens, 158 s, pelo campo de uso do subagente). Ele conferiu cerca de 150 números e afirmações (a contagem é dele) e apontou 6 pontos, nenhum de número: 2 imprecisos, 3 sem fonte e 1 sem rótulo de proposta. Corrigi os 6 antes do commit.
- **Modelo:** esta fatia foi escrita em `claude-opus-5-5`, como no gate da fatia 2.

## 10. O que ficou em aberto

- **Não medido:**
  - o ganho de leitura do Bardi fora do P3;
  - os tokens no Codex e no `claude-fable-5-1`;
  - o efeito do cache de prompt;
  - quantas vezes cada arquivo entra numa rodada;
  - a conversa na aba;
  - as páginas do ai-memory;
  - a renderização do `report.html` (não há navegador no container).
- **Sem resposta na medida do P3:** que parte da página ajudou (as decisões no topo, a lista de marcar ou o diagrama) e quanto tempo ela poupa.
- **Não conferido:** a fidelidade de 6 dos 7 arquivos das variantes b e c da fatia 1.
- **Lista que se perdeu:** a fatia 1 prometeu a lista completa dos trechos ambíguos do pt de hoje. Ela não ficou no branch. Ficaram os dois exemplos do comentário, que reli nesta fatia (`docker/swarm.md:88` e `addons/skills/oute-aidlc-qa-pr-audit/SKILL.md:253`).
- **O que ficou nos serviços:** esta fatia só leu. Ela chamou `memory_recent` e `memory_handoff_list` (leitura) e o `gh` (leitura). A única escrita fora do branch é o comentário final na #458, publicado depois deste commit. Os hooks da sessão gravam a atividade dela no ai-memory, no escopo do repo: **não conferi o que foi gravado**.

## Arquivos desta pasta

| Arquivo | Conteúdo |
|---|---|
| `README.md` | este relatório |
| [`pt-controlado.md`](pt-controlado.md) | as 15 regras e o dicionário |
| [`output-contract.md`](output-contract.md) | o contrato de saída dos 14 pontos |
| [`lado-maquina.md`](lado-maquina.md) | pt, inglês, STE ou enxuta, por tipo de texto |
| [`adr-rascunho-idioma.md`](adr-rascunho-idioma.md) | rascunho do ADR de idioma |
| [`issues-de-build.md`](issues-de-build.md) | as 12 issues recomendadas |
| [`report.html`](report.html) | o relatório em página, com o fluxo de hoje e o proposto |
| [`fatia-3-medidas.md`](fatia-3-medidas.md) | a forma e as referências deste relatório |
| [`prototypes/`](prototypes/README.md) | índice dos artefatos brutos |
| `fatia-1/`, `fatia-2/` | artefatos, ferramentas e medidas das duas fatias |
