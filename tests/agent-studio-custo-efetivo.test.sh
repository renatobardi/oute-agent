#!/usr/bin/env bash
# Testes do controle de custo do agent-studio (#531, épico #522): "custo de lista | custo efetivo" no Dashboard, Uso, Conversas
# e Sessões. Padrão = custo de lista; no efetivo, a chamada de assinatura (`oute.agent` = claude ou codex) conta 0 e a paga por
# uso mantém o custo; a escolha fica na URL e vai nos links entre telas; chamadas, tokens, latência e erros não mudam; a tela
# diz que a assinatura conta 0; o `GET /v1/usage` devolve o mesmo. Chama o app pelo ASGI (tests/lib/studio_asgi.py) sobre um
# DuckDB de exemplo com uma conversa de assinatura de cada agente e duas pagas por uso; sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-custo-efetivo.test.sh   (sai != 0 se algum caso falhar)
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
import json, re, sys
from datetime import datetime, timezone

from agent_studio import config as CF
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB
from studio_form import submit as form_submit

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2025-10-01T"
Q = "from=2025-10-01T00%3A00%3A00Z&to=2025-10-02T00%3A00%3A00Z"
EF = Q + "&custo=efetivo"
tok = dict(input=1000, output=100)   # sonnet: US$ 0,0045 estimado por chamada

# Sessão T-mix mistura assinatura e pago por uso:
#   claude (assinatura): custo informado US$ 1,00; codex (assinatura): sem custo, estimado US$ 0,0045;
#   ai-memory (pago por uso): custo informado US$ 0,25 e outra chamada sem custo, estimada US$ 0,0045.
db = StudioDB(tmp, "c")
db.span(ts(f"{D}10:00:00"), 2, model="claude-sonnet-5", task="T-mix", conv="c-cl", repo="alfa", agent="claude", cost_usd=1.0, **tok)
db.span(ts(f"{D}10:10:00"), 3, model="claude-sonnet-5", task="T-mix", conv="c-cx", repo="alfa", agent="codex", name="session_task.turn", **tok)
db.span(ts(f"{D}10:20:00"), 1, model="claude-sonnet-5", task="T-ai", conv="c-ai", repo="alfa", agent="ai-memory", name="ai_memory.llm_request", cost_usd=0.25, **tok)
db.span(ts(f"{D}10:30:00"), 1, model="claude-sonnet-5", task="T-ai", conv="c-ai", repo="alfa", agent="ai-memory", name="ai_memory.llm_request", **tok)
db.span(ts(f"{D}10:40:00"), 1, name="claude_code.tool", task="T-mix", conv="c-cl", repo="alfa", agent="claude", err=True, attrs={"tool_name": "Read"})
app = create_app(db.flush(), TOKEN, config=cfg)

def num(m):
    return None if m is None or m.group(1) == "" else float(m.group(1))

def kpi_cost(h):
    return num(re.search(r'data-kpi="cost" data-value="([^"]*)"', h))

def total(h):
    m = re.search(r'id="total" data-calls="(\d+)" data-real-usd="([^"]*)" data-estimated-usd="([^"]*)"', h)
    return int(m.group(1)), (float(m.group(2)) if m.group(2) else None), (float(m.group(3)) if m.group(3) else None)

def row(h, attr, ident):
    m = re.search(rf'<tr[^>]*data-{attr}="{re.escape(ident)}"[^>]*>', h)
    return dict(re.findall(r'data-([a-z0-9-]+)="([^"]*)"', m.group(0))) if m else None

def fl(v):
    return float(v) if v not in (None, "") else None

def same(a, b):
    return a is not None and b is not None and abs(a - b) < 1e-9

PAGES = ("/", "/conversas", "/sessoes", "/uso")
NOTE = "data-custo-efetivo"

def select_custo(h):
    m = re.search(r'<select name="custo">(.*?)</select>', h, re.S)
    return re.findall(r'<option value="([^"]*)"( selected)?>([^<]*)</option>', m.group(1)) if m else None

