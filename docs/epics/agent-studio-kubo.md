## Intenção

Restilizar a tela do **agent-studio** (`docker/agent-studio`, Jinja + HTMX + um `studio.css`) com o **Kubo Design System** e acrescentar um **Dashboard** com gráficos e insights, sem mudar rotas, dados, `data-*` nem a CSP restrita.

Para quem: o Bardi, único usuário, no Mac (desktop) e no celular (tailnet).

Como saber que deu certo: todas as telas abertas em `agent-studio.oute.pro` batem com o protótipo v1.0 (desktop e mobile), `tests/agent-studio-web.test.sh` continua verde, e o Dashboard responde com os números da janela.

**Protótipo v1.0 (canvas Design, navegável no Play):** https://claude.ai/code/artifact/3ff35e10-cb3c-4e7d-8c9a-57127fcd7e74
Página "v1.0 · Protótipo navegável": `App` (desktop) e `App mobile` com Play; abaixo, cada tela solta. Página "v0": rascunhos.

**Design system:** Kubo — https://claude.ai/code/artifact/14acc4c0-cf6a-4d6b-9048-d6e17448416b

## Contexto

Hoje (`agent_studio/static/studio.css`, 86 linhas): `system-ui` 14px, 10 variáveis hex, azul em link, verde em custo real, âmbar em custo estimado, barra de links no topo, tabelas com borda em tudo, raio 4px, sem ícones, dark só por `prefers-color-scheme`.

Restrições que valem (ADR-08 e `web.py`):
- **CSP** `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'` → nada de `style=` inline nos templates; todo o visual continua no `studio.css`. Precisa ganhar `font-src 'self'` para a Inter.
- **Sem CDN**: Inter Variable servida de `/static`; Lucide como sprite SVG em `/static` + macro Jinja `icon(nome)` que emite `<svg><use>`.
- **Dark mode sem JS**: o bloco `.dark` do Kubo entra dentro de `@media (prefers-color-scheme: dark)`; o toggle manual do protótipo é opcional (cookie + classe no `<html>`).
- **Testes** (`tests/agent-studio-web.test.sh`, `tests/lib/html-data.py`) leem `data-*` e ids (`#conteudo`, `#alertas`, `#decisoes`, `#total`, `#vazio`…): a troca mexe só em classes e wrappers.
- **Só leitura**: aprovar continua no host com `oute approve`. Botões "copiar" são o máximo de ação na tela.
- **HTMX**: `hx-select="#conteudo"` nos filtros e `hx-target` nos spans continuam; o shell (sidebar + header + faixas) fica fora de `#conteudo`.

### Tokens: `studio.css` → Kubo

| Hoje | Kubo | Nota |
|---|---|---|
| `--fundo` | `--background` | sidebar usa `--sidebar` |
| `--painel` | `--card` + ring `foreground/10` | card sem borda nem sombra |
| `--texto` | `--foreground` | texto e links |
| `--fraco` | `--muted-foreground` | meta, `th`, notas |
| `--linha` | `--border` | só entre linhas de tabela |
| `--link` (azul) | `--foreground` + sublinhado no hover | link azul sai |
| `--erro` | `--destructive` | texto de erro e Badge destructive |
| `--erro-fundo` | `destructive / 10%` (dark 20%) | sempre tingido, nunca sólido |
| `--real` (verde) | `--foreground` | custo real é o valor de verdade, sem cor |
| `--est` (âmbar) | `--muted-foreground` + itálico + `≈` | âmbar fica exclusivo do Gate |
| — | `--gate` / `--gate-tint` (novo) | âmbar do Kubo para decisão pendente e pedido pendente |

Inter everywhere, 14px; h1 20px/600/tracking-tight; card title 16px/500; meta 12px. Raios: pill 20.8px (botões, inputs, badges), card 14.4px, textarea/código 12px.

### Componentes: classe atual → padrão Kubo (em CSS puro)

| Hoje | Kubo | Como |
|---|---|---|
| `header.topo` + `nav` | Sidebar 256px + header 72px | grupos Telemetria / Análise / Governança; breadcrumb no header; Sair e tema no header |
| `button` | Button pill | h-36, px-12, 14px/500; hover 80%; press translateY(1px); default / outline / ghost |
| `select`, `input` | Input / Select pill | `bg input/30`, borda 1px, foco ring 3px `ring/50` |
| `table` | Card + tabela densa | `th` 12px/500 muted; hover `bg-muted/50`; números tabulares à direita |
| `.etiqueta` `.orfao` `.sub` | Badge | estado → default; avulsa/rodada/issue → outline; pai ausente → outline |
| `tr.erro` (borda interna) | Badge destructive na coluna Erros | linha não ganha borda colorida |
| `.aviso` / `.aviso.erro` | Callout com ícone | muted + `info`; erro tingido + `triangle-alert` |
| `.alertas` | Faixa destrutiva tingida sob o header | ícone `siren`, só em Dashboard e listas |
| `.decisoes` | Faixa Gate (âmbar) | ícone `hand`, link "Ver pedidos" |
| `.resumo` (`dl`) | StatTile ×4 + `dl` em card | chamadas, tokens, custo, duração viram tiles |
| `pre.script` | Bloco de código | bg-muted, raio 12px, mono 12px, cabeçalho com sha256 + Copiar |
| `.d1 … .d12` | Árvore de spans | recuo 16px/nível, ícone por tipo (`sparkles`, `wrench`, `terminal`), linha abre o conteúdo |

### Dashboard (rota nova `/`, substitui o redirect para `/conversas`)

