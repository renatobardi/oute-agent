### Changed
- **Trava semanal da `claude` sobe de 85% para 95%** (#800, decisão do Bardi; ADR-02 adendo de 2026-10-11). `weekly_guard_pct = 95` na assinatura `claude` de `config/select/models.toml`: o `oute-swarm spawn` passa a recusar com código 5 só com a janela de 7 dias em 95% ou mais. A `zai` segue em 85. Não precisa de release: a tabela entra com `git pull` + `oute down/up`.
