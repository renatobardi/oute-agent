#!/usr/bin/env bash
# Testes do filtro de repositório do agent-studio (#528, épico #522): Dashboard, Conversas, Sessões e Uso têm o filtro
# "Repositório" (Todos por padrão), a lista de opções traz os repositórios com fato na janela e "sem repositório", o filtro
# vale para todos os blocos do Dashboard, fica na URL e vai nos links entre telas, "Todos" dá os números de sempre e o
# histórico gravado antes da coluna `oute_repo` aparece filtrado do mesmo jeito (migração da subida). Chama o app pelo ASGI
# (tests/lib/studio_asgi.py) sobre um DuckDB de exemplo; sem servidor, sem rede e sem Docker.
# As datas ficam depois de 2026-10-06 (o corte do acerto do histórico, #617), para valer a regra normal.
# Uso: tests/agent-studio-repo.test.sh   (sai != 0 se algum caso falhar)
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
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import re, sys, time
from datetime import datetime, timezone

import duckdb
from agent_studio import config as CF, otlp, store as ST
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB
from studio_form import submit as form_submit

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC, H = 10**9, 3600 * 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-11-01T"
Q = "from=2026-11-01T00%3A00%3A00Z&to=2026-11-02T00%3A00%3A00Z"
NONE = "(sem)"

# Dois repositórios com fato na janela (alfa, beta), uma conversa sem repositório e um repositório (gama) só fora da janela.
db = StudioDB(tmp, "r")
tok = dict(input=1000, output=100)
for at, conv in ((f"{D}10:00:00", "c-a1"), (f"{D}10:10:00", "c-a1")):
    db.span(ts(at), 2, model="claude-sonnet-5", task="T-alfa", conv=conv, repo="alfa", **tok)
db.span(ts(f"{D}10:20:00"), 1, name="claude_code.tool", task="T-alfa", conv="c-a1", repo="alfa", err=True, attrs={"tool_name": "Read"})
db.log(ts(f"{D}10:21:00"), "tool_result", {}, conv="c-a1", task="T-alfa", repo="alfa", sev=17)
for i in range(3):
    db.span(ts(f"{D}11:{i}0:00"), 5, model="claude-sonnet-5", task="T-beta", conv="c-b1", repo="beta", cache_read=5000, **tok)
for i in range(2):
    db.span(ts(f"{D}12:{i}0:00"), 1, name="claude_code.tool", task="T-beta", conv="c-b1", repo="beta", err=True, attrs={"tool_name": "Bash"})
db.span(ts(f"{D}13:00:00"), 3, model="claude-sonnet-5", conv="c-solta", **tok)  # fora do oute-task: sem sessão e sem repositório
db.span(ts("2026-10-20T10:00:00"), 2, model="claude-sonnet-5", task="T-gama", conv="c-g1", repo="gama", **tok)
app = create_app(db.flush(), TOKEN, config=cfg)

def body(html):
    # a linha da janela traz a hora de agora nas páginas sem from/to; o resto é o que se compara
    return re.sub(r'<p class="nota janela".*?</p>', "", html, flags=re.S)

def calls(html):
    m = re.search(r'data-kpi="calls" data-value="(\d+)"', html)
    return int(m.group(1)) if m else None

def uso(html):
    m = re.search(r'id="total" data-calls="(\d+)"', html)
    return int(m.group(1)) if m else None

def ids(html, attr="conversa"):
    return sorted(re.findall(rf'data-{attr}="([^"]*)"', html))

def options(html):
    sel = re.search(r'<select name="repo">(.*?)</select>', html, re.S)
    return re.findall(r'<option value="([^"]*)"', sel.group(1)) if sel else None

def q(repo=None, extra=""):
    return Q + (f"&repo={repo}" if repo is not None else "") + extra

PAGES = ("/", "/conversas", "/sessoes", "/uso")
REPOS = {"alfa": 2, "beta": 3, NONE: 1}

# ---- o filtro nas quatro telas, "Todos" por padrão, e as opções
for p in PAGES:
    st, html = get(app, p, Q)
    check(f"{p}: 200 e o campo Repositório, com Todos marcado por padrão",
          st == 200 and "<label>Repositório" in html and '<option value="" selected>' not in html and '<option value="">Todos</option>' in html
          and 'selected' not in re.search(r'<select name="repo">(.*?)</select>', html, re.S).group(1))
    check(f"{p}: opções = repositórios com fato na janela (alfa, beta) e 'sem repositório'; gama (só fora da janela) não aparece",
          options(html) == ["", "alfa", "beta", NONE] and "gama" not in html)
    check(f"{p}: 'sem repositório' tem o rótulo certo", f'<option value="{NONE}">sem repositório</option>' in html)

