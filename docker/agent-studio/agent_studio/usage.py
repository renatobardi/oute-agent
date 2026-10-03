"""Agregação de uso (ADR-08 §9, #203): custo real e estimado, tokens, erros, p95 e série diária, com qualquer
agrupamento de `day`/`host`/`agent`/`model`/`conversation`/`session`. Tudo pela **hora do fato** (`time_unix_nano`), nunca pela de chegada;
dia no fuso configurado (#415: a meia-noite do fuso, não a do UTC; só a leitura converte). As regras de escopo e de custo estão no `cost.py`.

`aggregate` é a peça reusável (alertas #204, tray #205, tela #206 e #207); `usage` monta a resposta do `/v1/usage`.
"""
from . import tz as tz_mod
from .cost import (LOG_SEVERITY_ERROR, MODEL_CALL_PARAMS, MODEL_CALL_SQL, SPAN_STATUS_ERROR,
                   estimate_cost_usd, window_spans_with_cost)

DAY_NS = 86_400_000_000_000
KEYS = ("day", "host", "agent", "model", "conversation", "session")
# conversation = `session.id` (a conversa do agente, CONTEXT.md), para a tela (#206);
# session = `oute.task.id` (a sessão do `oute-task`), para a tela de sessões (#207)
_COLS = {"host": "host_name", "agent": "oute_agent",
         "model": "model", "conversation": "session_id", "session": "oute_task_id"}
# logs não têm modelo: agrupados por modelo, caem no modelo nulo
_LOG_MODEL = {"model": "CAST(NULL AS VARCHAR)"}
_WINDOW = "time_unix_nano >= ? AND time_unix_nano < ?"


def _cols(tz, extra=None):
    """Colunas de agrupamento. `day` = a data local no fuso `tz` (`ZoneInfo`) da hora do fato: o nome vem do `zoneinfo`
    (validado em `tz.parse`) e vai literal no SQL, o ICU do DuckDB faz a conversão, inclusive para dias antigos."""
    day = (f"CAST(timezone('{tz.key}', make_timestamp_ns(CAST(time_unix_nano AS BIGINT)) AT TIME ZONE 'UTC') "
           "AS DATE)")
    return {"day": day, **_COLS, **(extra or {})}


