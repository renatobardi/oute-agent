"""Conversas para a tela (ADR-08 §9, #206): lista por host/agente e detalhe (árvore de spans + logs).

**Conversa** = `session.id` do agente (CONTEXT.md), em `spans.session_id` e `logs.session_id`. Tudo pela **hora do
fato** (`time_unix_nano`), nunca pela de chegada. Chamadas, tokens e custo (real e estimado) saem do
`usage.aggregate` e do `cost.py` (#203): nenhuma regra de custo mora aqui.
"""
import json

from . import repo as repo_mod, usage as usage_mod
from .cost import (LOG_SEVERITY_ERROR, MODEL_CALL_PARAMS, MODEL_CALL_SQL, SPAN_STATUS_ERROR, call_cost, is_subscription,
                   spans_with_cost)

LIST_LIMIT = 200    # conversas por página da lista (as mais recentes)
SPAN_LIMIT = 5000   # spans na árvore de uma conversa (os primeiros, pela hora do fato)
LOG_PAGE = 200      # logs por página do detalhe

# um fato por linha: spans e logs com conversa
_FACTS = """
    SELECT session_id, host_name, oute_instance, oute_agent, service_name, oute_task_id, oute_swarm_round, {repo} AS repo,
           time_unix_nano AS t, COALESCE(end_unix_nano, time_unix_nano) AS e, TRUE AS is_span
    FROM spans WHERE session_id IS NOT NULL{where}
    UNION ALL
    SELECT session_id, host_name, oute_instance, oute_agent, service_name, oute_task_id, oute_swarm_round, {repo},
           time_unix_nano, time_unix_nano, FALSE
    FROM logs WHERE session_id IS NOT NULL{where}"""


def _first(col):
    # o primeiro valor presente, pela hora do fato
    return f"arg_min({col}, t) FILTER (WHERE {col} IS NOT NULL)"


_HEAD = f"""
    SELECT session_id AS id, min(t) AS start_ns, max(e) AS end_ns,
           {_first('host_name')} AS host, {_first('oute_agent')} AS agent,
           {_first('oute_instance')} AS instance, {_first('service_name')} AS service,
           {_first('oute_task_id')} AS task_id, {_first('oute_swarm_round')} AS swarm_round, {_first('repo')} AS repo,
           count(*) FILTER (WHERE is_span) AS spans, count(*) FILTER (WHERE NOT is_span) AS logs"""


def _dicts(cur):
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _with_usage(con, convs, prices, effective=False):
    """Põe em cada conversa as somas do #203 (a conversa inteira, não só o trecho da janela)."""
    if not convs:
        return
    lo, hi = min(c["start_ns"] for c in convs), max(c["end_ns"] for c in convs) + 1
    groups = usage_mod.aggregate(con, lo, hi, prices, ("conversation",), effective=effective)
    for c in convs:
        c["duration_ns"] = c["end_ns"] - c["start_ns"]
        c["usage"] = usage_mod.rendered(groups, (c["id"],))


def listing(con, from_ns, to_ns, prices, host=None, agent=None, limit=LIST_LIMIT, repo=None, effective=False):
    """Conversas com algum fato na janela [from_ns, to_ns), da mais recente para a mais antiga (pelo início).

    `host`/`agent`/`repo` filtram; `hosts`/`agents`/`repos` são as opções do filtro (da janela inteira); o repositório
    da conversa é o primeiro que os fatos dela trazem (`repo.NONE` filtra as sem repositório). Devolve no máximo
    `limit` conversas; `total` diz quantas a janela e o filtro têm."""
    cur = con.execute(
        f"WITH facts AS ({_FACTS.format(where='', repo=repo_mod.COL)}) {_HEAD}, "
        "count(*) FILTER (WHERE t >= ? AND t < ?) AS in_window "
        "FROM facts GROUP BY session_id HAVING in_window > 0 ORDER BY start_ns DESC, id",
        [from_ns, to_ns])
    convs = _dicts(cur)
    hosts = sorted({c["host"] for c in convs if c["host"]})
    agents = sorted({c["agent"] for c in convs if c["agent"]})
    repos = sorted({c["repo"] for c in convs if c["repo"]})
    if repo:
        convs = [c for c in convs if (c["repo"] is None if repo == repo_mod.NONE else c["repo"] == repo)]
    if host:
        convs = [c for c in convs if c["host"] == host]
    if agent:
        convs = [c for c in convs if c["agent"] == agent]
    total = len(convs)
    convs = convs[:limit]
    _with_usage(con, convs, prices, effective)
    return {"conversations": convs, "total": total, "hosts": hosts, "agents": agents, "repos": repos}


