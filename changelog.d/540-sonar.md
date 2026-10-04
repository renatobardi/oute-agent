### Changed

- **Fluxo de PR do worker do swarm:** antes de abrir ou atualizar PR, o worker confere o próprio diff contra a lista do SonarCloud do `AGENTS.md` (função de shell nova, `http://` literal, regex com backtracking, `[x]` aninhado) e corrige o que encontrar em vez de esperar o gate reprovado (#540).
