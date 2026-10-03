### Added
- `tests/compose-config.test.sh`: gate de validação do `docker compose config` (#265), com testes de resolução sem profile e com `--profile agent-studio`, caso negativo e pulo seguro fora do CI. Função `compose_config` em `tests/lib/compose-config.sh`, reutilizada pelo `tests/agent-studio-auth.test.sh`.