# ---- o controle nas quatro telas, custo de lista por padrão
for p in PAGES:
    st, h = get(app, p, Q)
    check(f"{p}: 200 e o controle 'custo de lista | custo efetivo', com o custo de lista marcado por padrão",
          st == 200 and select_custo(h) == [("lista", " selected", "custo de lista"), ("efetivo", "", "custo efetivo")])
    check(f"{p}: sem a escolha na URL, nenhum aviso de custo efetivo", NOTE not in h)
    he = get(app, p, EF)[1]
    check(f"{p}: com custo=efetivo, o controle marca o efetivo e a tela diz que as assinaturas contam como 0",
          select_custo(he) == [("lista", "", "custo de lista"), ("efetivo", " selected", "custo efetivo")]
          and NOTE in he and "as assinaturas (chamadas do claude e do codex) contam como 0" in he)
    check(f"{p}: valor desconhecido de custo = custo de lista", get(app, p, Q + "&custo=xyz")[1] == get(app, p, Q)[1]
          or re.sub(r'<p class="nota janela".*?</p>', "", get(app, p, Q + "&custo=xyz")[1], flags=re.S)
          == re.sub(r'<p class="nota janela".*?</p>', "", get(app, p, Q)[1], flags=re.S))
check("Ferramentas não tem o controle (não mostra custo), mas leva a escolha adiante",
      select_custo(get(app, "/ferramentas", EF)[1]) is None and '<input type="hidden" name="custo" value="efetivo">' in get(app, "/ferramentas", EF)[1]
      and "custo=efetivo" in get(app, "/ferramentas", EF)[1] and "custo=efetivo" not in get(app, "/ferramentas", Q)[1])

# ---- custo de lista = os números de hoje; efetivo = assinatura 0 e o resto igual
# lista: real 1,25 (1,00 do claude + 0,25 do ai-memory), estimado 0,009 (codex + ai-memory sem custo)
n, real, est = total(get(app, "/uso", Q)[1])
check("Uso, lista: 4 chamadas, informado US$ 1,25 e estimado US$ 0,009", n == 4 and same(real, 1.25) and same(est, 0.009))
n2, real2, est2 = total(get(app, "/uso", EF)[1])
check("Uso, efetivo: as mesmas 4 chamadas; informado US$ 0,25 (só o ai-memory) e estimado US$ 0,0045 (só o ai-memory sem custo)",
      n2 == 4 and same(real2, 0.25) and same(est2, 0.0045))
check("Dashboard: o KPI de custo vai de US$ 1,259 (lista) a US$ 0,2545 (efetivo)", same(kpi_cost(get(app, "/", Q)[1]), 1.259) and same(kpi_cost(get(app, "/", EF)[1]), 0.2545))
dl, de = get(app, "/", Q)[1], get(app, "/", EF)[1]
check("Dashboard: o rótulo do KPI diz lista ou efetivo", 'Custo (lista)' in dl and 'Custo (efetivo)' in de and 'Custo (efetivo)' not in dl)
check("Dashboard, de novo em lista depois do efetivo (o cache não mistura os dois)", same(kpi_cost(get(app, "/", Q)[1]), 1.259))
check("Dashboard, efetivo: as barras de custo por modelo somam o efetivo (informado 0,25, estimado 0,0045)",
      re.search(r'data-composicao data-real-usd="([^"]*)" data-estimated-usd="([^"]*)"', de).groups() == ("0.25", "0.0045")
      and re.search(r'data-composicao data-real-usd="([^"]*)" data-estimated-usd="([^"]*)"', dl).groups() == ("1.25", "0.009"))

def kpis(h):
    return {k: re.search(rf'<div class="kpi" data-kpi="{k}" data-value="([^"]*)"', h).group(1) for k in ("calls", "p95", "errors", "cache")}
check("Dashboard: chamadas, p95, erros e cache não mudam com o controle", kpis(dl) == kpis(de))

# conversas: cada uma com o custo dela; chamadas, tokens, p95 e erros iguais
cl, ce = get(app, "/conversas", Q)[1], get(app, "/conversas", EF)[1]
exp = {"c-cl": (1.0, None), "c-cx": (None, 0.0045), "c-ai": (0.25, 0.0045)}
exp_ef = {"c-cl": (0.0, None), "c-cx": (0.0, None), "c-ai": (0.25, 0.0045)}
def cost_of(h, c):
    r = row(h, "conversa", c)
    return fl(r["real-usd"]), fl(r["estimated-usd"])
