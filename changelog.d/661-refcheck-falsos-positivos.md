### Fixed
- **`oute-refcheck` não marca mais como quebrada a referência que existe** (#661). `arquivo:linha` sem pasta (ex.: `rotas.py:66`) é procurado também entre os arquivos do diff dos PRs citados no texto, e hash precedido de `sha256` (hash de arquivo) não é conferido como commit. Commit e issue inexistentes continuam `quebrada`. **Precisa de release** (`docker/oute-refcheck` vai na imagem).
