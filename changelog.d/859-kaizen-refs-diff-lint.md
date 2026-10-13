### Changed
- **Referências da auditoria de PR: uma por item, e `@sha` para arquivo que só existe no head** (#859). A `oute-aidlc-qa-pr-audit` escreve cada `arquivo:linha` com o seu `@sha`, sem lista de linhas, e um arquivo criado pelo PR leva `@<sha12 do head>`. Sem isso, o `oute-refcheck` recusava o relatório. Não precisa de release (o `addons/` é montado de fora da imagem).

### Fixed
- **Lint do diff: sem `origin/main`, falha fora do CI** (#859). O `tests/diff-lint.test.sh` deixava de conferir o diff do próprio PR sem a base e só avisava que pulou. Agora, fora do CI, a falta da base reprova e manda rodar `git fetch -q origin main`; no CI (`GITHUB_ACTIONS` definido) o caso continua pulado. Não precisa de release (teste).
