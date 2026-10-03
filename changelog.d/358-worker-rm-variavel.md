### Added

- `docker/swarm-worker.md`: regra que em teste e script, `rm` com variável usa `"${VAR:?}"/…` ou caminho literal, para não disparar o prompt de permissão. Exemplo: `rm -f "${FAKE:?}"/*.json` (#358). Precisa de release (swarm-worker.md vai na imagem).
