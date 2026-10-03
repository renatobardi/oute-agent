### Fixed

- oute-swarm close: registra a baixa (mark_closed) antes de escrever a saída, para que pipe cortado (| head -1) não deixe aba contando no --max (#407). **Precisa de release** (oute-swarm e swarm.md vão na imagem)
