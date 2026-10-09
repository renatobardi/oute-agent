#!/usr/bin/env bash
# Testes da assinatura no agent-studio (#679, ticket 4/5 da #673): a conversa traz `oute.subscription` (claude, zai ou
# codex); a ingestão guarda a coluna e o histórico sem ela vale `claude` ou `codex` pelo `oute.agent`; a chamada da `zai`
# com `cost_usd` preenchido (o valor do Claude Code, que não conhece `glm-*`) entra como custo de LISTA calculado pelo
# preço do config.toml (#747) e nunca soma ao custo real; o estimado fica só para a chamada fora das assinaturas; o Uso e o Dashboard filtram e quebram por assinatura (o formulário renderizado é
# enviado como o navegador envia); a migração põe a coluna num banco antigo; o estado derivado (`conversa`) leva a
# assinatura. O `rebuild-state` e o `replay` têm os casos deles nos testes de cada um. Chama o app pelo ASGI sobre um
# DuckDB de exemplo; sem servidor, sem rede e sem Docker. As datas ficam depois de 2026-10-06 (o corte do #617).
# Uso: tests/agent-studio-assinatura.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" "$ROOT" > "$TMP/py.out" 2>&1 <<'PY'
import base64, json, re, sys
from datetime import datetime, timezone

import duckdb
from agent_studio import config as CF, conversations as CV, otlp, state, store as ST
from agent_studio.app import create_app
from otlp_json import rl, rs, span, event
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB
from studio_form import submit as form_submit

tmp, root = sys.argv[1], sys.argv[2]
cfg = CF.load(f"{root}/config/agent-studio/config.toml")  # o preço do glm-5.3 é o do repo
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-11-01T"
FROM, TO = ts("2026-11-01T00:00:00"), ts("2026-11-02T00:00:00")
Q = "from=2026-11-01T00%3A00%3A00Z&to=2026-11-02T00%3A00%3A00Z"
near = lambda a, b: a is not None and abs(a - b) < 1e-9

# ---------------------------------------------------------------- o banco de exemplo
# claude (com a assinatura) e histórico (sem ela, agent=claude): custo real do Claude Code. codex: sem custo, estimado
# de lista pelo gpt-5. zai (agent=claude, sub=zai): três chamadas do glm-5.3 com o `cost_usd` que o Claude Code calcula sem conhecer o
# modelo (no span, no log api_request de mesmo request_id e uma sem custo nenhum). ai-memory: sem assinatura.
db = StudioDB(tmp, "a")
db.span(ts(f"{D}10:00:00"), 2, model="claude-sonnet-5", conv="c-claude", agent="claude", sub="claude", input=1000, output=100, cost_usd=0.5)
db.span(ts(f"{D}10:10:00"), 2, model="claude-sonnet-5", conv="c-hist", agent="claude", input=1000, output=100, cost_usd=0.25)
db.span(ts(f"{D}10:20:00"), 2, name="session_task.turn", model="gpt-5", conv="c-codex", agent="codex", input=1000, output=100)
db.span(ts(f"{D}11:00:00"), 2, model="glm-5.3", conv="c-zai", agent="claude", sub="zai", input=1_000_000, output=100_000, cost_usd=0.227)
db.span(ts(f"{D}11:10:00"), 2, model="glm-5.3", conv="c-zai", agent="claude", sub="zai", input=1_000_000, output=100_000)
db.span(ts(f"{D}11:20:00"), 2, model="glm-5.3", conv="c-zai", agent="claude", sub="zai", input=1_000_000, attrs={"request_id": "r-zai"})
db.log(ts(f"{D}11:20:03"), "api_request", {"request_id": "r-zai", "cost_usd": 0.9}, conv="c-zai", agent="claude", sub="zai")
db.span(ts(f"{D}12:00:00"), 1, name="ai_memory.llm_request", model="openai/gpt-oss-120b", conv="c-mem", agent="ai-memory", input=10, output=5, cost_usd=0.01)
st = db.flush()
prices = cfg.prices
USD = {"claude": 0.75, "zai": 1.4 * 3 + 0.44 * 2}   # real do claude (0,5 + 0,25); de lista da zai (3 M de entrada, 200 mil de saída)
EST_CODEX = 1000 * 1.25 / 1e6 + 100 * 10 / 1e6

