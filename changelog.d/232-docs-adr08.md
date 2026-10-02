### Changed
- **README, `AGENTS.md`, `CONTEXT.md` e `oute-aidlc-qa-pr-audit` alinhados ao ADR-08** (#232). A telemetria passa a ser descrita como bucket + agent-studio, com o Langfuse em paralelo até ser desligado (#160).
  - README: descrição, lista de ADRs até o 0008, serviços `agent-studio`, `surrealdb` e `volume-init` na tabela, `config/otel/agent-studio.yaml` e `config/agent-studio/` no layout, e a seção de observabilidade com o agent-studio.
  - `AGENTS.md` e `oute-aidlc-qa-pr-audit`: o gate do collector valida também `config/otel/agent-studio.yaml`; ferramenta nova só entra se mandar consumo ao bucket + agent-studio (ADR-08 §11).

### Fixed
- **Eventos operacionais descritos como "só ao bucket"** (#232). Com o pipeline `logs/studio` (#189) eles vão também ao agent-studio: texto corrigido no `oute help` (`docker/comandos.md`), no cabeçalho do `oute-emit`, no comentário do `Dockerfile`, no `AGENTS.md` e no `CONTEXT.md`. Nenhum comportamento muda. **Precisa de release** para o texto chegar aos hosts (o `oute-emit` e o `comandos.md` vão na imagem).
