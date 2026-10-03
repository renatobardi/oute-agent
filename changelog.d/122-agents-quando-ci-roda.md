### Added
- **`AGENTS.md` diz quando cada workflow de CI roda** (#122). O `pr` só em `pull_request`; o `image` só em tag `v*` (e manual). Push na `main` não roda workflow nenhum, e o estado de CI de uma mudança se confere no PR (`gh pr checks <n>`). Sem release (só documentação).
