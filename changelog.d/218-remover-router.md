### Removed
- **jev-router, LiteLLM e OpenRouter fora do stack** (#218, ADR-02). **Precisa de release** (o `entrypoint.sh` e o `Dockerfile` vão na imagem: saem o export de `OPENROUTER_*`/`LITELLM_*` para os logins ssh e a env `OUTE_ROUTER_URL`).
  - Saem o serviço `jev-router` do compose, `config/litellm/`, `scripts/router_sync.py`, os comandos `oute router-sync` e `oute schedule`, e `OUTE_LITELLM_IMAGE`/`OUTE_AB_*` do `.env.example`.
  - O `oute up` não exige mais `OPENROUTER_API_KEY` no `agent.env`; a nota `openrouter` (pasta `oute-agent`) e a `openrouter-mgmt` (pasta `oute-admin`) do vault deixam de ser lidas. **Só revogue a key e tire as notas depois do deploy nos dois hosts**: o `oute up` da versão anterior morre sem a key.
  - O `oute up` e o `oute down` tiram os restos do host, de forma idempotente (host sem eles não muda): a entrada diária do `router-sync` no crontab e o container `oute-jev-router`, que ficaria órfão e preso à rede `oute`.
  - Collector: não marca mais `oute.agent=router` nem filtra os spans do LiteLLM no pipeline do Langfuse. A telemetria antiga fica como está no bucket e no Langfuse (nada é apagado).

### Changed
- **Histórico do roteador continua legível** (#218). O agent-studio segue somando no `/v1/usage` o custo gravado do `jev.decision` (histórico até 2026-09-30). A `oute-aidlc-ops-observe` deixa de consultar os agentes `router` e `unknown` (não acusa "sem telemetria") e perde a anomalia `agente-unknown`.
- **`oute-aidlc-ship-verify`** (#218): o `verify-host.sh` não exige mais o `oute-jev-router` e passa a conferir `oute-agent-studio` e `oute-surrealdb` no host com o profile `agent-studio` ligado (`OUTE_AGENT_STUDIO=1` no ambiente ou no `.env` do checkout).
- **Regra de plugin herdr** (#218, ADR-02 e `CONTEXT.md`): plugin herdr não chama API de LLM; quem fala com modelo é o agente da sessão. A única chamada fora das assinaturas é o Jev na TypeSafe, feita pelo seletor.
