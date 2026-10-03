### Added

- `docker/swarm-worker.md`: regra que em teste e script, `rm` com variável usa `"${VAR:?}"/…` ou caminho literal, para não disparar o prompt de permissão que trava a sessão. Exemplo: `rm -f "${FAKE:?}"/*.json` (#358).