Inspirado nos dashboards do Langfuse (traces/observations over time, model usage & cost, latency percentiles table, user consumption → aqui "sessões que mais custaram"), adaptado ao que o agent-studio tem a mais: rodadas, Gates, fases AI-DLC e real × estimado.

- **KPIs** (janela 24 h | 7 d, com variação contra a janela anterior): chamadas ao modelo, custo de lista (real + ≈ estimado, % estimado), p95, taxa de erro, % de tokens de entrada em cache.
- **Insights**: regras fixas sobre a janela (sem LLM), cada uma com link para a tela de origem: p95 de um modelo piorou > 25%; Gate pendente há > 10 min; modelo com < 10% das chamadas e > 35% do custo; cobertura de cache e quanto custaria sem ela; erros concentrados num host/ferramenta; chamadas sem preço.
- **Gráficos** (monocromáticos, uma série por gráfico, hover com tooltip):
  1. Chamadas ao modelo por hora/dia (linha + área).
  2. Custo por modelo (barras horizontais, real × estimado em barra empilhada).
  3. Latência por modelo: tabela p50 / p90 / p95 / p99 com mini-barra no p95.
  4. Tokens por fase AI-DLC (barras).
  5. Mapa de atividade dia × hora (heatmap 7×24, 5 degraus de `--primary`).
  6. Sessões que mais custaram (top 5, link para a sessão).
- Dados: tudo sai do DuckDB (`spans` por hora do fato) e do SurrealDB (Gates/pedidos). Nenhuma chamada externa.

### Telas (todas no protótipo, desktop e mobile)

Entrar · Dashboard · Conversas · Conversa · Sessões · Sessão · Uso · Preços · Pedidos · Pedido.
Novas em relação ao código atual: Dashboard e a tela **Sessão** com linha do tempo de eventos (`oute.swarm.session.spawned`, `oute.task.opened`, `oute.canal.proposed`, `oute.swarm.round.asked`).

Mobile (≤ 640px): sidebar vira menu em sheet; header 56px com voltar nos detalhes; tabelas viram cartões; faixas compactas; alvos ≥ 44px.

## Plano (4 PRs, cada um fecha uma sub-issue)

1. **Tokens, fonte e CSP** — `studio.css` recebe os tokens Kubo (light + dark via media query), Inter Variable em `/static/fonts`, `font-src 'self'` em `web.py`. Nenhum template muda. Teste: `tests/agent-studio-web.test.sh` verde + screenshot antes/depois.
2. **Shell** — `base.html`: sidebar + header com breadcrumb + faixas de alerta/Gate fora de `#conteudo`; sprite Lucide + macro `icon()`; toggle de tema opcional. Login refeito (2 colunas no desktop).
3. **Macros de tabela e badges** — `_macros.html`: `session_table`, `conversation_row`, `session_row`, `session_tags`, `cost`, `state_warning`, `log_table`, `span_detail` com as receitas Kubo; páginas Conversas, Sessões, Uso, Preços, Pedidos, Pedido, Conversa. Tela Sessão com eventos.
4. **Dashboard** — rota `/`, consultas agregadas no DuckDB (`usage.py`/`cost.py` já têm as somas por janela), regras de insight, 6 gráficos em SVG inline gerado no Jinja (sem JS de gráfico), versão mobile. Tray (SwiftUI): SF Symbols mono e âmbar só no Gate.

## Critérios de aceite

- [ ] `studio.css` usa só tokens Kubo (OKLCH); nenhum hex antigo sobra; light e dark passam contraste 4.5:1 em texto.
- [ ] CSP continua `default-src 'none'`, só ganha `font-src 'self'`; nenhum `style=` inline nos templates; nenhum recurso de CDN.
- [ ] Inter Variable servida de `/static`, com `local('Inter')` de fallback.
- [ ] Sidebar + header + faixas fora de `#conteudo`; filtros e spans via HTMX funcionam como hoje.
- [ ] Todos os `data-*` e ids lidos por `tests/agent-studio-web.test.sh` e `tests/lib/html-data.py` continuam; suite verde.
- [ ] Custo real sem cor; estimado em muted itálico com `≈`; âmbar aparece só em Gate/pedido pendente; destrutivo sempre tingido.
- [ ] Telas Entrar, Conversas, Conversa, Sessões, Sessão, Uso, Preços, Pedidos, Pedido equivalentes ao protótipo v1.0 (desktop ≥ 1280 e mobile 390).
- [ ] Dashboard em `/` com os 5 KPIs, insights com link, os 6 gráficos e troca 24 h / 7 d; números batem com Uso na mesma janela.
- [ ] Nenhuma chamada a LLM ou à internet na tela; insights são regras.
- [ ] Screenshot desktop + mobile de cada tela anexado no PR.
- [ ] (ship) Em `agent-studio.oute.pro`, no Mac e no celular pela tailnet, todas as telas carregam com a Inter e o dark segue o sistema.

## Fora de escopo

- Aprovar ou recusar pedidos pela tela (continua `oute approve` no host, ADR-01).
- Paginação real nos botões "Mais …" além do que o HTMX já faz hoje.
- Dispensar alertas/Gates pela tela (somem quando a condição resolve).
- Gráficos com múltiplas séries coloridas (a paleta Kubo é monocromática e não passa no validador de distinção de cores).
- Tray além de ícones e cor do Gate.

## Fase / gate

Fase `design` (protótipo v1.0 aprovado pelo Bardi em 2026-10-04). Próximo gate: `plan` — abrir as 4 sub-issues com `aidlc:build` e ligar a esta.
