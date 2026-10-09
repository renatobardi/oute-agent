#!/usr/bin/env bash
# Testes do custo de lista das assinaturas (#747, ADR-08 "Custo de lista"): a chamada de `claude`, `codex` ou `zai` sem custo
# real é custo de lista calculado pela tabela, sem a marca "estimado ≈" (a de fora das três segue estimada); o claude sem o log
# de custo é contado à parte na tela de Uso; modelo de assinatura sem preço vira alerta (não estimado, nem zero); o custo
# informado do claude é conferido contra a tabela (limite configurável, alerta); todo modelo da tabela do seletor tem
# `fixed = true` no config.toml, com a página oficial e a data; o filtro do formulário de Uso é enviado como o navegador
# envia. Chama o app pelo ASGI sobre um DuckDB de exemplo; sem servidor, rede nem Docker. Datas depois de 2026-10-06 (#617).
# Uso: tests/agent-studio-custo-lista.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" "$ROOT" > "$TMP/py.out" 2>&1 <<'PY'
import re, sys, tomllib
from datetime import datetime, timezone

from agent_studio import alert_text, alerts as A, config as CF, cost_alerts, prices as P
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB
from studio_form import submit as form_submit

tmp, root = sys.argv[1], sys.argv[2]
cfg = CF.load(f"{root}/config/agent-studio/config.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-11-01T"
FROM, TO = ts("2026-11-01T00:00:00"), ts("2026-11-02T00:00:00")
Q = "from=2026-11-01T00%3A00%3A00Z&to=2026-11-02T00%3A00%3A00Z"
near = lambda a, b: a is not None and abs(a - b) < 1e-9
M = 1_000_000

# ---------------------------------------------------------------- o banco de exemplo
# claude: uma chamada com o log de custo (informado 3,1 contra 3,0 da tabela), uma sem log (calculada) e o opus 5.5 com
# informado 9,0 contra 6,0 da tabela. codex: gpt-6.1-sol (tabela) e um modelo sem preço. zai: glm-5.3. ai-memory: sem assinatura,
# sem custo, modelo com preço (estimado).
db = StudioDB(tmp, "a")
db.span(ts(f"{D}10:00:00"), 2, model="claude-sonnet-5", conv="c1", agent="claude", sub="claude", input=M, output=100_000, attrs={"request_id": "r1"})
db.log(ts(f"{D}10:00:03"), "api_request", {"request_id": "r1", "cost_usd": 3.1}, conv="c1", agent="claude", sub="claude")
db.span(ts(f"{D}10:10:00"), 2, model="claude-sonnet-5", conv="c1", agent="claude", sub="claude", input=M, output=100_000)
db.span(ts(f"{D}10:20:00"), 2, model="claude-opus-5-5", conv="c2", agent="claude", sub="claude", input=M, output=100_000, cost_usd=9.0)
db.span(ts(f"{D}11:00:00"), 2, name="session_task.turn", model="gpt-6.1-sol", conv="c3", agent="codex", sub="codex", input=M, output=100_000)
db.span(ts(f"{D}11:10:00"), 2, name="session_task.turn", model="gpt-9-sem-preco", conv="c3", agent="codex", sub="codex", input=M, output=100_000)
db.span(ts(f"{D}12:00:00"), 2, model="glm-5.3", conv="c4", agent="claude", sub="zai", input=M, output=100_000)
db.span(ts(f"{D}13:00:00"), 1, name="ai_memory.llm_request", model="openai/gpt-oss-120b", conv="c5", agent="ai-memory", input=M)
st = db.flush()
P.sync(st, cfg, now_ns=FROM - 3600 * SEC)  # a semente do histórico de preços, como na subida (os alertas leem o histórico do banco)
prices = cfg.prices
SONNET, SOL, GLM, MEM = 2.0 + 1.0, 2.0 + 1.0, 1.4 + 0.44, 0.037

u = st.usage(FROM, TO, prices)
c = u["totals"]["cost"]
check("real: só as duas chamadas com custo informado do claude (log 3,1 + opus 9,0)", near(c["real_usd"], 12.1) and c["real_calls"] == 2)
check("lista: o claude sem log (3,0), o gpt-6.1-sol (3,0) e o glm-5.3 (1,84) saem como custo de lista", near(c["listed_usd"], SONNET + SOL + GLM) and c["listed_calls"] == 3)
check("estimado: só a chamada fora das três assinaturas (ai-memory)", near(c["estimated_usd"], MEM) and c["estimated_calls"] == 1)
check("modelo de assinatura sem preço não entra como estimado nem como zero: unpriced_calls=1 e o modelo listado", c["unpriced_calls"] == 1 and u["unpriced_models"] == ["gpt-9-sem-preco"])
check("a soma das chamadas fecha: real + lista + estimado + sem preço = chamadas (7)", c["real_calls"] + c["listed_calls"] + c["estimated_calls"] + c["unpriced_calls"] == u["totals"]["calls"] == 7)
check("o claude sem o log de custo é contado à parte (1), e só ele: codex e zai não entram", c["claude_no_log_calls"] == 1)
by = {r["subscription"]: r["cost"] for r in u["by_subscription"]}
check("por assinatura: claude lista só a chamada sem log; codex e zai não têm estimado", near(by["claude"]["listed_usd"], SONNET) and by["claude"]["estimated_usd"] is None
      and by["codex"]["estimated_usd"] is None and near(by["zai"]["listed_usd"], GLM) and by["zai"]["estimated_usd"] is None and by[None]["listed_usd"] is None)

# ---------------------------------------------------------------- telas
app = create_app(st, TOKEN, config=cfg)
for sub in ("claude", "codex", "zai"):
    (status, html), sent = form_submit(get, app, "/uso", Q, assinatura=sub)
    total = re.search(r'<p class="cartao bloco" id="total".*?</p>', html, re.S).group(0)
    check(f"Uso, formulário enviado com assinatura={sub}: 200 e o total sem a marca 'estimado ≈'", status == 200 and ("assinatura", sub) in sent and "≈" not in total and "est." not in total)
(status, html), sent = form_submit(get, app, "/uso", Q)
total = re.search(r'<p class="cartao bloco" id="total".*?</p>', html, re.S).group(0)
check("Uso, todas: o '≈' aparece só pelo estimado de fora das assinaturas (ai-memory)", status == 200 and "≈" in total)
check("Uso: o número do claude sem log de custo está na tela (data-claude-no-log-calls=1)", re.search(r'id="claude-sem-log" data-claude-no-log-calls="1"', html) is not None and "1 do claude sem log de custo" in html)
check("Uso: o total traz data-listed-usd e data-listed-calls", re.search(r'id="total"[^>]*data-listed-usd="([^"]*)"[^>]*data-listed-calls="3"', html) is not None)
(status, html), _ = form_submit(get, app, "/", Q, assinatura="zai")
kpi = re.search(r'data-kpi="cost"[^>]*>', html).group(0)
check("Dashboard filtrado na zai: o KPI de custo é de lista (data-listed-usd) e o estimado está vazio, sem '≈' no valor",
      status == 200 and near(float(re.search(r'data-listed-usd="([^"]*)"', kpi).group(1)), GLM) and 'data-estimated-usd=""' in kpi
      and "≈" not in re.search(r'<strong class="kpi-valor">(.*?)</strong>', html, re.S).group(1))
(status, html), _ = form_submit(get, app, "/", Q, assinatura="codex")
check("Dashboard filtrado no codex: o modelo sem preço aparece 'sem preço' e o de lista sem '≈'", status == 200 and "sem preço" in html
      and "≈" not in re.search(r'data-grafico="custo-modelo".*?</section>', html, re.S).group(0).split("Composição")[0].replace("≈ estimado", ""))
conv = get(app, "/conversa", "id=c1&" + Q)[1]
check("Conversa do claude: a chamada com custo informado e a de lista não levam 'est.'", "est." not in conv and "custo de lista calculado" in conv)

# ---------------------------------------------------------------- alertas
acfg = cfg.alerts
al = cost_alerts.evaluate(st.con, TO, acfg)
by_type = {}
for a in al:
    by_type.setdefault(a["type"], []).append(a)
diff = by_type.get("cost_claude_diff", [])
check("conferência do claude: só o opus 5.5 passa do limite (informado 9,0 × tabela 6,0 = +50%)", [a["evidence"]["model"] for a in diff] == ["claude-opus-5-5"] and near(diff[0]["value"], 50.0) and diff[0]["limit"] == 10)
check("conferência do claude: o sonnet (3,1 × 3,0 = +3,3%) fica dentro do limite", all(a["evidence"]["model"] != "claude-sonnet-5" for a in diff))
unp = by_type.get("cost_subscription_unpriced", [])
check("modelo de assinatura sem preço vira alerta (gpt-9-sem-preco, 1 chamada, codex)", len(unp) == 1 and unp[0]["evidence"]["model"] == "gpt-9-sem-preco" and unp[0]["value"] == 1 and unp[0]["evidence"]["subscriptions"] == ["codex"])
check("o glm-5.3, o gpt-6.1-sol e o ai-memory (fora das assinaturas) não geram alerta de sem preço", {a["evidence"]["model"] for a in unp} == {"gpt-9-sem-preco"})
import dataclasses
loose = dataclasses.replace(acfg, claude_cost_diff_pct=60)
check("o limite é configurável: com 60% o alerta do opus some", not [a for a in cost_alerts.evaluate(st.con, TO, loose) if a["type"] == "cost_claude_diff"])
tight = dataclasses.replace(acfg, claude_cost_diff_pct=2)
check("o limite é configurável: com 2% o sonnet também alerta", {a["evidence"]["model"] for a in cost_alerts.evaluate(st.con, TO, tight) if a["type"] == "cost_claude_diff"} == {"claude-sonnet-5", "claude-opus-5-5"})
check("fora dos 7 dias da janela nada alerta", cost_alerts.evaluate(st.con, TO + 30 * 86400 * SEC, acfg) == [])
full = st.alerts(TO, acfg)
check("o /v1/alerts leva os dois tipos novos, com título e texto, e em `checks`", {a["type"] for a in full["alerts"]} >= {"cost_claude_diff", "cost_subscription_unpriced"}
      and all(t in full["checks"] for t in A.COST_TYPES) and all(alert_text.title(a) != a["type"] and alert_text.text(a) for a in full["alerts"] if a["type"] in A.COST_TYPES))
check("config: AlertConfig lê claude_cost_diff_pct do config.toml (10) e recusa valor inválido", acfg.claude_cost_diff_pct == 10
      and A.AlertConfig.parse({"claude_cost_diff_pct": -1})[1] != [])

# ---------------------------------------------------------------- preço fixo e fonte oficial
raw = open(f"{root}/config/agent-studio/config.toml").read()
conf = tomllib.loads(raw)
sel = tomllib.load(open(f"{root}/config/select/models.toml", "rb"))
models = set()
for tab in [sel["default"], *sel["line"]]:
    models |= {tab[s["name"]] for s in sel["subscription"] if s["name"] in tab}
check("a tabela do seletor tem modelos das três assinaturas", {"claude-opus-5-5", "claude-sonnet-5-5", "glm-5.3", "gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"} <= models)
check("todo modelo da tabela do seletor tem preço com fixed = true", all(conf["prices"].get(m, {}).get("fixed") is True for m in models))
check("o config.toml cita as páginas oficiais das três fontes e a data da leitura (2026-10-08)",
      all(u in raw for u in ("https://platform.claude.com/docs/en/about-claude/pricing", "https://developers.openai.com/api/docs/pricing", "https://docs.z.ai/guides/overview/pricing")) and raw.count("2026-10-08") >= 3)
p = conf["prices"]
check("preços da página oficial: opus 5.5 4/20/0,20/5; sonnet 5.5 2/10/0,10/2,5", (p["claude-opus-5-5"]["input"], p["claude-opus-5-5"]["output"], p["claude-opus-5-5"]["cache_read"], p["claude-opus-5-5"]["cache_creation"]) == (4.0, 20.0, 0.2, 5.0)
      and (p["claude-sonnet-5-5"]["input"], p["claude-sonnet-5-5"]["output"], p["claude-sonnet-5-5"]["cache_read"], p["claude-sonnet-5-5"]["cache_creation"]) == (2.0, 10.0, 0.1, 2.5))
check("preços da página oficial: gpt-6-astra 10/50/1/12,5; gpt-6.1-sol 2/10/0,1/2,5; gpt-6-luna 0,1/0,5/0,01/0,125",
      all((p[m]["input"], p[m]["output"], p[m]["cache_read"], p[m]["cache_creation"]) == v for m, v in
          {"gpt-6-astra": (10.0, 50.0, 1.0, 12.5), "gpt-6.1-sol": (2.0, 10.0, 0.1, 2.5), "gpt-6-luna": (0.1, 0.5, 0.01, 0.125)}.items()))
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 30
check_end
