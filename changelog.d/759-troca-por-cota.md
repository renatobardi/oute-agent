### Added
- **Troca de assinatura quando a sessão para por cota esgotada** (#759). O `oute-swarm watch` emite a linha `[cota]` quando uma sessão para com o erro de limite do fornecedor (429, `Limit Exhausted`, `usage limit`), com a assinatura e o reset. O novo `oute-swarm switch <n>-<slug>` reabre a sessão na próxima assinatura da cadeia da issue, na mesma worktree e branch, com a instrução original; sem cota em nenhuma, sai com 6 e lista o estado e o reset de cada uma. O dispatcher faz a troca sem pedir ao Bardi e avisa numa linha (`docker/swarm.md`). Novo `oute-select --next-subscription`. **Precisa de release** (`docker/oute-swarm`, `docker/oute-select` e `docker/swarm.md` vão na imagem).

### Changed
- **A trava semanal do `spawn` vale também para a `zai`** (#759). `weekly_guard_pct = 85` na assinatura `zai` de `config/select/models.toml` (entra com `git pull` + `oute down/up`): o `spawn` recusa com código 5 a sessão zai com a janela de 7 dias em 85% ou mais.
