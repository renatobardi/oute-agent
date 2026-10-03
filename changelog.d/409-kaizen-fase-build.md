### Changed

- **Seletor: `kaizen` não vence mais fase de código** (#409). A exceção `kaizen` (Haiku) só vale sem label de fase de código; com `aidlc:build`, `qa`, `design`, `plan`, `ship` ou `iter`, vale a fase (Sonnet). `kaizen` sem fase ou com `aidlc:spec` segue Haiku, e `spike` continua vencendo. A tabela ganha `unless_phases` na exceção, o `scripts/models-check` confere as fases e o ADR-02 registra a evidência (PR #362, amostra única). **Precisa de release** (`docker/oute-select` vai na imagem); a tabela entra com `git pull` + `oute down/up`.
