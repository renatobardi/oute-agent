### Changed
- **Skill `oute-aidlc-qa-pr-audit`: o arquivo do caminho da worktree de auditoria é um por PR** (#684). Nos passos 6 e 13 o arquivo passa de `$HOME/.oute-aud-path` para `$HOME/.oute-aud-<N>` (`<N>` = número do PR), para duas auditorias ao mesmo tempo não se sobrescreverem. Entra com `git pull` + `oute down/up`, sem release.
