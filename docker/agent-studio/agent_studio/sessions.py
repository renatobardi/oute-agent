"""Sessões para a tela (ADR-08 §9, #207): as conversas agrupadas pela sessão do `oute-task` e, sem ela, por conversa.

**Sessão** = `oute.task.id` (CONTEXT.md), em `spans.oute_task_id` e `logs.oute_task_id`: a identidade vai no
resource das conversas e nos eventos `oute.task.*` (ADR-04, #128). **Conversa** = `session.id`. Conversa sem
`oute.task.id` não é de sessão nenhuma: fica no grupo "sem sessão", uma linha por `session.id`.

- DuckDB = os fatos (conversas, hora do fato, chamadas, tokens, custo, p95, erros, eventos da sessão).
- SurrealDB = o estado derivado da sessão (`sessao:<oute.task.id>`: repo, slug, agente, estado, rodada e worker) e
  da rodada (`rodada:<oute.swarm.round>`). Só enfeita: sem ele a tela segue com o que o DuckDB tem.

Chamadas, tokens, custo e p95 saem do `usage.aggregate` (#203) com a chave `session`; o modelo de cada sessão e de
cada conversa é o das chamadas ao modelo (a mesma agregação, com a chave `model`). Nenhuma regra de custo mora aqui.
"""
import json

from . import repo as repo_mod, usage as usage_mod
from .conversations import LIST_LIMIT, _dicts, _first, _pretty

CONV_LIMIT = 20     # conversas mostradas por sessão na lista (as mais recentes); a página da sessão mostra todas
EVENT_LIMIT = 200   # eventos mostrados na página da sessão (os primeiros, pela hora do fato)
_ALL = 2**63        # fim de janela que pega tudo (a hora do fato cabe em 63 bits: `app._parse_time`)

# um fato por linha: spans e logs com sessão ou com conversa
_FACTS = """
    SELECT oute_task_id, session_id, host_name, oute_instance, oute_agent, service_name, oute_swarm_round, {repo} AS oute_repo,
           time_unix_nano AS t, COALESCE(end_unix_nano, time_unix_nano) AS e, TRUE AS is_span
    FROM spans WHERE {where}
    UNION ALL
    SELECT oute_task_id, session_id, host_name, oute_instance, oute_agent, service_name, oute_swarm_round, {repo},
           time_unix_nano, time_unix_nano, FALSE
    FROM logs WHERE {where}"""

# uma linha por par (sessão, conversa); conversa nula = eventos da própria sessão (`oute.task.*`)
_PAIRS = f"""
    SELECT oute_task_id AS session, session_id AS id, min(t) AS start_ns, max(e) AS end_ns,
           {_first('host_name')} AS host, {_first('oute_instance')} AS instance, {_first('oute_agent')} AS agent,
           {_first('service_name')} AS service, {_first('oute_swarm_round')} AS swarm_round, {_first('oute_repo')} AS repo,
           count(*) FILTER (WHERE is_span) AS spans, count(*) FILTER (WHERE NOT is_span) AS logs,
           count(*) FILTER (WHERE t >= ? AND t < ?) AS in_window
    FROM facts GROUP BY oute_task_id, session_id"""

# estado derivado (#187), pelo id do registro (sem varrer a tabela; tabela que ainda não existe = nenhum registro)
_STATE = (
    "SELECT record::id(id) AS id, repo, slug, agent, legacy, state, opened_at, reopened_at, removed_at, "
    "removed_reason, (IF rodada THEN record::id(rodada) END) AS round, rodada.label AS round_label, "
    "rodada.state AS round_state, worker.slug AS worker, worker.issue AS issue "
    'FROM $ids.map(|$i| type::record("sessao", $i)); '
    'SELECT record::id(id) AS id, label, state FROM $rounds.map(|$i| type::record("rodada", $i));')


def _pairs(con, where, params, from_ns=0, to_ns=_ALL):
    return _dicts(con.execute(f"WITH facts AS ({_FACTS.format(where=where, repo=repo_mod.COL)}) {_PAIRS}",
                              [*params, *params, from_ns, to_ns]))


