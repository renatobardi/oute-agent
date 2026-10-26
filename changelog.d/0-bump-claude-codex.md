### Changed
- **Versões fixas da reserva sobem para claude 2.1.310 e codex 0.164.0.** Os `ARG`s do `docker/Dockerfile` (versão e sha256) vêm de `scripts/agent-pins --print`; antes eram claude 2.1.296 e codex 0.159.2. **Precisa de release** (o `docker/Dockerfile` define a imagem).
- **Dockerfile: `WORKDIR` no lugar de `cd` e um só `RUN` nos `chmod`.** Corrige as duas issues do SonarCloud no trecho que o bump toca (`docker:S6597`, `docker:S7031`); a imagem fica igual.
