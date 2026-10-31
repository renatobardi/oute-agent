### Fixed
- **`oute-refcheck` confere `arquivo:linha` de arquivo que um PR citado cria ou amplia no head do PR** (lição 2). Antes dava `arquivo tem 116 linhas` ou `arquivo não existe` para o que só existe no PR. **Precisa de release** (`docker/oute-refcheck` vai na imagem).

### Changed
- **Prompts do swarm** (lições 3 e 4). O `PRONTO` do worker só vale com o gate do SonarCloud OK no head (`oute-sonar pr <n> --json`); o `tell` do dispatcher tem até 700 caracteres contando o prefixo, com o detalhe em comentário do PR. **Precisa de release** (`docker/swarm-worker.md` e `docker/swarm/acompanhamento.md` vão na imagem).

A lição 1 (o `watch` não ver o PR de um branch da sessão sem o número da issue) foi entregue pelo #876 e saiu deste PR.
