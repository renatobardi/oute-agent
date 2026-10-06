### Changed
- **agent-studio: o controle de custo passa a se chamar "custo pago"** (#591). O controle das telas Dashboard, Uso, Conversas e Sessões é "custo de lista | custo pago", e a URL leva `custo=pago`. "Custo efetivo" fica só com o sentido do custo do span ou do log `api_request` (ADR-08 e `CONTEXT.md`). O valor antigo do controle na URL não é mais lido: link salvo com ele abre no custo de lista. A conta não muda. **Precisa de release** (templates e código do agent-studio vão na imagem).

### Fixed
- **agent-studio: gráfico pedido depois de 120 s carrega sem pedir que a tela seja reaberta** (#591). Cada bloco servido renova o prazo da abertura. Bloco pedido depois do prazo abre a abertura de novo, com a janela de agora; a resposta 410 "Este carregamento expirou. Reabra a tela" saiu. **Precisa de release.**
