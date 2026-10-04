Parte 1/4 do épico #465 (agent-studio no Kubo Design System).

## Intenção
Trocar a base visual do agent-studio pelos tokens do Kubo sem mexer em nenhum template: `studio.css` passa a usar as variáveis OKLCH do Kubo (light + dark), a Inter Variable é servida de `/static` e a CSP ganha `font-src 'self'`.

## Contexto
- `docker/agent-studio/agent_studio/static/studio.css` (86 linhas, 10 variáveis hex).
- `docker/agent-studio/agent_studio/web.py` linha ~45: `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'`.
- Tokens de origem: Kubo `project/tokens/colors.css`, `typography.css`, `radius.css` (canvas v1.0 em #465). Mapa `studio.css → Kubo` está no épico.
- Dark mode continua por `@media (prefers-color-scheme: dark)`: o bloco `.dark` do Kubo entra ali.
- Fonte: `InterVariable.woff2` (self-hosted, `font-weight: 100 900`, `local('Inter')` de fallback).

## Critérios de aceite
- [ ] `studio.css` não tem mais nenhum hex antigo; todas as cores vêm de `--background`, `--foreground`, `--card`, `--muted`, `--muted-foreground`, `--border`, `--primary`, `--destructive`, `--gate`, `--gate-tint`.
- [ ] `--gate` / `--gate-tint` definidos (âmbar) e usados só em `.decisoes` e no estado pendente de pedido.
- [ ] `.real` sem cor; `.est` em `--muted-foreground` itálico; `.aviso.erro` e `tr.erro` com `--destructive` tingido.
- [ ] `body` em Inter 14px; `h1` 20px/600/`-0.025em`; `h2` 16px/500; `code`/`pre` mono 12px.
- [ ] `/static/fonts/InterVariable.woff2` servido; `@font-face` no `studio.css`; CSP com `font-src 'self'` e nada mais alterado.
- [ ] Nenhum arquivo em `templates/` muda neste PR.
- [ ] `tests/agent-studio-web.test.sh` verde.
- [ ] Screenshot light e dark de Conversas, Sessões e Pedidos no PR.

## Fora de escopo
- Sidebar, ícones, badges (PR 2 e 3).

## Fase / gate
`aidlc:build`. Gate: screenshots aprovados pelo Bardi.
