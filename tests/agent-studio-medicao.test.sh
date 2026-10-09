#!/usr/bin/env bash
# Testes da medição por sessão no agent-studio (#751, ADR-08 adendo "Medição por sessão"): o revisor das etapas como papel próprio,
# a quebra papel × modelo e papel × fase (na tela de Uso e no `GET /v1/usage`), a parte do custo que é saída × entrada + cache, e as
# sessões e conversas mais caras com o contexto por chamada (média e máximo). Chama o app pelo ASGI sobre um DuckDB de exemplo; os
# filtros da tela são enviados com o `studio_form.py`, como o navegador envia. Sem servidor, sem rede e sem Docker. As datas ficam
# depois de 2026-10-06 (o corte do #617).
# Uso: tests/agent-studio-medicao.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" "$ROOT" > "$TMP/py.out" 2>&1 <<'PY'
import json, re, sys
from datetime import datetime, timezone

from agent_studio import config as CF, usage as US
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB
from studio_form import submit as form_submit

tmp, root = sys.argv[1], sys.argv[2]
cfg = CF.load(f"{root}/config/agent-studio/config.toml")
prices = cfg.prices
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-11-01T"
FROM, TO = ts("2026-11-01T00:00:00"), ts("2026-11-02T00:00:00")
Q = "from=2026-11-01T00%3A00%3A00Z&to=2026-11-02T00%3A00%3A00Z"
near = lambda a, b: a is not None and abs(a - b) < 1e-9
PRICE = {"claude-sonnet-5": (2.0, 10.0, 0.2, 2.5), "claude-opus-5-5": (4.0, 20.0, 0.2, 5.0)}   # o config.toml do repo


def lst(model, i, o, cr, cc=0):
    p = PRICE[model]
    return (i * p[0] + o * p[1] + cr * p[2] + cc * p[3]) / 1e6


def outp(model, o):
    return o * PRICE[model][1] / 1e6


# ---------------------------------------------------------------- o banco de exemplo
# dispatcher (sessão t-disp, rodada r1), worker (t-wk, com oute.swarm.session), revisor das etapas (conversa c-rev: leva o oute.task.id
# do dispatcher e o oute.swarm.step no resource) e uma sessão avulsa (t-solo); mais uma conversa sem sessão. Cada chamada leva
# (entrada, saída, cache lido); o contexto da chamada é entrada + cache lido.
db = StudioDB(tmp, "m")
S, O = "claude-sonnet-5", "claude-opus-5-5"
WK = {"oute.swarm.session": "s1"}
calls = [  # (hora, conversa, sessão, rodada, resource, modelo, entrada, saída, cache lido)
    ("10:00:00", "c-disp", "t-disp", "r1", None, S, 100, 50, 900),
    ("10:01:00", "c-disp", "t-disp", "r1", None, S, 200, 100, 1800),
    ("10:10:00", "c-wk", "t-wk", "r1", WK, O, 1000, 500, 0),
    ("10:11:00", "c-wk", "t-wk", "r1", WK, S, 1000, 0, 4000),
    ("10:20:00", "c-rev", "t-disp", "r1", {"oute.swarm.step": "triagem"}, O, 5000, 1000, 0),
    ("10:30:00", "c-solo", "t-solo", None, None, S, 10, 10, 0),
    ("10:40:00", "c-nt", None, None, None, S, 100, 100, 0),
]
for at, conv, task, rnd, res, model, i, o, cr in calls:
    db.span(ts(D + at), 2, model=model, conv=conv, task=task, rnd=rnd, res=res, agent="claude", sub="claude", input=i, output=o, cache_read=cr)
db.log(ts(D + "09:59:00"), "oute.task.opened", {"oute.task.phase": "plan"}, task="t-disp", rnd="r1")
db.log(ts(D + "10:09:00"), "oute.task.opened", {"oute.task.phase": "build", "oute.swarm.session": "s1"}, task="t-wk", rnd="r1")
db.log(ts(D + "10:29:00"), "oute.task.opened", {"oute.task.phase": "ops"}, task="t-solo")
st = db.flush()

u = st.usage(FROM, TO, prices)
role = {r["role"]: r for r in u["by_role"]}
check("papel: o revisor das etapas é um papel próprio, ao lado de dispatcher, worker e standalone", set(role) == {"dispatcher", "worker", "reviewer", "standalone"})
check("papel: o revisor tem a única chamada dele; o dispatcher fica com as duas (a chamada do revisor, que leva o oute.task.id do dispatcher, não conta nele)",
      role["reviewer"]["calls"] == 1 and role["dispatcher"]["calls"] == 2 and role["worker"]["calls"] == 2 and role["standalone"]["calls"] == 2)
check("papel: o custo de lista do revisor é o do opus (5000 entrada + 1000 saída)", near(role["reviewer"]["cost"]["listed_usd"], lst(O, 5000, 1000, 0)))
check("papel: as linhas somam o total da janela", sum(r["calls"] for r in u["by_role"]) == u["totals"]["calls"] == 7)

