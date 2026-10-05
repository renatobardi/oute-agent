### Added
- **Controle "custo de lista | custo efetivo" no agent-studio** (#531). Dashboard, Uso, Conversas e Sessões ganham o controle; o padrão é o custo de lista. No custo efetivo, a chamada de assinatura (`oute.agent` = `claude` ou `codex`) conta US$ 0 e só aparece o que é pago por uso. A escolha fica na URL (`custo=efetivo`) e os links entre telas a levam. `GET /v1/usage` e `GET /v1/tray` seguem iguais. **Precisa de release** (o agent-studio vai na imagem).

### Changed
- **Rótulos de custo do agent-studio** (#531). "Real" deixa de nomear o custo informado pela fonte (que para o Claude é preço de lista): a tela diz "informado pela fonte", "estimado" e, no novo modo, "efetivo". **Precisa de release.**
