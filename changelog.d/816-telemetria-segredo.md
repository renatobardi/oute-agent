### Security
- **Filtro de segredo no collector** (#816). O collector mascara com `[redigido]`, antes da escrita no bucket e no agent-studio, bloco PEM, `Bearer <token>`, `gh[pousr]_…`, `github_pat_…`, `sk-…`, `AKIA…`, `AIza…` e `NOME=valor` com NOME em maiúscula terminado em KEY, TOKEN, SECRET ou PASSWORD, ou começando em GH_. É uma rede de padrões conhecidos, não garantia. Nenhum registro some. **Precisa de release** (docker/entrypoint.sh e docker/oute-emit vão na imagem).
- **`OTEL_LOG_TOOL_CONTENT` desligado por padrão** (#816). `docker/compose.yaml` passa a `${OTEL_LOG_TOOL_CONTENT:-0}`, e o `oute-emit run` não leva mais essa chave do `~/.oute_env` ao agente headless. O texto do resultado de ferramenta deixa de ir ao bucket e ao agent-studio nas sessões novas. **Precisa de release** (docker/entrypoint.sh e docker/oute-emit vão na imagem).

### Fixed
- **`~/.oute_env` só no login e no shell interativo** (#816). O `~/.bashrc` carrega o `~/.oute_env` só atrás da guarda de interativo; o `~/.profile` segue carregando no login. Um `bash -c` com stdin em socket deixa de herdar o ambiente. **Precisa de release** (docker/entrypoint.sh e docker/oute-emit vão na imagem).
