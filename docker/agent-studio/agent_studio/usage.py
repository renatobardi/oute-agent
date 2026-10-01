"""Agregação de uso (ADR-08 §9, #203): custo real e estimado, tokens, erros, p95 e série diária, com qualquer
agrupamento de `day`/`host`/`agent`/`model`/`conversation`. Tudo pela **hora do fato** (`time_unix_nano`), nunca pela de chegada;
dias em UTC. As regras de escopo e de custo estão no `cost.py`.

`aggregate` é a peça reusável (alertas #204, tray #205, tela #206); `usage` monta a resposta do `/v1/usage`.
"""
from datetime import datetime, timezone

from .cost import (LOG_SEVERITY_ERROR, MODEL_CALL_PARAMS, MODEL_CALL_SQL, SPAN_STATUS_ERROR,
                   estimate_cost_usd)

DAY_NS = 86_400_000_000_000
KEYS = ("day", "host", "agent", "model", "conversation")
# conversation = `session.id` (a conversa do agente, CONTEXT.md), para a tela (#206)
_COLS = {"day": f"CAST(time_unix_nano // {DAY_NS} AS BIGINT)", "host": "host_name", "agent": "oute_agent",
         "model": "model", "conversation": "session_id"}
# logs não têm modelo: agrupados por modelo, caem no modelo nulo
_LOG_COLS = {**_COLS, "model": "CAST(NULL AS VARCHAR)"}
_WINDOW = "time_unix_nano >= ? AND time_unix_nano < ?"


