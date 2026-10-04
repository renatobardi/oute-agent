Parte 4/4 do épico #465 (agent-studio no Kubo Design System). Depende do PR 3.

## Intenção
Criar a rota `/` **Dashboard** com KPIs, insights por regra e 6 gráficos monocromáticos, e alinhar o tray do Mac (SF Symbols mono, âmbar só no Gate).

## Contexto
- Rota nova em `web.py` (hoje `/` redireciona para `/conversas`); template `dashboard.html`; consultas em `usage.py`/`cost.py` (já somam por janela) + agregações novas por hora/dia, por modelo (percentis), por fase e por dia×hora no DuckDB; Gates/pedidos pendentes do SurrealDB.
- Janela: 24 h | 7 d (query `hours`), sempre comparada com a janela anterior de mesmo tamanho.
- **KPIs**: chamadas ao modelo; custo de lista (real + ≈ estimado, % estimado); p95; taxa de erro (spans erro / chamadas); % de tokens de entrada em cache. Cada um com Badge de variação.
- **Insights** (regras fixas, sem LLM, cada um com link): p95 de um modelo piorou > 25% vs janela anterior → sessão responsável; Gate pendente > 10 min → pedidos; modelo com < 10% das chamadas e > 35% do custo → uso; cobertura de cache + custo sem cache → uso; ≥ 2 erros com mesma ferramenta/host → conversa; chamadas sem preço → preços.
- **Gráficos** (SVG inline gerado no Jinja; sem JS de gráfico; uma série por gráfico; tooltip por hover em CSS/`<title>`): 1) chamadas por hora/dia (linha + área); 2) custo por modelo (barras, real × estimado empilhado); 3) latência por modelo p50/p90/p95/p99 (tabela, mini-barra no p95); 4) tokens por fase AI-DLC (barras); 5) atividade dia × hora (heatmap 7×24, 5 degraus de `--primary`); 6) sessões que mais custaram (top 5, link).
- Mobile: KPIs 2×2 (+1), tudo em coluna única; heatmap com rolagem horizontal.
- Tray (`tray/Sources/OuteTray`): ícones SF Symbols monocromáticos; cor âmbar só no item de Gate/pedido pendente; nada vermelho sólido.
- Referência: artboard `Tela · Dashboard` no canvas v1.0 e doc do Langfuse (traces over time, model cost, latency percentiles, user consumption).

## Critérios de aceite
- [ ] `/` responde o Dashboard para quem entrou; `/conversas` continua.
- [ ] KPIs, insights e os 6 gráficos conforme o protótipo, 24 h e 7 d; números batem com `/uso` na mesma janela.
- [ ] Nenhuma chamada a LLM ou à internet; nenhum JS além do htmx.
- [ ] Gráficos legíveis em light e dark; nenhum depende de cor para distinguir séries.
- [ ] Teste de tela novo (`tests/agent-studio-dashboard.test.sh`) cobrindo `data-*` dos KPIs, insights e totais.
- [ ] Tray com símbolos mono e âmbar só no Gate; `tests/agent-studio-tray.test.sh` verde.
- [ ] Screenshots desktop + mobile no PR.
- [ ] (ship) Em `agent-studio.oute.pro`, o Dashboard carrega em < 2 s com a janela de 7 d.

## Fora de escopo
- Dashboards customizáveis; múltiplas séries coloridas; alertas configuráveis.

## Fase / gate
`aidlc:build`. Gate: screenshots aprovados pelo Bardi; o critério `(ship)` vai no `## Falta` do PR.
