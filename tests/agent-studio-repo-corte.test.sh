#!/usr/bin/env bash
# Testes do acerto único do histórico sem repositório no agent-studio (#617, ADR-08 "Filtro de repositório"): fato sem
# repositório e com hora do fato antes de 2026-10-06T00:00:00Z fica com `oute-agent` na coluna `oute_repo`. Vale na ingestão
# (`otlp.*_rows`, o caminho do collector e do replay) e na subida (`store.Store`, depois do `repo_infer`), com a mesma data.
# Fato com repositório próprio nunca é trocado, fato da hora do corte em diante segue "sem repositório", e o JSON
# `resource_attributes` fica como chegou. A mesma entrada pelo `agent_studio.replay` real está no
# `tests/agent-studio-replay.test.sh`. As datas são fixas: nada aqui depende do relógio. Sem Docker e sem processo em
# segundo plano.
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
import json, logging, re, sys
from datetime import datetime, timezone

import duckdb
from agent_studio import config as CF, otlp, repo as R, store as ST
from agent_studio.app import create_app
from otlp_json import event, kv, rl, rs, span
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
sec = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp())
ts = lambda s: sec(s) * SEC
# o corte e o valor escritos aqui por extenso, como na issue #617 e no ADR-08: o teste não os lê do código
LEGACY, NONE = "oute-agent", "(sem)"
CUT = "2026-10-06T00:00:00"
OLD, OLDER, NEW = "2026-10-05T12:00:00", "2026-09-30T08:00:00", "2026-10-07T12:00:00"
tok = dict(input=1000, output=100)

# ---- 1. ingestão: a linha que o OTLP vira (o caminho do collector e do replay)
RES = {"host.name": "h1", "service.name": "oute"}   # sem oute.task.repo


def span_row(at, res=RES, rec=None):
    return otlp.span_rows({"resourceSpans": [rs(res, [span("claude_code.llm_request", sec(at), 2, rec or {})])]}, ts(NEW))[0]


def log_row(at, res=RES, rec=None):
    return otlp.log_rows({"resourceLogs": [rl(res, [event(sec(at), "oute.exemplo", f"ev-{at}", rec or {})])]}, ts(NEW))[0]


def metric_row(at, res=RES):
    point = {"timeUnixNano": str(ts(at)), "asInt": "1", "attributes": []}
    return otlp.metric_rows({"resourceMetrics": [{"resource": {"attributes": kv(res)}, "scopeMetrics": [
        {"metrics": [{"name": "m", "gauge": {"dataPoints": [point]}}]}]}]}, ts(NEW))[0]


ROWS = (("span", span_row), ("log", log_row), ("métrica", metric_row))
for name, row in ROWS:
    check(f"ingestão, {name}: sem repositório antes do corte entra com oute-agent", [row(OLD)["oute_repo"], row(OLDER)["oute_repo"]] == [LEGACY] * 2)
    check(f"ingestão, {name}: sem repositório depois do corte segue sem repositório (NULL)", row(NEW)["oute_repo"] is None)
    check(f"ingestão, {name}: a hora exata do corte já é depois (NULL)", row(CUT)["oute_repo"] is None)
    check(f"ingestão, {name}: com repositório próprio antes do corte, fica o dele", row(OLD, {**RES, "oute.task.repo": "alfa"})["oute_repo"] == "alfa")
    check(f"ingestão, {name}: o resource_attributes fica como chegou", json.loads(row(OLD)["resource_attributes"]) == RES)
check("ingestão: repositório vazio antes do corte = sem repositório, então oute-agent", span_row(OLD, {**RES, "oute.task.repo": ""})["oute_repo"] == LEGACY)
check("ingestão: repositório vazio depois do corte segue NULL", span_row(NEW, {**RES, "oute.task.repo": ""})["oute_repo"] is None)
check("ingestão: o repositório do registro (não do resource) antes do corte também fica",
      span_row(OLD, RES, {"oute.task.repo": "beta"})["oute_repo"] == "beta" and log_row(OLD, RES, {"oute.task.repo": "beta"})["oute_repo"] == "beta")
