### Changed
- **ADR-02 e ADR-01: a `zai` (GLM) vira a padrão da execução numa entrega só** (#629, decisão do Bardi depois do spike).
  - **ADR-02:** saem as três fatias; as cadeias (execução `zai` → `claude` → `codex`, raciocínio `claude` → `zai` → `codex`) viram o padrão da tabela na entrega da assinatura `zai`. A medição GLM × Sonnet deixa de ser condição; a regressão de agentes na `zai` continua. O plano fica no Lite, e o Pro deixa de ser critério de `ship`.
  - **ADR-02 e ADR-01:** a sessão `zai` não lê imagem. No spike, a Z.ai subiu a imagem lida a um CDN de terceiro e o modelo não a viu.
  - O `CONTEXT.md` acompanha.
  - Só documentação: **não precisa de release**.
