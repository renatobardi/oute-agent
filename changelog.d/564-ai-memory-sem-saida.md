### Security
- **O `ai-memory` fica sem saída à internet, por construção** (#564, decisão do Bardi de 2026-10-05). No `docker/compose.yaml`, o `ai-memory` sai da rede `oute` e passa a só entrar em redes `internal`: `memoria` (com o `agent`) e `llm` (com o `llm-proxy` e o collector). O `llm-proxy` ganha a rede `saida`, a única com rota ao OpenRouter. O ADR-08 registra a regra e o levantamento do que o `ai-memory` 2.5.2 acessa fora do compose (o download único do modelo local de embeddings). Entra com `git pull` + `oute down/up`. **Precisa de release** só pelo `docker/oute-llm-proxy` (novo `LLM_PROXY_UPSTREAM_TIMEOUT`, padrão 300 s, igual ao de antes).

### Fixed
- **`sig` do `tests/oute-up.test.sh` sem prazo fixo** (#564). O teste esperava até 10 s o vault falso parar e mandava o sinal mesmo sem ele; agora espera até o vault falso avisar, ou o `oute` morrer. Também ganha os casos 413 e timeout do upstream em `tests/oute-llm-proxy.test.sh`.
