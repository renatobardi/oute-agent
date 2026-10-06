### Fixed
- **Notas dos agentes: regras de checkout principal, escopo de memória e segredo mais explícitas** (#666). `docker/agent-notes.md` manda conferir `git rev-parse --git-dir --git-common-dir` antes de criar ou fazer commit, ler o `.ai-memory.toml` antes de chamar a memória e não ler o valor de segredo. **Precisa de release** (`agent-notes.md` vai na imagem).
