Parte 3/4 do épico #465 (agent-studio no Kubo Design System). Depende do PR 2.

## Intenção
Aplicar as receitas Kubo nas macros de tabela, custo e badges, e em todas as páginas de lista e detalhe. Criar a tela **Sessão** com linha do tempo de eventos.

## Contexto
- `templates/_macros.html`: `cost`, `log_rows`, `log_table`, `span_detail`, `filter`, `usage_cells`, `model_list`, `session_table`, `conversation_row`, `session_tags`, `session_row`, `state_warning`.
- Páginas: `conversations.html`, `conversation.html`, `sessions.html`, `session.html`, `usage.html`, `prices.html`, `proposals.html`, `proposal.html`, `span.html`, `span_detail.html`, `log_rows.html`.
- Receitas (épico #465, tabela "Componentes"): tabela dentro de card com ring; `th` 12px/500 muted; linhas hover `bg-muted/50`; `.etiqueta`/`.orfao`/`.sub` → Badge (estado default, avulsa/rodada/issue outline, pai ausente outline); `tr.erro` → Badge destructive na coluna Erros, sem borda na linha; `.resumo` → 4 StatTiles (chamadas, tokens, custo, duração) + `dl` em card; `pre.script` → bloco mono com cabeçalho sha256 + Copiar; árvore de spans com recuo 16px/nível e ícone por tipo (`sparkles` llm_request, `wrench` tool, `terminal` execução, `workflow` interaction).
- Colunas: Entrada/Saída viram "Tokens ent / saí" numa célula, cache em segunda linha menor; custo real sem cor, estimado muted itálico com `≈`.
- Sessão (`session.html`): Badges (estado, rodada · worker, issue, fase `aidlc:*`), tiles, lista de conversas, **linha do tempo** dos eventos `oute.swarm.session.spawned`, `oute.task.opened`, `oute.canal.proposed`, `oute.swarm.round.asked` etc. (ponto âmbar nos eventos de Gate), resumo em `dl`.
- Preços: cards de fontes (models.dev, OpenRouter) com Badge ok/falhou no topo; tabela de vigentes com linha expansível mostrando o histórico (mini-barra do preço de entrada); modelo sem preço com Badge destructive.
- Pedidos: duas colunas (Pendentes com chip âmbar "há N min" + Badge root/user; Decididos com Badge aprovado/recusado e `rc` ≠ 0 em destrutivo). Pedido: script em bloco mono + card "Decidir no host" com `oute approve <id>` e Copiar.
- Mobile: tabelas viram cartões (Sessões) ou linhas de 2 níveis (Conversas, Logs); alvos ≥ 44px.
- Referência: artboards `Tela · *` no canvas v1.0.

## Critérios de aceite
- [ ] Todas as páginas acima equivalentes ao protótipo em desktop e mobile.
- [ ] `data-*`, ids e `hx-*` inalterados; `tests/agent-studio-web.test.sh` e `tests/lib/html-data.py` verdes.
- [ ] `session.html` mostra a linha do tempo com os eventos da sessão pela hora do fato.
- [ ] Botões Copiar funcionam (clipboard) e mostram confirmação; nenhuma ação além de copiar.
- [ ] Screenshots desktop + mobile de cada página no PR.

## Fora de escopo
- Dashboard (PR 4). Paginação além do HTMX atual. Dispensar alertas.

## Fase / gate
`aidlc:build`. Gate: screenshots aprovados pelo Bardi.
