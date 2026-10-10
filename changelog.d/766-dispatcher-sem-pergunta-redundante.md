### Changed
- swarm: o dispatcher fecha a aba de PR mergeado (ou de issue abandonada pelo Bardi) sem perguntar e executa sem pergunta a ação que uma regra do prompt já manda; fechar aba com sessão trabalhando, `clean --yes`, merge e ação no host seguem com confirmação. O dispatcher registra no log o que espera e de quem (#766).

### Added
- swarm: o `oute-swarm watch` emite a linha `[pendencia]` quando PR aberto, CI vermelho ou sessão `done` sem PR ficam 30 minutos sem mudança (`OUTE_WATCH_STALL_S`); sem pendência parada, nada é emitido (#766, #767). **Precisa de release** (`swarm.md` e `oute-swarm` vão na imagem).
