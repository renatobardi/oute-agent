### Added
- **Procedimento de rotação da senha root do SurrealDB** (#427). `secrets/README.md` descreve os passos no oute-server (vault, `oute up --refresh-secrets`, remover `oute-surrealdb` **e** `oute-volume-init`, apagar o volume, `oute up` e `oute studio rebuild-state`) e a conferência das contagens. Só documentação; não precisa de release.
