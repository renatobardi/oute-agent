#!/usr/bin/env bash
# Testes da fase do AI-DLC de toda conversa, por classificação póstuma (#749, ADR-08 "Fase da conversa", ADR-02 adendo):
# os sinais na ordem (abertura, label, skill, papel, ação, Jev), a predominância e o empate, a baixa confiança, a troca do Bardi
# (`POST /fase`, tela `/fases`) que vale sobre a automática, o Uso, o Dashboard e o `GET /v1/usage` só com fases do ADR-07
# (nunca `desconhecida` nem `interativa`), o histórico passando pelo mesmo classificador, o `rebuild-state` refazendo a
# fase, e a chamada ao Jev (só https, teto de tempo, sem chave não chama, consumo no `tel`). Sem Docker; a TypeSafe é a falsa
# de tests/lib/typesafe.sh (TLS, certificado gerado na hora). Datas depois do corte da #617 (2026-10-06).
# Uso: tests/agent-studio-fase-conversa.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
. "$ROOT/tests/lib/typesafe.sh"
trap 'studio_stop; ts_stop; rm -rf "${TMP:?}"' EXIT
studio_init
ts_start "$TMP/ts" || die "a TypeSafe falsa não subiu"
ts_set ok build 0.9
READ_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
MARK_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
JEV_KEY="$TS_KEY"
export JEV_URL="$OUTE_SELECT_JEV_URL" JEV_KEY
ts_off   # o seletor real não é chamado; o agent-studio recebe o endereço e a chave de teste pelo próprio ambiente

# ---------------------------------------------------------------- 1. o classificador, o Uso e o Jev (Python)
PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" SSL_CERT_FILE="$TMP/ts/cert.pem" "$STUDIO_PY" - "$TMP" "$ROOT" > "$TMP/py.out" 2>&1 <<'PY'
import json, os, sys
from datetime import datetime, timezone

from agent_studio import config as CF, jev, phase, state, store as ST
from agent_studio import rebuild_state
from pycheck import check
from studio_db import StudioDB

