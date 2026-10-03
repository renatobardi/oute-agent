### Changed
- **`oute-aidlc-ops-observe` e `oute-aidlc-learn-insights` leem do agent-studio, não mais do Langfuse** (#259, ADR-08 §9).
  - `observe.sh studio` (no lugar de `langfuse`) lê `GET /v1/usage` (janela e base) e `GET /v1/alerts` com a credencial de leitura (`AGENT_STUDIO_READ_TOKEN`, pelo stdin do `curl`, fora do argv). Nenhuma chamada ao Langfuse nem exigência de `LANGFUSE_*`.
  - Tabela host × agente com chamadas, spans, erros de span e de log, custo real e estimado em colunas separadas, chamadas sem preço, tokens, p95 e base por dia; custo por modelo; anomalias `erro-alto` (spans com erro sobre os spans), `custo-alto`, `sem-telemetria` e a nova `sem-preço`; alertas do pipeline (`ALERTA`) e último dado por host.
  - A seção do bucket não muda; `all` = `studio` + `bucket`. Fonte ilegível (variável ausente, HTTP ≠ 200, agent-studio fora do ar) = linha `ERRO` e código ≠ 0.
  - `AGENT_STUDIO_URL` no ambiente do `agent` (compose): rede docker no oute-server, vhost da tailnet no Mac. No Mac, o `oute up` passa o vhost mesmo sem a credencial de ingestão (a leitura não depende dela).
  - `collect.sh` sem a lacuna dos 30 dias do Langfuse.
  - Sem release: skills, `docker/compose.yaml` e `scripts/oute` entram com `git pull` + `oute down/up`.
