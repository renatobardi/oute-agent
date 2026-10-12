### Fixed
- **A tarefa da regressão deixa de herdar o ambiente da sessão zai** (#736). O `claude -p` de cada tarefa sai sem as variáveis `ANTHROPIC_*`, `API_TIMEOUT_MS` e `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` que a sessão exporta; só o ramo `--subscription zai` as põe, como antes. **Precisa de release** (o `oute-regression` vai na imagem).