check("Conversas, lista: o custo de cada conversa é o de hoje", all(cost_of(cl, c) == exp[c] for c in exp))
check("Conversas, efetivo: claude e codex = 0; ai-memory mantém o custo", all(cost_of(ce, c) == exp_ef[c] for c in exp_ef))
def stable(h, c):
    r = row(h, "conversa", c)
    return {k: r[k] for k in ("calls", "input", "output", "cache-read", "cache-creation", "errors")}
check("Conversas: chamadas, tokens e erros iguais nos dois custos", all(stable(cl, c) == stable(ce, c) for c in exp) and stable(cl, "c-cl")["errors"] == "1")

# sessões
sl, se = get(app, "/sessoes", Q)[1], get(app, "/sessoes", EF)[1]
check("Sessões, lista: T-mix = informado 1,00 e estimado 0,0045; T-ai = 0,25 e 0,0045",
      same(fl(row(sl, "sessao", "T-mix")["real-usd"]), 1.0) and same(fl(row(sl, "sessao", "T-mix")["estimated-usd"]), 0.0045)
      and same(fl(row(sl, "sessao", "T-ai")["real-usd"]), 0.25))
check("Sessões, efetivo: T-mix (só assinatura) = 0 e sem estimativa; T-ai mantém o custo",
      fl(row(se, "sessao", "T-mix")["real-usd"]) == 0.0 and row(se, "sessao", "T-mix")["estimated-usd"] == ""
      and same(fl(row(se, "sessao", "T-ai")["real-usd"]), 0.25) and same(fl(row(se, "sessao", "T-ai")["estimated-usd"]), 0.0045))
check("Sessões: chamadas, tokens, p95 e erros iguais nos dois custos",
      all({k: row(sl, "sessao", s)[k] for k in ("calls", "input", "output", "p95-ms", "errors")}
          == {k: row(se, "sessao", s)[k] for k in ("calls", "input", "output", "p95-ms", "errors")} for s in ("T-mix", "T-ai")))

# detalhe da conversa e da sessão: a chamada de assinatura custa 0 na linha de cada span
cdl, cde = get(app, "/conversa", "id=c-cx")[1], get(app, "/conversa", "id=c-cx&custo=efetivo")[1]
check("Conversa de assinatura: lista = estimado; efetivo = US$ 0 e o resumo zerado",
      'data-cost-kind="estimated"' in cdl and 'data-cost-kind="effective"' in cde and 'data-cost="0.0"' in cde and NOTE in cde and NOTE not in cdl)
adl, ade = get(app, "/conversa", "id=c-ai&custo=efetivo")[1], get(app, "/conversa", "id=c-ai")[1]
check("Conversa paga por uso: o custo do span é o mesmo nos dois", re.findall(r'data-cost-kind="[^"]*"\s+data-cost="[^"]*"', adl) == re.findall(r'data-cost-kind="[^"]*"\s+data-cost="[^"]*"', ade))
sdl, sde = get(app, "/sessao", "id=T-mix")[1], get(app, "/sessao", "id=T-mix&custo=efetivo")[1]
check("Sessão: o resumo de custo segue o controle (lista 1,00; efetivo 0)",
      same(fl(re.search(r'data-resumo[^>]*data-real-usd="([^"]*)"', sdl).group(1)), 1.0) and fl(re.search(r'data-resumo[^>]*data-real-usd="([^"]*)"', sde).group(1)) == 0.0
      and NOTE in sde)

# ---- a escolha na URL e nos links entre telas
def links(h):
    return re.findall(r'href="([^"]*)"', h)

for p in PAGES:
    he = get(app, p, EF)[1]
    nav = [l for l in links(he) if l.split("?")[0] in ("/", "/conversas", "/sessoes", "/uso", "/ferramentas", "/precos", "/pedidos", "/rodadas")]
    check(f"{p}: com custo=efetivo, os links do menu e das janelas levam a escolha",
          len(nav) >= 8 and all("custo=efetivo" in l for l in nav))
    check(f"{p}: em custo de lista, nenhum link leva custo=", not any("custo=" in l for l in links(get(app, p, Q)[1])))