def tree(spans):
    """Spans (em ordem de início) -> a mesma lista em ordem de árvore (pai antes dos filhos), com `depth`.

    Raiz = span sem pai. Span cujo pai não está na conversa (não chegou, ficou fora do limite ou é de outra
    conversa) também vira raiz, marcado `orphan`. Ciclo de pais (dado ruim) não some: entra como raiz órfã."""
    by_id = {(s["trace_id"], s["span_id"]): s for s in spans}
    children, roots = {}, []
    for s in spans:
        key = (s["trace_id"], s["span_id"])
        parent = (s["trace_id"], s["parent_span_id"]) if s["parent_span_id"] else None
        if parent and parent != key and parent in by_id:
            s["orphan"] = False
            children.setdefault(parent, []).append(s)
        else:
            s["orphan"] = bool(s["parent_span_id"])
            roots.append(s)
    out, seen = [], set()

    def walk(root):
        stack = [(root, 0)]
        while stack:
            s, depth = stack.pop()
            key = (s["trace_id"], s["span_id"])
            if key in seen:
                continue
            seen.add(key)
            s["depth"] = depth
            out.append(s)
            stack.extend((c, depth + 1) for c in reversed(children.get(key, [])))

    for r in roots:
        walk(r)
    for s in spans:
        if (s["trace_id"], s["span_id"]) not in seen:
            s["orphan"] = True
            walk(s)
    return out


def detail(con, session_id, prices, span_limit=SPAN_LIMIT, log_limit=LOG_PAGE, errors_only=False, effective=False):
    """Cabeçalho, somas, árvore de spans e a primeira página de logs de uma conversa; `None` se ela não existe.

    `errors_only` (#530): só spans com status de erro e logs ERROR ou acima (o que o contador de erros soma); o
    cabeçalho e as somas seguem sendo os da conversa inteira. `effective` (#531): a chamada de assinatura custa 0, na
    soma e na linha de cada span."""
    head = _dicts(con.execute(
        f"WITH facts AS ({_FACTS.format(where=' AND session_id = ?', repo=repo_mod.COL)}) {_HEAD} FROM facts GROUP BY session_id",
        [session_id, session_id]))
    if not head:
        return None
    conv = head[0]
    _with_usage(con, [conv], prices, effective)
    # custo efetivo de cada span (o do span ou o do log `api_request` da conversa, #157), pela regra do `cost.py`
    table, params = spans_with_cost("session_id = ?", [session_id], "session_id = ?", [session_id])
    spans = _dicts(con.execute(
        "SELECT trace_id, span_id, parent_span_id, name, time_unix_nano, duration_ns, model, input_tokens, "
        f"output_tokens, cache_read_tokens, cache_creation_tokens, cost_usd, status_code, oute_agent, ({MODEL_CALL_SQL}) AS is_call "
        f"FROM {table}{' WHERE status_code = ?' if errors_only else ''} ORDER BY time_unix_nano, trace_id, span_id LIMIT ?",
        [*MODEL_CALL_PARAMS, *params, *([SPAN_STATUS_ERROR] if errors_only else []), span_limit]))
    for s in spans:
        s["error"] = s["status_code"] == SPAN_STATUS_ERROR
        # tokens e custo só nas chamadas ao modelo: o que aparece na coluna é o que entra na soma (#203)
        s["cost_kind"], s["cost"] = None, None
        if s["is_call"]:
            s["cost_kind"], s["cost"] = call_cost(
                s["cost_usd"], s["input_tokens"], s["output_tokens"], s["cache_read_tokens"],
                s["cache_creation_tokens"], prices.lookup(s["model"], s["time_unix_nano"]))
            if effective and is_subscription(s["oute_agent"]):
                s["cost_kind"], s["cost"] = "effective", 0.0
    if errors_only:
        # sem os pais a árvore não vale: uma lista plana, pela hora do fato
        for s in spans:
            s["depth"], s["orphan"] = 0, False
        shown, total = spans, conv["usage"]["errors"]["spans"]
    else:
        shown, total = tree(spans), conv["spans"]
    return {"conversation": conv, "spans": shown, "spans_truncated": total > len(spans),
            **logs(con, session_id, 0, log_limit, errors_only)}


def logs(con, session_id, offset=0, limit=LOG_PAGE, errors_only=False):
    """Uma página dos logs da conversa, em ordem da hora do fato. `next_offset` = há mais (senão `None`).
    `errors_only`: só os de severidade ERROR ou acima (#530)."""
    rows = _dicts(con.execute(
        "SELECT time_unix_nano, severity_number, severity_text, event_name, body, trace_id, span_id, attributes "
        f"FROM logs WHERE session_id = ?{' AND severity_number >= ?' if errors_only else ''} "
        "ORDER BY time_unix_nano, dedupe_key LIMIT ? OFFSET ?",
        [session_id, *([LOG_SEVERITY_ERROR] if errors_only else []), limit + 1, offset]))
    more = len(rows) > limit
    rows = rows[:limit]
    for r in rows:
        r["attributes"] = _pretty(r["attributes"])
    return {"logs": rows, "next_offset": offset + limit if more else None}


def span(con, trace_id, span_id):
    """Um span com o conteúdo completo (atributos, eventos, links) para o detalhe; `None` se não existe."""
    rows = _dicts(con.execute(
        "SELECT trace_id, span_id, parent_span_id, name, session_id, time_unix_nano, duration_ns, kind, status_code, "
        "status_message, scope_name, attributes, resource_attributes, events, links "
        "FROM spans WHERE trace_id = ? AND span_id = ?", [trace_id, span_id]))
    if not rows:
        return None
    s = rows[0]
    for col in ("attributes", "resource_attributes", "events", "links"):
        s[col] = _pretty(s[col])
    return s


def _pretty(raw):
    """Coluna JSON -> texto indentado para leitura; vazio (`{}`, `[]`, NULL) = `None`."""
    value = json.loads(raw) if raw else None
    if not value:
        return None
    return json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True)
