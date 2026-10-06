### Changed
- **ADR-02 e ADR-01: adendo do provedor Z.ai (GLM) e cadeia por grupo de fase** (#629, gate de `arch` do Bardi).
  - **ADR-02:** o GLM Coding Plan entra como **provedor** do próprio Claude Code (`oute.agent` segue `claude`; `oute.provider` novo). Pareamento Opus/Sonnet/Haiku ↔ `glm-5.3`/`glm-5.3`/`glm-5.3-flash` ↔ astra/sol/luna. Dois grupos de fase com cadeia própria: raciocínio `anthropic` → `zai` → `openai`, execução `zai` → `anthropic` → `openai`. Gatilhos `indisponivel` e `cota` por provedor; o revisor das etapas cobre os autores GLM. Entra em três fatias, e a (c), que muda o padrão da tabela, só depois da medição.
  - **ADR-01:** segredo novo `OUTE_ZAI_API_KEY` (pasta `oute-agent`, opcional, só no ambiente da sessão `zai`); todos os repos podem mandar código à Z.ai.
  - O `CONTEXT.md` ganha o resumo e os termos provedor, cadeia e grupo de fase.
  - Só documentação: **não precisa de release**.