check("Conversas e Sessões: os links para o detalhe e para os erros levam a escolha",
      all("custo=efetivo" in l for l in links(ce) if l.startswith("/conversa?"))
      and all("custo=efetivo" in l for l in links(se) if l.startswith("/sessao?") or l.startswith("/conversa?")))
check("Dashboard: os links 'ver Uso' e das sessões levam a escolha, e os insights também",
      all("custo=efetivo" in l for l in links(de) if l.startswith(("/uso?", "/sessoes?", "/sessao?", "/ferramentas?", "/ferramenta?"))))
check("Dashboard: o formulário do modelo leva a escolha", '<input type="hidden" name="custo" value="efetivo">' in de and 'name="custo" value' not in dl)
check("Detalhe: o 'voltar' e a trilha levam a escolha", all("custo=efetivo" in l for l in links(cde) if l.split("?")[0] in ("/conversas",))
      and all("custo=efetivo" in l for l in links(sde) if l.split("?")[0] == "/sessoes"))

# o formulário como o navegador envia: escolher "custo efetivo" no controle devolve a tela no custo efetivo
for p in PAGES:
    (st, h), sent = form_submit(get, app, p, Q, custo="efetivo")
    check(f"{p}: o formulário enviado com 'custo efetivo' manda custo=efetivo e a tela vem no efetivo",
          st == 200 and ("custo", "efetivo") in sent and NOTE in h)
    (st, h), sent = form_submit(get, app, p, EF)
    check(f"{p}: o formulário enviado sem mexer mantém o custo efetivo", st == 200 and ("custo", "efetivo") in sent and NOTE in h)
    (st, h), sent = form_submit(get, app, p, EF, custo="lista")
    check(f"{p}: voltar a 'custo de lista' pelo formulário", st == 200 and ("custo", "lista") in sent and NOTE not in h)

# ---- rótulos: informado pela fonte, estimado e efetivo; "real" não designa preço de lista
for p in PAGES:
    for q, nome in ((Q, "lista"), (EF, "efetivo")):
        h = get(app, p, q)[1]
        visible = re.sub(r"<[^>]+>", " ", re.sub(r"<(script|style)\b.*?</\1>", "", h, flags=re.S))
        titles = " ".join(re.findall(r'title="([^"]*)"', h))
        check(f"{p} ({nome}): nenhum 'real' como rótulo de custo na tela nem nas dicas", not re.search(r"\b[Rr]eal\b", visible + " " + titles))
check("Uso: a legenda diz 'Informado pela fonte' (lista) ou 'Efetivo (assinatura = 0)' e 'Estimado'",
      "Informado pela fonte" in get(app, "/uso", Q)[1] and "Efetivo (assinatura = 0)" in get(app, "/uso", EF)[1]
      and "Estimado ≈" in get(app, "/uso", EF)[1])
check("Dashboard: a composição diz 'Informado pela fonte' (lista) ou 'Efetivo' (efetivo)", "Informado pela fonte US$" in dl and "Efetivo US$" in de)

# ---- a API não muda: o `GET /v1/usage` ignora a escolha e traz o custo de lista
ul = json.loads(get(app, "/v1/usage", Q)[1])
ue = json.loads(get(app, "/v1/usage", EF)[1])
check("GET /v1/usage: igual com e sem custo=efetivo, e com o custo de lista (real 1,25, estimado 0,009)",
      ul == ue and same(ul["totals"]["cost"]["real_usd"], 1.25) and same(ul["totals"]["cost"]["estimated_usd"], 0.009))
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 68
check "a regra de assinatura mora só no cost.py (nenhum outro módulo lista os agentes)" \
  bash -c '! grep -ln "SUBSCRIPTION_AGENTS\|\"claude\", \"codex\"" "$1"/docker/agent-studio/agent_studio/*.py | grep -v -e "/cost.py" -e "/prices.py" | grep -q .' _ "$ROOT"
check_end
