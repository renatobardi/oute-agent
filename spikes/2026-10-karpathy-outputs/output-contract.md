# Contrato de saída por ponto de supervisão (spike #458, fatia 3)

**Estado:** proposta do spike. A decisão sobre o que adotar é do Bardi.

**O que é.** Para cada um dos 14 pontos em que o Bardi lê ou aprova, o contrato diz: o idioma, o formato, o que consta, que fonte o texto cita e que modelo pode escrever. Os 14 pontos são os do mapa da fatia 1 ([comentário](https://github.com/renatobardi/oute-agent/issues/458#issuecomment-5978841358)).

**Como ler a coluna "Base".** Ela diz de onde vem cada linha do contrato:
- **medido:** um protótipo da fatia 2 testou essa forma nesse ponto;
- **hoje:** a forma já existe no prompt ou no código, com a fonte citada;
- **autor:** recomendação do autor do relatório, sem protótipo.

## Regras que valem nos 14 pontos

1. **Idioma: pt-BR**, no PT controlado de [`pt-controlado.md`](pt-controlado.md). O que é contrato fica em crase e sem tradução (regra 15).
2. **A decisão do Bardi abre o texto**, com opções numeradas (regra 2).
3. **Fonte:** cada afirmação cita algo que o Bardi abre com um clique ou um comando (regra 10).
4. **Recomendação:** só com fonte ou com o rótulo "recomendação do autor" (regra 11).
5. **Vídeo: nenhum ponto usa.** Veredito da fatia 2: descartar por ora ([`fatia-2/video/viabilidade.md`](fatia-2/video/viabilidade.md)).

## Que modelo pode escrever

| Classe | Quem escreve | Quem confere | Base |
|---|---|---|---|
| **A: texto com decisão ou com risco** | Sonnet 5.5 ou Opus 5.5. Haiku não. | máquina (`refcheck.py`; no ponto 8, `p2check.sh`) e, quando houver, um revisor de outro modelo | medido (P1, P2) |
| **B: texto de acompanhamento, sem decisão** | Sonnet 5.5 ou Opus 5.5. Haiku: não provado. | máquina | autor |
| **C: texto fixo no código** | ninguém em tempo de execução; o texto muda por PR | teste do repo | hoje |

Evidência da classe A, da fatia 2 (uma amostra por protótipo):
- P1: o Haiku mudou o sentido de 4 fatos e inventou 1. O Sonnet mudou 1 e inventou 0.
- P1: 15 das 19 referências do Haiku apontam para arquivo que o Bardi não tem ([`refcheck-p1-haiku.tsv`](fatia-2/medidas/refcheck-p1-haiku.tsv)).
- P2: o Haiku perdeu 2 fatos e mudou 2. Os dois avisos dele tranquilizam em vez de avisar.

**Conflito com a tabela do seletor.** Hoje três linhas da tabela abrem a sessão em Haiku:
- as fases `ops`, `ctx` e `learn` (`config/select/models.toml:30-31`);
- a exceção `kaizen` (`config/select/models.toml:46`);
- a exceção `docs` (`config/select/models.toml:52`).

Uma sessão dessas escreve para o Bardi nos pontos 4, 7, 8, 13 e 14. O contrato não muda a tabela. Ele propõe uma de duas saídas, e a escolha é do Bardi:
1. a sessão em Haiku faz o trabalho e entrega o texto final a um subagente Sonnet;
2. a tabela muda, e essas fases abrem em Sonnet.

Recomendação do autor: a saída 1, porque não mexe no custo do resto da sessão. Nenhuma das duas foi testada.

## Os 14 pontos

Degraus do post: 1 = texto, 2 = diagrama, 3 = página HTML, 4 = vídeo.

| # | Ponto | Quem escreve hoje | Classe | Formato proposto (degrau) | O que consta, nesta ordem | Fonte que cita | Base |
|---|---|---|---|---|---|---|---|
| 1 | Proposta do ciclo | sessão `iter` (Sonnet) | A | texto com tabela (1) | o que decidir; foco; issues do ciclo; limpeza do backlog; cada item com número | `#N` de cada issue; issue do ciclo anterior | hoje (`addons/skills/oute-aidlc-iter-roadmap/SKILL.md:31-44`); autor |
| 2 | Triagem da rodada | dispatcher (Sonnet) | A | tabela (1) | pedido de ok com opções; a tabela; avisos (`aviso: <motivo>`) | `#N` e labels de cada issue | hoje (`docker/swarm.md:33-37`) |
| 3 | Pergunta com opções | dispatcher (Sonnet) | A | texto (1); a linha do `oute-swarm ask` tem até 300 caracteres | a pergunta; opções numeradas; a opção que leva a ação irreversível traz PR, estratégia e head | PR e head curto; link do comentário | hoje (`docker/oute-swarm:470`, `docker/swarm.md:94`) |
| 4 | Corpo do PR | worker (o modelo da fase; pode ser Haiku) | A | Markdown com seções fixas (1) | `Closes` ou `Refs`; o que mudou; validação com os números do head; `## Falta` | comando de cada número; `arquivo:linha` | hoje (`docker/swarm-worker.md:17`); autor |
| 5 | Relatório de auditoria | dispatcher (Sonnet) | A | comentário com o gabarito (1); **forma curta quando não há achado** | ação recomendada e decisões do Bardi no topo; achados por gravidade; gates; alegações | `arquivo:linha@sha`; comando e saída de cada gate | hoje (`addons/skills/oute-aidlc-qa-pr-audit/SKILL.md:342-429`); forma curta: autor |
| 6 | Pedido de merge | dispatcher (Sonnet) | A | texto (1) | a decisão e as opções; cada achado com a decisão que ele pede; link da auditoria | link do comentário da auditoria; `arquivo:linha@sha` | medido (P1) |
| 7 | Proposta só GitHub e relatório de spike | worker (o modelo da fase) | A | comentário (1); diagrama (2) quando o relatório descreve um fluxo | resumo de até 5 linhas; o que foi conferido e como; achados; recomendação rotulada; o que ficou em aberto | comando de cada número; "não medido" onde não há dado | hoje (`docker/swarm-worker.md:19-21`); autor |
| 8 | Script no `oute watch` | worker (o modelo da fase; pode ser Haiku) | A | script com bloco `# RESUMO` no topo e `# CUIDADO:` antes de cada passo que apaga, para ou não se desfaz (1) | resumo de todos os efeitos; condição de cada passo; aviso com o comando e a perda; os comandos | o estado lido antes (`ssh oute-server`); a issue no título (`#N`) | medido (P2) |
| 9 | Lições kaizen | dispatcher (Sonnet) | A | texto (1) | opções por número; para cada lição: fato, evidência, regra proposta, nível | linha do log da rodada; PR ou issue | hoje (`docker/swarm.md:125-136`) |
| 10 | Resumo de fim de rodada | dispatcher (Sonnet) | B | texto (1). Diagrama (2): **pendente** da comparação do Bardi no P3 | o que o Bardi ainda decide; issue → PR → estado; lições; problemas; achados | `#N`, PR, head | medido em parte (P3) |
| 11 | Saída do `scripts/oute` | texto fixo | C | terminal (1) | o que o comando fez; o que falta o Bardi fazer | não se aplica | hoje (`scripts/oute`) |
| 12 | Tray, telas e alertas do agent-studio | texto fixo | C | página e menu (3), como hoje | máquinas, pedidos pendentes, decisão pendente, custo, erros, alertas | a própria telemetria | hoje (`docker/agent-studio/agent_studio/templates/base.html:2`, `docker/agent-studio/agent_studio/alert_text.py`) |
| 13 | Insights do ciclo | sessão `learn` (Haiku) | A | comentário com tabela (1) | opções por número; cada insight com evidência e destino sugerido | rodadas, issues e consultas à telemetria | hoje (`addons/skills/oute-aidlc-learn-insights/SKILL.md:79-87`); modelo: medido por analogia (P1) |
| 14 | Relatórios de ship e ops | `ship` (Sonnet); `ops` (Haiku) | A | texto (1) | veredito na primeira linha; o que o Bardi roda ou decide; checklist; números | comando de cada número; pedido do canal | hoje (`addons/skills/oute-aidlc-ship-release/SKILL.md:122-132`, `addons/skills/oute-aidlc-ops-observe/SKILL.md:52`); autor |

Notas da tabela:
- **"Quem escreve hoje"** vem da tabela do seletor (`config/select/models.toml:18-31`) e do `CONTEXT.md`, que diz que o dispatcher abre na fase `plan`. Uma sessão aberta com `--model` foge disso.
- **Ponto 8:** a garantia "os comandos não mudaram" se confere por máquina ([`p2check.sh`](fatia-2/tools/p2check.sh)). No protótipo o diff dos comandos ficou vazio nos dois modelos.
- **Ponto 10:** o texto em PT controlado custou 143% mais tokens que o original, o diagrama 102% e a página 392% ([`deltas-tokens.tsv`](fatia-2/medidas/deltas-tokens.tsv)). O ganho de leitura **não foi medido**.
- **Pontos 11 e 12:** mudar idioma ou forma é mudança de produção, com teste. O contrato só registra que eles já estão em pt-BR.
- **Ponto 13 e ponto 14 (`ops`):** não houve protótipo nesses pontos. A classe A vem do P1 e do P2, que são de outro ponto. Por isso a base diz "por analogia".

## O que o contrato não cobre

- **A conversa livre na aba.** Ela não tem forma fixa. As regras de [`pt-controlado.md`](pt-controlado.md) valem, mas nenhum protótipo a mediu.
- **A issue como caixa de entrada do dono** (FE#67, do `frentes-engenharia`). É um ponto de outro repo. O que se aproveita está no [`README.md`](README.md), seção 8.
- **O texto entre agentes.** Está em [`lado-maquina.md`](lado-maquina.md).
