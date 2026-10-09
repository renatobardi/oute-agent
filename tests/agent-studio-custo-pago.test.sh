#!/usr/bin/env bash
# Testes do controle de custo do agent-studio (#531, épico #522): "custo de lista | custo pago" no Dashboard, Uso, Conversas
# e Sessões. Padrão = custo de lista; no pago, a chamada de assinatura (`oute.agent` = claude ou codex) conta 0 e a paga por
# uso mantém o custo; a escolha fica na URL e vai nos links entre telas; chamadas, tokens, latência e erros não mudam; a tela
# diz que a assinatura conta 0; o `GET /v1/usage` devolve o mesmo. Chama o app pelo ASGI (tests/lib/studio_asgi.py) sobre um
# DuckDB de exemplo com uma conversa de assinatura de cada agente e duas pagas por uso; sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-custo-pago.test.sh   (sai != 0 se algum caso falhar)
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
EF = Q + "&custo=pago"
tok = dict(input=1000, output=100)   # sonnet: US$ 0,0045 estimado por chamada

# Sessão T-mix mistura assinatura e pago por uso:
#   claude (assinatura): custo informado US$ 1,00; codex (assinatura): sem custo, custo de lista calculado US$ 0,0045 (#747);
#   ai-memory (pago por uso): custo informado US$ 0,25 e outra chamada sem custo, estimada US$ 0,0045 (única estimada).
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
    m = re.search(r'id="total" data-calls="(\d+)" data-real-usd="([^"]*)" data-estimated-usd="([^"]*)" data-listed-usd="([^"]*)"', h)
    return int(m.group(1)), (float(m.group(2)) if m.group(2) else None), (float(m.group(3)) if m.group(3) else None), (float(m.group(4)) if m.group(4) else None)

def row(h, attr, ident):
    m = re.search(rf'<tr[^>]*data-{attr}="{re.escape(ident)}"[^>]*>', h)
    return dict(re.findall(r'data-([a-z0-9-]+)="([^"]*)"', m.group(0))) if m else None

def fl(v):
    return float(v) if v not in (None, "") else None

def same(a, b):
    return a is not None and b is not None and abs(a - b) < 1e-9

PAGES = ("/", "/conversas", "/sessoes", "/uso")
NOTE = "data-custo-pago"

def select_custo(h):
    m = re.search(r'<select name="custo">(.*?)</select>', h, re.S)
    return re.findall(r'<option value="([^"]*)"( selected)?>([^<]*)</option>', m.group(1)) if m else None

# ---- o controle nas quatro telas, custo de lista por padrão
for p in PAGES:
    st, h = get(app, p, Q)
    check(f"{p}: 200 e o controle 'custo de lista | custo pago', com o custo de lista marcado por padrão",
          st == 200 and select_custo(h) == [("lista", " selected", "custo de lista"), ("pago", "", "custo pago")])
    check(f"{p}: sem a escolha na URL, nenhum aviso de custo pago", NOTE not in h)
    he = get(app, p, EF)[1]
    check(f"{p}: com custo=pago, o controle marca o pago e a tela diz que o custo pago é a mensalidade rateada",
          select_custo(he) == [("lista", "", "custo de lista"), ("pago", " selected", "custo pago")]
          and NOTE in he and "mensalidade do plano de cada assinatura, rateada pelo uso" in he)
    check(f"{p}: valor desconhecido de custo = custo de lista", get(app, p, Q + "&custo=xyz")[1] == get(app, p, Q)[1]
          or re.sub(r'<p class="nota janela".*?</p>', "", get(app, p, Q + "&custo=xyz")[1], flags=re.S)
          == re.sub(r'<p class="nota janela".*?</p>', "", get(app, p, Q)[1], flags=re.S))
check("Ferramentas não tem o controle (não mostra custo), mas leva a escolha adiante",
      select_custo(get(app, "/ferramentas", EF)[1]) is None and '<input type="hidden" name="custo" value="pago">' in get(app, "/ferramentas", EF)[1]
      and "custo=pago" in get(app, "/ferramentas", EF)[1] and "custo=pago" not in get(app, "/ferramentas", Q)[1])

