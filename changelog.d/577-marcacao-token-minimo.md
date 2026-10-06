### Security
- **Credencial de marcação com tamanho mínimo** (#577). O `AGENT_STUDIO_MARK_TOKEN` com menos de 32 caracteres é descartado, com aviso no stderr, e a rota `POST /rodada/acao` e a entrada `/marcar` não existem (como já era para valor igual a outra credencial). **Precisa de release** (`docker/agent-studio` vai na imagem).