def blank(session_id):
    """Sessão sem fato nenhum no DuckDB (só o registro do SurrealDB): tudo vazio, somas zeradas."""
    return {"id": session_id, "start_ns": None, "end_ns": None, "duration_ns": None, "in_window": 0, "host": None,
            "instance": None, "swarm_round": None, "repo": None, "agents": [], "conversations": [], "conversation_count": 0,
            "hidden": 0, "events": 0, "models": [], "usage": usage_mod.rendered({}, ()), "state": None, "round": None}


def _group(rows):
    """Pares (sessão, conversa) -> (sessões, conversas sem sessão), sem ordem definida."""
    by_session, loose = {}, []
    for r in sorted(rows, key=lambda r: (r["start_ns"], r["id"] or "")):
        r["duration_ns"] = r["end_ns"] - r["start_ns"]
        r["models"], r["usage"] = [], None
        if r["session"] is None:
            loose.append(r)
        else:
            by_session.setdefault(r["session"], []).append(r)
    sessions = []
    for sid, parts in by_session.items():
        convs = [r for r in parts if r["id"] is not None]
        s = blank(sid)
        s.update(start_ns=min(r["start_ns"] for r in parts), end_ns=max(r["end_ns"] for r in parts),
                 in_window=sum(r["in_window"] for r in parts), conversations=convs, conversation_count=len(convs),
                 # o agente da sessão é o das conversas: nos eventos `oute.task.*`, `oute.agent` é quem chamou
                 agents=sorted({r["agent"] for r in convs if r["agent"]}),
                 events=sum(r["spans"] + r["logs"] for r in parts if r["id"] is None))
        for col in ("host", "instance", "swarm_round", "repo"):
            s[col] = next((r[col] for r in parts if r[col] is not None), None)
        s["duration_ns"] = s["end_ns"] - s["start_ns"]
        sessions.append(s)
    return sessions, loose


def _models(calls):
    """{modelo: chamadas} -> lista, do mais chamado para o menos."""
    return [{"model": m, "calls": n} for m, n in sorted(calls.items(), key=lambda kv: (-kv[1], kv[0] or ""))]


def _with_usage(con, sessions, loose, prices):
    """Põe em cada sessão e em cada conversa as somas e o p95 do #203 (inteiros, não só o trecho da janela) e os
    modelos chamados."""
    items = [x for x in sessions + loose if x["start_ns"] is not None]
    if not items:
        return
    lo, hi = min(x["start_ns"] for x in items), max(x["end_ns"] for x in items) + 1
    by_session = usage_mod.aggregate(con, lo, hi, prices, ("session",))
    by_conv = usage_mod.aggregate(con, lo, hi, prices, ("session", "conversation"))
    session_models, conv_models = {}, {}
    for (sid, cid, model), a in usage_mod.aggregate(con, lo, hi, prices, ("session", "conversation", "model")).items():
        if a["calls"]:
            conv_models.setdefault((sid, cid), {})[model] = a["calls"]
            calls = session_models.setdefault(sid, {})
            calls[model] = calls.get(model, 0) + a["calls"]
    for s in sessions:
        s["usage"] = usage_mod.rendered(by_session, (s["id"],))
        s["models"] = _models(session_models.get(s["id"], {}))
    for c in [c for s in sessions for c in s["conversations"]] + loose:
        c["usage"] = usage_mod.rendered(by_conv, (c["session"], c["id"]))
        c["models"] = _models(conv_models.get((c["session"], c["id"]), {}))


