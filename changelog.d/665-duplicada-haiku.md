### Fixed
- **Nota global manda procurar issue aberta antes de criar issue** (#665). A regra de `gh issue list` antes do `gh issue create` virou item próprio, em imperativo, em `docker/agent-notes.md`: o Haiku a pulava quando ela vinha no fim de um item longo (`duplicada@haiku` falhava 2 de 3). **Precisa de release** (`agent-notes.md` entra na imagem).
