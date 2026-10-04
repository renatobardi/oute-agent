# Forma e referências do relatório da fatia 3 (spike #458)

O relatório passou pelas ferramentas da fatia 2. Comandos, rodados nesta pasta:

```bash
python3 fatia-2/tools/textstats.py pt README.md pt-controlado.md output-contract.md lado-maquina.md adr-rascunho-idioma.md issues-de-build.md
for f in README.md pt-controlado.md output-contract.md lado-maquina.md adr-rascunho-idioma.md issues-de-build.md; do python3 fatia-2/tools/refcheck.py "$f" HEAD; done
```

## Forma (`textstats.py`)

| arquivo | palavras | frases | média de palavras por frase | mediana | maior frase | % acima de 20 | % acima de 25 | parágrafos | maior parágrafo (frases) | % de parágrafos acima de 6 | % passiva (heurística) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| README.md | 2940 | 157 | 8.4 | 8 | 23 | 3 | 0 | 71 | 6 | 0 | 6 |
| pt-controlado.md | 1565 | 61 | 9.0 | 8 | 24 | 5 | 0 | 28 | 5 | 0 | 3 |
| output-contract.md | 1499 | 74 | 9.0 | 9.0 | 22 | 3 | 0 | 40 | 4 | 0 | 7 |
| lado-maquina.md | 1300 | 51 | 8.5 | 7 | 23 | 4 | 0 | 28 | 4 | 0 | 4 |
| adr-rascunho-idioma.md | 1137 | 88 | 9.9 | 9.0 | 24 | 3 | 0 | 44 | 6 | 0 | 8 |
| issues-de-build.md | 1003 | 28 | 7.8 | 8.0 | 17 | 0 | 0 | 16 | 4 | 0 | 7 |

## Referências (`refcheck.py`, contra o `HEAD` do branch)

| arquivo | resultado |
|---|---|
| README.md | 13 referências distintas, 0 falha(s) |
| pt-controlado.md | 1 referências distintas, 0 falha(s) |
| output-contract.md | 19 referências distintas, 0 falha(s) |
| lado-maquina.md | 4 referências distintas, 0 falha(s) |
| adr-rascunho-idioma.md | 5 referências distintas, 0 falha(s) |
| issues-de-build.md | 7 referências distintas, 0 falha(s) |

Limites:
- A ferramenta mede a prosa. Ela pula as tabelas e os blocos de código, e este relatório tem muita tabela.
- A voz passiva é heurística.
- O `refcheck.py` confere que a referência existe. Ele não confere que ela sustenta a frase.
- O `report.html` não entra: a ferramenta lê Markdown.
