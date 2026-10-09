#!/usr/bin/env bash
# Testes do custo pago rateado pela mensalidade do plano (#748, ADR-08 adendo "Custo pago rateado"): o valor do dia (mensalidade ÷ dias do
# mês, pela linha do plan_history que valia no dia) é dividido entre as chamadas da assinatura na proporção do custo de lista; dia com
# plano e sem chamada é "sem uso"; a soma de um mês fechado fecha com a mensalidade e as quebras (conversa, repositório, fase, papel,
# assinatura) fecham com o total; plano 0 = 0; sem plano = "sem plano"; a API, o tray e os alertas seguem com o custo de lista.
# Chama o app pelo ASGI (tests/lib/studio_asgi.py) sobre um DuckDB de exemplo; sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-custo-pago-rateio.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

cat > "$TMP/config.toml" <<'TOML'
[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
TOML
cat > "$TMP/config-sp.toml" <<'TOML'
timezone = "America/Sao_Paulo"

[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import json, re, sys
from datetime import datetime, timezone

from agent_studio import config as CF, planos, tz as tz_mod, usage as U
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB

tmp = sys.argv[1]
cfg, cfg_sp = CF.load(f"{tmp}/config.toml"), CF.load(f"{tmp}/config-sp.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
N = "2025-11-"
FROM, TO = ts(N + "01T00:00:00"), ts("2025-12-01T00:00:00")
Q = "from=2025-11-01T00%3A00%3A00Z&to=2025-12-01T00%3A00%3A00Z"
QP = Q + "&custo=pago"
tok = dict(input=1000, output=100)

def same(a, b):
    return a is not None and b is not None and abs(a - b) < 1e-9

# claude: US$ 30 por mês até o dia 15 e US$ 60 a partir do dia 16 (novembro tem 30 dias: US$ 1,00 e US$ 2,00 por dia); codex: plano de US$ 0; zai: sem plano
db = StudioDB(tmp, "r")
planos.append(db.st.con, "claude", "Max 5x", 30.0, "2025-10-01")
planos.append(db.st.con, "claude", "Max 20x", 60.0, N + "16")
planos.append(db.st.con, "codex", "Gratuito", 0.0, "2025-10-01")
# dia 02: duas chamadas do claude (US$ 3,00 em alfa e US$ 1,00 em beta) -> o valor do dia (1,00) vira 0,75 e 0,25
db.span(ts(N + "02T10:00:00"), 2, model="claude-sonnet-5", task="T-a", conv="c-a", repo="alfa", agent="claude", cost_usd=3.0, **tok)
db.span(ts(N + "02T11:00:00"), 2, model="claude-sonnet-5", task="T-b", conv="c-b", repo="beta", agent="claude", cost_usd=1.0, **tok)
# dia 20 (plano de US$ 60): uma chamada leva o dia inteiro, US$ 2,00
db.span(ts(N + "20T10:00:00"), 2, model="claude-sonnet-5", task="T-c", conv="c-c", repo="alfa", agent="claude", cost_usd=0.1, **tok)
# dia 25: duas chamadas sem custo e sem preço (peso 0 no dia inteiro): dividem o dia por número de chamadas, US$ 1,00 cada
db.span(ts(N + "25T10:00:00"), 2, model="modelo-sem-preco", task="T-d", conv="c-d", repo="beta", agent="claude", **tok)
db.span(ts(N + "25T10:05:00"), 2, model="modelo-sem-preco", task="T-d", conv="c-d", repo="beta", agent="claude", **tok)
# borda de fuso: 01:00Z do dia 16 é dia 15 em São Paulo
db.span(ts(N + "16T01:00:00"), 2, model="claude-sonnet-5", task="T-e", conv="c-e", repo="alfa", agent="claude", cost_usd=0.5, **tok)
# codex (plano 0) e zai (sem plano) no dia 03; ai-memory (pago por uso) no dia 04
db.span(ts(N + "03T10:00:00"), 3, model="claude-sonnet-5", task="T-x", conv="c-x", agent="codex", name="session_task.turn", **tok)
db.span(ts(N + "03T11:00:00"), 3, model="claude-sonnet-5", task="T-z", conv="c-z", agent="claude", sub="zai", **tok)
db.span(ts(N + "04T10:00:00"), 1, model="claude-sonnet-5", task="T-ai", conv="c-ai", agent="ai-memory", name="ai_memory.llm_request", cost_usd=0.5, **tok)
st = db.flush()
con = st.con
app = create_app(st, TOKEN, config=cfg)
app_sp = create_app(st, TOKEN, config=cfg_sp)

def usage(paid=True, repo=None, sub=None, tz=tz_mod.UTC, lo=FROM, hi=TO):
    return U.usage(con, lo, hi, cfg.prices, tz, repo, paid, sub)

def usd(c):
    return (c["real_usd"] or 0) + (c["listed_usd"] or 0) + (c["estimated_usd"] or 0)

def cost_sum(rows):
    return sum(usd(r["cost"]) for r in rows)

def agg(keys, **kw):
    g = U.aggregate(con, kw.pop("lo", FROM), kw.pop("hi", TO), cfg.prices, keys, p95=False, **kw)
    return {k: v for k, v in g.items()}

def conv_cost(c, **kw):
    a = agg(("conversation",), paid=True, **kw).get((c,))
    return None if a is None else a["real_usd"]

up = usage()
by_sub = {r["subscription"]: r for r in up["by_subscription"]}
claude_month = 15 * 1.0 + 15 * 2.0

# ---- critério 1: a chamada de assinatura recebe a parte do valor do dia, e não US$ 0
check("claude, dia 02: a chamada de US$ 3,00 recebe 0,75 e a de US$ 1,00 recebe 0,25 (proporção do custo de lista)",
      same(conv_cost("c-a"), 0.75) and same(conv_cost("c-b"), 0.25))
check("claude, dia 20: a única chamada leva o valor do dia inteiro (US$ 2,00)", same(conv_cost("c-c"), 2.0))
check("claude, dia 25: duas chamadas sem custo e sem preço dividem o dia por número de chamadas (1,00 cada)", same(conv_cost("c-d"), 2.0))
check("o custo de lista segue como era (sem paid): c-a = 3,00 informado", same(agg(("conversation",))[("c-a",)]["real_usd"], 3.0))

# ---- critério 2: o mês fechado soma a mensalidade, por assinatura
check("a soma do pago do claude no mês fechado = soma das mensalidades por dia (15 × 1,00 + 15 × 2,00 = 45,00)",
      same(usd(by_sub["claude"]["cost"]), claude_month))
check("a soma do pago do mês = mensalidade do claude + o pago por uso do ai-memory (0,50)", same(usd(up["totals"]["cost"]), claude_month + 0.5))
check("o ai-memory (pago por uso) mantém o custo informado: 0,50", same(usd(by_sub[None]["cost"]), 0.5))

# ---- critério 3: as quebras fecham com o total, sem sobra
total = usd(up["totals"]["cost"])
for kind in ("conversation", "repo", "phase", "role", "subscription", "day", "host", "agent", "model"):
    check(f"a soma por {kind} fecha com o total do período (incluindo a linha 'sem uso')",
          same(sum((a["real_usd"] or 0) + (a["listed_usd"] or 0) + (a["estimated_usd"] or 0) for a in agg((kind,), paid=True).values()), total))
check("as tabelas by_role, by_phase e by_subscription do /uso fecham com o total",
      all(same(cost_sum(up[k]), total) for k in ("by_role", "by_phase", "by_subscription")) and same(cost_sum(up["series"]), total))
check("o 'sem uso' aparece como linha própria por papel e por fase", "sem uso" in {r["role"] for r in up["by_role"]} and "sem uso" in {r["phase"] for r in up["by_phase"]})

# ---- critério 4: dia com plano e sem chamada = "sem uso", com o valor do dia
idle = up["idle"]
claude_idle = [r for r in idle if r["subscription"] == "claude"]
used_days = {"02", "16", "20", "25"}   # o dia 16 tem a chamada de 01:00Z
check("claude: 26 dias sem uso (30 dias menos os 4 com chamada: 02, 16, 20 e 25)", len(claude_idle) == 26 and not used_days & {r["day"][-2:] for r in claude_idle})
check("cada dia sem uso traz o valor do dia: 1,00 até o dia 15 e 2,00 a partir do 16",
      all(same(r["usd"], 1.0 if int(r["day"][-2:]) <= 15 else 2.0) for r in claude_idle))
check("plano de US$ 0 (codex) não gera dia sem uso; assinatura sem plano (zai) também não", {r["subscription"] for r in idle} == {"claude"})
html = get(app, "/uso", QP)[1]
check("/uso, pago: a tabela de dias sem uso lista os 26 dias do claude", len(re.findall(r'<tr data-sem-uso="', html)) == 26 and "sem uso" in html)

# ---- critério 5: mudança de preço no meio do mês
check("o valor de cada dia é o que valia nele: a chamada do dia 15 (BRT) leva 1,00 e a do dia 20 leva 2,00",
      same(conv_cost("c-e", tz=tz_mod.parse("America/Sao_Paulo")), 1.0) and same(conv_cost("c-c"), 2.0))
check("o dia local decide o rateio: 01:00Z do dia 16 é dia 16 em UTC (valor 2,00) e dia 15 em São Paulo (1,00)",
      same(conv_cost("c-e"), 2.0) and same(conv_cost("c-e", tz=tz_mod.parse("America/Sao_Paulo")), 1.0))
sp = usage(tz=tz_mod.parse("America/Sao_Paulo"), lo=ts("2025-11-01T03:00:00"), hi=ts("2025-12-01T03:00:00"))
check("em São Paulo o mês fechado (03:00Z a 03:00Z) também soma a mensalidade do claude: 45,00",
      same(usd({s["subscription"]: s for s in sp["by_subscription"]}["claude"]["cost"]), claude_month))

# ---- critério 6: plano 0 e sem plano
check("plano de US$ 0 (codex) conta 0 e não aparece como 'sem plano'", same(usd(by_sub["codex"]["cost"]), 0.0) and "no_plan_calls" not in by_sub["codex"]["cost"])
check("assinatura sem plano (zai) conta 0 e a chamada é contada como 'sem plano'", same(usd(by_sub["zai"]["cost"]), 0.0) and by_sub["zai"]["cost"]["no_plan_calls"] == 1)
check("a tela diz 'sem plano' na linha da zai", re.search(r'data-subscription="zai".*?data-sem-plano', html, re.S) is not None
      or re.search(r'<tr data-subscription="zai"[^>]*>.*?1 sem plano', html, re.S) is not None)

# ---- filtros: a parte de cada grupo não muda com o filtro (o denominador é o dia inteiro)
check("com filtro de repositório (alfa) a conversa c-a segue com 0,75 e não aparece 'sem uso'",
      same(conv_cost("c-a", repo="alfa"), 0.75) and not usage(repo="alfa")["idle"])
check("a soma do repositório alfa é a soma das partes dele: c-a 0,75 + c-c 2,00 + c-e 2,00 (dia 16 em UTC)",
      same(usd(usage(repo="alfa")["totals"]["cost"]), 0.75 + 2.0 + 2.0))
check("com o filtro de assinatura (claude) o total é a mensalidade dele", same(usd(usage(sub="claude")["totals"]["cost"]), claude_month))
check("janela de meio dia: a parte da chamada não depende da janela (denominador = dia inteiro)",
      same(conv_cost("c-b", lo=ts(N + "02T10:30:00"), hi=ts(N + "02T12:00:00")), 0.25))

# ---- critério 7: o texto da tela
check("a tela diz que o custo pago é a mensalidade rateada, e 'contam como 0' saiu",
      "mensalidade do plano" in html and "rateada" in html and "contam como 0" not in html and "assinatura = 0" not in html)
check("/conversa, pago: a linha do span leva a parte do dia (0,75) e o título não diz que conta 0",
      'data-cost-kind="paid"' in get(app, "/conversa", "id=c-a&custo=pago")[1] and 'data-cost="0.75"' in get(app, "/conversa", "id=c-a&custo=pago")[1]
      and "conta 0" not in get(app, "/conversa", "id=c-a&custo=pago")[1])
check("/conversa, pago, assinatura sem plano: a linha diz 'sem plano'", "sem plano" in get(app, "/conversa", "id=c-z&custo=pago")[1])
dash = get(app, "/", QP)[1]
check("Dashboard, pago: o KPI de custo soma a mensalidade (45,50)", same(float(re.search(r'data-kpi="cost" data-value="([^"]*)"', dash).group(1)), claude_month + 0.5))
check("Dashboard, pago: a dica diz mensalidade rateada", "mensalidade do plano" in dash and "contam US$ 0" not in dash)

# ---- critério 8: a API, o tray e os alertas seguem com o custo de lista
ul, ue = json.loads(get(app, "/v1/usage", Q)[1]), json.loads(get(app, "/v1/usage", QP)[1])
check("GET /v1/usage: igual com e sem custo=pago, sem 'idle' e sem 'no_plan_calls' (custo de lista)",
      ul == ue and "idle" not in ul and all("no_plan_calls" not in r["cost"] for r in ul["rows"]) and same(ul["totals"]["cost"]["real_usd"], 3.0 + 1.0 + 0.1 + 0.5 + 0.5))
check("lista: o total é o custo de lista (informado 5,10 + calculado 0,0045 do codex e 0,0045 da zai)",
      same(usd(usage(paid=False)["totals"]["cost"]), 3.0 + 1.0 + 0.1 + 0.5 + 0.5 + 0.0045 + 0.0045) and "idle" not in usage(paid=False))
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 39
check "tray, alertas e API não leem o rateio (nenhum 'paid' nem 'rateio' em tray.py, cost_alerts.py, alerts.py e app.py)" \
  bash -c 'cd "$1/docker/agent-studio/agent_studio" && ! grep -nE "paid|rateio" tray.py cost_alerts.py alerts.py app.py' _ "$ROOT"
check "a conta do rateio mora só no rateio.py (nenhum outro módulo divide a mensalidade por dias do mês)" \
  bash -c 'cd "$1/docker/agent-studio/agent_studio" && ! grep -ln "monthrange" *.py | grep -v "^rateio.py$" | grep -q .' _ "$ROOT"
check_end
