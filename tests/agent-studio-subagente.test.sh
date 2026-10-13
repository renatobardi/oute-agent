#!/usr/bin/env bash
# Testes do subagente visível no agent-studio (#832): a chamada de subagente (span com `query_source_safe` `agent.…` ou `agent_id`; log
# `api_request` com `query_source` `agent:…`) vira o papel `subagente` no Uso e no `GET /v1/usage` sem mudar o custo, a página da
# conversa mostra quantas chamadas e quanto custo vieram de subagente, e a página da rodada lista os eventos `oute.swarm.round.subagent`.
# Sem Docker. Horas fixas de 2026-11-01, com folga dos limites da janela.
# Uso: tests/agent-studio-subagente.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init
mkdir -p "$TMP/s"

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" "$ROOT" > "$TMP/py.out" 2>&1 <<'PY'
import hashlib, json, re, sys
from datetime import datetime, timezone

from agent_studio import config as CF, conversations as CV, etapas
from pycheck import check
from studio_db import StudioDB

tmp, root = sys.argv[1], sys.argv[2]
cfg = CF.load(f"{root}/config/agent-studio/config.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-11-01T"
FROM, TO = ts("2026-11-01T00:00:00"), ts("2026-11-02T00:00:00")
db = StudioDB(tmp, "a")


def call(conv, minute, cost, attrs=None, **kw):
    db.span(ts(f"{D}10:{minute:02d}:00"), 1, model="claude-sonnet-5", conv=conv, input=1000, output=100, cost_usd=cost, attrs=attrs, **kw)


# c-1: a chamada da sessão (0,10), três de subagente: pelo `query_source_safe` (0,20), só pelo `agent_id` (0,30) e só pelo log (0,40)
call("c-1", 1, 0.10, {"query_source_safe": "sdk"})
call("c-1", 2, 0.20, {"query_source_safe": "agent.builtin.general-purpose", "agent_id": "ag-1"})
call("c-1", 3, 0.30, {"agent_id": "ag-2"})
db.span(ts(f"{D}10:04:00"), 1, model="claude-sonnet-5", conv="c-1", input=1000, output=100, attrs={"request_id": "rq-log", "query_source_safe": "sdk"})
db.log(ts(f"{D}10:04:30"), "api_request", {"request_id": "rq-log", "cost_usd": "0.4", "query_source": "agent:builtin:general-purpose"}, conv="c-1")
# c-2: sem subagente; o log da chamada principal (`query_source` sdk) não a torna subagente
db.span(ts(f"{D}11:00:00"), 1, model="claude-sonnet-5", conv="c-2", input=1000, output=100, attrs={"request_id": "rq-main", "query_source_safe": "sdk"})
db.log(ts(f"{D}11:00:30"), "api_request", {"request_id": "rq-main", "cost_usd": "0.5", "query_source": "sdk"}, conv="c-2")
# rodada com um evento de subagente (com HTML no texto) e rodada com a etapa mas sem evento de subagente
SHA = hashlib.sha256(b"x").hexdigest()
for i, rnd in enumerate(("swarm-r1", "swarm-r2")):
    db.log(ts(f"{D}09:0{i}:00"), "oute.swarm.step.published",
           {"oute.swarm.step.kind": "fechamento", "oute.swarm.step.rev": 1, "oute.swarm.step.sha256": SHA, "oute.swarm.step.review": "aprovado"},
           body="x", rnd=rnd)
    db.logs[-1]["oute_event_id"] = f"ev-{i}"
db.log(ts(f"{D}09:30:00"), "oute.swarm.round.subagent", {}, body="conferir <b>as 4 issues</b> da triagem", rnd="swarm-r1")
db.log(ts(f"{D}09:10:00"), "oute.swarm.round.subagent", {}, body="primeiro: ler o CONTEXT", rnd="swarm-r1")
db.log(ts(f"{D}09:40:00"), "oute.swarm.round.subagent", {}, body="de outra rodada", rnd="swarm-rx")
st = db.flush()

u = st.usage(FROM, TO, cfg.prices)
roles = {r["role"]: r for r in u["by_role"]}
usd = lambda r: round(sum(r["cost"][k] or 0 for k in ("real_usd", "listed_usd", "estimated_usd")), 6)
check("a) by_role tem o papel subagente com as 3 chamadas (safe, agent_id e log)", roles.get("subagente", {}).get("calls") == 3)
check("a) a chamada de subagente não entra no papel da sessão (standalone: c-1 principal + c-2 + rodada)", roles["standalone"]["calls"] == 2)
check("b) o custo do subagente é o das 3 chamadas (0,20 + 0,30 + 0,40)", usd(roles["subagente"]) == 0.9)
check("o total de chamadas e de custo não muda com o papel", u["totals"]["calls"] == sum(r["calls"] for r in u["by_role"]) == 5
      and abs(usd(u["totals"]) - sum(usd(r) for r in u["by_role"])) < 1e-9)
check("by_role_model e by_role_phase também trazem o subagente", any(r["role"] == "subagente" for r in u["by_role_model"])
      and any(r["role"] == "subagente" for r in u["by_role_phase"]))
check("c) o log com query_source agent: conta como subagente; o de query_source sdk não", usd(roles["standalone"]) == 0.1 + 0.5)

c1 = CV.detail(st.con, "c-1", cfg.prices)["conversation"]["subagents"]
c2 = CV.detail(st.con, "c-2", cfg.prices)["conversation"]["subagents"]
check("d) conversa c-1: 3 chamadas, US$ 0,90, 90 % do custo", (c1["calls"], round(c1["usd"], 6), c1["pct"]) == (3, 0.9, 90))
check("d) conversa sem subagente: zero chamadas, zero, 0 %", (c2["calls"], c2["usd"], c2["pct"]) == (0, 0, 0))

sub = etapas.subagents(st.con, "swarm-r1")
check("e) etapas.subagents: os dois eventos da rodada, pela hora do fato", [a["text"] for a in sub] == ["primeiro: ler o CONTEXT", "conferir <b>as 4 issues</b> da triagem"])
check("e) rodada sem evento: lista vazia", etapas.subagents(st.con, "swarm-r2") == [])
# o formulário de filtro do /uso como o navegador o envia: a linha de subagente segue na tela (#586: não montar só a URL)
from studio_asgi import TOKEN, get
from studio_form import submit as form_submit
from agent_studio.app import create_app
app = create_app(st, TOKEN, config=cfg)
(stt, html), sent = form_submit(get, app, "/uso", "from=2026-11-01T00%3A00%3A00Z&to=2026-11-02T00%3A00%3A00Z")
check("/uso pelo formulário enviado: a linha subagente segue na tela", stt == 200 and bool(sent) and re.search(r"<td[^>]*>subagente</td>", html) is not None)
st.con.close()
PY
check_py_lines "$TMP/py.out"

cp "$TMP/a.duckdb" "$TMP/s/db.duckdb"
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
C=(-H "Authorization: Bearer $STUDIO_TOKEN")
page() { local path="$1"; studio_page "${C[@]}" "$STUDIO_URL$path"; return $?; }

OUT="$(curl -s "${C[@]}" "$STUDIO_URL/v1/usage?from=2026-11-01T00:00:00Z&to=2026-11-02T00:00:00Z")"
check "/v1/usage: by_role tem subagente com 3 chamadas e mantém os campos de sempre" jqe '[.by_role[] | select(.role == "subagente")][0] | .calls == 3 and (.cost | has("real_usd")) and has("tokens")' <<<"$OUT"
OUT="$(page "/uso?de=2026-11-01T00:00&ate=2026-11-02T00:00")"
check "/uso: a tabela de papéis mostra a linha subagente" has '<td[^>]*>subagente</td>'
OUT="$(page "/conversa?id=c-1")"
check "/conversa c-1: bloco de subagentes com 3 chamadas e 90 %" bash -c 'grep -q "data-calls=\"3\"" <<<"$1" && grep -q "Subagentes: 3 chamadas" <<<"$1" && grep -q "(90 % do custo)" <<<"$1"' _ "$OUT"
OUT="$(page "/conversa?id=c-2")"
check "/conversa c-2: o bloco mostra zero chamadas" bash -c 'grep -q "data-calls=\"0\"" <<<"$1" && grep -q "Subagentes: 0 chamadas" <<<"$1"' _ "$OUT"
OUT="$(page "/rodada?id=swarm-r1")"
check "/rodada r1: bloco Subagentes do dispatcher com os dois textos" bash -c 'grep -q "Subagentes do dispatcher (2)" <<<"$1" && grep -q "primeiro: ler o CONTEXT" <<<"$1"' _ "$OUT"
check "/rodada r1: o texto do evento vem escapado" bash -c 'grep -q "&lt;b&gt;as 4 issues&lt;/b&gt;" <<<"$1" && ! grep -q "<b>as 4 issues" <<<"$1"' _ "$OUT"
check "/rodada r1: não lista o evento de outra rodada" hasnt_str 'de outra rodada'
OUT="$(page "/rodada?id=swarm-r2")"
check "/rodada r2: sem evento, o bloco não aparece" hasnt 'data-subagentes'
check_end