tmp, root = sys.argv[1], sys.argv[2]
cfg = CF.load(f"{root}/config/agent-studio/config.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-11-01T"
FROM, TO = ts("2026-11-01T00:00:00"), ts("2026-11-02T00:00:00")
LATER = ts("2026-11-03T00:00:00")   # "agora" dos casos do Jev: todas as conversas já estão paradas

db = StudioDB(tmp, "a")
n = [0]


def tool(conv, minute, name, **attrs):
    n[0] += 1
    db.span(ts(f"{D}10:{minute:02d}:00"), 1, name="claude_code.tool", conv=conv, attrs={"tool_name": name, **attrs})


def call(conv, minute=30, task=None, rnd=None):
    db.span(ts(f"{D}10:{minute:02d}:00"), 1, model="claude-sonnet-5", conv=conv, task=task, input=1000, output=100, cost_usd=0.1)
    if rnd:
        db.spans[-1]["oute_swarm_round"] = rnd


def resource(extra):
    db.spans[-1]["resource_attributes"] = json.dumps(extra)


def opened(task, at, **a):
    db.log(ts(f"{D}{at}"), "oute.task.opened", a, task=task)


# 1 abertura: a fase do `oute.task.opened` vale sobre a skill
opened("t-ab", "09:00:00", **{"oute.task.phase": "arch", "oute.task.origin": "jev", "oute.task.repo": "r", "oute.task.slug": "7-x"})
call("c-abertura", task="t-ab")
tool("c-abertura", 1, "Skill", skill_name="oute-aidlc-qa-pr-audit")
# 2 label: sessão sem fase, da issue 12 do mesmo repositório que outra sessão abriu com origem `label`
opened("t-l1", "09:00:00", **{"oute.task.phase": "spec", "oute.task.origin": "label", "oute.task.repo": "r", "oute.task.slug": "12-foo"})
opened("t-l2", "09:01:00", **{"oute.task.repo": "r", "oute.task.slug": "12-bar"})
call("c-label", task="t-l2")
opened("t-l3", "09:02:00", **{"oute.task.repo": "r", "oute.task.slug": "99-sem-label"})
call("c-sem-label", task="t-l3")
# 3 skill predominante: 1 uso de qa e 3 leituras de SKILL.md de build
call("c-skill")
tool("c-skill", 1, "Skill", skill_name="oute-aidlc-qa-pr-audit")
for m in (2, 3, 4):
    tool("c-skill", m, "Read", file_path="/opt/oute/addons/skills/oute-aidlc-build-implement/SKILL.md")
# 4 skill empatada: qa primeiro, ship depois -> qa, baixa confiança
call("c-empate")
tool("c-empate", 1, "Skill", skill_name="oute-aidlc-qa-pr-audit")
tool("c-empate", 5, "Skill", skill_name="oute-aidlc-ship-release")
# 5 papel: dispatcher = plan; revisor das etapas (oute.swarm.step, sem sessão de worker) = qa; worker não é papel
call("c-disp", rnd="swarm-1"); resource({"oute.swarm.round": "swarm-1"})
call("c-revisor", rnd="swarm-1"); resource({"oute.swarm.round": "swarm-1", "oute.swarm.step": "triagem"})
call("c-worker", rnd="swarm-1"); resource({"oute.swarm.round": "swarm-1", "oute.swarm.session": "749-x"})
# 6 ação: forte (abriu PR), forte (editou ADR), forte (telemetria), fraca (uma edição) e sem nada
call("c-pr")
for m in (1, 2):
    tool("c-pr", m, "Bash", full_command="gh pr create --title x")
call("c-adr")
for m in (1, 2):
    tool("c-adr", m, "Edit", file_path="/workspace/oute-agent/docs/adr/0008-agent-studio.md")
call("c-ops")
for m in (1, 2):
    tool("c-ops", m, "Bash", full_command="curl -s agent-studio/v1/usage")
call("c-fraca")
tool("c-fraca", 1, "Edit", file_path="/x/a.py")
db.log(ts(f"{D}10:00:00"), "user_prompt", {"prompt": "revise os custos da semana e diga o que mudou"}, conv="c-fraca")
call("c-nada")
db.log(ts(f"{D}10:00:00"), "user_prompt", {"prompt": "oi"}, conv="c-nada")
# conversa sem oute.task.id e a chamada sem conversa (ai-memory)
db.span(ts(f"{D}12:00:00"), 1, name="ai_memory.llm_request", model="openai/gpt-oss-120b", agent="ai-memory", input=10, output=5, cost_usd=0.01)
st = db.flush()

phases = {c: (r["phase"], r["origin"], r["confidence"]) for c, r in phase.compute(st.con).items()}
exp = {"c-abertura": ("arch", "abertura", "alta"), "c-label": ("spec", "label", "alta"), "c-skill": ("build", "skill", "alta"),
       "c-empate": ("qa", "skill", "baixa"), "c-disp": ("plan", "papel", "alta"), "c-revisor": ("qa", "papel", "alta"),
       "c-pr": ("build", "acao", "alta"), "c-adr": ("arch", "acao", "alta"), "c-ops": ("ops", "acao", "alta"),
       "c-fraca": ("build", "acao", "baixa"), "c-nada": ("build", "acao", "baixa"),
       "c-sem-label": ("build", "acao", "baixa"), "c-worker": ("build", "acao", "baixa")}
for conv, want in exp.items():
    check(f"sinal: {conv} -> {want}", phases.get(conv) == want)
check("toda conversa tem fase do ADR-07 (nenhuma fica sem)", all(p[0] in phase.PHASES for p in phases.values()) and len(phases) == len(exp))
check("nenhum sinal é a fase 'ctx' nem texto de fora: PHASES são as 12 do ADR-07",
      phase.PHASES == ("strat", "intent", "spec", "arch", "design", "plan", "build", "qa", "ship", "ops", "learn", "iter"))

# --- a decisão pura: ordem dos níveis, e o que o Jev muda
d = phase.decide
check("ordem: manual > abertura", d({"manual": "ops", "opening": "qa"})["origin"] == "manual")
check("ordem: abertura > label > skill > papel > ação",
      d({"opening": "qa", "label": "spec", "skills": {"ops": (1, 1)}, "reviewer": True, "actions": {"build": 9}})["origin"] == "abertura"
      and d({"label": "spec", "skills": {"ops": (1, 1)}})["origin"] == "label"
      and d({"skills": {"ops": (1, 1)}, "reviewer": True})["origin"] == "skill"
      and d({"reviewer": True, "actions": {"build": 9}})["origin"] == "papel"
      and d({"dispatcher": True, "actions": {"build": 9}})["phase"] == "plan")
check("ação com margem curta (4 contra 3) não é forte: baixa confiança, pede o Jev",
      d({"actions": {"build": 4, "qa": 3}}) == {"phase": "build", "origin": "acao", "confidence": "baixa", "needs_jev": True})
check("Jev com confiança >= 0,6 vale sobre a ação fraca, origem jev, alta", d({"actions": {"build": 1}, "jev": ("spec", 0.6)}) == {"phase": "spec", "origin": "jev", "confidence": "alta", "needs_jev": False})
check("Jev abaixo de 0,6 não vale: a ação fraca fica, baixa, sem pedir de novo", d({"actions": {"build": 1}, "jev": ("spec", 0.59)}) == {"phase": "build", "origin": "acao", "confidence": "baixa", "needs_jev": False})
check("Jev abaixo de 0,6 sem ação nenhuma: a fase do Jev, baixa", d({"jev": ("spec", 0.3)}) == {"phase": "spec", "origin": "jev", "confidence": "baixa", "needs_jev": False})
check("fase fora do ADR-07 no sinal não vale", d({"opening": "desconhecida", "manual": "interativa"})["phase"] == phase.DEFAULT_PHASE)

# --- classify grava, é incremental e a mesma conversa não volta à fila
check("pending: todas as conversas, antes", len(phase.pending(st.con)) == len(exp))
phase.classify(st.con, ts(f"{D}11:00:00"))
check("pending: vazio depois de classificar", phase.pending(st.con) == [])
db2_conv = "c-nova"
db.spans.clear(); db.logs.clear()
db.span(ts(f"{D}13:00:00"), 1, model="claude-sonnet-5", conv=db2_conv, input=1, cost_usd=0.1)
db.span(ts(f"{D}13:10:00"), 1, model="claude-sonnet-5", conv="c-pr", input=1, cost_usd=0.1)
db.flush()
check("pending: só a conversa nova e a com fato novo", sorted(phase.pending(st.con)) == ["c-nova", "c-pr"])
phase.classify(st.con, ts(f"{D}14:00:00"))

# --- troca do Bardi: vale sobre a automática e sobre a reclassificação
res = phase.mark(st.con, "c-nada", "learn", ts(f"{D}15:00:00"))
check("troca manual: learn, origem manual, alta", (res["phase"], res["origin"], res["confidence"]) == ("learn", "manual", "alta"))
phase.classify(st.con, ts(f"{D}16:00:00"), list(phases))
check("a reclassificação não desfaz a troca", phase.phase_of(st.con, "c-nada") == ("learn", "manual", "alta"))
check("a troca fica em phase_marks (só de acréscimo)", st.con.execute("SELECT count(*) FROM phase_marks WHERE conversation = 'c-nada'").fetchone()[0] == 1)
check("a conversa trocada sai da lista de baixa confiança", "c-nada" not in [r["conversation"] for r in phase.low_confidence(st.con)])
check("a lista de baixa confiança tem as chutadas", {"c-fraca", "c-empate", "c-sem-label"} <= {r["conversation"] for r in phase.low_confidence(st.con)})

# --- Uso, /v1/usage e Dashboard: só fases do ADR-07
from agent_studio import usage as U
data = st.usage(FROM, TO + 86400 * SEC, cfg.prices)
names = [r["phase"] for r in data["by_phase"]]
check("by_phase: só fases do ADR-07", set(names) <= set(phase.PHASES) and names)
check("by_phase: nem desconhecida nem interativa", "desconhecida" not in names and "interativa" not in names)
check("by_phase: a chamada sem conversa (ai-memory) cai em ops", "ops" in names)
check("by_phase: a soma das fases é o total de chamadas", sum(r["calls"] for r in data["by_phase"]) == data["totals"]["calls"])
from agent_studio import dashboard as DASH
snap = st.dashboard(FROM, TO + 86400 * SEC, cfg.prices)
shown = {r["phase"] for r in snap["phases"]}
check("Dashboard: só fases do ADR-07", shown and shown <= set(phase.PHASES))

# --- state.phase_statements e o rebuild-state
check("phase_statements: fase, origem e confiança válidas viram estado", len(state.phase_statements("c-1", "qa", "skill", "alta")) >= 1)
check("phase_statements: fase fora do ADR-07 não vira estado", state.phase_statements("c-1", "desconhecida", "skill", "alta") == [])
check("phase_statements: origem desconhecida não vira estado", state.phase_statements("c-1", "qa", "chute", "alta") == [])


class Fake:
    def __init__(self):
        self.stmts = []

    def apply(self, stmts):
        self.stmts += stmts


f = Fake()
n_conv = rebuild_state.rebuild_phases(st.con, f)
sent = [(v["id"], v["d"]) for _, v in f.stmts if isinstance(v, dict) and "d" in v]
check("rebuild-state refaz a classificação de todas as conversas", n_conv == len(exp) + 1)
import base64
check("rebuild-state leva a troca do Bardi (phase_marks) como fase da conversa",
      any(v.get("id") == "c-nada" and base64.b64encode(b"learn").decode() in json.dumps(v) for _, v in f.stmts if isinstance(v, dict)))
st.close()
ro = __import__("duckdb").connect(f"{tmp}/a.duckdb", read_only=True)
check("rebuild-state roda com o DuckDB só leitura", rebuild_state.rebuild_phases(ro, Fake()) == n_conv)
ro.close()
import duckdb as _dk
old = _dk.connect(f"{tmp}/velho.duckdb")   # banco anterior à #749: sem as tabelas da fase
check("rebuild-state: banco anterior à #749 (sem as tabelas) não refaz nada e não falha", rebuild_state.rebuild_phases(old, Fake()) == 0)
old.close()


class Boom:
    def apply(self, stmts):
        raise RuntimeError("segredo-da-falha")


sink = state.phase_sink(Boom())
try:
    sink({"c-1": {"phase": "qa", "origin": "skill", "confidence": "alta"}})
    survived = True
except Exception:  # noqa: BLE001
    survived = False
check("espelho no SurrealDB que falha não derruba a classificação (o rebuild-state refaz)", survived and state.phase_sink(None)({"c": {}}) is None)

# ---------------------------------------------------------------- o Jev
URL, KEY = os.environ["JEV_URL"], os.environ["JEV_KEY"]
ok = jev.classify("escreva um adr sobre o cache", URL, KEY)
check("jev: resposta válida -> (fase, confiança)", ok == ("build", 0.9))
check("jev: só https", not jev.usable("http://127.0.0.1:1/x", KEY) and jev.usable(URL, KEY) and not jev.usable(URL, "") and not jev.usable("https://u:p@h/x", KEY))
for bad in ("http://127.0.0.1:9/x", "ftp://h/x", "https://h x/y", "file:///etc/passwd", ""):
    try:
        jev.classify("texto", bad, KEY)
        check(f"jev: endereço recusado {bad!r}", False)
    except jev.JevError:
        check(f"jev: endereço recusado {bad!r}", True)
try:
    jev.classify("texto", URL, "")
    check("jev: sem chave não chama", False)
except jev.JevError:
    check("jev: sem chave não chama", True)
reqs = open(f"{tmp}/ts/requests.jsonl").read().splitlines()
last = json.loads(reqs[-1])
check("jev: leva só o texto, o modelo e as 12 fases", sorted(last["body"]) == ["model", "questions", "state"] and last["body"]["state"] == "escreva um adr sobre o cache"
      and sorted(last["body"]["questions"]["fase"]["criteria"]) == sorted(phase.PHASES))
check("jev: a chave só vai no cabeçalho Authorization", last["auth"] == f"Bearer {KEY}" and KEY not in json.dumps(last["body"]))


# ---- a rotina do Jev (call_pending): só conversa parada de baixa confiança, uma resposta por conversa, falha com recuo
def fake(mode, choice="spec", confidence="0.9"):
    for name, val in (("mode", mode), ("choice", choice), ("confidence", confidence)):
        open(f"{tmp}/ts/{name}", "w").write(val)


def nreq():
    try:
        return len(open(f"{tmp}/ts/requests.jsonl").read().splitlines())
    except OSError:
        return 0


class Tel:
    def __init__(self):
        self.calls, self.warns = [], []

    def jev(self, result, seconds):
        self.calls.append(result)

    def warn(self, kind, msg, *args, **kw):
        self.warns.append(msg % args if args else msg)


b = StudioDB(tmp, "b")
for conv in ("j-ok", "j-baixa", "j-erro", "j-recente"):
    b.span(ts(f"{D}10:00:00"), 1, name="claude_code.tool", conv=conv, attrs={"tool_name": "Edit", "file_path": "/x.py"})
    b.log(ts(f"{D}10:00:00"), "user_prompt", {"prompt": f"texto do pedido de {conv}"}, conv=conv)
b.span(ts("2026-11-03T00:00:00") - 60 * SEC, 1, name="claude_code.tool", conv="j-recente", attrs={"tool_name": "Edit", "file_path": "/y.py"})
sb = b.flush()
sb.classify_pending(force=True)
check("jev: antes, as quatro estão de baixa confiança pela ação", all(phase.phase_of(sb.con, c)[1:] == ("acao", "baixa") for c in ("j-ok", "j-baixa", "j-erro", "j-recente")))
tel = Tel()
before = nreq()
fake("ok", "spec", "0.9")
only_ok = lambda: None
# uma de cada vez: a resposta depende da conversa, então a falsa responde o que está nos arquivos; rodamos por conversa com o limite
backoff = {}
out = jev.call_pending(sb, LATER, URL, KEY, tel, limit=1, backoff=backoff)
first = next(iter(out))
check("jev: uma chamada por passada com limit=1", nreq() - before == 1 and len(out) == 1)
check("jev: confiança 0,9 -> fase do Jev, origem jev, alta", (out[first]["phase"], out[first]["origin"], out[first]["confidence"]) == ("spec", "jev", "alta"))
check("jev: a resposta fica em phase_jev e o consumo vai ao tel", sb.con.execute("SELECT count(*) FROM phase_jev").fetchone()[0] == 1 and tel.calls == ["ok"])
check("jev: o texto enviado é o do primeiro pedido da conversa", f"texto do pedido de {first}" == json.loads(open(f"{tmp}/ts/requests.jsonl").read().splitlines()[-1])["body"]["state"])
fake("ok", "ship", "0.3")
out = jev.call_pending(sb, LATER, URL, KEY, tel, limit=10, backoff=backoff)
check("jev: a conversa recente (fato há 1 min) não vai ao Jev", "j-recente" not in out and "j-recente" not in {r for (r,) in sb.con.execute("SELECT conversation FROM phase_jev").fetchall()})
low = [c for c in out if c != first]
check("jev: confiança 0,3 -> a ação fraca fica, baixa; a resposta é guardada", all(phase.phase_of(sb.con, c) == ("build", "acao", "baixa") for c in low) and len(low) == 2)
n_before = nreq()
again = jev.call_pending(sb, LATER, URL, KEY, tel, backoff=backoff)
check("jev: conversa que já tem resposta não é perguntada de novo", again == {} and nreq() == n_before)
sb.con.execute("DELETE FROM phase_jev WHERE conversation = 'j-erro'"); sb.con.execute("DELETE FROM conversation_phase WHERE conversation = 'j-erro'")
sb.classify_pending(force=True)
fake("5xx")
tel2 = Tel()
n_before = nreq()
out = jev.call_pending(sb, LATER, URL, KEY, tel2, backoff=backoff)
check("jev: 5xx -> nada gravado, erro no tel, a conversa fica no passo da ação", out == {} and tel2.calls == ["erro"] and
      sb.con.execute("SELECT count(*) FROM phase_jev WHERE conversation = 'j-erro'").fetchone()[0] == 0 and phase.phase_of(sb.con, "j-erro")[1:] == ("acao", "baixa"))
check("jev: o aviso de falha diz o tipo e não leva o texto nem a chave", tel2.warns and KEY not in " ".join(tel2.warns) and "texto do pedido" not in " ".join(tel2.warns))
n_mid = nreq()
jev.call_pending(sb, LATER, URL, KEY, tel2, backoff=backoff)
check("jev: depois da falha, recua (não tenta de novo na hora)", nreq() == n_mid and n_mid == n_before + 1)
fake("lixo"); backoff.clear()
tel3 = Tel()
jev.call_pending(sb, LATER, URL, KEY, tel3, backoff=backoff)
check("jev: resposta que não é JSON -> erro, nada gravado", tel3.calls == ["erro"])
fake("fora"); backoff.clear()
tel3 = Tel()
jev.call_pending(sb, LATER, URL, KEY, tel3, backoff=backoff)
check("jev: fase fora das 12 -> erro, nada gravado", tel3.calls == ["erro"])
fake("redirect"); backoff.clear()
n_before = nreq()
tel3 = Tel()
jev.call_pending(sb, LATER, URL, KEY, tel3, backoff=backoff)
check("jev: redirecionamento não é seguido", tel3.calls == ["erro"] and nreq() == n_before + 1)
fake("ok", "spec", "0.9"); backoff.clear()
n_before = nreq()
check("jev: endereço http:// -> nenhuma chamada", jev.call_pending(sb, LATER, "http://127.0.0.1:9/x", KEY, Tel(), backoff={}) == {} and nreq() == n_before)
check("jev: sem chave -> nenhuma chamada", jev.call_pending(sb, LATER, URL, "", Tel(), backoff={}) == {} and nreq() == n_before)
import time as _t
fake("hang"); open(f"{tmp}/ts/hang", "w").write("4")
t0 = _t.monotonic()
try:
    jev.classify("texto", URL, KEY, timeout=0.5)
    hung = False
except jev.JevError as e:
    hung = "sem resposta" in str(e)
check("jev: sem resposta -> para no teto de tempo (0,5 s aqui; 3 s no código)", hung and _t.monotonic() - t0 < 2.5 and jev.TIMEOUT_S == 3.0)
fake("ok")
sb.close()
sys.stdout.flush()
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E "^(ok   |FAIL )" "$TMP/py.out")" = 70

