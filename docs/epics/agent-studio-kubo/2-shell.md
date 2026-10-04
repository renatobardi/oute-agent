Parte 2/4 do épico #465 (agent-studio no Kubo Design System). Depende do PR 1.

## Intenção
Trocar o `header.topo` por sidebar 256px + header 72px com breadcrumb, mover alertas e Gate para faixas sob o header, trazer ícones Lucide sem CDN e refazer a tela Entrar.

## Contexto
- `templates/base.html`: `header.topo`, `section.alertas`, `section.decisoes`, `main#conteudo`. Tudo isso fica **fora** de `#conteudo` (o HTMX troca só o `main`).
- `templates/login.html`.
- Ícones: sprite SVG Lucide em `/static/lucide.svg` (só os glifos usados: layout-dashboard, message-square, layers, chart-column, receipt, shield-check, siren, hand, panel-left, log-out, moon, sun, chevron-*, info, triangle-alert, copy, check, x, server, terminal, sparkles, wrench, workflow, corner-down-right, circle-dot, repeat, archive, loader, user, shield-alert, lock, eye, eye-off, arrow-left, arrow-right) + macro Jinja `icon(name, size=16)` em `_macros.html` que emite `<svg><use href="/static/lucide.svg#name">`.
- Sidebar: grupos **Telemetria** (Conversas, Sessões) · **Análise** (Uso, Preços) · **Governança** (Pedidos); Dashboard acima dos grupos (rota entra no PR 4; até lá o item pode apontar para `/conversas`). Rodapé: Renato Bardi + Sair.
- Header: botão recolher (`panel-left`), divisor 1×16, breadcrumb (`Telemetria › Sessões`; nos detalhes `Sessões › <id>`), à direita Badge do host, toggle de tema (opcional: cookie + classe `.dark` no `<html>`), Sair.
- Faixas: `.alertas` tingida `destructive/10` com `siren`; `.decisoes` em `--gate-tint` com `hand` e link "Ver pedidos". Mostradas em Dashboard e listas; escondidas nos detalhes (conversa, sessão, pedido).
- Mobile (≤ 640px): sidebar vira sheet aberta pelo `menu`; header 56px; nos detalhes, botão voltar no lugar do menu.
- Entrar: duas colunas no desktop (painel `--primary` com logo, frase e 3 pontos; formulário à direita com label, dica do vault, campo com mostrar/esconder e botão lg); coluna única no mobile. Erro em callout tingido com `triangle-alert`.
- Referência: artboards `App`, `App mobile` e `Tela · Login` no canvas v1.0.

## Critérios de aceite
- [ ] Sidebar, header, faixas e login iguais ao protótipo (desktop ≥ 1280 e mobile 390).
- [ ] `#conteudo`, `#alertas`, `#decisoes` e todos os `data-*` lidos pelos testes continuam.
- [ ] Nenhum `style=` inline; nenhum recurso externo; CSP inalterada além do PR 1.
- [ ] Macro `icon()` e sprite em `/static`; nenhum `<svg>` colado em template.
- [ ] Faixas somem nas telas de detalhe e voltam nas listas.
- [ ] `tests/agent-studio-web.test.sh` verde; screenshots desktop + mobile de base e login no PR.

## Fora de escopo
- Tabelas, badges e páginas (PR 3). Dashboard (PR 4).

## Fase / gate
`aidlc:build`. Gate: screenshots aprovados pelo Bardi.
