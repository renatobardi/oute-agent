# Spike #458, fatia 2: protótipos

Só protótipo e medição. Nada daqui é código de produção. O relatório da fatia 2 é o comentário final da issue #458.

| pasta | conteúdo |
|---|---|
| `briefs/` | instruções dadas aos subagentes: `COMMON.md`, `PT-CONTROLADO-RASCUNHO.md` (15 regras e dicionário, rascunho), `FIDELIDADE.md` (protocolo do revisor) |
| `tools/` | `textstats.py` (forma da prosa), `tok.sh` + `count-claude.sh` (tokens, como na fatia 1), `refcheck.py` (a referência existe?), `p2check.sh` (o script mudou só comentário e `echo`?), `p2prose.py`, `fisher.py` |
| `p1/` | pedido de merge do PR #457: original, versão do Sonnet, versão do Haiku, revisão do Opus de cada uma |
| `p2/` | pedido real do canal de aprovação: original, versão do Sonnet, versão do Haiku, revisão do Opus |
| `p3/` | resumo do ciclo da #437: original, texto, diagrama SVG, página HTML, revisão do Opus |
| `p4/` | `run-variant.sh` (arranjo descartável), `d-enxuta/` (variante reescrita, rastreio, revisão do Opus para b, c e d), `resultados/` (saída bruta do `oute-regression`) |
| `p5/` | **só as medidas** (o artefato é privado e fica fora do repo) |
| `video/` | viabilidade de vídeo (pesquisa) |
| `medidas/` | `forma.tsv`, `tokens.tsv`, `deltas-tokens.tsv`, `p4-resumo.tsv`, `refcheck-*`, `p2check-*`, `custo-subagentes.tsv`, `custo-regressao.tsv` |

Insumos que não estão aqui: as cópias de `gh` das fontes (auditoria, resumo do ciclo, pedido do canal estão em `p1/`, `p3/`, `p2/`
como "original"); o venv com `tiktoken==0.12.0` e o diretório `t/` com `one.txt` (`x`) que o `tok.sh` pede (`COUNT_T`, `COUNT_PY`).

Notas de execução:
- `p4/resultados/result-d.txt` termina com uma linha `rc=126` a mais. Editei o `run-variant.sh` enquanto a cadeia rodava; o relatório do
  `oute-regression` daquela execução está completo e é o que vale.
- Os modelos dos escritores e revisores estão na tabela `medidas/custo-subagentes.tsv`.