# ---------------------------------------------------------------- 2. o serviço: /fases, POST /fase, o Jev pela rotina em segundo plano
SRV="$TMP/srv"; mkdir -p "$SRV"   # 2026-10-07: depois do corte da #617 e já parado, para a rotina do Jev (conversa parada há 10 min)
PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$SRV" <<'PY2'
import sys
from datetime import datetime, timezone
from studio_db import StudioDB

SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-10-07T"
db = StudioDB(sys.argv[1], "db")
for conv, cmd in (("s-a", None), ("s-c", None), ("s-d", None), ("s-b", "gh pr create --title x")):
    db.span(ts(f"{D}10:00:00"), 1, model="claude-sonnet-5", conv=conv, input=1000, output=100, cost_usd=0.2)
    if cmd:
        for m in (1, 2):
            db.span(ts(f"{D}10:0{m}:00"), 1, name="claude_code.tool", conv=conv, attrs={"tool_name": "Bash", "full_command": cmd})
    else:
        db.span(ts(f"{D}10:01:00"), 1, name="claude_code.tool", conv=conv, attrs={"tool_name": "Edit", "file_path": "/x.py"})
        db.log(ts(f"{D}10:00:00"), "user_prompt", {"prompt": f"pedido de {conv}"}, conv=conv)
