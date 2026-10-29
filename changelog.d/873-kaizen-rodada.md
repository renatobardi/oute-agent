### Fixed
- **Watch avisa resultado rc 0 do canal e pendência repete a cada 2 h (#873, kaizen swarm-1027-0802).** O `oute-swarm watch` agora emite `[canal] resultado <id>: rc=0` para pedido da rodada (pelos campos `# rodada:` ou `# sessao:` do script, já movido para `done/` ou `rejected/`), não só para rc≠0; e a linha `[pendencia]` parada repete no máximo a cada 2 h (`OUTE_WATCH_PEND_REPEAT_S`, padrão 7200) em vez de a cada passada. **Precisa de release** (o `docker/oute-swarm` e os prompts vão na imagem).

### Changed
- **Premerge distingue check pulado de pendente (#873, kaizen swarm-1027-0802).** O `oute-swarm premerge` classifica `SKIPPED`/`NEUTRAL` como `pulou`: o SonarCloud pulado ou ausente segue recusando com 4, e qualquer outro check pulado (ex.: CodeRabbit) não bloqueia — sai na linha do ok como `pulou: <check>`. **Precisa de release** (o `docker/oute-swarm` vai na imagem).