def sub_rows(data):
    return {r["subscription"]: r for r in data["by_subscription"]}

u = st.usage(FROM, TO, prices)
by = sub_rows(u)
check("quebra por assinatura: claude, codex, zai e a chamada sem assinatura (ai-memory)", set(by) == {"claude", "codex", "zai", None})
check("claude: o histórico sem o atributo conta como claude pelo oute.agent (2 chamadas, custo real 0,75)",
      by["claude"]["calls"] == 2 and near(by["claude"]["cost"]["real_usd"], 0.75) and by["claude"]["cost"]["estimated_usd"] is None
      and by["claude"]["cost"]["listed_usd"] is None)
check("codex: sem oute.subscription, pelo oute.agent; custo de lista calculado pelo gpt-5, não estimado",
      by["codex"]["calls"] == 1 and by["codex"]["cost"]["real_usd"] is None and near(by["codex"]["cost"]["listed_usd"], EST_CODEX)
      and by["codex"]["cost"]["estimated_usd"] is None and by["codex"]["cost"]["listed_calls"] == 1 and by["codex"]["cost"]["estimated_calls"] == 0)
z = by["zai"]
check("zai: 3 chamadas, todas de lista pelo preço do config.toml (3 M de entrada a 1,4 + 200 mil de saída a 4,4), nenhuma estimada",
      z["calls"] == 3 and z["cost"]["listed_calls"] == 3 and near(z["cost"]["listed_usd"], USD["zai"])
      and z["cost"]["estimated_calls"] == 0 and z["cost"]["estimated_usd"] is None and z["cost"]["claude_no_log_calls"] == 0)
check("zai: o cost_usd do span (0,227) e o do log api_request (0,9) não entram: custo real nulo e nenhuma chamada real",
      z["cost"]["real_usd"] is None and z["cost"]["real_calls"] == 0 and z["cost"]["unpriced_calls"] == 0)
check("ai-memory: sem assinatura, custo real dele (0,01)", by[None]["calls"] == 1 and near(by[None]["cost"]["real_usd"], 0.01))
check("o total: custo real = claude + ai-memory (a zai não soma ao real), o de lista = codex + zai e nada estimado",
      near(u["totals"]["cost"]["real_usd"], 0.76) and near(u["totals"]["cost"]["listed_usd"], EST_CODEX + USD["zai"])
      and u["totals"]["cost"]["estimated_usd"] is None)
tc = u["totals"]["cost"]
check("o total: informadas + de lista + estimadas + sem preço = chamadas (3 + 4 + 0 + 0 = 7)",
      (tc["real_calls"], tc["listed_calls"], tc["estimated_calls"], tc["unpriced_calls"]) == (3, 4, 0, 0)
      and tc["real_calls"] + tc["listed_calls"] + tc["estimated_calls"] + tc["unpriced_calls"] == u["totals"]["calls"])
check("glm-5.3 tem preço: não aparece em unpriced_models", u["unpriced_models"] == [] and u["totals"]["cost"]["unpriced_calls"] == 0)
check("a soma das assinaturas é o total de chamadas", sum(r["calls"] for r in u["by_subscription"]) == u["totals"]["calls"] == 7)
ue = st.usage(FROM, TO, prices, paid=True)
check("custo pago: a zai é assinatura e custa 0 (real 0, sem custo de lista nem estimativa); o ai-memory segue pago",
      near(sub_rows(ue)["zai"]["cost"]["real_usd"], 0.0) and sub_rows(ue)["zai"]["cost"]["estimated_usd"] is None and sub_rows(ue)["zai"]["cost"]["listed_usd"] is None and near(ue["totals"]["cost"]["real_usd"], 0.01))
uz = st.usage(FROM, TO, prices, sub="zai")
check("filtro zai: só as 3 chamadas dela, e a quebra por assinatura só tem a zai",
      uz["totals"]["calls"] == 3 and list(sub_rows(uz)) == ["zai"] and near(uz["totals"]["cost"]["listed_usd"], USD["zai"]))
check("filtro claude: 2 chamadas (a com atributo e o histórico); filtro codex: 1",
      st.usage(FROM, TO, prices, sub="claude")["totals"]["calls"] == 2 and st.usage(FROM, TO, prices, sub="codex")["totals"]["calls"] == 1)
