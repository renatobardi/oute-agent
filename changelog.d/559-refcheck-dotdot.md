### Fixed
- **`oute-refcheck` recusa `..` no dono e no repo do link de comentário** (#559). O link `https://github.com/../r/issues/N#issuecomment-ID` deixa de entrar no caminho do `gh api`. **Precisa de release** (o `docker/oute-refcheck` vai na imagem).
