# Spike #458, fatia 1: artefatos da medição de tokens (pergunta 7)

Só leitura e medição. Nada daqui é código de produção. O relatório da fatia 1 está no comentário da issue #458.

- `variants/b-en-concise/`, `variants/c-en-ste80/`: as variantes em inglês dos 7 arquivos (a variante `a-pt` é o arquivo do repo no commit `e83eb5e`). Escritas por subagentes a partir do `BRIEF.md`.
- `count-claude.sh`, `measure.sh`, `table.py`: a contagem. Precisam de uma pasta `t/` ao lado, com `one.txt` (conteúdo `x`), e de um venv em `venv/` com `tiktoken==0.12.0`.
- `tokens.tsv`: a saída do `measure.sh` (duas rodadas: 6 arquivos e depois o `swarm.md`; a linha de base foi igual nas duas).
- `fidelity.sh` → `fidelity.tsv`; `shape.py` → `shape.tsv`.
- `count-codex.sh`: tentativa de contar pelo Codex. Não reproduz (os hooks do ai-memory mudam o contexto a cada execução). Não usar os números dela.