check("ingestão: repositório próprio de nome oute-agent depois do corte fica", span_row(NEW, {**RES, "oute.task.repo": LEGACY})["oute_repo"] == LEGACY)


def no_time(received):
    """Log sem hora do fato nem hora observada: a hora do fato é a de chegada, e é ela que o corte confere."""
    return otlp.log_rows({"resourceLogs": [rl(RES, [{"body": {"stringValue": "x"}, "attributes": []}])]}, ts(received))[0]


check("ingestão: fato sem hora vale a hora de chegada (antes do corte = oute-agent; depois = NULL)",
      [no_time(OLD)["oute_repo"], no_time(NEW)["oute_repo"]] == [LEGACY, None]
      and [no_time(OLD)["time_unix_nano"], no_time(NEW)["time_unix_nano"]] == [ts(OLD), ts(NEW)])

# ---- 2. a subida: o banco que já existe (fatos gravados sem repositório, como antes desta mudança)
db = StudioDB(tmp, "c")


def call(at, conv, repo=None, task=None):
    db.span(ts(at), 2, model="claude-sonnet-5", conv=conv, repo=repo, task=task, **tok)


def tool(at, conv, path=None, cmd=None, repo=None):
    attrs = {"tool_name": "Read"}
    if path is not None:
        attrs["file_path"] = path
    if cmd is not None:
        attrs["full_command"] = cmd
    db.span(ts(at), 1, name="claude_code.tool", conv=conv, repo=repo, attrs=attrs)


def metric(key, at, repo=None):
    return {"dedupe_key": key, "time_unix_nano": ts(at), "metric_name": "m", "metric_type": "gauge", "value": 1.0,
            "oute_repo": repo, "resource_attributes": json.dumps({"oute.task.repo": repo} if repo else {}),
            "attributes": "{}", "point": "{}", "received_unix_nano": ts(at)}


call("2026-10-05T08:00:00", "c-alfa", "alfa", "T-alfa")          # antes do corte, com repositório próprio
call("2026-10-05T09:00:00", "h-pasta"); tool("2026-10-05T09:01:00", "h-pasta", "/workspace/alfa/README.md")  # o repo_infer acha alfa
call("2026-10-05T10:00:00", "h-velha"); call("2026-09-30T10:00:00", "h-velha")
tool("2026-10-05T10:01:00", "h-velha", cmd="cd /workspace/alfa && cat README.md")   # só o texto do comando: ninguém lê
db.log(ts("2026-10-05T10:02:00"), "tool_result", {}, conv="h-velha")
db.log(ts("2026-10-05T10:03:00"), "oute.exemplo", {})                                # log sem conversa
call("2026-10-06T00:00:00", "n-borda")                           # a hora exata do corte
call("2026-10-07T10:00:00", "n-nova"); db.log(ts("2026-10-07T10:01:00"), "tool_result", {}, conv="n-nova")
call("2026-10-07T11:00:00", "n-alfa", "alfa", "T-alfa2")
st = db.flush()
st.write({"metrics": [metric("m:velha", OLD), metric("m:nova", NEW), metric("m:beta", OLD, "beta")]})
check("antes da subida: os fatos sem repositório estão com NULL (o banco como era)",
      st.con.execute("SELECT count(*) FROM spans WHERE oute_repo IS NULL").fetchone()[0] == 7)
st.close()


def by_conv(con):
    return {c: sorted(v, key=str) for c, v in con.execute("SELECT session_id, list(DISTINCT oute_repo) FROM spans GROUP BY ALL").fetchall()}


def snapshot(con):
    return [con.execute(f"SELECT dedupe_key, oute_repo, resource_attributes::VARCHAR FROM {t} ORDER BY 1").fetchall() for t in ("spans", "logs", "metrics")]


st = ST.Store(f"{tmp}/c.duckdb")
got = by_conv(st.con)
check("subida: os spans sem repositório de antes do corte viram oute-agent", got["h-velha"] == [LEGACY]
      and st.con.execute("SELECT count(*) FROM spans WHERE session_id = 'h-velha' AND oute_repo = ?", [LEGACY]).fetchone()[0] == 3)