check("filtro: a soma dos filtros das três assinaturas + sem assinatura é o total (7)",
      sum(st.usage(FROM, TO, prices, sub=s)["totals"]["calls"] for s in ("claude", "zai", "codex")) + by[None]["calls"] == 7)
det = CV.detail(st.con, "c-zai", prices)
kinds = [(s["cost_kind"], round(s["cost"], 6)) for s in det["spans"] if s["is_call"]]
check("detalhe da conversa zai: cada chamada é de lista (o custo do Claude Code é descartado)",
      [k for k, _ in kinds] == ["listed"] * 3 and kinds[0][1] == round(1.4 + 0.44, 6) and kinds[2][1] == 1.4)
dete = CV.detail(st.con, "c-zai", prices, paid=True)
check("detalhe da conversa zai no custo pago: 0 em cada chamada", [s["cost_kind"] for s in dete["spans"] if s["is_call"]] == ["paid"] * 3)

# ---------------------------------------------------------------- as telas
app = create_app(st, TOKEN, config=cfg)
kpi = lambda html: int(re.search(r'data-kpi="calls" data-value="(\d+)"', html).group(1))
uso = lambda html: int(re.search(r'id="total" data-calls="(\d+)"', html).group(1))
def sel(html):
    m = re.search(r'<select name="assinatura">(.*?)</select>', html, re.S)
    return re.findall(r'<option value="([^"]*)"( selected)?', m.group(1)) if m else None
OPTS = [("", ""), ("claude", ""), ("zai", ""), ("codex", "")]
for p, total in (("/", kpi), ("/uso", uso)):
    st_, html = get(app, p, Q)
    check(f"{p}: campo Assinatura com Todas e as três assinaturas, Todas por padrão", st_ == 200 and sel(html) == OPTS and total(html) == 7)
    st_, html = get(app, p, Q + "&assinatura=zai")
    check(f"{p}: assinatura=zai na URL: 3 chamadas e a opção marcada", st_ == 200 and total(html) == 3 and ("zai", " selected") in sel(html))
    check(f"{p}: assinatura em branco = sem o parâmetro", total(get(app, p, Q + "&assinatura=")[1]) == 7)
    for bad in ("outra", "zai%27%20OR%20%271%27%3D%271", "%3Cscript%3E"):
        st_, html = get(app, p, Q + f"&assinatura={bad}")
        check(f"{p}: assinatura inválida ({bad[:10]}): 400, nada vai ao SQL e a entrada não volta na página", st_ == 400 and "<script>" not in html and "OR" not in html)
    (st_, html), sent = form_submit(get, app, p, "hours=168", assinatura="zai")
    check(f"{p}: formulário enviado com a assinatura escolhida: assinatura=zai no envio, 200 e a opção marcada",
          st_ == 200 and ("assinatura", "zai") in sent and ("zai", " selected") in sel(html))
    (st_, html), sent = form_submit(get, app, p, "hours=168")
    check(f"{p}: formulário enviado sem escolher (Todas): assinatura em branco e 200", st_ == 200 and ("assinatura", "") in sent)
(st_, html), sent = form_submit(get, app, "/uso", Q + "&assinatura=zai", assinatura="")
check("Uso: trocar para Todas num formulário que tinha a zai volta ao total", st_ == 200 and uso(html) == 7)
(st_, html), sent = form_submit(get, app, "/", Q + "&assinatura=zai", assinatura="codex")
check("Dashboard: do formulário que tinha a zai para o codex: 1 chamada", st_ == 200 and kpi(html) == 1)

html = get(app, "/uso", Q)[1]
rows = re.findall(r'data-subscription="([^"]*)" data-calls="(\d+)"', html)
check("Uso: tabela por assinatura, a zai com 3 chamadas e a sem assinatura com o nome de exibição",
      dict(rows) == {"claude": "2", "codex": "1", "zai": "3", "sem assinatura": "1"})
zrow = re.search(r'<tr data-subscription="zai"[^>]*data-real-usd="([^"]*)" data-estimated-usd="([^"]*)" data-listed-usd="([^"]*)"', html)
check("Uso: a linha da zai tem custo real e estimado vazios e o de lista do config.toml",
      zrow and zrow.group(1) == "" and zrow.group(2) == "" and near(float(zrow.group(3)), USD["zai"]))