# ---- Todos = os números de hoje (sem o parâmetro e com ele em branco, a mesma página)
check("Dashboard: Todos = 6 chamadas", calls(get(app, "/", Q)[1]) == 6)
check("Dashboard: repo em branco = sem o parâmetro (mesma página)", all(get(app, p, Q + "&repo=")[1] == get(app, p, Q)[1] for p in PAGES))
check("Uso: Todos = 6 chamadas", uso(get(app, "/uso", Q)[1]) == 6)
check("Conversas: Todos = as 3 conversas da janela", ids(get(app, "/conversas", Q)[1]) == ["c-a1", "c-b1", "c-solta"])

# ---- cada repositório: só os fatos dele, e a soma dos repositórios é o Todos
for repo, n in REPOS.items():
    dash = get(app, "/", q(repo))[1]
    check(f"Dashboard repo={repo}: KPI de chamadas = {n}", calls(dash) == n)
    check(f"Uso repo={repo}: total = {n} chamadas", uso(get(app, "/uso", q(repo))[1]) == n)
# os gráficos da tela de Uso seguem o repositório (#533): chamadas das colunas e tokens de entrada do gráfico de tokens
def chart_calls(html):
    return sum(int(c) for c in re.findall(r'<g class="coluna" data-bucket="[^"]*" data-calls="(\d+)"', html))

def chart_input(html):
    m = re.search(r'data-grafico="uso-tokens-dia" data-days="\d+" data-input="(\d+)"', html)
    return int(m.group(1)) if m else None
INPUTS = {"alfa": 2000, "beta": 3000, NONE: 1000}
for repo, n in REPOS.items():
    h = get(app, "/uso", q(repo))[1]
    check(f"Uso repo={repo}: gráfico de custo por dia soma {n} chamadas e o de tokens, {INPUTS[repo]} de entrada",
          chart_calls(h) == n and chart_input(h) == INPUTS[repo])
check("Uso: Todos = 6 chamadas nas colunas e 6000 de entrada", chart_calls(get(app, "/uso", Q)[1]) == 6 and chart_input(get(app, "/uso", Q)[1]) == 6000)
check("Dashboard: chamadas dos repositórios somam o Todos", sum(calls(get(app, "/", q(r))[1]) for r in REPOS) == 6)
check("Uso: papel e fase do repositório somam o total dele",
      all(sum(int(c) for c in re.findall(r'data-role="[^"]*" data-calls="(\d+)"', get(app, "/uso", q(r))[1])) == n for r, n in REPOS.items()))

# todos os blocos do Dashboard
d_alfa, d_beta, d_none, d_all = (get(app, "/", q(r))[1] for r in ("alfa", "beta", NONE, None))
check("Dashboard alfa: o modelo (gráfico de custo) e a latência trazem só as 2 chamadas dele",
      re.findall(r'data-modelo="claude-sonnet-5" data-calls="(\d+)"', d_alfa) == ["2", "2"])
check("Dashboard beta: modelo e latência trazem as 3 chamadas dele", re.findall(r'data-modelo="claude-sonnet-5" data-calls="(\d+)"', d_beta) == ["3", "3"])
check("Dashboard: o KPI de erros conta os spans com erro do repositório (alfa 1, beta 2, sem 0)",
      [re.search(r'data-kpi="errors"[^>]*data-errors="(\d+)"', h).group(1) for h in (d_alfa, d_beta, d_none)] == ["1", "2", "0"])
check("Dashboard: a série (gráfico de chamadas) soma as chamadas do repositório",
      all(re.search(r'data-grafico="chamadas"[^>]*data-total="(\d+)"', h).group(1) == str(n) for h, n in ((d_alfa, 2), (d_beta, 3), (d_none, 1), (d_all, 6))))
check("Dashboard: o mapa de calor (7 dias até o fim da janela) soma as chamadas do repositório",
      all(re.search(r'data-grafico="atividade"[^>]*data-total="(\d+)"', h).group(1) == str(n) for h, n in ((d_alfa, 2), (d_beta, 3), (d_none, 1), (d_all, 6))))