# ---- custo de lista = os números de hoje; pago = assinatura 0 e o resto igual
# lista: informado 1,25 (1,00 do claude + 0,25 do ai-memory), de lista 0,0045 (codex sem custo) e estimado 0,0045 (só o ai-memory sem custo)
n, real, est, listed = total(get(app, "/uso", Q)[1])
check("Uso, lista: 4 chamadas, informado US$ 1,25, de lista US$ 0,0045 (codex) e estimado US$ 0,0045 (ai-memory)",
      n == 4 and same(real, 1.25) and same(listed, 0.0045) and same(est, 0.0045))
n2, real2, est2, listed2 = total(get(app, "/uso", EF)[1])
check("Uso, pago: as mesmas 4 chamadas; informado US$ 0,25 (só o ai-memory), sem custo de lista e estimado US$ 0,0045 (só o ai-memory sem custo)",
      n2 == 4 and same(real2, 0.25) and listed2 is None and same(est2, 0.0045))
check("Dashboard: o KPI de custo vai de US$ 1,259 (lista) a US$ 0,2545 (pago)", same(kpi_cost(get(app, "/", Q)[1]), 1.259) and same(kpi_cost(get(app, "/", EF)[1]), 0.2545))
dl, de = get(app, "/", Q)[1], get(app, "/", EF)[1]
check("Dashboard: o rótulo do KPI diz lista ou pago", 'Custo (lista)' in dl and 'Custo (pago)' in de and 'Custo (pago)' not in dl)
check("Dashboard, de novo em lista depois do pago (o cache não mistura os dois)", same(kpi_cost(get(app, "/", Q)[1]), 1.259))
check("Dashboard, pago: as barras de custo por modelo somam o pago (informado 0,25, estimado 0,0045)",
      re.search(r'data-composicao data-real-usd="([^"]*)" data-listed-usd="([^"]*)" data-estimated-usd="([^"]*)"', de).groups() == ("0.25", "", "0.0045")
      and re.search(r'data-composicao data-real-usd="([^"]*)" data-listed-usd="([^"]*)" data-estimated-usd="([^"]*)"', dl).groups() == ("1.25", "0.0045", "0.0045"))

def kpis(h):
    return {k: re.search(rf'<div class="kpi" data-kpi="{k}" data-value="([^"]*)"', h).group(1) for k in ("calls", "p95", "errors", "cache")}
check("Dashboard: chamadas, p95, erros e cache não mudam com o controle", kpis(dl) == kpis(de))

# conversas: cada uma com o custo dela; chamadas, tokens, p95 e erros iguais
cl, ce = get(app, "/conversas", Q)[1], get(app, "/conversas", EF)[1]
exp = {"c-cl": (1.0, None, None), "c-cx": (None, 0.0045, None), "c-ai": (0.25, None, 0.0045)}
exp_ef = {"c-cl": (0.0, None, None), "c-cx": (0.0, None, None), "c-ai": (0.25, None, 0.0045)}
def cost_of(h, c):
    r = row(h, "conversa", c)
    return fl(r["real-usd"]), fl(r["listed-usd"]), fl(r["estimated-usd"])
check("Conversas, lista: o custo de cada conversa é o de hoje", all(cost_of(cl, c) == exp[c] for c in exp))
check("Conversas, pago: claude e codex = 0; ai-memory mantém o custo", all(cost_of(ce, c) == exp_ef[c] for c in exp_ef))
def stable(h, c):
    r = row(h, "conversa", c)
    return {k: r[k] for k in ("calls", "input", "output", "cache-read", "cache-creation", "errors")}
check("Conversas: chamadas, tokens e erros iguais nos dois custos", all(stable(cl, c) == stable(ce, c) for c in exp) and stable(cl, "c-cl")["errors"] == "1")