def listing(con, from_ns, to_ns, prices, host=None, agent=None, limit=LIST_LIMIT, conv_limit=CONV_LIMIT, repo=None):
    """Sessões e conversas sem sessão com algum fato na janela [from_ns, to_ns), da mais recente para a mais antiga
    (pelo início). Os números são da sessão (ou da conversa) inteira.

    `host`/`agent`/`repo` filtram; `hosts`/`agents`/`repos` são as opções do filtro (da janela inteira); o repositório da
    sessão é o primeiro que os fatos dela trazem (#528; `repo.NONE` filtra as sem repositório). No máximo `limit` sessões
    e `limit` conversas sem sessão (`total`/`loose_total` dizem quantas há) e, em cada sessão, as `conv_limit`
    conversas mais recentes (`hidden` = quantas ficaram de fora)."""
    sessions, loose = _group(_pairs(con, "(oute_task_id IS NOT NULL OR session_id IS NOT NULL)", [], from_ns, to_ns))
    sessions = [s for s in sessions if s["in_window"]]
    loose = [c for c in loose if c["in_window"]]
    hosts = sorted({x["host"] for x in sessions + loose if x["host"]})
    agents = sorted({a for s in sessions for a in s["agents"]} | {c["agent"] for c in loose if c["agent"]})
    repos = sorted({x["repo"] for x in sessions + loose if x["repo"]})
    if repo:
        sessions = [s for s in sessions if _in_repo(s, repo)]
        loose = [c for c in loose if _in_repo(c, repo)]
    if host:
        sessions = [s for s in sessions if s["host"] == host]
        loose = [c for c in loose if c["host"] == host]
    if agent:
        sessions = [s for s in sessions if agent in s["agents"]]
        loose = [c for c in loose if c["agent"] == agent]
    recent = lambda x: (-x["start_ns"], x["id"])  # noqa: E731
    total, loose_total = len(sessions), len(loose)
    sessions, loose = sorted(sessions, key=recent)[:limit], sorted(loose, key=recent)[:limit]
    for s in sessions:
        s["hidden"] = max(0, len(s["conversations"]) - conv_limit)
        s["conversations"] = s["conversations"][s["hidden"]:]
    _with_usage(con, sessions, loose, prices)
    return {"sessions": sessions, "total": total, "loose": loose, "loose_total": loose_total,
            "hosts": hosts, "agents": agents, "repos": repos}


def _in_repo(x, repo):
    return x["repo"] is None if repo == repo_mod.NONE else x["repo"] == repo


def _phase(raw):
    """Fase do AI-DLC que o seletor escolheu (`oute.task.phase`, no `oute.task.opened`); `None` se o evento não a traz."""
    try:
        value = json.loads(raw) if raw else None
    except ValueError:
        return None
    phase = value.get("oute.task.phase") if isinstance(value, dict) else None
    return phase if isinstance(phase, str) and phase else None


def detail(con, session_id, prices, event_limit=EVENT_LIMIT):
    """Uma sessão com todas as conversas e os eventos dela (logs com o `oute.task.id` e sem conversa: `oute.task.*`
    e o que mais levar a identidade da sessão); `None` se o DuckDB não tem fato nenhum dela."""
    sessions, _ = _group(_pairs(con, "oute_task_id = ?", [session_id]))
    if not sessions:
        return None
    _with_usage(con, sessions, [], prices)
    events = _dicts(con.execute(
        "SELECT time_unix_nano, severity_number, severity_text, event_name, body, attributes "
        "FROM logs WHERE oute_task_id = ? AND session_id IS NULL ORDER BY time_unix_nano, dedupe_key LIMIT ?",
        [session_id, event_limit + 1]))
    truncated = len(events) > event_limit
    events = events[:event_limit]
    phase = None
    for e in events:
        phase = phase or _phase(e["attributes"])
        e["attributes"] = _pretty(e["attributes"])
    return {"session": sessions[0], "events": events, "events_truncated": truncated, "phase": phase}


def with_state(surreal, sessions):
    """Põe em cada sessão o registro `sessao` do SurrealDB (`state`; `None` = sem registro) e a rodada (`round`).

    A rodada vem do fato (`oute.swarm.round` no DuckDB) ou, sem ele, do link do registro. Erro do SurrealDB levanta
    (SurrealError): quem chama decide seguir sem o estado."""
    if not sessions:
        return
    rounds = sorted({s["swarm_round"] for s in sessions if s["swarm_round"]})
    found = surreal.query(_STATE, {"ids": [s["id"] for s in sessions], "rounds": rounds})
    records = {r["id"]: r for r in found[0]["result"] or []}
    by_round = {r["id"]: r for r in found[1]["result"] or []}
    for s in sessions:
        rec = records.get(s["id"])
        s["state"] = rec
        s["swarm_round"] = s["swarm_round"] or (rec or {}).get("round")
        if s["swarm_round"]:
            linked = rec if rec and rec.get("round") == s["swarm_round"] else {}
            s["round"] = by_round.get(s["swarm_round"]) or {"label": linked.get("round_label"),
                                                             "state": linked.get("round_state")}