check("Dashboard: as sessões que mais custaram são só as do repositório",
      ids(d_alfa, "sessao") == ["T-alfa"] and ids(d_beta, "sessao") == ["T-beta"] and ids(d_none, "sessao") == [] and ids(d_all, "sessao") == ["T-alfa", "T-beta"])
check("Dashboard: o insight de erros da mesma ferramenta (2 erros do Bash) só existe em beta e em Todos",
      all(('data-insight="tool_errors"' in h) == want for h, want in ((d_alfa, False), (d_beta, True), (d_none, False), (d_all, True))))
# sonnet: US$ 3/M de entrada e 15/M de saída; sem preço de cache na tabela, o cache lido custa como entrada
est = [float(re.search(r'data-kpi="cost"[^>]*data-estimated-usd="([^"]*)"', h).group(1)) for h in (d_alfa, d_beta)]
check("Dashboard: o custo estimado é o do repositório (alfa 2 chamadas de US$ 0,0045; beta 3 de US$ 0,0195)",
      abs(est[0] - 0.009) < 1e-9 and abs(est[1] - 0.0585) < 1e-9)

# Conversas e Sessões
check("Conversas: cada repositório lista só as conversas dele",
      [ids(get(app, "/conversas", q(r))[1]) for r in ("alfa", "beta", NONE)] == [["c-a1"], ["c-b1"], ["c-solta"]])
check("Conversas: a linha leva o repositório", 'data-conversa="c-a1" data-host="oute-server" data-repo="alfa"' in get(app, "/conversas", q("alfa"))[1])
sess = {r: get(app, "/sessoes", q(r))[1] for r in ("alfa", "beta", NONE)}
check("Sessões: cada repositório lista só as sessões dele", ids(sess["alfa"], "sessao") == ["T-alfa"] and ids(sess["beta"], "sessao") == ["T-beta"])
check("Sessões: a conversa sem sessão e sem repositório só aparece em 'sem repositório'",
      ids(sess[NONE]) == ["c-solta"] and ids(sess[NONE], "sessao") == [] and "c-solta" not in sess["alfa"] + sess["beta"])
check("Sessões: as conversas de cada sessão são as do repositório", ids(sess["alfa"]) == ["c-a1"] and ids(sess["beta"]) == ["c-b1"])
check("Sessões: Todos traz as duas sessões e a conversa solta", ids(get(app, "/sessoes", Q)[1], "sessao") == ["T-alfa", "T-beta"]
      and "c-solta" in get(app, "/sessoes", Q)[1])
check("Sessões e Conversas com host e agente juntos com o repositório: a interseção",
      ids(get(app, "/conversas", q("beta", "&host=oute-server&agent=claude"))[1]) == ["c-b1"]
      and ids(get(app, "/conversas", q("beta", "&host=outro"))[1]) == [])

# ---- fica na URL e vai nos links
for p in PAGES:
    html = get(app, p, q("beta"))[1]
    check(f"{p}: a opção do repositório da URL vem marcada", '<option value="beta" selected>beta</option>' in html)
    check(f"{p}: as janelas prontas levam o repositório", all(f'repo=beta' in a for a in re.findall(r'<nav class="janelas".*?</nav>', html, re.S)[0].split("<a ")[1:]))
dash = get(app, "/", "hours=24&repo=beta")[1]
check("Dashboard: ver Uso e ver Sessões levam o repositório e a janela",
      'href="/uso?hours=24&amp;repo=beta"' in dash and 'href="/sessoes?hours=24&amp;repo=beta"' in dash)
ins = re.search(r'<li data-insight="cache".*?</li>', get(app, "/", q("beta"))[1], re.S)
check("Dashboard: o insight de cache (link para o Uso) leva a janela e o repositório", ins is not None and "repo=beta" in ins.group(0) and "/uso?" in ins.group(0))
check("o repositório com caractere especial vai codificado no link", 'repo=a%26b%3Dc' in get(app, "/", "hours=24&repo=a%26b%3Dc")[1])
st, via = get(app, "/uso", "hours=24&repo=beta")
check("o link do Dashboard abre o Uso já com o repositório marcado", st == 200 and '<option value="beta" selected>' in via)

# ---- o formulário renderizado, enviado como o navegador envia (lição do #553)
def submit(path, query, **pick):
    return form_submit(get, app, path, query, **pick)

