### Added
- **Teste de fumaça da imagem** (#430). `tests/image-smoke.sh <imagem>` sobe a imagem com segredos fictícios e confere o uid 10001, que `/run/secrets` só tem `agent_env` e que o sshd responde na porta 2222; sai com 1 e diz qual conferência falhou. Roda à mão contra imagem local; o passo no workflow `image` (antes do push) entra pelo Bardi. Não precisa de release.
