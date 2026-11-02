### Fixed
- **O dispatcher volta a ser acordado depois de reinício do container** (#893). O `religar` do boot sobe o `watch` com `--deliver` nas rodadas com dispatcher e troca o watch vivo sem entrega; antes, todo deploy deixava as rodadas sem nenhum despertador, e elas só andavam quando o Bardi chamava. Pergunta pendente deixa de segurar a entrega da rodada (mantém só o recomeço de contexto). `[pendencia]` passa a cobrir sessão `idle` e `blocked` sem PR. **Precisa de release** (`docker/oute-swarm`, `docker/swarm/acompanhamento.md`, agent-studio).
- **`tell` não entregue deixa rastro** (#884). Recusa por campo ocupado ou diálogo na tela gera um `[tell]` e entra na `[pendencia]` até outro `tell` entregar.

### Changed
- **Só o que pede ação acorda o dispatcher** (#893). `[sessao] working`, `[canal]` alheio ou sem título, `[subagente]`, `[aba]` de rotina e a volta de `gh` ou `herdr` ficam só no log, para a entrega religada não trazer de volta o gasto de tokens.

### Added
- **Aviso de entrega parada no tray** (#893). Fila do dispatcher parada há 1 h (`OUTE_WATCH_DLV_STALL_S`) gera `[aviso]` sem modelo e o item `delivery` no bloco `attention`.