def _query(con, keys, cols, aggs, table, where, params):
    """Linhas como dict; sem chaves, uma linha só (total). `table` = nome ou subconsulta (os parâmetros dela vêm
    antes dos de `where` em `params`)."""
    select = [f"{cols[k]} AS {k}" for k in keys] + aggs
    group = " GROUP BY ALL" if keys else ""
    cur = con.execute(f"SELECT {', '.join(select)} FROM {table} WHERE {where}{group}", params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _epoch_col(prices):
    """Faixa de preço de cada chamada (#339): quantas trocas de preço (`PriceTable.boundaries`) já tinham acontecido na
    hora do fato. Dentro de uma faixa nenhum preço muda; as horas vão no SQL como inteiros (vêm do nosso banco)."""
    bounds = prices.boundaries()
    if not bounds:
        return "0"
    return f"len(list_filter([{', '.join(str(int(b)) for b in bounds)}]::UBIGINT[], x -> x <= time_unix_nano))"


def _calls(con, keys, from_ns, to_ns, prices, tz):
    aggs = ["count(*) AS calls", "count(cost_usd) AS calls_real", "sum(cost_usd) AS cost_real"]
    for t in ("input", "output", "cache_read", "cache_creation"):
        aggs.append(f"COALESCE(sum({t}_tokens), 0) AS {t}")
        aggs.append(f"COALESCE(sum({t}_tokens) FILTER (WHERE cost_usd IS NULL), 0) AS est_{t}")
    # custo efetivo (o do span ou o do log `api_request`, #157): a regra está no `cost.spans_with_cost`
    table, params = window_spans_with_cost(from_ns, to_ns)
    return _query(con, (*keys, "epoch"), _cols(tz, {"epoch": _epoch_col(prices)}), aggs, table, MODEL_CALL_SQL,
                  [*params, *MODEL_CALL_PARAMS])


def _p95(con, keys, from_ns, to_ns, tz):
    return _query(con, keys, _cols(tz), ["quantile_cont(CAST(duration_ns AS DOUBLE), 0.95) / 1e6 AS p95"], "spans",
                  f"{_WINDOW} AND duration_ns IS NOT NULL AND {MODEL_CALL_SQL}", [from_ns, to_ns, *MODEL_CALL_PARAMS])


def _spans(con, keys, from_ns, to_ns, tz):
    """Todos os spans (o denominador da taxa de erro) e os com status de erro."""
    return _query(con, keys, _cols(tz), ["count(*) AS spans", "count(*) FILTER (WHERE status_code = ?) AS n"], "spans",
                  _WINDOW, [SPAN_STATUS_ERROR, from_ns, to_ns])


def _log_errors(con, keys, from_ns, to_ns, tz):
    return _query(con, keys, _cols(tz, _LOG_MODEL), ["count(*) AS n"], "logs", f"{_WINDOW} AND severity_number >= ?",
                  [from_ns, to_ns, LOG_SEVERITY_ERROR])


def _empty():
    return {"calls": 0, "tokens": dict.fromkeys(("input", "output", "cache_read", "cache_creation"), 0),
            "real_usd": None, "estimated_usd": None, "real_calls": 0, "estimated_calls": 0, "unpriced_calls": 0,
            "unpriced_models": set(), "spans": 0, "span_errors": 0, "log_errors": 0, "p95": None}


def _add(a, b):
    return b if a is None else a + b


def aggregate(con, from_ns, to_ns, prices, keys=("host", "agent", "model"), tz=tz_mod.UTC):
    """{tupla das chaves: acumulador} na janela [from_ns, to_ns). O custo estimado é calculado por modelo e
    depois somado; sem `model` nas chaves, o agrupamento fino inclui o modelo e sobe para `keys`. O preço é o que valia
    na **hora do fato** de cada chamada (`PriceTable`, #339): o agrupamento fino também separa as faixas entre trocas."""
    keys = tuple(keys)
    if set(keys) - set(KEYS):
        raise ValueError(f"chave inválida: {keys}")
    prices = prices.snapshot()  # uma versão da tabela do começo ao fim, mesmo se a rotina de preços trocar no meio
    bounds = prices.boundaries()
    groups = {} if keys else {(): _empty()}

    def at_ns(epoch):
        # qualquer hora da faixa serve (nenhum preço muda dentro dela): o início dela; a faixa 0 é "desde sempre"
        return bounds[epoch - 1] if epoch else 0

    def acc(rec):
        return groups.setdefault(tuple(rec[k] for k in keys), _empty())

    fine = keys if "model" in keys else keys + ("model",)
    for rec in _calls(con, fine, from_ns, to_ns, prices, tz):
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
                                    rec["est_cache_creation"], prices.lookup(rec["model"], at_ns(rec["epoch"])))
            if est is None:
                a["unpriced_calls"] += pending
                a["unpriced_models"].add(rec["model"])
            else:
                a["estimated_calls"] += pending
                a["estimated_usd"] = _add(a["estimated_usd"], est)
    for rec in _p95(con, keys, from_ns, to_ns, tz):
        if rec["p95"] is not None:
            acc(rec)["p95"] = rec["p95"]
    for rec in _spans(con, keys, from_ns, to_ns, tz):
        a = acc(rec)
        a["spans"] += rec["spans"]
        a["span_errors"] += rec["n"]
    for rec in _log_errors(con, keys, from_ns, to_ns, tz):
        if rec["n"]:
            acc(rec)["log_errors"] += rec["n"]
    return groups


def render(key, a, keys):
    """Acumulador -> objeto da resposta (custo real e estimado sempre separados)."""
    out = {}
    for k, v in zip(keys, key):
        out[k] = v.isoformat() if k == "day" else v
    out.update({
        "calls": a["calls"],
        "spans": a["spans"],  # todos os spans do grupo (chamada ao modelo ou não): o denominador de `errors.spans`
        "tokens": a["tokens"],
        "cost": {
            "real_usd": a["real_usd"],            # custo que veio na chamada (span ou log api_request); null = nenhuma chamada com custo real
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


def usage(con, from_ns, to_ns, prices, tz=tz_mod.UTC):
    """Resposta do `/v1/usage`: `totals`, `rows` (host × agente × modelo) e `series` (dia × host × agente × modelo;
    o dia é o do fuso `tz`, e `timezone` diz qual)."""
    total = aggregate(con, from_ns, to_ns, prices, (), tz)[()]
    rows = aggregate(con, from_ns, to_ns, prices, ("host", "agent", "model"), tz)
    series = aggregate(con, from_ns, to_ns, prices, ("day", "host", "agent", "model"), tz)
    return {
        "timezone": tz.key,
        "totals": render((), total, ()),
        # modelos com chamada sem custo real e sem preço na tabela (null = span sem modelo)
        "unpriced_models": sorted(total["unpriced_models"], key=lambda m: (m is None, m or "")),
        "rows": [render(k, a, ("host", "agent", "model")) for k, a in _sorted(rows)],
        "series": [render(k, a, ("day", "host", "agent", "model")) for k, a in _sorted(series)],
    }
