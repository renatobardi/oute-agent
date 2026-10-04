# PT controlado: regras e dicionário (spike #458, fatia 3)

**Estado:** proposta do spike. Nada aqui vale como regra do repo até o Bardi decidir.

**Para que serve.** O PT controlado é a forma do texto que o Bardi lê ou aprova. Ele adapta ao pt-BR os limites do ASD-STE100 que o post do Karpathy resume (issue #458, seção "O que o post diz"). Ele não vale para texto entre agentes: esse lado está em [`lado-maquina.md`](lado-maquina.md).

**De onde vem cada regra.** A coluna "Origem" diz se a regra vem do post, do prompt do Bardi ou de um defeito que as fatias mediram. O rascunho usado na fatia 2 está em [`fatia-2/briefs/PT-CONTROLADO-RASCUNHO.md`](fatia-2/briefs/PT-CONTROLADO-RASCUNHO.md).

## As 15 regras

| # | Regra | Como conferir | Origem |
|---|---|---|---|
| 1 | **O texto para o Bardi sai em pt-BR.** Vale mesmo quando o prompt, a skill ou a fonte estão em inglês. | leitura | fatia 2, P4: nas três variantes em inglês, nada garante o pt-BR da saída |
| 2 | **A decisão vem primeiro.** A primeira linha diz o que o Bardi decide. As opções vêm numeradas. | leitura | prompt do Bardi; P1 |
| 3 | **Frase curta, uma ideia.** Frase de instrução: até 20 palavras. Frase descritiva: até 25. Uma instrução por frase. | `textstats.py` (colunas `pct_>20`, `pct_>25`, `max`) | post |
| 4 | **Parágrafo: até 6 frases, um assunto só.** | `textstats.py` (`max_frases_par`) | post |
| 5 | **Voz ativa, sujeito explícito, tempo simples.** "O teste falha", não "é observada uma falha". "O script roda", não "está rodando". "Falhou", não "tinha falhado". | `textstats.py` (passiva, só heurística) | post |
| 6 | **Grupo nominal: até 3 palavras seguidas.** Quebre "relatório de auditoria de segurança do PR" em duas frases ou em lista. | leitura | post |
| 7 | **Uma palavra, um sentido.** Use o termo do dicionário abaixo. Não varie por estilo. | `grep` dos termos a evitar | post |
| 8 | **Lista vertical** quando a frase teria 3 ou mais itens ou condições. | leitura | post |
| 9 | **Aviso de risco: comando primeiro, risco depois.** Formato: `CUIDADO: <o que o passo faz>. <o que se perde>.` Diga "não se desfaz" quando for o caso. O aviso não tranquiliza: ele avisa. | `grep -c 'CUIDADO:'`; leitura | post; P2 (o Haiku tranquilizou em vez de avisar) |
| 10 | **Toda afirmação cita uma fonte que o Bardi consegue abrir.** Formas: `arquivo:linha@sha`, `#N`, link de comentário, ou o comando que reproduz. Todo número traz o comando ou a palavra "não medido". Sem fonte, escreva "não verificado". | `refcheck.py` (a referência existe?) | prompt do Bardi; P1 (o Haiku citou 15 arquivos do scratchpad) |
| 11 | **Recomendação só com fonte, ou com o rótulo "recomendação do autor".** Nunca atribua a outro documento ou ao Bardi uma recomendação ou decisão que ele não deu. | leitura por revisor | P1 (os dois modelos puseram recomendação que a auditoria não faz) |
| 12 | **Reescrever não muda o fato.** Mantenha cada condição ("só se", "pelo menos", "antes de") e cada valor como na fonte. Classifique só quando a fonte sustenta a classe. | revisor de outro modelo, pelo [protocolo](fatia-2/briefs/FIDELIDADE.md) | prompt do Bardi ("polimento não é correção"); P1, P2, P5 |
| 13 | **Frase completa.** Não corte artigos. Não escreva em estilo telegráfico. | leitura | post |
| 14 | **Fato primeiro, incerteza depois.** Diga o que é certo. Marque o resto como "incerto" e diga o que resolve. | leitura | rascunho da fatia 2 |
| 15 | **Contrato fica em crase e sem tradução:** comandos, labels, nomes de evento, `PRONTO #N`, `Closes`, `Refs`, `## Falta`. | `fidelity.sh` (trechos entre crases iguais) | issue #458, pergunta 12 |

As regras 1, 11 e 12 são novas em relação ao rascunho. Para caber em 15, o rascunho perdeu três linhas por fusão: "uma ideia por frase" entrou na regra 3, "sem gerúndio" entrou na regra 5 e "todo número traz a origem" entrou na regra 10.

## O modelo cumpre as regras? (pergunta 3)

Medida da fatia 2, em [`fatia-2/medidas/forma.tsv`](fatia-2/medidas/forma.tsv), pelo [`textstats.py`](fatia-2/tools/textstats.py). Uma amostra por protótipo.

| Texto | Média de palavras por frase | Maior frase | Frases acima de 25 | Parágrafos acima de 6 frases | Passiva (heurística) |
|---|---|---|---|---|---|
| P1, auditoria original | 8,5 | 30 | 2% | 5% | 4% |
| P1, Sonnet | 10,5 | 23 | 0% | 6% | 7% |
| P1, Haiku | 8,3 | 39 | 4% | 0% | 1% |
| P3, resumo original | 8,8 | 26 | 3% | 0% | 5% |
| P3, Sonnet | 6,6 | 18 | 0% | 0% | 4% |

O que a tabela diz:
- **O Sonnet cumpre o limite de 25 palavras** nas duas amostras. No P1, 5% das frases dele passam de 20, o limite da frase de instrução (`forma.tsv`). A ferramenta não separa instrução de descrição.
- **O P3 do Sonnet cumpre os dois limites:** a maior frase tem 18 palavras.
- **O Sonnet não cumpre a regra 4 no P1:** 6% dos parágrafos passam de 6 frases, e o maior tem 8.
- **O Haiku não cumpre a regra 3 no P1:** a maior frase tem 39 palavras.
- **A voz passiva não tem medida confiável.** A heurística erra nos dois sentidos (cabeçalho do `textstats.py`).
- **As regras 10, 11 e 12 não se medem pela forma.** Elas falharam nos dois modelos no P1. O resultado está no [`README.md`](README.md), seção 3.

## Dicionário (pergunta 4)

Regra de uso: a coluna "Use" é o termo aprovado. A coluna "Evite" lista o que não usar **para esse sentido**.

### Parte A: termos que o `CONTEXT.md` já fixa

O glossário do `CONTEXT.md` tem 50 termos, e 9 deles já trazem "Evite" (`sed -n 32,83p CONTEXT.md | grep -c '^- \*\*'` dá 50; `git grep -n -E "Evite" CONTEXT.md | wc -l` dá 9). Esses 9 entram no dicionário sem mudança, nas 8 primeiras linhas abaixo ("Jev" e "seletor" dividem uma linha). A última linha vem do termo "worker", que diz "Não usar para scripts" sem a palavra "Evite".

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

### Parte B: termos novos, propostos pelo spike

| Use | Evite | Nota |
|---|---|---|
| fazer merge | mergear, mesclar, integrar | conflito com os prompts de hoje, ver abaixo |
| rodar (um comando, um teste) | executar, disparar | |
| aprovar (o `oute approve`) | autorizar, dar o ok | |
| recusar (um pedido) | negar, rejeitar | a tela do watch usa `[r]ecusar` |
| achado (da auditoria) | problema, issue | issue é só o item do GitHub |
| critério de aceite | requisito, condição de pronto | |
| falha (de teste ou de gate) | erro, problema | |
| rodada | ciclo | ciclo é outra coisa no glossário |
| proposta (comentário de issue sem arquivo) | pedido | pedido é só o do canal de aprovação |
| não medido; não verificado | estimado, aproximadamente (sem rótulo) | regra 10 |

### O que foi medido sobre o dicionário

Contei os termos a evitar da parte B nos artefatos da fatia 2. Comando, em `fatia-2/`:

```bash
grep -oiwE 'solicitaç(ão|ões)|requisiç(ão|ões)|job|mergear|mergeado|mergeada|mergeie|mesclar|integrar|executar|executa|executado|disparar|autorizar|problema|problemas|requisito|requisitos' <arquivo>
```

| Arquivo | Termos a evitar |
|---|---|
| `p1/original-auditoria-457.md` | 1 (`mergeado`) |
| `p1/sonnet/pedido-merge.md` | 0 |
| `p1/haiku/pedido-merge.md` | 3 (`mergear`) |
| `p3/original-resumo-ciclo-437.md` | 2 (`mergeada`, `mergear`) |
| `p3/p3-texto.md` (Sonnet) | 0 |
| `p2/sonnet/pedido.sh` | 0 |
| `p2/haiku/pedido.sh` | 0 |

- **O Sonnet seguiu o dicionário** nas três amostras. O Haiku não seguiu no P1.
- **Resposta à pergunta 4:** sim, o glossário vira dicionário. A parte A já existe. A parte B é pequena e o Sonnet a segue.
- **Limite:** o `grep` só acha o termo a evitar. Ele não confere se o termo aprovado foi usado no sentido certo.

### Conflito a decidir

O par "fazer merge × mergear" contraria os prompts de hoje. O verbo "mergear" e suas formas aparecem 31 vezes nos prompts e skills, e "fazer merge" aparece 12 vezes:

```bash
git grep -o -i -w -E 'merge(ar|ie|ado|ada|ados|adas|ou)' -- docker/*.md addons/skills AGENTS.md | wc -l   # 31
git grep -o -i -E 'fazer merge|faz merge|faça merge' -- docker/*.md addons/skills AGENTS.md | wc -l      # 12
```

O modelo imita o prompt. Se o dicionário valer, o Bardi escolhe um dos dois termos e os prompts mudam junto. Recomendação do autor: manter "fazer merge", que o Sonnet já produziu sem esforço.
