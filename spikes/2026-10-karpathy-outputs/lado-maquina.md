# Lado máquina: pt, inglês, STE ou enxuta, por tipo de texto (spike #458, fatia 3)

**Estado:** recomendação do autor do relatório. A decisão é do Bardi.

**A prioridade do Bardi para este lado** (issue #458, "Prioridades"): economizar o possível, sem perder qualidade. A economia só vale se a regressão não cair.

## Resumo

1. **Nenhuma troca de idioma está provada.** A regressão de hoje não separa as variantes, e ela cobre 3 grupos de regra de cerca de 53.
2. **A variante mais barata é a enxuta** (inglês reescrito): 23% menos tokens que o pt no `agent-notes.md`.
3. **O STE a 80% não se paga** neste lado: custa mais que o inglês direto e não mostrou ganho de qualidade.
4. **Primeiro passo recomendado:** estender a suíte de regressão. Só depois trocar um arquivo, o `agent-notes.md`.

## As quatro variantes

| Variante | O que é | Tokens contra o pt (Sonnet e Opus) | Onde foi medida |
|---|---|---|---|
| a | pt de hoje | linha de base | 7 arquivos |
| b | inglês conciso, traduzido frase por frase | −13,1% (67887 → 59003) | 7 arquivos ([`fatia-1/tokens.tsv`](fatia-1/tokens.tsv)) |
| c | inglês em ASD-STE100 a 80% | −7,4% (67887 → 62847) | 7 arquivos |
| d | inglês enxuto, reescrito | −23% (2292 → 1761) | só o `agent-notes.md` ([`fatia-2/medidas/tokens.tsv`](fatia-2/medidas/tokens.tsv)) |

No Haiku 4.5: b −12,9% (51081 → 44517), c −6,3% (51081 → 47883), d −24% (1729 → 1306).

## Qualidade medida

**Fidelidade do `agent-notes.md`** (revisão do Opus, 53 regras; [`fidelidade-opus-bcd.md`](fatia-2/p4/d-enxuta/fidelidade-opus-bcd.md)):

| Variante | Regras mantidas | Pontos de ambiguidade nova |
|---|---|---|
| b | 53 de 53 | 0 |
| c | 53 de 53 | 3 |
| d | 53 de 53 | 2 |

**Regressão em Haiku** ([`p4-resumo.tsv`](fatia-2/medidas/p4-resumo.tsv)):

| Variante | `root`, `select` e `emit` juntas | `worktree` |
|---|---|---|
| a | 48 de 48 | 0 de 6 |
| b | 39 de 39 | 0 de 3 |
| c | 38 de 39 | 0 de 3 |
| d | 38 de 39 | 1 de 3 |

- A diferença entre a e d não é significativa: `tools/fisher.py 16 16 12 13` dá p = 0,448.
- A tarefa `worktree` falha também com as notas reais. Ela não mede as variantes.

## Recomendação por tipo de texto

| Tipo de texto | Exemplos | Recomendação do autor | O que sustenta | O que falta provar |
|---|---|---|---|---|
| **Notas do agente** | `docker/agent-notes.md` | **enxuta (d)**, depois de corrigir a regra 10 e a regra 37 e de acrescentar a regra do pt-BR | −23% de tokens; 53 de 53 regras | regressão com poder de prova; o pt-BR da saída ao Bardi |
| **Prompts do swarm** | `docker/swarm.md`, `docker/swarm-worker.md` | **inglês conciso (b)** primeiro; enxuta depois, arquivo por arquivo | −14,9% e −14,8% de tokens (fatia 1) | fidelidade por leitura (não conferida nesses arquivos); nenhuma tarefa da regressão lê esses prompts |
| **Skills em pt** | 21 dos 30 `SKILL.md` (medida da issue #458) | **inglês conciso (b)**, uma skill por PR | −12,0% a −12,7% nas 3 skills medidas (fatia 1) | fidelidade por leitura; não há regressão de skill |
| **`AGENTS.md`** | o arquivo que entra em toda sessão | **fica em pt** | o ganho é o menor (−9,0%); o Bardi também lê o arquivo | nada: ver o rascunho do ADR |
| **`tell`** | `oute-swarm tell` | **fica como está** | já tem teto de cerca de 750 caracteres (`docker/swarm.md:57`); média medida de 69 palavras | tokens por idioma: não medido |
| **Eventos do watch** | linhas `[ci]`, `[pr]`, `[sessao]` | **fica o idioma; cortar repetição** | 6,5 palavras por linha; 523 das 546 linhas `[ci]` são de check que passou | se juntar as linhas `pass` tira informação que o dispatcher usa |
| **Relatório de auditoria** | comentário no PR | **pt** (o Bardi lê); forma curta sem achado | 447 palavras no #445, sem achado (fatia 1) | o tamanho da forma curta |
| **Handoffs e páginas do ai-memory** | `memory_handoff_*` | **não mexer agora** | regra do repo: o comportamento do ai-memory não muda sem decisão do Bardi (`AGENTS.md`, "Regras") | tokens por idioma: não medido |
| **Log, telemetria, nomes de evento** | `oute.*`, tags do watch | **não se aplica** | é dado estruturado e contrato (pergunta 12) | nada |
| **Commits** | assunto e corpo | **fica em pt** | opinião do autor, sem medida: o `CHANGELOG.md` e os fragmentos são em pt | tokens: não medido; se o Bardi lê os commits: não verificado |

Sobre o **STE a 80% (c)**: nenhuma linha da tabela o recomenda. Motivos medidos:
- ele custa 6,5% mais tokens que o inglês direto no Sonnet e no Opus, e 7,6% mais no Haiku (fatia 1);
- ele trouxe 3 pontos de ambiguidade nova no `agent-notes.md`, contra 0 do inglês direto;
- a regressão não mostrou ganho.

A hipótese da issue (o STE reduz erro de leitura em texto de instrução) fica **sem prova**, nem a favor nem contra. A suíte não tem poder para isso.

## Onde o texto entre agentes é gordo (pergunta 9)

Medido nos 58 logs de rodada de `~/.oute/swarm/*/log` (2070 linhas) e no ai-memory, em 2026-10-04.

| Texto | Medida | Leitura |
|---|---|---|
| `tell` | 113 mensagens; média de 69 palavras; maior com 131 palavras e 749 caracteres | não é gordo: o teto já existe e é respeitado |
| Eventos do watch | 1454 linhas; 9516 palavras; 6,5 por linha | a linha é magra |
| Eventos `[ci]` | 546 linhas; 523 são de check que passou (`checks`, `SonarCloud Code Analysis`, `CodeRabbit`) | **repetição:** até 3 linhas por head para dizer "tudo passou" |
| Relatório de auditoria | 399 a 761 palavras nos 8 PRs auditados; 447 palavras no #445, sem achado (fatia 1) | **gordo quando não há achado** |
| Handoffs abertos | 36; média de 236 palavras (resumo, próximos passos e perguntas); 8512 palavras no total; 33 em pt e 3 em inglês. O revisor contou 8781 palavras e 2 em inglês: a contagem depende de como se separam as palavras | **acúmulo:** 36 abertos; o tamanho de cada um não é o problema |
| Páginas do ai-memory | não medido | o spike #429 tratou do idioma misto |

Comandos:

```bash
cd ~/.oute/swarm
ls | wc -l; cat */log | wc -l                                   # 58 rodadas, 2070 linhas
cat */log | awk -F'\t' '$1 ~ / tell [^ ]+ ok/ {n++; w=split($2,a," "); sw+=w; if(w>mw)mw=w; c=length($2); if(c>mc)mc=c}
  END{printf "%d %.0f %d %d\n",n,sw/n,mw,mc}'                   # 113 69 131 749
cat */log | awk '$2=="watch"{n++; w+=NF-2} END{print n, w, w/n}' # 1454 9516 6.5447
cat */log | grep -c '\[ci\]'                                     # 546
cat */log | grep '\[ci\]' | grep -c ': pass'                     # 523
```

Handoffs: `memory_handoff_list` (workspace `default`, project `oute-agent`, só leitura) e `jq` sobre a resposta: quantidade, palavras de `summary`, `next_steps` e `open_questions`. O idioma saiu de uma heurística (`the|and|was|with` no resumo).

## O que falta provar, em ordem

1. **Uma regressão com poder de prova.** Hoje ela cobre 3 grupos de regra de cerca de 53: pedir root, escolher modelo e emitir evento. Uma das 4 tarefas falha na linha de base.
2. **O pt-BR da saída ao Bardi com prompt em inglês.** Nenhuma tarefa mede isso.
3. **A fidelidade dos outros 6 arquivos** das variantes b e c. Só o `agent-notes.md` foi lido por revisor.
4. **Tokens no Codex e no `claude-fable-5-1`.** Não medido nas duas fatias.
5. **O total por rodada.** Falta saber quantas vezes cada arquivo entra numa rodada e o efeito do cache de prompt.