# sessões
sl, se = get(app, "/sessoes", Q)[1], get(app, "/sessoes", EF)[1]
check("Sessões, lista: T-mix = informado 1,00 e de lista 0,0045 (sem estimado); T-ai = 0,25 e estimado 0,0045",
      same(fl(row(sl, "sessao", "T-mix")["real-usd"]), 1.0) and same(fl(row(sl, "sessao", "T-mix")["listed-usd"]), 0.0045)
      and row(sl, "sessao", "T-mix")["estimated-usd"] == ""
      and same(fl(row(sl, "sessao", "T-ai")["real-usd"]), 0.25) and same(fl(row(sl, "sessao", "T-ai")["estimated-usd"]), 0.0045))
check("Sessões, pago: T-mix (só assinatura) = 0 e sem estimativa; T-ai mantém o custo",
      fl(row(se, "sessao", "T-mix")["real-usd"]) == 0.0 and row(se, "sessao", "T-mix")["estimated-usd"] == "" and row(se, "sessao", "T-mix")["listed-usd"] == ""
      and same(fl(row(se, "sessao", "T-ai")["real-usd"]), 0.25) and same(fl(row(se, "sessao", "T-ai")["estimated-usd"]), 0.0045))
check("Sessões: chamadas, tokens, p95 e erros iguais nos dois custos",
      all({k: row(sl, "sessao", s)[k] for k in ("calls", "input", "output", "p95-ms", "errors")}
          == {k: row(se, "sessao", s)[k] for k in ("calls", "input", "output", "p95-ms", "errors")} for s in ("T-mix", "T-ai")))

# detalhe da conversa e da sessão: a chamada de assinatura custa 0 na linha de cada span
cdl, cde = get(app, "/conversa", "id=c-cx")[1], get(app, "/conversa", "id=c-cx&custo=pago")[1]
check("Conversa de assinatura: lista = custo de lista; pago = US$ 0 e o resumo zerado",
      'data-cost-kind="listed"' in cdl and 'data-cost-kind="estimated"' not in cdl and 'data-cost-kind="noplan"' in cde and 'data-cost="0.0"' in cde and NOTE in cde and NOTE not in cdl)
adl, ade = get(app, "/conversa", "id=c-ai&custo=pago")[1], get(app, "/conversa", "id=c-ai")[1]
check("Conversa paga por uso: o custo do span é o mesmo nos dois", re.findall(r'data-cost-kind="[^"]*"\s+data-cost="[^"]*"', adl) == re.findall(r'data-cost-kind="[^"]*"\s+data-cost="[^"]*"', ade))
sdl, sde = get(app, "/sessao", "id=T-mix")[1], get(app, "/sessao", "id=T-mix&custo=pago")[1]
check("Sessão: o resumo de custo segue o controle (lista 1,00; pago 0)",
      same(fl(re.search(r'data-resumo[^>]*data-real-usd="([^"]*)"', sdl).group(1)), 1.0) and fl(re.search(r'data-resumo[^>]*data-real-usd="([^"]*)"', sde).group(1)) == 0.0
      and NOTE in sde)

# ---- a escolha na URL e nos links entre telas
def links(h):
    return re.findall(r'href="([^"]*)"', h)

for p in PAGES:
    he = get(app, p, EF)[1]
    nav = [l for l in links(he) if l.split("?")[0] in ("/", "/conversas", "/sessoes", "/uso", "/ferramentas", "/precos", "/pedidos", "/rodadas")]
    check(f"{p}: com custo=pago, os links do menu e das janelas levam a escolha",
          len(nav) >= 8 and all("custo=pago" in l for l in nav))
    check(f"{p}: em custo de lista, nenhum link leva custo=", not any("custo=" in l for l in links(get(app, p, Q)[1])))
check("Conversas e Sessões: os links para o detalhe e para os erros levam a escolha",
      all("custo=pago" in l for l in links(ce) if l.startswith("/conversa?"))
      and all("custo=pago" in l for l in links(se) if l.startswith("/sessao?") or l.startswith("/conversa?")))
check("Dashboard: os links 'ver Uso' e das sessões levam a escolha, e os insights também",
      all("custo=pago" in l for l in links(de) if l.startswith(("/uso?", "/sessoes?", "/sessao?", "/ferramentas?", "/ferramenta?"))))