check("Uso: o gráfico de custo por assinatura traz as quatro barras", len(re.findall(r'data-grafico="uso-custo-subscription".*?</section>', html, re.S)[0].split('class="barra-linha"')) == 5)
check("Uso: filtrado na zai, a tabela por assinatura só tem a zai", re.findall(r'<tr data-subscription="([^"]*)"', get(app, "/uso", Q + "&assinatura=zai")[1]) == ["zai"])
dash = get(app, "/", Q)[1]
bars = dict(re.findall(r'data-assinatura="([^"]*)" data-calls="(\d+)"', dash))
check("Dashboard: bloco por assinatura (zai 3, claude 2, codex 1 e a sem assinatura, com chave vazia)", bars == {"zai": "3", "claude": "2", "codex": "1", "": "1"})
check("Dashboard: o custo de lista da zai aparece no bloco; o real e o estimado não (vazios)",
      re.search(r'data-assinatura="zai" data-calls="3" data-real-usd="" data-listed-usd="[0-9.]+" data-estimated-usd=""', dash) is not None)
dz = get(app, "/", Q + "&assinatura=zai")[1]
check("Dashboard filtrado na zai: o KPI de custo de lista é o dela e os outros blocos seguem o filtro",
      near(float(re.search(r'data-kpi="cost"[^>]*data-listed-usd="([^"]*)"', dz).group(1)), USD["zai"])
      and re.search(r'data-grafico="chamadas"[^>]*data-total="(\d+)"', dz).group(1) == "3"
      and re.search(r'data-grafico="atividade"[^>]*data-total="(\d+)"', dz).group(1) == "3"
      and re.findall(r'data-modelo="([^"]*)" data-calls', dz) == ["glm-5.3", "glm-5.3"])
check("Dashboard: as janelas prontas e os links levam a assinatura", "assinatura=zai" in re.findall(r'<nav class="janelas".*?</nav>', dz, re.S)[0] and 'href="/uso?hours=24&amp;assinatura=zai"' in get(app, "/", "hours=24&assinatura=zai")[1])
check("Dashboard: o formulário do modelo leva a assinatura escondida", '<input type="hidden" name="assinatura" value="zai">' in dz)
dc = get(app, "/", Q + "&assinatura=zai&custo=pago")[1]
check("Dashboard filtrado na zai com custo pago: sem custo de lista nem estimado, a chamada de assinatura custa 0",
      re.search(r'data-kpi="cost"[^>]*data-listed-usd=""[^>]*data-estimated-usd=""', dc) is not None)

