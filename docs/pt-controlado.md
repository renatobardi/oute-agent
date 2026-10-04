# PT controlado: regras e dicionário

**Estado:** regra do repo (#478). Origem: spike #458, fatia 3 ([versão do spike](https://github.com/renatobardi/oute-agent/blob/672df2f/spikes/2026-10-karpathy-outputs/pt-controlado.md), com as medidas).

**Para que serve.** O PT controlado é a forma do texto que o Bardi lê ou aprova. Ele adapta ao pt-BR os limites do ASD-STE100 que o post do Karpathy resume (issue #458). Ele não vale para texto entre agentes.

**Quem segue.** Todo agente que escreve para o Bardi: sessão avulsa, worker e dispatcher. Isso inclui PR, comentário de issue, relatório, pedido do canal de aprovação e pergunta de `BLOQUEADO`. As regras curtas estão em `docker/agent-notes.md`, `docker/swarm-worker.md` e `docker/swarm.md`. Este doc é a versão completa.

**Fora de escopo.** O idioma dos prompts não muda aqui. O formato de cada ponto de supervisão tem issue própria (#479, #480, #482). A decisão de idioma é do ADR da #483.

## As 15 regras

| # | Regra | Como conferir |
|---|---|---|
| 1 | **O texto para o Bardi sai em pt-BR.** Vale mesmo quando o prompt, a skill ou a fonte estão em inglês. | leitura |
| 2 | **A decisão vem primeiro.** A primeira linha diz o que o Bardi decide. As opções vêm numeradas. | leitura |
| 3 | **Frase curta, uma ideia.** Frase de instrução: até 20 palavras. Frase descritiva: até 25. Uma instrução por frase. | `textstats.py` do spike |
| 4 | **Parágrafo: até 6 frases, um assunto só.** | `textstats.py` do spike |
| 5 | **Voz ativa, sujeito explícito, tempo simples.** "O teste falha", não "é observada uma falha". "O script roda", não "está rodando". "Falhou", não "tinha falhado". | heurística |
| 6 | **Grupo nominal: até 3 palavras seguidas.** Quebre "relatório de auditoria de segurança do PR" em duas frases ou em lista. | leitura |
| 7 | **Uma palavra, um sentido.** Use o termo do dicionário abaixo. Não varie por estilo. | `grep` dos termos a evitar |
| 8 | **Lista vertical** quando a frase teria 3 ou mais itens ou condições. | leitura |
| 9 | **Aviso de risco: comando primeiro, risco depois.** Formato: `CUIDADO: <o que o passo faz>. <o que se perde>.` Diga "não se desfaz" quando for o caso. O aviso não tranquiliza: ele avisa. | `grep -c 'CUIDADO:'`; leitura |
| 10 | **Toda afirmação cita uma fonte que o Bardi consegue abrir.** Formas: link, `arquivo:linha@sha`, `#N` (issue ou PR), link de comentário, ou o comando que reproduz. Nunca caminho de scratchpad nem de arquivo temporário. Todo número traz o comando ou a palavra "não medido". Sem fonte, escreva "não verificado". | a referência existe e abre? |
| 11 | **Recomendação só com fonte, ou com o rótulo "recomendação do autor".** Nunca atribua a outro documento ou ao Bardi uma recomendação ou decisão que ele não deu. | leitura por revisor |
| 12 | **Reescrever não muda o fato.** Mantenha cada condição ("só se", "pelo menos", "antes de") e cada valor como na fonte. Classifique só quando a fonte sustenta a classe. | revisor de outro modelo |
| 13 | **Frase completa.** Não corte artigos. Não escreva em estilo telegráfico. | leitura |
| 14 | **Fato primeiro, incerteza depois.** Diga o que é certo. Marque o resto como "incerto" e diga o que resolve. | leitura |
| 15 | **Contrato fica em crase e sem tradução:** comandos, labels, nomes de evento, `PRONTO #N`, `Closes`, `Refs`, `## Falta`. | trechos entre crases iguais à fonte |

Por que as regras 1, 10, 11 e 12 existem (medido no spike):
- **1:** nas três variantes em inglês do P4, nada garantia o pt-BR da saída.
- **10:** no P1, 15 de 19 referências do Haiku apontavam para o scratchpad.
- **11:** no P1, os dois modelos puseram recomendação que a auditoria não faz.
- **12:** o polimento mudou fato nos protótipos P1, P2 e P5.

## Dicionário

A coluna "Use" é o termo aprovado. A coluna "Evite" lista o que não usar **para esse sentido**.

### Parte A: termos que o `CONTEXT.md` já fixa

| Use | Evite | Fonte |
|---|---|---|
| Jev; seletor | roteador | `CONTEXT.md`, termos "Jev" e "seletor" |
| reserva | fallback | termo "reserva" |
| pedido (do canal de aprovação) | proposta, job | termo "pedido" |
| conversa (do agente) | sessão | termo "sessão" |
| sessão avulsa | worker | termo "sessão avulsa" |
| evento operacional | telemetria do swarm | termo "evento operacional" |
| credencial de ingestão; credencial de leitura | o token do agent-studio | termo "credencial de ingestão / de leitura" |
| addon | plugin (como nome geral) | termo "addon" |
| worker (só a sessão do swarm por issue) | worker (para script) | termo "worker" |

### Parte B: termos novos

| Use | Evite | Nota |
|---|---|---|
| fazer merge | mergear, mesclar, integrar | decisão do par: "fazer merge" (recomendação do autor do spike, que os protótipos já usaram; o Bardi pode trocar no PR da #478) |
| rodar (um comando, um teste) | executar, disparar | |
| aprovar (o `oute approve`) | autorizar, dar o ok | |
| recusar (um pedido) | negar, rejeitar | a tela do watch usa `[r]ecusar` |
| achado (da auditoria) | problema, issue | issue é só o item do GitHub |
| critério de aceite | requisito, condição de pronto | |
| falha (de teste ou de gate) | erro, problema | |
| rodada | ciclo | ciclo é outra coisa no glossário |
| proposta (comentário de issue sem arquivo) | pedido | pedido é só o do canal de aprovação |
| não medido; não verificado | estimado, aproximadamente (sem rótulo) | regra 10 |

**Limite do dicionário.** O `grep` só acha o termo a evitar. Ele não confere se o termo aprovado foi usado no sentido certo.

**Prompts de hoje.** Vários prompts e skills ainda dizem "mergear". Trocar esses textos é mudança de prompt e fica fora da #478. A regra vale para o que o agente escreve ao Bardi a partir de agora.
