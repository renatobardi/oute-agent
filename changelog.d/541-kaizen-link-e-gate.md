### Changed
- **Dispatcher não digita link de comentário e guarda a saída dos gates** (#541). O `docker/swarm.md` §3 manda o `tell` que cita comentário usar o URL copiado da saída do `gh pr comment`, e a auditoria e a reauditoria gravarem a saída de cada gate em arquivo, só removendo a worktree depois de a falha ser copiada para o relatório. **Precisa de release** (o `swarm.md` vai na imagem).
