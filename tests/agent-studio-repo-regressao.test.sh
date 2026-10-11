#!/usr/bin/env bash
# Testes do acerto do histórico da regressão dos agentes no agent-studio (#803, ADR-08 "Filtro de repositório"): fato sem
# repositório com `oute.task.id` começando por `regression-` fica com `oute-agent` na coluna `oute_repo`, em qualquer hora.
# Vale na ingestão (`otlp.*_rows`, o caminho do collector e do replay) e na subida (`store.Store`, depois do `repo_infer`
# e do acerto do corte da #617), numa transação só. Fato com repositório nunca é trocado, conversa comum sem repositório
# depois do corte segue "sem repositório", e o JSON `resource_attributes` fica como chegou. As datas são fixas: nada aqui
# depende do relógio. Sem Docker e sem processo em segundo plano.
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
import sys
from datetime import datetime, timezone

import duckdb
from agent_studio import otlp, repo as R, store as ST
from otlp_json import event, kv, rl, rs, span
from pycheck import check
from studio_db import StudioDB

tmp = sys.argv[1]
SEC = 10**9
sec = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp())
ts = lambda s: sec(s) * SEC
# valores escritos por extenso, como na issue #803 e no ADR-08: o teste não os lê do código
LEGACY = "oute-agent"
OLD, NEW = "2026-10-05T12:00:00", "2026-10-07T12:00:00"   # antes e depois do corte da #617 (2026-10-06T00:00:00Z)
REG_OLD, REG_NEW = "regression-20261005-120000-abc", "regression-20261007-120000-def"
RES = {"host.name": "h1", "service.name": "oute"}   # sem oute.task.repo

# ---- 1. ingestão: a linha que o OTLP vira (o caminho do collector e do replay)


def span_row(at, res=RES, rec=None):
    return otlp.span_rows({"resourceSpans": [rs(res, [span("claude_code.llm_request", sec(at), 2, rec or {})])]}, ts(NEW))[0]


def log_row(at, res=RES, rec=None):
    return otlp.log_rows({"resourceLogs": [rl(res, [event(sec(at), "oute.exemplo", f"ev-{at}", rec or {})])]}, ts(NEW))[0]


def metric_row(at, res=RES):
    point = {"timeUnixNano": str(ts(at)), "asInt": "1", "attributes": []}
    return otlp.metric_rows({"resourceMetrics": [{"resource": {"attributes": kv(res)}, "scopeMetrics": [
        {"metrics": [{"name": "m", "gauge": {"dataPoints": [point]}}]}]}]}, ts(NEW))[0]


for name, row in (("span", span_row), ("log", log_row), ("métrica", metric_row)):
    check(f"ingestão, {name}: regressão depois do corte, sem repositório, entra com oute-agent",
          row(NEW, {**RES, "oute.task.id": REG_NEW})["oute_repo"] == LEGACY)
    check(f"ingestão, {name}: regressão antes do corte segue com oute-agent",
          row(OLD, {**RES, "oute.task.id": REG_OLD})["oute_repo"] == LEGACY)
    check(f"ingestão, {name}: conversa comum depois do corte segue sem repositório (NULL)",
          row(NEW, {**RES, "oute.task.id": "t-comum"})["oute_repo"] is None)
    check(f"ingestão, {name}: regressão com repositório próprio fica com o dele",
          row(NEW, {**RES, "oute.task.id": REG_NEW, "oute.task.repo": "alfa"})["oute_repo"] == "alfa")
    check(f"ingestão, {name}: o resource_attributes fica como chegou (sem oute.task.repo no JSON)",
          "oute.task.repo" not in row(NEW, {**RES, "oute.task.id": REG_NEW})["resource_attributes"])
check("ingestão: o oute.task.id do registro vale (não só o do resource)",
      span_row(NEW, RES, {"oute.task.id": REG_NEW})["oute_repo"] == LEGACY)
check("ingestão: task id que só contém 'regression-' no meio não entra",
      span_row(NEW, {**RES, "oute.task.id": "t-" + REG_NEW})["oute_repo"] is None)
check("ingestão: task id 'regression' sem o traço final não entra",
      span_row(NEW, {**RES, "oute.task.id": "regression"})["oute_repo"] is None)
