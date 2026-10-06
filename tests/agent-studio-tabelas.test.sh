#!/usr/bin/env bash
# Testes das tabelas com ordem, filtro por coluna e página do agent-studio (#529, épico #522): Conversas, Sessões e Uso (as
# de Pedidos e Rodadas leem o SurrealDB e ficam em `agent-studio-proposals` e `agent-studio-rodada`).
# Cada critério de aceite tem caso aqui: página de 20, 50 ou 100 (20 é o padrão) e o rodapé "N a M de total"; o clique no
# cabeçalho ordena a lista inteira (o segundo inverte); filtro por valor nas colunas de categoria; ordem, filtro, página e
# tamanho na URL; mudar o filtro ou a ordem volta à primeira página; Uso só com ordem; parâmetro fora da lista fixa = 400;
# tudo por link, sem JavaScript. O formulário do período é enviado como o navegador envia (tests/lib/studio_form.py).
# Chama o app pelo ASGI (tests/lib/studio_asgi.py); sem servidor, sem rede.
# Uso: tests/agent-studio-tabelas.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "$TMP"' EXIT
studio_init

cat > "$TMP/config.toml" <<'TOML'
timezone = "America/Sao_Paulo"
[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import re, sys
from datetime import datetime, timezone
from agent_studio import config as CF, tabela
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB
from studio_form import submit

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
T0 = int(datetime(2025, 10, 1, 12, 0, tzinfo=timezone.utc).timestamp()) * SEC
W = "from=2025-10-01&to=2025-10-02"

# 45 conversas, c-00 a c-44, uma a cada 10 minutos (c-44 é a mais recente). O custo informado não segue a ordem do início:
# a conversa i custa ((i * 7) % 45 + 1) centavos, então a ordem por custo é outra e só aparece com a lista inteira.
# Host: mac nas ímpares, server nas pares; agente: codex nas múltiplas de 3, claude nas outras. A sessão da conversa i é T(i % 25).
cents = {i: (i * 7) % 45 + 1 for i in range(45)}


def fill(db, loose):
    for i in range(45):
        db.span(T0 + i * 600 * SEC, 2, model="claude-sonnet-5", task=f"T{i % 25:02d}", conv=f"c-{i:02d}", cost_usd=cents[i] / 100,
                host="oute-mac" if i % 2 else "oute-server", agent="codex" if i % 3 == 0 else "claude", input=1000 + i, output=100)
    # 6 conversas sem sessão (o segundo bloco da tela de Sessões); modelo haiku nas pares. Só no banco das Sessões: nas Conversas elas seriam mais 6 linhas
    for i in range(6 if loose else 0):
        db.span(T0 + (46 + i) * 600 * SEC, 1, model="claude-sonnet-5" if i % 2 else "claude-haiku-4", conv=f"solta-{i}", cost_usd=(i + 1) / 100,
                host="oute-mac", agent="claude", input=10, output=10)
    return create_app(db.flush(), TOKEN, config=cfg)


app = fill(StudioDB(tmp, "t"), False)
app_s = fill(StudioDB(tmp, "s"), True)


def q(path, query="", which=None):
    return get(which or app, path, f"{W}&{query}" if query else W)


def qs(path, query=""):
    return q(path, query, app_s)


def rows(html):
    return re.findall(r'<tr[^>]* data-conversa="([^"]*)"', html)


def faixas(html):
    return re.findall(r'data-faixa>([^<]*)<', html)


def link(html, col):
    return re.search(rf'<th[^>]*data-col="{col}">\s*<a class="ordem" href="([^"]*)"', html).group(1).replace("&amp;", "&")


def rel(html, name):
    return re.search(rf'<a href="([^"]*)" rel="{name}"', html).group(1).replace("&amp;", "&")


num = lambda c: int(c[2:])   # noqa: E731
ALL = [f"c-{i:02d}" for i in range(45)]
by_start_desc = list(reversed(ALL))
by_cost_desc = sorted(ALL, key=lambda c: -cents[num(c)])
by_cost_asc = list(reversed(by_cost_desc))
mac = [c for c in by_start_desc if num(c) % 2]

# ---------------------------------------------------------------- página: 20, 50 ou 100, com 20 de padrão
st, html = q("/conversas")
check("Conversas: 200, 20 linhas por padrão, as mais recentes (a ordem de sempre)", st == 200 and rows(html) == by_start_desc[:20])
check("Conversas: o rodapé diz 'N a M de total'", faixas(html) == ["1 a 20 de 45"])
check("Conversas: o tamanho 20 vem marcado e 50 e 100 são links", re.search(r'<span class="tabela-tamanho">\s*Linhas:\s*<a href="[^"]*" aria-current="true">20</a>'
      r'<a href="[^"]*tam=50[^"]*">50</a><a href="[^"]*tam=100[^"]*">100</a>', html) is not None)
check("Conversas: 50 e 100 mostram as 45, com o rodapé", all(rows(q("/conversas", f"tam={n}")[1]) == by_start_desc and faixas(q("/conversas", f"tam={n}")[1]) == ["1 a 45 de 45"] for n in (50, 100)))
check("Conversas: páginas 2 e 3 com 20 por página (a última, 41 a 45)", rows(q("/conversas", "pag=2")[1]) == by_start_desc[20:40]
      and faixas(q("/conversas", "pag=3")[1]) == ["41 a 45 de 45"] and rows(q("/conversas", "pag=3")[1]) == by_start_desc[40:])
check("Conversas: página além da última cai na última (a lista pode ter encolhido)", faixas(q("/conversas", "pag=9")[1]) == ["41 a 45 de 45"])
check("Conversas: anterior e próxima aparecem só onde existem", 'rel="next"' in html and 'rel="prev"' not in html
      and 'rel="prev"' in q("/conversas", "pag=2")[1] and 'rel="next"' not in q("/conversas", "pag=3")[1])

# ---------------------------------------------------------------- ordem: a lista inteira, entre as páginas; o segundo clique inverte
page1, page2 = q("/conversas", "ord=cost&dir=desc")[1], q("/conversas", "ord=cost&dir=desc&pag=2")[1]
check("ordenar por custo vale para a lista inteira: a página 1 tem as 20 mais caras de todas e a 2 as 20 seguintes",
      rows(page1) == by_cost_desc[:20] and rows(page2) == by_cost_desc[20:40])
check("custo crescente inverte", rows(q("/conversas", "ord=cost&dir=asc")[1]) == by_cost_asc[:20])
check("cabeçalho: coluna ainda não ordenada começa pela direção natural (custo: do maior; agente: de A a Z)",
      "ord=cost&dir=desc" in link(html, "cost") and "ord=agent&dir=asc" in link(html, "agent"))
check("cabeçalho: o segundo clique inverte (a coluna ordenada propõe a direção oposta)", "ord=cost&dir=asc" in link(page1, "cost")
      and "ord=cost&dir=desc" in link(q("/conversas", "ord=cost&dir=asc")[1], "cost"))
check("cabeçalho: a ordem de sempre (início, mais recente primeiro) também inverte no clique", "ord=start&dir=asc" in link(html, "start"))
check("cabeçalho: aria-sort marca a coluna ordenada e só ela", re.findall(r'aria-sort="(ascending|descending)" data-col="(\w+)"', page1) == [("descending", "cost")]
      and re.findall(r'aria-sort="(ascending|descending)" data-col="(\w+)"', html) == [("descending", "start")])
by_agent = rows(q("/conversas", "ord=agent&dir=asc&tam=100")[1])
check("ordenar por agente de A a Z: as 30 de claude antes das 15 de codex",
      [("codex" if num(c) % 3 == 0 else "claude") for c in by_agent] == ["claude"] * 30 + ["codex"] * 15)

# ---------------------------------------------------------------- filtro por valor no cabeçalho
check("filtro por host: só as do host, e o rodapé conta o filtrado e o total",
      rows(q("/conversas", "host=oute-mac&tam=100")[1]) == mac and faixas(q("/conversas", "host=oute-mac")[1]) == ["1 a 20 de 22 (filtrado, 45 no total)"])
check("filtro por agente", rows(q("/conversas", "agent=codex&tam=100")[1]) == [c for c in by_start_desc if num(c) % 3 == 0])
check("filtro por host e agente juntos", rows(q("/conversas", "host=oute-mac&agent=codex&tam=100")[1]) == [c for c in by_start_desc if num(c) % 2 and num(c) % 3 == 0])
f_html = q("/conversas", "host=oute-mac")[1]
check("filtro: as opções do cabeçalho são os valores da lista inteira (não só do filtrado), com 'todos', e a escolhida marcada",
      re.findall(r'<li><a href="[^"]*"( aria-current="true")?>([^<]*)</a></li>', re.search(r'data-filtro="host">.*?</details>', f_html, re.S).group(0))
      == [("", "todos"), (' aria-current="true"', "oute-mac"), ("", "oute-server")])
empty = q("/conversas", "host=nao-existe")[1]
check("filtro sem linha: fica o aviso com o link para limpar (a tabela volta com ele limpo)", "Nenhuma conversa nessa janela" in empty and "Limpar o filtro" in empty
      and 'href="/conversas?from=2025-10-01&amp;to=2025-10-02"' in empty)
check("filtro com valor hostil: a comparação é em memória, 200 vazio e nada chega ao SQL", q("/conversas", "host=x'%20OR%20'1'%3D'1")[0] == 200)

# ordem + filtro + página juntos; mudar o filtro, a ordem ou o tamanho volta à primeira página
st, both = q("/conversas", "host=oute-mac&ord=cost&dir=desc&pag=2&tam=20")
exp = [c for c in by_cost_desc if num(c) % 2]
check("filtro + ordem + página 2 juntos: a segunda página do filtrado, ordenada", rows(both) == exp[20:] and faixas(both) == ["21 a 22 de 22 (filtrado, 45 no total)"])
prev_url = rel(both, "prev")
check("mudar de página não perde o filtro, a ordem nem a direção", all(x in prev_url for x in ("host=oute-mac", "ord=cost", "dir=desc")) and "pag=" not in prev_url
      and all(x in rel(q("/conversas", "host=oute-mac&ord=cost&dir=desc")[1], "next") for x in ("host=oute-mac", "ord=cost", "dir=desc", "pag=2")))
size_links = re.findall(r'<a href="([^"]*)"', re.search(r'<span class="tabela-tamanho">.*?</span>', both, re.S).group(0))
check("mudar o tamanho leva o filtro e a ordem e volta à primeira página (sem 'pag')", len(size_links) == 3
      and all("host=oute-mac" in h and "ord=cost" in h and "pag=" not in h for h in size_links))
check("mudar a ordem volta à página 1: o link do cabeçalho leva o filtro e não leva 'pag'", "pag=" not in link(both, "start") and "host=oute-mac" in link(both, "start"))
agent_links = re.findall(r'<a href="([^"]*)"', re.search(r'data-filtro="agent">.*?</details>', both, re.S).group(0))
check("mudar o filtro volta à página 1: os links do filtro levam a ordem e o outro filtro e não levam 'pag'", len(agent_links) == 3
      and all("pag=" not in h and "host=oute-mac" in h and "ord=cost" in h for h in agent_links))
check("a mesma URL dá a mesma página (ordem, filtro, página e tamanho ficam na URL e valem ao recarregar)", q("/conversas", "host=oute-mac&ord=cost&dir=desc&pag=2&tam=20")[1] == both)
# o formulário do período, enviado como o navegador envia: leva a ordem, o filtro e o tamanho, e a página volta à primeira
(st, after), sent = submit(get, app, "/conversas", f"{W}&host=oute-mac&ord=cost&dir=desc&tam=50&pag=2")
check("formulário do período: leva host, ordem, direção e tamanho escondidos e não leva a página",
      st == 200 and all(p in sent for p in (("host", "oute-mac"), ("ord", "cost"), ("dir", "desc"), ("tam", "50"))) and not any(k == "pag" for k, _ in sent))
check("formulário do período enviado: a primeira página do filtrado e ordenado, no tamanho escolhido", rows(after) == exp)

# ---------------------------------------------------------------- parâmetro fora da lista fixa: 400
bad = ["ord=nao-existe", "ord=cost;DROP%20TABLE%20spans", "ord=cost%20desc", "dir=up", "tam=7", "tam=abc", "tam=-20", "tam=20.0", "tam=", "pag=0", "pag=-1", "pag=x", "pag=1e3", "pag=%C2%B2", "tam=%D9%A2%D9%A0",
       "f_nada=1", "f_host=oute-mac", "ord_c=start", "dir_c=asc", "pag_p=2", "f_state=aberta", "f_model=x", "f_agent_c=x"]
check("Conversas: ordem, direção, tamanho, página e filtro fora da lista fixa dão 400", [b for b in bad if q("/conversas", b)[0] != 400] == [])
check("o 400 não repete o que veio na URL", "DROP" not in q("/conversas", "ord=cost;DROP%20TABLE%20spans")[1] and "nao-existe" not in q("/conversas", "ord=nao-existe")[1])
check("Sessões: ordem inválida = 400; vale o sufixo das conversas sem sessão (_c) e não o dos pedidos (_p)", q("/sessoes", "ord=nope")[0] == 400 and q("/sessoes", "ord_c=nope")[0] == 400
      and q("/sessoes", "ord_p=start")[0] == 400 and q("/sessoes", "ord_c=cost&dir_c=asc&tam_c=50")[0] == 200)
check("Uso: ordem fora da lista = 400 e não há página, tamanho nem filtro (só ordenação)", q("/uso", "ord_papel=nope")[0] == 400 and q("/uso", "dir_fase=x")[0] == 400
      and all(q("/uso", b)[0] == 400 for b in ("pag_papel=2", "tam_fase=50", "f_host=x", "ord=cost")))
check("o que não é de tabela passa (repositório, custo)", all(q("/conversas", x)[0] == 200 for x in ("repo=", "custo=lista", "custo=pago")))

# ---------------------------------------------------------------- sem JavaScript: tudo é link
foot = re.search(r'<nav class="tabela-rodape".*?</nav>', html, re.S).group(0)
check("o cabeçalho e o rodapé são links <a href>, sem atributo de evento nem style=", re.search(r'<th[^>]*>\s*<a class="ordem" href="/conversas\?', html) is not None
      and "onclick" not in html and " style=" not in html and all('href="' in a for a in re.findall(r'<a [^>]*>', foot)))
check("o filtro do cabeçalho é <details> com links, que abre sem script", re.search(r'<details class="th-filtro"[^>]*data-filtro="host">\s*<summary[^>]*>filtrar</summary>\s*<ul>', html) is not None)
check("a página não ganhou script: só os de /static (a CSP não muda)", all(s.startswith("/static/") for s in re.findall(r'<script[^>]*src="([^"]*)"', html)) and "<script>" not in html)

# ---------------------------------------------------------------- Sessões: duas tabelas, cada uma com a sua ordem, filtro e página
st, sess = qs("/sessoes")
sess_rows = lambda h: re.findall(r'<tr class="sessao" data-sessao="([^"]*)"', h)       # noqa: E731
loose_rows = lambda h: [c for c in rows(h) if c.startswith("solta")]                  # noqa: E731
cost_of = lambda t: sum(cents[i] for i in range(45) if f"T{i % 25:02d}" == t)         # noqa: E731
tasks_by_cost = sorted((f"T{i:02d}" for i in range(25)), key=lambda t: (-cost_of(t), -int(t[1:])))   # empate: a mais recente primeiro, como a lista
check("Sessões: 20 sessões por padrão com o rodapé '1 a 20 de 25' e as 6 conversas sem sessão no outro bloco, com o rodapé dele",
      st == 200 and len(sess_rows(sess)) == 20 and faixas(sess) == ["1 a 20 de 25", "1 a 6 de 6"] and len(loose_rows(sess)) == 6)
check("Sessões: ordenar por custo ordena as 25 inteiras (a página 2 tem as 5 mais baratas)",
      sess_rows(qs("/sessoes", "ord=cost&dir=desc")[1]) == tasks_by_cost[:20] and sess_rows(qs("/sessoes", "ord=cost&dir=desc&pag=2")[1]) == tasks_by_cost[20:])
by_cost_loose = loose_rows(qs("/sessoes", "ord_c=cost&dir_c=desc")[1])
check("Sessões: a ordem das conversas sem sessão (_c) não mexe na das sessões, e a das sessões não mexe na delas",
      by_cost_loose == [f"solta-{i}" for i in range(5, -1, -1)] and sess_rows(qs("/sessoes", "ord_c=cost&dir_c=desc")[1]) == sess_rows(sess)
      and loose_rows(qs("/sessoes", "ord=cost&dir=desc")[1]) == loose_rows(sess))
check("Sessões: o tamanho das conversas sem sessão (tam_c) não mexe no das sessões", faixas(qs("/sessoes", "tam_c=50")[1]) == ["1 a 20 de 25", "1 a 6 de 6"]
      and len(sess_rows(qs("/sessoes", "tam=50")[1])) == 25 and faixas(qs("/sessoes", "tam=50")[1]) == ["1 a 25 de 25", "1 a 6 de 6"])
hh = qs("/sessoes", "f_model=claude-haiku-4")[1]
check("Sessões: filtro por modelo deixa só o que tem o modelo (as 3 conversas soltas de haiku) e o rodapé conta o filtrado",
      loose_rows(hh) == ["solta-4", "solta-2", "solta-0"] and sess_rows(hh) == [] and faixas(hh) == ["1 a 3 de 3 (filtrado, 6 no total)"])
check("Sessões: o filtro por host, agente e modelo está no cabeçalho das duas tabelas", all(sess.count(f'data-filtro="{c}"') == 2 for c in ("host", "agent", "model")))
chk = qs("/sessoes", "ord_c=cost&dir_c=desc&ord=cost&dir=desc")[1]
check("Sessões: o link de página das sessões leva a ordem das conversas sem sessão (e a recíproca)", all(x in rel(chk, "next") for x in ("ord=cost", "ord_c=cost", "dir_c=desc")))

# ---------------------------------------------------------------- Uso: só a ordenação
st, uso = q("/uso")
named = lambda h, k: re.findall(rf'<tr data-{k}="([^"]*)"', h)   # noqa: E731
check("Uso: as três tabelas ganham o cabeçalho com link e não ganham filtro nem rodapé", st == 200 and 'data-uso="role" data-tabela' in uso
      and 'data-uso="phase" data-tabela' in uso and 'data-uso="subscription" data-tabela' in uso and uso.count('data-col="name"') == 3 and "data-filtro" not in uso and "data-rodape" not in uso)
asc, desc = q("/uso", "ord_papel=name&dir_papel=asc")[1], q("/uso", "ord_papel=name&dir_papel=desc")[1]
check("Uso: papel de A a Z e invertido, sem mexer na tabela por fase", named(asc, "role") == sorted(named(uso, "role")) and named(desc, "role") == sorted(named(uso, "role"), reverse=True)
      and named(asc, "phase") == named(uso, "phase") and len(named(uso, "role")) >= 1)
both_uso = q("/uso", "ord_papel=name&dir_papel=asc&ord_fase=cost&dir_fase=asc")[1]
role_block = both_uso.split('data-uso="role"')[1].split("</table>")[0]
check("Uso: o link de ordem de uma tabela leva a ordem da outra", "ord_fase=cost" in link(role_block, "name") and "dir_fase=asc" in link(role_block, "name")
      and "ord_papel=name&dir_papel=desc" in link(role_block, "name"))

# ---------------------------------------------------------------- a lógica direto
class P(dict):
    def multi_items(self):
        return list(self.items())


C = lambda: [tabela.Col("a", "text", lambda r: r["a"], lambda r: [r["a"]]), tabela.Col("n", "num", lambda r: r["n"])]   # noqa: E731
T = tabela.Table(C(), default=("n", "desc"))
R = [{"a": "x", "n": 1}, {"a": "y", "n": None}, {"a": "x", "n": 3}, {"a": "z", "n": 2}]
ap = lambda t, query, rws=R, pairs=(): tabela.apply(t, tabela.parse(t, P(query)), rws, list(pairs), "/p")   # noqa: E731
check("lógica: valor ausente fica no fim nas duas direções", [r["n"] for r in ap(T, {}).rows] == [3, 2, 1, None] and [r["n"] for r in ap(T, {"dir": "asc"}).rows] == [1, 2, 3, None])
check("lógica: filtro por valor, e as opções vêm da lista inteira", [r["n"] for r in ap(T, {"f_a": "x"}).rows] == [3, 1] and ap(T, {"f_a": "x"}).options == {"a": ["x", "y", "z"]})
check("lógica: lista vazia = 0 a 0 de 0, uma página só", (lambda w: (w.first, w.last, w.total, w.pages, w.page))(ap(T, {}, [])) == (0, 0, 0, 1, 1))
check("lógica: tabela sem página mostra tudo", len(ap(tabela.Table(C(), ("n", "desc"), paginate=False), {}, R * 30).rows) == 120)
check("lógica: a coluna padrão inverte no primeiro clique e a outra começa pela direção natural", ap(T, {}).sort_link("n").endswith("ord=n&dir=asc")
      and ap(T, {}).sort_link("a").endswith("ord=a&dir=asc"))
check("lógica: os links levam o que não é da tabela, escapado", "x=%26y" in ap(T, {}, R, [("x", "&y")]).url(page=2))
Td = tabela.Table(C(), ("n", "desc"), suffix="_d", anchor="#d")
check("lógica: tabela com sufixo e âncora", (lambda w: w.sort_link("a").endswith("#d") and "ord_d=a" in w.sort_link("a"))(ap(Td, {})))
for bad_q in ({"ord": "x"}, {"dir": "x"}, {"tam": "30"}, {"pag": "0"}, {"pag": "a"}, {"tam": ""}):
    try:
        tabela.parse(T, P(bad_q))
        check(f"lógica: {bad_q} dá ValueError", False)
    except ValueError:
        check(f"lógica: {bad_q} dá ValueError", True)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" -ge 45
check_end
