### Added
- **Como a sessão abriu na página de sessão** (#825). A página da sessão no agent-studio lê o `oute.task.abertura` do evento de abertura e mostra um Badge no cabeçalho (`aba`, `terminal` ou `sem-tela`) e a linha "Como abriu" no resumo. O atributo entra no catálogo de eventos do ADR-04. **Precisa de release** (o agent-studio vai na imagem).

### Changed
- **Sessão sem issue no resumo de fechamento** (#825). O prompt de fechamento do dispatcher diz que sessão aberta sem número de issue (`oute-swarm spawn <slug>`) entra no resumo como `sem issue` → PR → estado, e `tell`/`watch` ganham casos de teste próprios com sessão sem issue.
