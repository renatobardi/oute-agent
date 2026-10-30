### Fixed
- **`oute-swarm watch` registra o PR e o CI de um branch da sessão que não leva o número da issue dela** (kaizen swarm-1029-2126, lição 1). A passada lê o branch atual da worktree de cada sessão aberta e inclui o PR dele, na issue da sessão; antes o PR #154 do hanko (`fix/153-…`, sessão `125-…`) nunca entrava. **Precisa de release** (`docker/oute-swarm` vai na imagem).
- **`oute-refcheck` confere `arquivo:linha` de arquivo que um PR citado cria ou amplia no head do PR** (lição 2). Antes dava `arquivo tem 116 linhas` ou `arquivo não existe` para o que só existe no PR. **Precisa de release** (`docker/oute-refcheck` vai na imagem).

### Changed
- **Prompts do swarm** (lições 3 e 4). O `PRONTO` do worker só vale com o gate do SonarCloud OK no head (`oute-sonar pr <n> --json`); o `tell` do dispatcher tem até 700 caracteres contando o prefixo, com o detalhe em comentário do PR. **Precisa de release** (`docker/swarm-worker.md` e `docker/swarm/acompanhamento.md` vão na imagem).