check("Dashboard: o formulário do modelo leva a escolha", '<input type="hidden" name="custo" value="pago">' in de and 'name="custo" value' not in dl)
check("Detalhe: o 'voltar' e a trilha levam a escolha", all("custo=pago" in l for l in links(cde) if l.split("?")[0] in ("/conversas",))
      and all("custo=pago" in l for l in links(sde) if l.split("?")[0] == "/sessoes"))

# o formulário como o navegador envia: escolher "custo pago" no controle devolve a tela no custo pago
for p in PAGES:
    (st, h), sent = form_submit(get, app, p, Q, custo="pago")
    check(f"{p}: o formulário enviado com 'custo pago' manda custo=pago e a tela vem no pago",
          st == 200 and ("custo", "pago") in sent and NOTE in h)
    (st, h), sent = form_submit(get, app, p, EF)
    check(f"{p}: o formulário enviado sem mexer mantém o custo pago", st == 200 and ("custo", "pago") in sent and NOTE in h)
    (st, h), sent = form_submit(get, app, p, EF, custo="lista")
    check(f"{p}: voltar a 'custo de lista' pelo formulário", st == 200 and ("custo", "lista") in sent and NOTE not in h)

# ---- rótulos: informado pela fonte, estimado e pago; "real" não designa preço de lista
for p in PAGES:
    for q, nome in ((Q, "lista"), (EF, "pago")):
        h = get(app, p, q)[1]
        visible = re.sub(r"<[^>]+>", " ", re.sub(r"<(script|style)\b.*?</\1>", "", h, flags=re.S))
        titles = " ".join(re.findall(r'title="([^"]*)"', h))
        check(f"{p} ({nome}): nenhum 'real' como rótulo de custo na tela nem nas dicas", not re.search(r"\b[Rr]eal\b", visible + " " + titles))
check("Uso: a legenda diz 'Custo de lista' (lista) ou 'Pago (mensalidade rateada)' e 'Estimado'",
      "Custo de lista" in get(app, "/uso", Q)[1] and "Pago (mensalidade rateada)" in get(app, "/uso", EF)[1]
      and "Estimado ≈" in get(app, "/uso", EF)[1])
check("Dashboard: a composição diz 'Custo de lista' (lista) ou 'Pago' (pago)", "Custo de lista US$" in dl and "Pago US$" in de)

# ---- assinatura com modelo sem preço: no pago custa 0 (não vira "sem preço"); na lista segue "sem preço"; a paga por uso segue sem preço
db2 = StudioDB(tmp, "np")
db2.span(ts(f"{D}10:00:00"), 2, model="modelo-sem-preco", task="T-np", conv="c-np", agent="codex", name="session_task.turn", **tok)
db2.span(ts(f"{D}10:10:00"), 2, model="modelo-sem-preco", task="T-np2", conv="c-np2", agent="ai-memory", name="ai_memory.llm_request", **tok)
app2 = create_app(db2.flush(), TOKEN, config=cfg)
u2l, u2e = (json.loads(get(app2, "/v1/usage", Q)[1])["totals"]["cost"], None)
check("modelo sem preço, lista: as 2 chamadas ficam em 'sem preço' (API)", u2l["unpriced_calls"] == 2 and u2l["real_usd"] is None and u2l["estimated_usd"] is None)
r_l, r_e = row(get(app2, "/sessoes", Q)[1], "sessao", "T-np"), row(get(app2, "/sessoes", EF)[1], "sessao", "T-np")
check("modelo sem preço, sessão de assinatura: lista = sem preço; pago = US$ 0",
      r_l["unpriced-calls"] == "1" and r_l["real-usd"] == "" and r_e["unpriced-calls"] == "0" and r_e["real-usd"] == "0.0")
check("modelo sem preço, paga por uso: segue 'sem preço' no pago", row(get(app2, "/sessoes", EF)[1], "sessao", "T-np2")["unpriced-calls"] == "1")