def _query(con, keys, cols, aggs, table, where, params):
    """Linhas como dict; sem chaves, uma linha só (total)."""
    select = [f"{cols[k]} AS {k}" for k in keys] + aggs
    group = " GROUP BY ALL" if keys else ""
    cur = con.execute(f"SELECT {', '.join(select)} FROM {table} WHERE {where}{group}", params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _calls(con, keys, from_ns, to_ns):
    aggs = ["count(*) AS calls", "count(cost_usd) AS calls_real", "sum(cost_usd) AS cost_real"]
    for t in ("input", "output", "cache_read", "cache_creation"):
        aggs.append(f"COALESCE(sum({t}_tokens), 0) AS {t}")
        aggs.append(f"COALESCE(sum({t}_tokens) FILTER (WHERE cost_usd IS NULL), 0) AS est_{t}")
    return _query(con, keys, _COLS, aggs, "spans", f"{_WINDOW} AND {MODEL_CALL_SQL}",
                  [from_ns, to_ns, *MODEL_CALL_PARAMS])


def _p95(con, keys, from_ns, to_ns):
    return _query(con, keys, _COLS, ["quantile_cont(CAST(duration_ns AS DOUBLE), 0.95) / 1e6 AS p95"], "spans",
                  f"{_WINDOW} AND duration_ns IS NOT NULL AND {MODEL_CALL_SQL}", [from_ns, to_ns, *MODEL_CALL_PARAMS])


def _span_errors(con, keys, from_ns, to_ns):
    return _query(con, keys, _COLS, ["count(*) AS n"], "spans", f"{_WINDOW} AND status_code = ?",
                  [from_ns, to_ns, SPAN_STATUS_ERROR])


def _log_errors(con, keys, from_ns, to_ns):
    return _query(con, keys, _LOG_COLS, ["count(*) AS n"], "logs", f"{_WINDOW} AND severity_number >= ?",
                  [from_ns, to_ns, LOG_SEVERITY_ERROR])


def _empty():
    return {"calls": 0, "tokens": dict.fromkeys(("input", "output", "cache_read", "cache_creation"), 0),
            "real_usd": None, "estimated_usd": None, "real_calls": 0, "estimated_calls": 0, "unpriced_calls": 0,
            "unpriced_models": set(), "span_errors": 0, "log_errors": 0, "p95": None}


def _add(a, b):
    return b if a is None else a + b


def aggregate(con, from_ns, to_ns, prices, keys=("host", "agent", "model")):
    """{tupla das chaves: acumulador} na janela [from_ns, to_ns). O custo estimado é calculado por modelo e
    depois somado; sem `model` nas chaves, o agrupamento fino inclui o modelo e sobe para `keys`."""
    keys = tuple(keys)
    if set(keys) - set(KEYS):
        raise ValueError(f"chave inválida: {keys}")
    groups = {} if keys else {(): _empty()}

    def acc(rec):
        return groups.setdefault(tuple(rec[k] for k in keys), _empty())

    fine = keys if "model" in keys else keys + ("model",)
    for rec in _calls(con, fine, from_ns, to_ns):
        a = acc(rec)
        a["calls"] += rec["calls"]
        for t in a["tokens"]:
            a["tokens"][t] += rec[t]
        a["real_calls"] += rec["calls_real"]
        if rec["cost_real"] is not None:
            a["real_usd"] = _add(a["real_usd"], rec["cost_real"])
        pending = rec["calls"] - rec["calls_real"]
        if pending:
            est = estimate_cost_usd(rec["est_input"], rec["est_output"], rec["est_cache_read"],
                                    rec["est_cache_creation"], prices.lookup(rec["model"]))
            if est is None:
                a["unpriced_calls"] += pending
                a["unpriced_models"].add(rec["model"])
            else:
                a["estimated_calls"] += pending
                a["estimated_usd"] = _add(a["estimated_usd"], est)
    for rec in _p95(con, keys, from_ns, to_ns):
        if rec["p95"] is not None:
            acc(rec)["p95"] = rec["p95"]
    for rec in _span_errors(con, keys, from_ns, to_ns):
        if rec["n"]:
            acc(rec)["span_errors"] += rec["n"]
    for rec in _log_errors(con, keys, from_ns, to_ns):
        if rec["n"]:
            acc(rec)["log_errors"] += rec["n"]
    return groups


def _day(idx):
    return datetime.fromtimestamp(idx * DAY_NS // 1_000_000_000, timezone.utc).date().isoformat()


def render(key, a, keys):
    """Acumulador -> objeto da resposta (custo real e estimado sempre separados)."""
    out = {}
    for k, v in zip(keys, key):
        out[k] = _day(v) if k == "day" else v
    out.update({
        "calls": a["calls"],
        "tokens": a["tokens"],
        "cost": {
            "real_usd": a["real_usd"],            # custo que veio no span; null = nenhuma chamada com custo real
            "estimated_usd": a["estimated_usd"],  # estimado pela tabela; null = nada estimado (ver unpriced_calls)
            "real_calls": a["real_calls"],
            "estimated_calls": a["estimated_calls"],
            "unpriced_calls": a["unpriced_calls"],  # sem custo real e sem preço: fora das duas somas
        },
        "errors": {"spans": a["span_errors"], "logs": a["log_errors"], "total": a["span_errors"] + a["log_errors"]},
        "latency_p95_ms": None if a["p95"] is None else round(a["p95"], 3),
    })
    return out


def rendered(groups, key):
    """O grupo `key` de um `aggregate` no formato do `render`, sem as chaves; zerado se o grupo não existe."""
    return render((), groups.get(key) or _empty(), ())


def _sorted(groups):
    return sorted(groups.items(), key=lambda kv: tuple((v is not None, v if v is not None else "") for v in kv[0]))


def usage(con, from_ns, to_ns, prices):
    """Resposta do `/v1/usage`: `totals`, `rows` (host × agente × modelo) e `series` (dia × host × agente × modelo)."""
    total = aggregate(con, from_ns, to_ns, prices, ())[()]
    rows = aggregate(con, from_ns, to_ns, prices, ("host", "agent", "model"))
    series = aggregate(con, from_ns, to_ns, prices, ("day", "host", "agent", "model"))
    return {
        "totals": render((), total, ()),
        # modelos com chamada sem custo real e sem preço na tabela (null = span sem modelo)
        "unpriced_models": sorted(total["unpriced_models"], key=lambda m: (m is None, m or "")),
        "rows": [render(k, a, ("host", "agent", "model")) for k, a in _sorted(rows)],
        "series": [render(k, a, ("day", "host", "agent", "model")) for k, a in _sorted(series)],
    }