check("subida: os logs de antes do corte também, com ou sem conversa",
      st.con.execute("SELECT oute_repo FROM logs WHERE time_unix_nano < ? ORDER BY time_unix_nano", [ts(CUT)]).fetchall() == [(LEGACY,)] * 2)
check("subida: o fato de depois do corte segue sem repositório (span e log)", got["n-nova"] == [None]
      and st.con.execute("SELECT oute_repo FROM logs WHERE session_id = 'n-nova'").fetchall() == [(None,)])
check("subida: a hora exata do corte já é depois (NULL)", got["n-borda"] == [None])
check("subida: quem tem repositório próprio fica com ele, antes e depois do corte", got["c-alfa"] == ["alfa"] and got["n-alfa"] == ["alfa"])
check("subida: o repo_infer roda antes, e o que ele acha pelo file_path não é trocado", got["h-pasta"] == ["alfa"])
check("subida: as métricas seguem a mesma regra (velha = oute-agent, nova = NULL, com repositório = o dela)",
      st.con.execute("SELECT dedupe_key, oute_repo FROM metrics ORDER BY 1").fetchall() == [("m:beta", "beta"), ("m:nova", None), ("m:velha", LEGACY)])
check("subida: o resource_attributes não muda (nenhum fato ganhou oute.task.repo no JSON)",
      [st.con.execute(f"SELECT count(*) FROM {t} WHERE oute_repo = ? AND resource_attributes::VARCHAR <> '{{}}'", [LEGACY]).fetchone()[0]
       for t in ("spans", "logs", "metrics")] == [0, 0, 0])
check("subida: nenhum fato de antes do corte ficou sem repositório",
      [st.con.execute(f"SELECT count(*) FROM {t} WHERE oute_repo IS NULL AND time_unix_nano < ?", [ts(CUT)]).fetchone()[0]
       for t in ("spans", "logs", "metrics")] == [0, 0, 0])
first = snapshot(st.con)
st.close()
st = ST.Store(f"{tmp}/c.duckdb")
check("subida de novo: nada muda", snapshot(st.con) == first)

# ---- 3. as telas: antes do corte nada em "sem repositório"; depois, a regra normal
app = create_app(st, TOKEN, config=cfg)
BEFORE = "from=2026-09-29T00%3A00%3A00Z&to=2026-10-06T00%3A00%3A00Z"    # os 7 dias que acabam no corte
ACROSS = "from=2026-10-01T00%3A00%3A00Z&to=2026-10-08T00%3A00%3A00Z"    # 7 dias com o corte no meio
q = lambda win, repo: win + f"&repo={repo}"


def kpi(html):
    m = re.search(r'data-kpi="calls" data-value="(\d+)"', html)
    return int(m.group(1)) if m else None


def uso(html):
    m = re.search(r'id="total" data-calls="(\d+)"', html)
    return int(m.group(1)) if m else None


def ids(html):
    return sorted(set(re.findall(r'data-conversa="([^"]*)"', html)))


check("Dashboard de 7 dias até o corte, 'sem repositório': 0 chamadas", kpi(get(app, "/", q(BEFORE, NONE))[1]) == 0)
check("Dashboard de 7 dias até o corte: as chamadas estão em oute-agent (2) e em alfa (2)",
      [kpi(get(app, "/", q(BEFORE, r))[1]) for r in (LEGACY, "alfa")] == [2, 2])
check("Dashboard de 7 dias com o corte no meio, 'sem repositório': só as 2 chamadas de depois do corte", kpi(get(app, "/", q(ACROSS, NONE))[1]) == 2)
check("Uso: o mesmo ('sem repositório' 0 até o corte e 2 com o corte no meio; oute-agent 1 na janela que começa em 10-01)",
      [uso(get(app, "/uso", q(BEFORE, NONE))[1]), uso(get(app, "/uso", q(ACROSS, NONE))[1]), uso(get(app, "/uso", q(ACROSS, LEGACY))[1])] == [0, 2, 1])
