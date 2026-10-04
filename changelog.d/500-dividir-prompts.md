### Changed

- **Testes:** dividir `tests/oute-swarm-prompts.test.sh` por arquivo de prompt em três arquivos tema-específicos (`tests/oute-swarm-prompts-dispatcher.test.sh` para swarm.md, `-worker.test.sh` para swarm-worker.md, `-notas.test.sh` para agent-notes.md) para reduzir conflitos de merge quando múltiplos PRs acrescentam casos de temas diferentes (#500). Criar apoio comum em `tests/lib/oute-swarm-prompts.sh` para caminhos de arquivos compartilhados. Atualizar mapa de testes do `AGENTS.md` com a nova estrutura.