for p in PAGES:
    (st, html), sent = submit(p, "hours=168", repo="beta")
    check(f"{p}: formulário enviado com o repositório escolhido: 200 e o campo repo = beta na URL do envio", st == 200 and ("repo", "beta") in sent
          and '<option value="beta" selected>' in html)
    (st, html), sent = submit(p, "hours=168")
    check(f"{p}: formulário enviado sem escolher (Todos): repo em branco, 200, mesma página que sem o campo", st == 200 and ("repo", "") in sent
          and body(html) == body(get(app, p, "hours=168")[1]))
(st, html), sent = submit("/uso", q("beta"), repo="")
check("trocar para Todos num formulário que tinha o repositório: volta ao total", st == 200 and uso(html) == 6)
(st, html), sent = submit("/sessoes", Q + "&host=oute-server", repo=NONE)   # o host vem do filtro do cabeçalho (#529) e o formulário o leva escondido
check("formulário de Sessões com 'sem repositório' e host: 200, repo e host no envio e só a conversa solta",
      st == 200 and ("repo", NONE) in sent and ("host", "oute-server") in sent and ids(html) == ["c-solta"])

# ---- ramos: repositório que não existe, entrada hostil, cache por repositório
for p in PAGES:
    st, html = get(app, p, q("nao-existe"))
    check(f"{p}: repositório sem fato: 200 vazio, a opção da URL continua marcada", st == 200 and '<option value="nao-existe" selected>nao-existe</option>' in html)
check("repositório sem fato: nenhuma chamada no Dashboard e no Uso", calls(get(app, "/", q("nao-existe"))[1]) == 0 and uso(get(app, "/uso", q("nao-existe"))[1]) == 0)
hostil = "x'%20OR%20'1'%3D'1"
check("repositório com aspas e SQL: parâmetro, não texto de SQL (200, vazio)", all(get(app, p, q(hostil))[0] == 200 for p in PAGES)
      and calls(get(app, "/", q(hostil))[1]) == 0)
check("repositório com HTML na URL sai escapado na opção marcada", "<script>" not in get(app, "/", q("%3Cscript%3Ealert(1)%3C%2Fscript%3E"))[1])

# o Dashboard de janela viva (últimas 24 h) guarda o resultado por repositório: dois repositórios seguidos não se misturam
now = time.time_ns()
live = StudioDB(tmp, "live")
live.span(now - 2 * H, 2, model="claude-sonnet-5", task="T-1", conv="l1", repo="alfa", **tok)
live.span(now - 3 * H, 2, model="claude-sonnet-5", task="T-2", conv="l2", repo="beta", **tok)
live.span(now - 4 * H, 2, model="claude-sonnet-5", task="T-2", conv="l2", repo="beta", **tok)
app_live = create_app(live.flush(), TOKEN, config=cfg)
seq = [calls(get(app_live, "/", f"hours=24&repo={r}")[1]) for r in ("alfa", "beta", "alfa", "", "beta")]
check("Dashboard de janela viva: o cache é por repositório (alfa 1, beta 2, alfa 1, Todos 3, beta 2)", seq == [1, 2, 1, 3, 2])

# ---- API: o contrato do /v1/usage não muda, sem filtro de repositório
st, body = get(app, "/v1/usage", Q + "&repo=alfa")
import json
check("/v1/usage ignora o repositório (fora de escopo): o total é o de todos", st == 200 and json.loads(body)["totals"]["calls"] == 6)

# ---- ingestão: oute.task.repo vira a coluna
def payload(res_attrs, rec_attrs=()):
    kv = lambda d: [{"key": k, "value": {"stringValue": v}} for k, v in d]
    return {"resourceSpans": [{"resource": {"attributes": kv(res_attrs)}, "scopeSpans": [{"spans": [{
        "traceId": "a" * 32, "spanId": "b" * 16, "name": "claude_code.llm_request", "kind": 1,
        "startTimeUnixNano": "1793527200000000000", "endTimeUnixNano": "1793527201000000000", "attributes": kv(rec_attrs)}]}]}]}

row = lambda *a: otlp.span_rows(payload(*a), 1)[0]["oute_repo"]
check("ingestão: oute.task.repo do resource vira oute_repo", row([("oute.task.repo", "alfa")]) == "alfa")
check("ingestão: o do registro vale mais que o do resource", row([("oute.task.repo", "alfa")], [("oute.task.repo", "beta")]) == "beta")
check("ingestão: sem o atributo, NULL", row([("oute.task.id", "T")]) is None)
check("ingestão: repositório vazio = sem repositório (NULL)", row([("oute.task.repo", "")]) is None)

