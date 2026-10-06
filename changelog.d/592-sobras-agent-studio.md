### Fixed
- **agent-studio: a data da troca de preço não desloca mais 1 h em fuso com horário de verão** (#592). O `_parse_iso` de `prices.py` lia a data em UTC como hora local e descontava o fuso sem o horário de verão; agora usa `calendar.timegm`, e o fuso do processo não muda o valor. Afeta o gráfico de preço e a contagem de "subiram e caíram nos últimos 30 dias" da tela Preços. **Precisa de release** (o `agent_studio/prices.py` vai na imagem).

### Removed
- **agent-studio: CSS `.metades` sem uso** (#592). Nenhum template nem módulo usava a classe; as três regras saíram de `static/studio.css`. Nenhuma tela muda. **Precisa de release** (o `studio.css` vai na imagem).

### Changed
- **ADR-08 descreve a paginação das listas** (#592). Seção nova "Tela: tabelas com ordem, filtro e página (#529)"; os itens de Conversas, Sessões e Pedidos deixam de citar os tetos de 200 e de 50 linhas, que a tela não usa desde o #583. Só documentação.
- **Testes das dicas do agent-studio** (#592). A dica de custo do Dashboard (preço de lista e custo efetivo) e as dicas de Papel e de Fase da tela Uso passam a ter teste. Só testes.