# ---- papel × modelo e papel × fase
rm = {(r["role"], r["model"]): r for r in u["by_role_model"]}
check("papel × modelo: as cinco combinações", set(rm) == {("dispatcher", S), ("worker", O), ("worker", S), ("reviewer", O), ("standalone", S)})
check("papel × modelo: o revisor é opus e o worker tem os dois modelos", rm[("reviewer", O)]["calls"] == 1 and rm[("worker", O)]["calls"] == 1 and rm[("worker", S)]["calls"] == 1)
check("papel × modelo: soma as chamadas e o custo do total", sum(r["calls"] for r in u["by_role_model"]) == 7
      and near(sum(r["cost"]["listed_usd"] for r in u["by_role_model"]), u["totals"]["cost"]["listed_usd"]))
rp = {(r["role"], r["phase"]): r for r in u["by_role_phase"]}
check("papel × fase: dispatcher plan, worker build, avulso ops (a da abertura) e a conversa sem sessão build; o revisor aparece com a fase que o phase.py lhe deu",
      {k for k in rp if k[0] != "reviewer"} == {("dispatcher", "plan"), ("worker", "build"), ("standalone", "ops"), ("standalone", "build")}
      and len([k for k in rp if k[0] == "reviewer"]) == 1 and rp[next(k for k in rp if k[0] == "reviewer")]["calls"] == 1)
check("papel × fase: soma as chamadas do total", sum(r["calls"] for r in u["by_role_phase"]) == 7)

# ---- a parte do custo que é saída
exp_out = {"dispatcher": outp(S, 150), "worker": outp(O, 500), "reviewer": outp(O, 1000), "standalone": outp(S, 110)}
check("saída × entrada + cache: a saída de cada papel é o preço de lista dos tokens de saída", all(near(role[k]["cost"]["output_usd"], v) for k, v in exp_out.items()))
exp_all = {"dispatcher": lst(S, 300, 150, 2700), "worker": lst(O, 1000, 500, 0) + lst(S, 1000, 0, 4000), "reviewer": lst(O, 5000, 1000, 0), "standalone": lst(S, 110, 110, 0)}
check("saída × entrada + cache: as duas partes somam o custo de lista", all(near(role[k]["cost"]["output_usd"] + role[k]["cost"]["input_cache_usd"], v) for k, v in exp_all.items()))
check("saída × entrada + cache: o total é a soma dos papéis, sem chamada fora do preço", near(u["totals"]["cost"]["output_usd"], sum(exp_out.values()))
      and u["totals"]["cost"]["split_unpriced_calls"] == 0)

# ---- as sessões e as conversas mais caras
ts_ = {r["session"]: r for r in u["top_sessions"]}
check("sessões mais caras: as quatro sessões, a conversa sem sessão fica de fora", set(ts_) == {"t-disp", "t-wk", "t-solo"})
cost_of = lambda r: r["cost"]["listed_usd"]
check("sessões mais caras: ordenadas do maior para o menor custo", [cost_of(r) for r in u["top_sessions"]] == sorted((cost_of(r) for r in u["top_sessions"]), reverse=True))
d = ts_["t-disp"]
check("sessão t-disp: 3 chamadas (as duas do dispatcher e a do revisor), tokens e custo", d["calls"] == 3 and d["tokens"] == {"input": 5300, "output": 1150, "cache_read": 2700, "cache_creation": 0}
      and near(d["cost"]["listed_usd"], exp_all["dispatcher"] + exp_all["reviewer"]))
check("sessão t-disp: contexto por chamada = entrada + cache lido; média de 1000, 2000 e 5000 e máximo 5000", d["context"] == {"avg": round((1000 + 2000 + 5000) / 3, 1), "max": 5000})
check("sessão t-wk: contexto médio 3000, máximo 5000", ts_["t-wk"]["context"] == {"avg": 3000.0, "max": 5000})
tc = {r["conversation"]: r for r in u["top_conversations"]}
check("conversas mais caras: as cinco, com a sem sessão", set(tc) == {"c-disp", "c-wk", "c-rev", "c-solo", "c-nt"})
check("conversa c-disp: 2 chamadas, contexto médio 1500 e máximo 2000", tc["c-disp"]["calls"] == 2 and tc["c-disp"]["context"] == {"avg": 1500.0, "max": 2000})
check("conversa c-rev: 1 chamada, contexto 5000 nos dois", tc["c-rev"]["context"] == {"avg": 5000.0, "max": 5000})
check("conversa c-solo: cache zero, contexto = a entrada", tc["c-solo"]["context"] == {"avg": 10.0, "max": 10})
check("conversas mais caras: o custo e a saída da conversa saem do mesmo aggregate", near(tc["c-wk"]["cost"]["output_usd"], outp(O, 500)))