# ---- a API não muda: o `GET /v1/usage` ignora a escolha e traz o custo de lista
ul = json.loads(get(app, "/v1/usage", Q)[1])
ue = json.loads(get(app, "/v1/usage", EF)[1])
check("GET /v1/usage: igual com e sem custo=pago, e com o custo de lista (real 1,25, de lista 0,0045, estimado 0,0045)",
      ul == ue and same(ul["totals"]["cost"]["real_usd"], 1.25) and same(ul["totals"]["cost"]["listed_usd"], 0.0045)
      and same(ul["totals"]["cost"]["estimated_usd"], 0.0045))
c_ul = ul["totals"]["cost"]
check("GET /v1/usage: as chamadas se conservam (informadas + de lista + estimadas + sem preço = chamadas) e só o ai-memory é estimado",
      c_ul["real_calls"] + c_ul["listed_calls"] + c_ul["estimated_calls"] + c_ul["unpriced_calls"] == ul["totals"]["calls"]
      and (c_ul["real_calls"], c_ul["listed_calls"], c_ul["estimated_calls"], c_ul["unpriced_calls"]) == (2, 1, 1, 0)
      and c_ul["claude_no_log_calls"] == 0)

# ---- #591: o controle se chama "custo pago"; "custo efetivo" não nomeia mais o controle
OLD = Q + "&custo=" + "efe" + "tivo"
for p in ("/", "/uso", "/conversas", "/sessoes"):
    hl, hp, ho = get(app, p, Q)[1], get(app, p, EF)[1], get(app, p, OLD)[1]
    check(f"{p}: a tela não escreve 'efetivo' em nenhum dos dois modos", not re.search("efetiv", hl + hp, re.I) and NOTE in hp)
    check(f"{p}: o valor antigo do controle na URL não é o custo pago (vale o custo de lista)",
          NOTE not in ho and select_custo(ho) == [("lista", " selected", "custo de lista"), ("pago", "", "custo pago")])
check("Conversa: o detalhe no custo pago não escreve 'efetivo'", NOTE in cde and not re.search("efetiv", cde, re.I))
check("Sessão: o detalhe no custo pago não escreve 'efetivo'", NOTE in sde and not re.search("efetiv", sde, re.I))
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 82
check "a regra de assinatura mora só no cost.py (nenhum outro módulo lista os agentes)" \
  bash -c '! grep -ln "SUBSCRIPTION_AGENTS\|\"claude\", \"codex\"" "$1"/docker/agent-studio/agent_studio/*.py | grep -v -e "/cost.py" -e "/prices.py" | grep -q .' _ "$ROOT"
# #591: "custo efetivo" tem um sentido só (o custo do span ou do log `api_request`); o controle é o "custo pago"
SENSE=(docker/agent-studio docs/adr/0008-agent-studio.md CONTEXT.md)
check "código, ADR-08 e CONTEXT.md: toda linha com 'efetivo' fala do span, do log api_request ou do spans_with_cost" \
  bash -c 'cd "$1" && shift && ! git grep -n -i -e "efetiv" -- "$@" | grep -v -e "api_request" -e "spans_with_cost" | grep -q .' _ "$ROOT" "${SENSE[@]}"
check "código, ADR-08 e CONTEXT.md: 'custo efetivo' segue definido (o sentido do span não saiu)" \
  bash -c 'cd "$1" && shift && for f in "$@"; do git grep -q -i -e "custo efetivo" -- "$f" || exit 1; done' _ "$ROOT" docker/agent-studio/agent_studio/cost.py docs/adr/0008-agent-studio.md CONTEXT.md
check "código do agent-studio: nenhum 'effective' (o parâmetro do controle é paid)" \
  bash -c 'cd "$1" && ! git grep -q -i -e "effective" -- docker/agent-studio' _ "$ROOT"
check "ADR-08 e CONTEXT.md definem o custo pago" \
  bash -c 'cd "$1" && git grep -q -e "custo pago" -- docs/adr/0008-agent-studio.md && git grep -q -e "custo pago" -- CONTEXT.md' _ "$ROOT"
check_end
