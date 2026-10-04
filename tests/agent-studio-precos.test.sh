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
ins("modelo-barato", (1, 5, 0, 0), "config", OLD)
ins("modelo-barato", (0.8, 5, 0, 0), "fontes", RECENT - DAY)
ins("modelo-velho", (1, 5, 0, 0), "config", OLD)
ins("modelo-velho", (2, 5, 0, 0), "fontes", OLD + DAY)
app = create_app(st, TOKEN, config=cfg)
status, html = get(app, "/precos")
section = lambda m: re.search(rf'<section data-modelo="{re.escape(m)}".*?</section>', html, re.S).group(0)

check("200 com HTML", status == 200 and html.startswith("<!doctype html>"))
check("um bloco por modelo, em ordem de nome", re.findall(r'<section data-modelo="([^"]*)"', html) ==
      ["claude-sonnet-5", "gpt-5-codex", "m&lt;b&gt;x&lt;/b&gt;&amp;y", "modelo-barato", "modelo-velho"])
cod = section("gpt-5-codex")
vig = re.search(r"<tr data-vigente.*?</tr>", cod, re.S).group(0)
check("vigente: os 4 campos do preço mais novo, a origem e o desde", 'data-origin="fontes"' in vig and
      all(v in vig for v in (">1,5<", ">10<", ">0,125<", ">0<")) and f"{RECENT // 10**9}" not in vig
      and time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(RECENT // 10**9)) in vig)
rows = re.findall(r"<tr data-historico data-origin=\"(\w+)\" data-since=\"([^\"]+)\"", cod)
check("histórico: as duas linhas, da mais antiga para a mais nova, cada uma com a origem",
      [r[0] for r in rows] == ["config", "fontes"] and rows[0][1] < rows[1][1])
check("histórico: o preço antigo continua na lista", ">1,25<" in cod)
# Kubo (#468): o histórico abre num <details> (sem botão) e cada linha leva a mini-barra do preço de entrada
check("histórico abre num <details>, uma mini-barra <meter> por linha, na escala do maior preço de entrada",
      '<details class="historico">' in cod and cod.count("<meter ") == 2 and 'max="1.5" value="1.25"' in cod and 'max="1.5" value="1.5"' in cod)
check("cada modelo é um cartão (o bloco <section>)", all(f'class="cartao">' in section(m) for m in ("claude-sonnet-5", "gpt-5-codex")))
check("fixo vira Badge de contorno com o cadeado", 'class="badge contorno" data-fixo>' in section("claude-sonnet-5") and "lucide.svg#lock" in section("claude-sonnet-5"))
check("fontes em cartões, antes dos modelos, cada uma com o Badge", html.index('class="cartao fonte"') < html.index("<section data-modelo")
      and html.count('class="badge secundario">ainda não conferiu') == 2)
# fontes que já conferiram: Badge ok e Badge destrutivo com o motivo
from agent_studio import price_sources as PS
st2 = ST.Store(f"{tmp}/fontes.duckdb")
def run(con, ns, source, ok, reason):
    con.execute("INSERT INTO price_runs VALUES (?, ?, ?, ?)", [ns, source, ok, reason])
    return True
assert st2.transact(lambda con: run(con, NOW - 3600 * 10**9, PS.SOURCES[0], True, None))
assert st2.transact(lambda con: run(con, NOW - 60 * 10**9, PS.SOURCES[1], False, "http_500"))
_, hs = get(create_app(st2, TOKEN, config=cfg), "/precos")
check("fonte que conferiu: Badge ok, ícone check e último sucesso", f'data-fonte="{PS.SOURCES[0]}"' in hs and 'class="badge">ok</span>' in hs and "lucide.svg#check" in hs)
check("fonte que falhou: Badge destrutivo com o motivo e o ícone de alerta", 'class="badge destrutivo">falhou: http_500</span>' in hs and 'class="fonte-icone falhou"' in hs)
check("fonte: nenhum botão nem campo (só mostra)", "<button" not in hs.split("<main", 1)[1] and "<input" not in hs.split("<main", 1)[1])
check("modelo fixo marcado (e só ele)", 'data-fixed="true"' in section("claude-sonnet-5") and "data-fixo" in section("claude-sonnet-5")
      and 'data-fixed="false"' in cod and "data-fixo" not in cod)
check("origem config no modelo sem troca", 'data-origin="config"' in section("claude-sonnet-5"))
check("nome de modelo escapado: nada de HTML do dado", "<b>x</b>" not in html and "m&lt;b&gt;x&lt;/b&gt;&amp;y" in html)
check("fontes: as duas, ainda sem conferência", html.count("ainda não conferiu") == 2)
check("link no menu", re.search(r'<a class="nav-item" href="/precos"[^>]*>.*<span>Preços</span></a>', html) is not None)
check("o aviso 'preço trocado' no topo leva à página",
      'data-alerta="price_changed"' in html and '<a href="/precos">Preço trocado</a>' in html
      and "US$ 1,25 → US$ 1,5 por 1M tokens" in html)
check("o link do menu também está nas outras telas", re.search(r'<a class="nav-item" href="/precos"[^>]*>.*<span>Preços</span></a>', get(app, "/conversas")[1]) is not None)

# tendência e gráfico (#534)
alta, queda, sem, velho = section("gpt-5-codex"), section("modelo-barato"), section("claude-sonnet-5"), section("modelo-velho")
check("alta: selo com a direção, a variação sobre o preço anterior e a data da troca",
      'data-tendencia="up"' in alta and "Entrada subiu +20,0%" in alta
      and time.strftime("%Y-%m-%d", time.gmtime(RECENT // 10**9)) in re.search(r'data-tendencia="up".*?</span>', alta, re.S).group(0))
check("queda: selo de queda com a variação negativa", 'data-tendencia="down"' in queda and "Entrada caiu -20,0%" in queda)
check("modelo com uma linha só: 'sem troca' e nenhum selo de tendência", "data-sem-troca" in sem and "data-tendencia" not in sem)
check("cada modelo tem o gráfico em degrau, com a entrada e a saída",
      all(s.count("data-grafico") == 1 and 'class="entrada"' in s and 'class="saida"' in s for s in (alta, queda, sem)))
check("gráfico em degrau: o modelo com troca tem um salto vertical (V), o sem troca não",
      re.search(r'class="entrada" d="[^"]* V', alta) is not None and re.search(r'class="entrada" d="[^"]* V', sem) is None)
check("topo: 1 subiu e 1 caiu nos últimos 30 dias (a troca antiga não conta)",
      '<strong data-subiram>1</strong>' in html and '<strong data-cairam>1</strong>' in html and "data-tendencia=\"up\"" in velho)
check("a CSP não muda: o gráfico não usa style= nem script", "style=" not in html.split("<main", 1)[1] and "<script" not in html.split("<main", 1)[1])

# só mostra: nenhuma ação
check("sem formulário nem botão além do Sair", re.findall(r"<form[^>]*>", html) == ['<form method="post" action="/logout">'] * 2
      and html.count("<button") == 2 and html.count('title="Sair"') + html.count(">Sair</button>") == 2
      and re.findall(r"<input[^>]*>", html) == ['<input type="checkbox" id="menu" class="menu-interruptor" aria-label="Mostrar ou esconder o menu">'])
check("nenhuma rota de /precos além do GET", [sorted(r.methods) for r in app.routes if "preco" in getattr(r, "path", "")] == [["GET"]])
check("POST /precos = 405", get(app, "/precos", method="POST")[0] == 405)
rows_after = st.read(P.history_rows)
check("abrir a página não escreve no histórico", len(rows_after) == 8)

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
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 35
check_end
