#!/usr/bin/env bash
# Testes da página /precos do agent-studio (#340, ADR-08 adendo "Preços"): por modelo o preço vigente (4 campos, origem,
# desde quando) e o histórico em ordem de data, o modelo fixo marcado, o link no menu, o aviso "preço trocado" no topo
# das telas levando à página, login de leitura, tudo escapado, a mesma CSP e nenhuma ação (a tela só mostra). Chama o
# app pelo ASGI (tests/lib/studio_asgi.py) sobre um DuckDB de exemplo; sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-precos.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "$TMP"' EXIT
studio_init

cat > "$TMP/config.toml" <<'TOML'
[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
fixed = true
[prices."gpt-5-codex"]
input = 1.25
output = 10.0
cache_read = 0.125
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import re, sys, time
from agent_studio import config as CF, cost as C, prices as P, store as ST, web
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, Broken, get

tmp = sys.argv[1]
DAY = P.DAY_NS
OLD = 1_760_000_000 * 10**9                    # 2025-10-09 08:53:20 UTC, muito antes de qualquer janela
NOW = time.time_ns()
RECENT = (NOW - 2 * DAY) // 10**9 * 10**9     # 2 dias atrás (o alerta "preço trocado" vale por 7)
cfg = CF.load(f"{tmp}/config.toml")
st = ST.Store(f"{tmp}/db.duckdb")


def ins(model, price, origin, at):
    assert st.transact(lambda con: P._insert(con, model, C.ModelPrice(*price), origin, at))


ins("claude-sonnet-5", (3, 15, 0.3, 3.75), "config", OLD)
ins("gpt-5-codex", (1.25, 10, 0.125, 0), "config", OLD)
ins("gpt-5-codex", (1.5, 10, 0.125, 0), "fontes", RECENT)
ins("m<b>x</b>&y", (2, 4, 0, 0), "config", OLD)
app = create_app(st, TOKEN, config=cfg)
status, html = get(app, "/precos")
section = lambda m: re.search(rf'<section data-modelo="{re.escape(m)}".*?</section>', html, re.S).group(0)

check("200 com HTML", status == 200 and html.startswith("<!doctype html>"))
check("um bloco por modelo, em ordem de nome", re.findall(r'<section data-modelo="([^"]*)"', html) ==
      ["claude-sonnet-5", "gpt-5-codex", "m&lt;b&gt;x&lt;/b&gt;&amp;y"])
cod = section("gpt-5-codex")
vig = re.search(r"<tr data-vigente.*?</tr>", cod, re.S).group(0)
check("vigente: os 4 campos do preço mais novo, a origem e o desde", 'data-origin="fontes"' in vig and
      all(v in vig for v in (">1,5<", ">10<", ">0,125<", ">0<")) and f"{RECENT // 10**9}" not in vig
      and time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(RECENT // 10**9)) in vig)
rows = re.findall(r"<tr data-historico data-origin=\"(\w+)\" data-since=\"([^\"]+)\"", cod)
check("histórico: as duas linhas, da mais antiga para a mais nova, cada uma com a origem",
      [r[0] for r in rows] == ["config", "fontes"] and rows[0][1] < rows[1][1])
check("histórico: o preço antigo continua na lista", ">1,25<" in cod)
check("modelo fixo marcado (e só ele)", 'data-fixed="true"' in section("claude-sonnet-5") and "data-fixo" in section("claude-sonnet-5")
      and 'data-fixed="false"' in cod and "data-fixo" not in cod)
check("origem config no modelo sem troca", 'data-origin="config"' in section("claude-sonnet-5"))
check("nome de modelo escapado: nada de HTML do dado", "<b>x</b>" not in html and "m&lt;b&gt;x&lt;/b&gt;&amp;y" in html)
check("fontes: as duas, ainda sem conferência", html.count("ainda não conferiu") == 2)
check("link no menu", '<a href="/precos">Preços</a>' in html)
check("o aviso 'preço trocado' no topo leva à página",
      'data-alerta="price_changed"' in html and '<a href="/precos">Preço trocado</a>' in html
      and "US$ 1,25 → US$ 1,5 por 1M tokens" in html)
check("o link do menu também está nas outras telas", '<a href="/precos">Preços</a>' in get(app, "/conversas")[1])

# só mostra: nenhuma ação
check("sem formulário nem botão além do Sair", re.findall(r"<form[^>]*>", html) == ['<form method="post" action="/logout">']
      and html.count("<button") == 1 and "<input" not in html)
check("nenhuma rota de /precos além do GET", [sorted(r.methods) for r in app.routes if "preco" in getattr(r, "path", "")] == [["GET"]])
check("POST /precos = 405", get(app, "/precos", method="POST")[0] == 405)
rows_after = st.read(P.history_rows)
check("abrir a página não escreve no histórico", len(rows_after) == 4)

# acesso e CSP
st_login, _ = get(create_app(st, "outro-token", config=cfg), "/precos")
check("sem credencial de leitura: 303 para o login", st_login == 303)
check("a mesma CSP e o htmx local, sem CDN", "https://" not in html and "http://" not in html and "/static/htmx.min.js" in html)
check("a CSP da tela só aceita script e estilo do próprio servidor", web.HEADERS["Content-Security-Policy"].startswith("default-src 'none'; script-src 'self'"))

# estados
empty = create_app(ST.Store(f"{tmp}/vazio.duckdb"), TOKEN)
s, h = get(empty, "/precos")
check("sem nenhum preço: aviso no lugar, página 200", s == 200 and 'id="sem-precos"' in h)
s, h = get(create_app(Broken(), TOKEN), "/precos")
check("leitura que falha: 500, sem a causa na página", s == 500 and "segredo-da-falha" not in h and "A consulta falhou" in h)
PY
grep -v '^Traceback\|^  \|^RuntimeError\|^$\|^ok   \|tela: .* falhou' "$TMP/py.out" || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 21
check_end
