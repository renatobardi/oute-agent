### Changed
- **`oute-aidlc-qa-pr-audit`: link do relatório no comentário de merge vem do `gh pr comment`** (#420). O passo 12 guarda o URL que o `gh pr comment` imprime (`REPORT_URL`) e o passo 14 usa esse valor no campo "relatório" do comentário de merge; sem ele, o campo diz "não registrado", nunca um link escrito à mão. **Não precisa de release** (skill entra com `git pull`).
