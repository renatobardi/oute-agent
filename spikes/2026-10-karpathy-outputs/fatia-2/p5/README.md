# P5, caixa de entrada do dono: só as medidas

O artefato e o original ficam **fora deste repo** (o original é uma issue do repositório privado `frentes-engenharia`; este repo é público).
Nada do conteúdo está aqui, nem a revisão de fidelidade, só números. Os comandos são os mesmos dos outros protótipos
(`tools/textstats.py`, `tools/tok.sh`), rodados sobre os dois arquivos privados.

| medida | original (corpo + 2 comentários) | artefato |
|---|---|---|
| palavras (`wc -w`) | 1595 | 3594 |
| frases · média de palavras por frase | 143 · 10,5 | 286 · 7,7 |
| frases com mais de 20 palavras | 8% | 1% |
| frases com mais de 25 palavras | 3% | 1% |
| tokens `o200k_base` · Haiku 4.5 · Sonnet 5.5 e Opus 5.5 | 2700 · 3345 · 4322 | 6049 · 7479 · 9303 |
| estrutura do artefato | | 8 ações só do dono, 3 decisões, 7 divergências de spec, 43 itens de dívida técnica |

Fidelidade (Sonnet, outra instância, que não escreveu o artefato; só números): 54 fatos do original, 53 mantidos, 1 perdido,
2 com sentido levemente mudado, 0 inventados (mais 2 inferências fracas); 95 afirmações do artefato, 89 com fonte que confere,
0 com fonte que não confere, 6 sem fonte (todas rotuladas "não citado no original"). Veredito: fiel com ressalvas.

Primeira tentativa (descartada): a entrada veio de `gh issue view 67 --comments`, que nesta versão do `gh` (2.102.0) **não imprime o
corpo da issue**, só os comentários. O escritor e o revisor trabalharam sem o corpo (as 9 caixas de seleção). Refiz tudo com o
corpo e os comentários pelo `--json body,comments`. O custo da tentativa descartada entra no total (`medidas/custo-subagentes.tsv`).
