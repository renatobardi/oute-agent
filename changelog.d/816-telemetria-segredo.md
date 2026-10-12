### Security
- **Filtro de segredo no collector** (#816). O collector mascara com `[redigido]`, antes da escrita no bucket e no agent-studio, bloco PEM, `Bearer <token>`, `Authorization: Basic`, tokens do GitHub, `sk-`, `xox…`, chaves AWS, `AIza…`, JWT, `usuário:senha@` em URL e `NOME=valor` ou `"password": "…"` com nome de segredo. É uma rede de padrões conhecidos, não garantia. Nenhum registro some. Entra com `git pull` e `oute down/up` (`config/otel/`), sem release.
- **`OTEL_LOG_TOOL_CONTENT` desligado por padrão** (#816). `docker/compose.yaml` passa a `${OTEL_LOG_TOOL_CONTENT:-0}` (entra com `git pull`), e o `oute-emit run` não leva mais essa chave do `~/.oute_env` ao agente headless. **Precisa de release** (docker/oute-emit vai na imagem).

### Fixed
- **`~/.oute_env` só no login e no shell interativo** (#816). O `~/.bashrc` carrega o `~/.oute_env` só atrás da guarda de interativo; o `~/.profile` segue carregando no login (`oute ssh`, `oute shell`, `bash -l`). Um `bash -c` com stdin em socket deixa de herdar o ambiente. **Precisa de release** (docker/entrypoint.sh vai na imagem).
