### Changed
- **Regra de `check-lib` em `docker/swarm-worker.md`** (#401): quando o PR altera `tests/*.test.sh` ou `tests/lib/`, o worker roda também `bash tests/check-lib.test.sh` (no ambiente da sessão e no limpo) antes de abrir o PR, confere o lint do `check` (#285), e diz no corpo do PR que rodou. Falha no `check-lib` é falha do PR. **Precisa de release** (`swarm-worker.md` entra na imagem).