# ---- o filtro vale para as listas e para as quebras
codex = StudioDB(tmp, "m2")
codex.span(ts(D + "11:00:00"), 2, name="session_task.turn", model="gpt-9-sem-preco", conv="c-cx", task="t-cx", agent="codex", sub="codex", input=1000, output=100)
codex.span(ts(D + "11:10:00"), 2, model=S, conv="c-ar", task="t-ar", agent="claude", sub="claude", input=7, output=7, cache_read=3)
u2 = codex.flush().usage(FROM, TO, prices, sub="claude")
check("assinatura=claude: a lista só traz a sessão do claude", [r["session"] for r in u2["top_sessions"]] == ["t-ar"] and u2["top_sessions"][0]["context"] == {"avg": 10.0, "max": 10})
u3 = codex.st.usage(FROM, TO, prices, repo="nenhum-repo")
check("repositório sem fato: as listas e as quebras vêm vazias", u3["top_sessions"] == [] and u3["top_conversations"] == [] and u3["by_role_model"] == [])
check("modelo sem preço: as chamadas ficam fora das duas partes e são contadas", codex.st.usage(FROM, TO, prices)["totals"]["cost"]["split_unpriced_calls"] == 1)

# ---- a tela de Uso e a API
app = create_app(st, TOKEN, config=cfg)
row = lambda h, attr, val: re.search(rf'<tr data-{attr}="{val}"[^>]*>', h)
code, html = get(app, "/uso", Q)
check("/uso: 200 com as quatro tabelas novas", code == 200 and all(f'data-uso="{k}"' in html for k in ("papel-modelo", "papel-fase", "top-session", "top-conversation")))
check("/uso: o revisor é uma linha da tabela por papel", bool(row(html, "role", "reviewer")))
check("/uso: linha papel × modelo do revisor leva as chamadas e os dólares de saída e de entrada + cache",
      'data-par-papel="reviewer" data-par-modelo="claude-opus-5-5" data-calls="1"' in html and f'data-output-usd="{outp(O, 1000)}"' in html)
m = row(html, "session", "t-disp")
check("/uso: sessão t-disp com contexto médio e máximo e link para a sessão", bool(m) and 'data-context-avg="2666.7"' in m.group(0) and 'data-context-max="5000"' in m.group(0)
      and 'href="/sessao?id=t-disp"' in html)
check("/uso: conversa c-rev com link para a conversa", 'href="/conversa?id=c-rev"' in html and bool(row(html, "conversation", "c-rev")))
check("/uso: a coluna Saída mostra a parte (c-rev: US$ 0,02 de saída e US$ 0,02 de entrada = 50%)", "50%" in re.search(r'<tr data-conversation="c-rev".*?</tr>', html, re.S).group(0))
# o formulário do período enviado como o navegador envia: a janela, a ordem e o repositório seguem
(code2, html2), sent = form_submit(get, app, "/uso", Q + "&ord_topsessao=ctx_max&dir_topsessao=desc")
check("/uso: o envio do formulário mantém a ordem da tabela das sessões", code2 == 200 and ("ord_topsessao", "ctx_max") in sent and html2.index('data-session="t-disp"') < html2.index('data-session="t-solo"'))
code3, html3 = get(app, "/uso", Q + "&ord_topsessao=ctx_max&dir_topsessao=asc")
check("/uso: ordem por contexto máximo, do menor para o maior (t-solo antes de t-disp)", code3 == 200 and html3.index('data-session="t-solo"') < html3.index('data-session="t-disp"'))
check("/uso: coluna de ordem fora da lista = 400", get(app, "/uso", Q + "&ord_topsessao=sql")[0] == 400 and get(app, "/uso", Q + "&ord_papelmodelo=nope")[0] == 400)
(code4, html4), sent4 = form_submit(get, app, "/uso", Q, assinatura="codex")
check("/uso: filtro por assinatura enviado pelo formulário: sem a sessão do claude nas listas", code4 == 200 and 'data-session="t-disp"' not in html4)
code5, html5 = get(app, "/uso", Q + "&custo=pago")
check("/uso: custo pago responde 200 e traz as listas", code5 == 200 and 'data-session="t-disp"' in html5 and "sem uso" not in re.search(r'data-uso="top-session".*?</table>', html5, re.S).group(0))
code6, body = get(app, "/v1/usage", Q)
api = json.loads(body)
check("/v1/usage: by_role_model, by_role_phase, top_sessions e top_conversations", code6 == 200 and all(k in api for k in ("by_role_model", "by_role_phase", "top_sessions", "top_conversations")))
check("/v1/usage: o revisor das etapas em by_role e a parte de saída no custo", any(r["role"] == "reviewer" for r in api["by_role"]) and near(api["totals"]["cost"]["output_usd"], sum(exp_out.values())))
check("/v1/usage: a lista de sessões traz o contexto", api["top_sessions"][0]["context"]["max"] > 0)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 39
check_end