# ---------------------------------------------------------------- ingestão: a coluna `oute_subscription`
RES = {"host.name": "oute-server", "oute.agent": "claude", "service.name": "oute", "session.id": "c-1"}
def span_row(res, at=ts(f"{D}10:00:00")):
    return otlp.span_rows({"resourceSpans": [rs(res, [span("claude_code.llm_request", at // SEC, 2, {"model": "glm-5.3"})])]}, at)[0]
def log_row(res, at=ts(f"{D}10:00:00")):
    return otlp.log_rows({"resourceLogs": [rl(res, [event(at // SEC, "oute.exemplo", "ev-1", {})])]}, at)[0]
check("ingestão: span com oute.subscription=zai guarda a coluna", span_row({**RES, "oute.subscription": "zai"})["oute_subscription"] == "zai")
check("ingestão: log com oute.subscription=zai guarda a coluna", log_row({**RES, "oute.subscription": "zai"})["oute_subscription"] == "zai")
check("ingestão: histórico sem o atributo fica NULL (a leitura deriva pelo oute.agent)", span_row(RES)["oute_subscription"] is None and log_row(RES)["oute_subscription"] is None)
check("ingestão: atributo vazio = sem assinatura marcada (NULL)", span_row({**RES, "oute.subscription": ""})["oute_subscription"] is None)
check("ingestão: o resource_attributes fica como chegou", json.loads(span_row({**RES, "oute.subscription": "zai"})["resource_attributes"])["oute.subscription"] == "zai")
mrow = otlp.metric_rows({"resourceMetrics": [{"resource": {"attributes": [{"key": "oute.subscription", "value": {"stringValue": "zai"}}]}, "scopeMetrics": [
    {"metrics": [{"name": "claude_code.token.usage", "unit": "tokens", "sum": {"dataPoints": [{"timeUnixNano": str(ts(f"{D}10:00:00")), "asInt": "3"}]}}]}]}]}, ts(f"{D}10:00:00"))[0]
check("ingestão: a métrica também guarda a assinatura", mrow["oute_subscription"] == "zai")

# ---------------------------------------------------------------- banco antigo: a coluna entra na subida, o histórico segue
old = StudioDB(tmp, "antigo")
old.span(ts(f"{D}10:00:00"), 2, model="claude-sonnet-5", conv="h-claude", agent="claude", input=10, output=1, cost_usd=0.1)
old.span(ts(f"{D}10:10:00"), 2, name="session_task.turn", model="gpt-5", conv="h-codex", agent="codex", input=10, output=1)
old.flush().close()
raw = duckdb.connect(f"{tmp}/antigo.duckdb")
for t in ("spans", "logs", "metrics"):
    raw.execute(f"ALTER TABLE {t} DROP COLUMN oute_subscription")
cols = lambda c: {t: [r[0] for r in c.execute(f"SELECT column_name FROM information_schema.columns WHERE table_name = '{t}'").fetchall()] for t in ("spans", "logs", "metrics")}
check("banco antigo: sem a coluna oute_subscription (como antes do #679)", all("oute_subscription" not in c for c in cols(raw).values()))
raw.close()
st2 = ST.Store(f"{tmp}/antigo.duckdb")
check("subida: a migração põe a coluna nas três tabelas", all("oute_subscription" in c for c in cols(st2.con).values()))
u2 = sub_rows(st2.usage(FROM, TO, prices))
check("subida: o histórico aparece como claude e codex pelo oute.agent, sem preencher a coluna",
      set(u2) == {"claude", "codex"} and st2.con.execute("SELECT count(*) FROM spans WHERE oute_subscription IS NOT NULL").fetchone()[0] == 0)
st2.close()
st3 = ST.Store(f"{tmp}/antigo.duckdb")
check("subida de novo (a coluna já existe): nada muda e nada quebra", set(sub_rows(st3.usage(FROM, TO, prices))) == {"claude", "codex"})
st3.write({"spans": [span_row({**RES, "oute.subscription": "zai"})]})
check("depois da migração a ingestão grava a assinatura (zai)", st3.con.execute("SELECT oute_subscription FROM spans WHERE oute_subscription IS NOT NULL").fetchone()[0] == "zai")
st3.close()
new = ST.Store(f"{tmp}/novo.duckdb")
check("banco novo: já nasce com a coluna", all("oute_subscription" in c for c in cols(new.con).values()))
new.close()

# ---------------------------------------------------------------- estado derivado (SurrealDB): a conversa leva a assinatura
def conversa(rows, sid):
    out = {}
    for sql, var in state.statements("spans", rows):
        if var.get("id") == sid and "b" in var and "subscription" in var["b"]:
            out["subscription"] = base64.b64decode(var["b"]["subscription"]).decode()
    return out.get("subscription")
zrow_, crow, hrow, mrow_ = (span_row({**RES, "oute.subscription": "zai", "session.id": "c-z"}), span_row({**RES, "oute.agent": "claude", "oute.subscription": "claude", "session.id": "c-c"}),
                            span_row({**RES, "session.id": "c-h"}), span_row({**RES, "oute.agent": "codex", "session.id": "c-x"}))
check("estado: a conversa zai (agent claude) leva subscription=zai", conversa([zrow_], "c-z") == "zai")
check("estado: a conversa com o atributo claude leva claude", conversa([crow], "c-c") == "claude")
check("estado: o histórico sem o atributo vira claude ou codex pelo oute.agent", conversa([hrow], "c-h") == "claude" and conversa([mrow_], "c-x") == "codex")
check("estado: conversa de agente sem assinatura (ai-memory) não leva o campo", conversa([span_row({**RES, "oute.agent": "ai-memory", "session.id": "c-m"})], "c-m") is None)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 60
check_end