# ---- histórico: banco criado antes da coluna `oute_repo`, só com o JSON do resource; a subida preenche, e o filtro vale igual
def old_db(name):
    """Banco no esquema anterior ao #528: as tabelas sem a coluna, as linhas com o repositório só no `resource_attributes`."""
    con = duckdb.connect(f"{tmp}/{name}.duckdb")
    con.execute("SET TimeZone='UTC'")
    for table, cols in ST.TABLES.items():
        keep = [(c, t) for c, t in cols if c != "oute_repo"]
        con.execute(f"CREATE TABLE {table} ({', '.join(f'{c} {t}' for c, t in keep)})")
    return con

def put(con, table, rows):
    cols = [c for c in ST.SQL[table]["columns"] if c != "oute_repo"]
    ph = ", ".join(ST.TS_UTC if c in ST.DERIVED else "?" for c in cols)
    con.executemany(f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({ph})",
                    [[r[ST.DERIVED[c]] if c in ST.DERIVED else r.get(c) for c in cols] for r in rows])

hist = StudioDB(tmp, "hist-src")
hist.span(ts(f"{D}10:00:00"), 2, model="claude-sonnet-5", task="T-alfa", conv="h-a", repo="alfa", **tok)
hist.span(ts(f"{D}11:00:00"), 2, model="claude-sonnet-5", task="T-beta", conv="h-b", repo="beta", **tok)
hist.span(ts(f"{D}12:00:00"), 2, model="claude-sonnet-5", conv="h-solta", **tok)
hist.log(ts(f"{D}10:30:00"), "tool_result", {}, conv="h-a", task="T-alfa", repo="alfa", sev=17)
con = old_db("hist")
put(con, "spans", hist.spans)
put(con, "logs", hist.logs)
has_col = lambda c, t: c.execute("SELECT count(*) FROM information_schema.columns WHERE table_name = ? AND column_name = 'oute_repo'", [t]).fetchone()[0]
check("histórico: o banco antigo não tem a coluna", has_col(con, "spans") == 0 and has_col(con, "logs") == 0 and has_col(con, "metrics") == 0)
con.close()
st_old = ST.Store(f"{tmp}/hist.duckdb")
check("histórico: a subida põe a coluna nas três tabelas", all(has_col(st_old.con, t) == 1 for t in ("spans", "logs", "metrics")))
check("histórico: a coluna foi preenchida do JSON do resource (alfa, beta e NULL para o fato sem repositório)",
      st_old.con.execute("SELECT oute_repo, count(*) FROM spans GROUP BY 1 ORDER BY 1 NULLS LAST").fetchall() == [("alfa", 1), ("beta", 1), (None, 1)])
check("histórico: os logs também", st_old.con.execute("SELECT oute_repo FROM logs").fetchall() == [("alfa",)])
app_old = create_app(st_old, TOKEN, config=cfg)
check("histórico: Dashboard e Uso filtram o dado antigo do mesmo jeito (alfa 1, beta 1, sem 1, Todos 3)",
      [calls(get(app_old, "/", q(r))[1]) for r in ("alfa", "beta", NONE, None)] == [1, 1, 1, 3]
      and [uso(get(app_old, "/uso", q(r))[1]) for r in ("alfa", "beta", NONE, None)] == [1, 1, 1, 3])
check("histórico: Conversas e Sessões idem",
      [ids(get(app_old, "/conversas", q(r))[1]) for r in ("alfa", "beta", NONE)] == [["h-a"], ["h-b"], ["h-solta"]]
      and ids(get(app_old, "/sessoes", q("beta"))[1], "sessao") == ["T-beta"])
check("histórico: as opções do filtro vêm do dado antigo", options(get(app_old, "/uso", Q)[1]) == ["", "alfa", "beta", NONE])
st_old.close()
before = duckdb.connect(f"{tmp}/hist.duckdb", read_only=True).execute("SELECT count(*) FROM spans WHERE oute_repo IS NOT NULL").fetchone()[0]
again = ST.Store(f"{tmp}/hist.duckdb")
check("subida de novo (coluna já existe): nada muda e nada quebra", again.con.execute("SELECT count(*) FROM spans WHERE oute_repo IS NOT NULL").fetchone()[0] == before == 2)
again.close()
fresh = ST.Store(f"{tmp}/fresh.duckdb")
check("banco novo: já nasce com a coluna, sem passar pela migração", all(has_col(fresh.con, t) == 1 for t in ("spans", "logs", "metrics")))
fresh.close()
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 87
check_end