check("legacy(): regressão sem repositório = oute-agent em qualquer hora; conversa comum depois do corte = None",
      [R.legacy(None, ts(NEW), REG_NEW), R.legacy(None, ts(NEW), "t-comum"), R.legacy(None, ts(NEW)), R.legacy("alfa", ts(NEW), REG_NEW)]
      == [LEGACY, None, None, "alfa"])

# ---- 2. subida: o banco que já existe, com fatos sem repositório
db = StudioDB(tmp, "r")


def call(at, conv, task=None):
    db.span(ts(at), 2, model="claude-sonnet-5", conv=conv, task=task, input=10, output=1)


call(NEW, "r-nova", REG_NEW)                 # regressão depois do corte, sem repositório
call(OLD, "r-velha", REG_OLD)                # regressão antes do corte, sem repositório
call(NEW, "r-com", REG_NEW)                  # regressão que terá repositório próprio
db.log(ts(NEW), "oute.exemplo", {}, task=REG_NEW, conv="r-nova")
call(NEW, "t-comum")                         # conversa comum depois do corte, sem repositório
db.log(ts(NEW), "oute.exemplo", {}, conv="t-comum")
st = db.flush()
st.write({"metrics": [{"dedupe_key": "m:reg", "time_unix_nano": ts(NEW), "metric_name": "m", "metric_type": "gauge", "value": 1.0,
                       "oute_repo": None, "oute_task_id": REG_NEW, "resource_attributes": '{"oute.task.id": "%s"}' % REG_NEW, "attributes": "{}",
                       "point": "{}", "received_unix_nano": ts(NEW)}]})
st.con.execute("UPDATE spans SET oute_repo = 'alfa' WHERE session_id = 'r-com'")
check("antes da subida: as regressões sem repositório estão com NULL (o banco como era)",
      st.con.execute("SELECT count(*) FROM spans WHERE oute_task_id LIKE 'regression-%' AND oute_repo IS NULL").fetchone()[0] == 2)
st.close()

st = ST.Store(f"{tmp}/r.duckdb")
got = {c: sorted(v, key=str) for c, v in st.con.execute("SELECT session_id, list(DISTINCT oute_repo) FROM spans GROUP BY ALL").fetchall()}
check("subida: regressão depois do corte, sem repositório, vira oute-agent (span)", got["r-nova"] == [LEGACY])
check("subida: regressão antes do corte também vira oute-agent", got["r-velha"] == [LEGACY])
check("subida: regressão com repositório próprio não é trocada", got["r-com"] == ["alfa"])
check("subida: conversa comum depois do corte segue sem repositório", got["t-comum"] == [None])
check("subida: o log da regressão vira oute-agent; o da conversa comum segue NULL",
      st.con.execute("SELECT session_id, oute_repo FROM logs ORDER BY 1").fetchall() == [("r-nova", LEGACY), ("t-comum", None)])
check("subida: a métrica da regressão vira oute-agent",
      st.con.execute("SELECT oute_repo FROM metrics WHERE dedupe_key = 'm:reg'").fetchone() == (LEGACY,))
check("subida: o resource_attributes não ganha oute.task.repo",
      st.con.execute("SELECT count(*) FROM spans WHERE oute_repo = ? AND resource_attributes::VARCHAR LIKE '%oute.task.repo%'", [LEGACY]).fetchone()[0] == 0)
first = [st.con.execute(f"SELECT dedupe_key, oute_repo, resource_attributes::VARCHAR FROM {t} ORDER BY 1").fetchall() for t in ("spans", "logs", "metrics")]
st.close()

st = ST.Store(f"{tmp}/r.duckdb")
again = [st.con.execute(f"SELECT dedupe_key, oute_repo, resource_attributes::VARCHAR FROM {t} ORDER BY 1").fetchall() for t in ("spans", "logs", "metrics")]
check("subida de novo: nada muda", again == first)
check("aplicação de novo: nenhuma linha", R.apply_legacy(st.con) == {"spans": 0, "logs": 0, "metrics": 0})
st.con.execute("UPDATE spans SET oute_repo = NULL WHERE session_id = 'r-nova'")
check("linha desfeita de propósito volta a ser gravada: 1 span; o log já estava certo",
      R.apply_legacy(st.con) == {"spans": 1, "logs": 0, "metrics": 0})
st.close()


class Dead:
    def execute(self, *a):
        raise duckdb.Error("falha de teste")


check("falha no acerto: devolve None, sem exceção (a subida segue)", R.apply_legacy(Dead()) is None)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 31
check_end