check("Conversas: 'sem repositório' vazio até o corte; com o corte no meio, só as conversas de depois",
      ids(get(app, "/conversas", q(BEFORE, NONE))[1]) == [] and ids(get(app, "/conversas", q(ACROSS, NONE))[1]) == ["n-borda", "n-nova"])
check("Conversas: o histórico aparece em oute-agent, e o que o repo_infer achou, em alfa",
      ids(get(app, "/conversas", q(BEFORE, LEGACY))[1]) == ["h-velha"] and ids(get(app, "/conversas", q(BEFORE, "alfa"))[1]) == ["c-alfa", "h-pasta"])
check("o filtro oferece oute-agent entre os repositórios da janela",
      f'<option value="{LEGACY}"' in get(app, "/uso", BEFORE)[1])

# ---- 4. as duas pontas usam a mesma data e o mesmo valor
check("o corte do código é 2026-10-06T00:00:00Z e o valor é oute-agent", R.LEGACY_CUTOFF_NS == ts(CUT) and R.LEGACY_REPO == LEGACY)
check("legacy(): sem repositório antes do corte = oute-agent; na hora do corte e depois = None; com repositório = ele",
      [R.legacy(None, ts(CUT) - 1), R.legacy(None, ts(CUT)), R.legacy(None, ts(NEW)), R.legacy("alfa", ts(OLD)), R.legacy("alfa", ts(NEW))]
      == [LEGACY, None, None, "alfa", "alfa"])
check("apply_legacy() num banco já acertado: nenhuma linha", R.apply_legacy(st.con) == {"spans": 0, "logs": 0, "metrics": 0})

# ---- 5. falha do acerto: nada muda pela metade e a subida segue


class Broken:
    """Conexão que falha no UPDATE de `logs`, depois de `spans` já ter sido alterado na transação."""

    def __init__(self, con):
        self.con, self.sql = con, []

    def execute(self, sql, params=None):
        self.sql.append(sql.split()[0])
        if sql.startswith("UPDATE logs"):
            raise duckdb.Error("falha de teste")
        return self.con.execute(sql, params) if params is not None else self.con.execute(sql)


class Dead:
    def execute(self, *a):
        raise duckdb.Error("falha de teste")


class Keep(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


keep = Keep()
logging.getLogger("agent_studio").addHandler(keep)
logging.getLogger("agent_studio").setLevel(logging.INFO)
st.con.execute("UPDATE spans SET oute_repo = NULL WHERE session_id = 'h-velha'")
st.con.execute("UPDATE logs SET oute_repo = NULL WHERE session_id = 'h-velha'")
broken = Broken(st.con)
check("falha no meio: devolve None, sem exceção", R.apply_legacy(broken) is None)
check("falha no meio: a transação foi desfeita (ROLLBACK) e nenhum span ficou com o valor",
      broken.sql[-1] == "ROLLBACK" and "COMMIT" not in broken.sql
      and st.con.execute("SELECT count(*) FROM spans WHERE session_id = 'h-velha' AND oute_repo IS NOT NULL").fetchone()[0] == 0)
check("falha já no começo: devolve None, sem exceção", R.apply_legacy(Dead()) is None)
WARN = "repo: acerto do histórico falhou (Error); o histórico de antes do corte segue sem repositório"
check("falha: um aviso por falha no log, só com o tipo do erro (sem o texto dele)", keep.lines == [WARN] * 2)
check("depois da falha, a aplicação seguinte grava tudo (3 spans e 1 log)", R.apply_legacy(st.con) == {"spans": 3, "logs": 1, "metrics": 0}
      and snapshot(st.con) == first)
check("quando grava, uma linha no log com as linhas por tabela",
      keep.lines[2:] == ["repo: histórico sem repositório de antes do corte gravado como oute-agent, linhas: {'spans': 3, 'logs': 1, 'metrics': 0}"])
st.close()
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 47
check_end