db.flush().close()
PY2
read -r COOKIE_R COOKIE_M CSRF < <(PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -c '
import sys
from agent_studio.auth import Auth
a = Auth(sys.argv[1], sys.argv[2], sys.argv[3])
print(a.cookie_value, a.mark_cookie_value, a.mark_csrf)' "$STUDIO_TOKEN" "$READ_T" "$MARK_T")
SENV=(AGENT_STUDIO_READ_TOKEN="$READ_T" AGENT_STUDIO_MARK_TOKEN="$MARK_T" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml"
      AGENT_STUDIO_JEV_URL="$JEV_URL" AGENT_STUDIO_JEV_KEY="$JEV_KEY" SSL_CERT_FILE="$TMP/ts/cert.pem" AGENT_STUDIO_PHASE_INTERVAL_S=1)
RC_="Cookie: agent_studio=$COOKIE_R"; MC_="Cookie: agent_studio=$COOKIE_R; agent_studio_mark=$COOKIE_M"
Q="from=2026-10-07T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z"
phases_of() { curl -s -H "Authorization: Bearer $READ_T" "$STUDIO_URL/v1/usage?$Q" | jq -c '[.by_phase[] | {(.phase): .calls}] | add'; }
# fase <cabeçalho Cookie ou vazio> <Origin ou vazio> <corpo>: POST /fase; imprime o código HTTP e deixa o corpo em $TMP/resp
fase() {
  local cookie="$1" origin="$2" body="$3"; shift 3
  curl -s -o "$TMP/resp" -w '%{http_code}' -X POST ${cookie:+-H "$cookie"} ${origin:+-H "Origin: $origin"} \
    -H 'Content-Type: application/x-www-form-urlencoded' --data "$body" "$@" "$STUDIO_URL/fase"
  return $?
}

ts_set 5xx
studio_start "$SRV" "${SENV[@]}" || { cat "$SRV/stderr"; die "o serviço não subiu"; }
R="$(phases_of)"
check "serviço: Uso só com fases do ADR-07 (build e nada mais): $R" jqe '(keys | all(. as $k | ["strat","intent","spec","arch","design","plan","build","qa","ship","ops","learn","iter"] | index($k)))' <<<"$R"
check "serviço: nenhuma fase desconhecida nem interativa" jqe 'has("desconhecida") or has("interativa") | not' <<<"$R"
PAGE="$(curl -s -H "$RC_" "$STUDIO_URL/fases")"
check "tela /fases: lista as conversas de baixa confiança (s-a e s-c), não a forte (s-b)" bash -c 'grep -q "data-conversa=\"s-a\"" <<<"$1" && grep -q "data-conversa=\"s-c\"" <<<"$1" && ! grep -q "data-conversa=\"s-b\"" <<<"$1"' _ "$PAGE"
check "tela /fases: sem o cookie de marcação não há formulário de troca" bash -c '! grep -q "data-fase-form" <<<"$1" && grep -q "data-ack-entrar" <<<"$1"' _ "$PAGE"
PAGE_M="$(curl -s -H "$MC_" "$STUDIO_URL/fases")"
check "tela /fases: com o cookie de marcação cada linha traz o formulário e o csrf" bash -c 'grep -q "data-fase-form=\"s-a\"" <<<"$1" && grep -q "name=\"csrf\" value=\"$2\"" <<<"$1"' _ "$PAGE_M" "$CSRF"
check "tela /fases: sem login vai ao login" test "$(code "$STUDIO_URL/fases")" = 303
B_="conversa=s-a&fase=ops&csrf=$CSRF"
check "POST /fase: sem credencial = 401" test "$(fase '' "$STUDIO_URL" "$B_")" = 401
check "POST /fase: credencial de leitura (a do agente) = 403" test "$(fase "$RC_" "$STUDIO_URL" "$B_")" = 403
check "POST /fase: sem Origin = 403" test "$(fase "$MC_" '' "$B_")" = 403
check "POST /fase: Origin de outro site = 403" test "$(fase "$MC_" 'https://evil.example' "$B_")" = 403
check "POST /fase: csrf errado = 403" test "$(fase "$MC_" "$STUDIO_URL" 'conversa=s-a&fase=ops&csrf=errado')" = 403
check "POST /fase: fase fora do ADR-07 = 400" test "$(fase "$MC_" "$STUDIO_URL" "conversa=s-a&fase=desconhecida&csrf=$CSRF")" = 400
check "POST /fase: campo a mais = 400" test "$(fase "$MC_" "$STUDIO_URL" "$B_&x=1")" = 400
check "POST /fase: conversa que não existe = 400" test "$(fase "$MC_" "$STUDIO_URL" "conversa=nao-existe&fase=ops&csrf=$CSRF")" = 400
check "POST /fase: corpo grande = 413" test "$(fase "$MC_" "$STUDIO_URL" "$B_&p=$(head -c 5000 /dev/zero | tr '\0' a)")" = 413
PAGE="$(curl -s -H "$RC_" "$STUDIO_URL/fases")"
check "nenhuma recusa trocou fase: s-a e s-c seguem na lista de baixa confiança" bash -c 'grep -q "data-conversa=\"s-a\"" <<<"$1" && grep -q "data-conversa=\"s-c\"" <<<"$1"' _ "$PAGE"
check "POST /fase: com o cookie, Origin e csrf = 303 para /fases" test "$(fase "$MC_" "$STUDIO_URL" "$B_")" = 303
PAGE="$(curl -s -H "$MC_" "$STUDIO_URL/fases?trocada=s-a")"
check "tela /fases: a trocada sai da lista de baixa confiança e a página avisa" bash -c '! grep -q "data-conversa=\"s-a\"" <<<"$1" && grep -q "data-fase-trocada=\"s-a\"" <<<"$1"' _ "$PAGE"
R="$(phases_of)"
check "Uso: a troca vale na hora (ops com 1 conversa)" jqe '.ops == 1' <<<"$R"
check "Uso: segue sem fase desconhecida" jqe 'has("desconhecida") or has("interativa") | not' <<<"$R"
check "POST /fase (json): devolve a fase, a origem manual e a confiança alta" bash -c 'curl -s -X POST -H "$1" -H "Origin: $2" -H "Accept: application/json" -H "Content-Type: application/x-www-form-urlencoded" --data "conversa=s-c&fase=learn&csrf=$3" "$2/fase" | jq -e ".conversa == \"s-c\" and .fase == \"learn\" and .origem == \"manual\" and .confianca == \"alta\"" >/dev/null' _ "$MC_" "$STUDIO_URL" "$CSRF"
studio_stop
check "POST /fase: as duas trocas estão em phase_marks (só de acréscimo), por human" test "$(studio_sql "$SRV/db.duckdb" "SELECT count(*) AS n FROM phase_marks WHERE marked_by = 'human' AND ((conversation = 's-a' AND phase = 'ops') OR (conversation = 's-c' AND phase = 'learn'))" | jq .n)" = 2
# a segunda subida, com o Jev respondendo: a rotina em segundo plano classifica o que sobrou; a troca do Bardi continua valendo
rm -f "$TMP/ts/requests.jsonl"; ts_set ok spec 0.9
studio_start "$SRV" "${SENV[@]}" || { cat "$SRV/stderr"; die "o serviço não subiu (2)"; }
sleep 4
REQS="$(jq -r '.body.state' "$TMP/ts/requests.jsonl" 2>/dev/null)"
check "serviço: a rotina chamou o Jev só para a conversa de baixa confiança sem troca (s-d); não para s-a, s-c (trocadas) nem s-b (forte)" bash -c 'grep -qx "pedido de s-d" <<<"$1" && ! grep -q "pedido de s-[ac]" <<<"$1" && ! grep -q s-b <<<"$1"' _ "$REQS"
studio_stop
check "serviço: s-d ficou com a fase do Jev (spec, origem jev, alta) e a resposta está em phase_jev" test "$(studio_sql "$SRV/db.duckdb" "SELECT c.phase || '/' || c.origin || '/' || c.confidence AS p FROM conversation_phase c JOIN phase_jev j ON j.conversation = c.conversation WHERE c.conversation = 's-d'" | jq -r .p)" = "spec/jev/alta"
check "depois da subida, a troca segue valendo (s-a = ops, manual)" test "$(studio_sql "$SRV/db.duckdb" "SELECT phase || '/' || origin AS p FROM conversation_phase WHERE conversation = 's-a'" | jq -r .p)" = "ops/manual"
check_end
