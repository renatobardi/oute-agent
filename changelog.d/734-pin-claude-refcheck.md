### Changed
- **Reserva do claude na imagem sobe de 2.1.285 para 2.1.296** (#734). A versão anterior não reconhecia o id `claude-haiku-5-5`, reserva da execução na tabela do seletor; `scripts/agent-pins` confere a versão e os sha256. **Precisa de release** (o `docker/Dockerfile` vai na imagem).

### Fixed
- **`tests/oute-refcheck.test.sh` deixa de falhar por acaso** (#734). O prefixo de 10 caracteres do hash do commit de teste podia sair só com dígitos (~1,8% por execução) e virava número puro, que o `oute-refcheck` não confere como SHA; o teste agora escolhe um prefixo com letra e dígito.
