"""Dados dos quatro gráficos da tela `/uso` (#533), tirados do `usage.usage` sem mudar o `GET /v1/usage`: custo por dia, por
papel e por fase, e tokens por dia. Só soma e proporção; o desenho é do `templates/_graficos_uso.html`."""
import datetime as dt
import math

TOKENS = ("input", "output", "cache_read", "cache_creation")


def _zero():
    return {"calls": 0, "real_usd": None, "estimated_usd": None, "tokens": dict.fromkeys(TOKENS, 0)}


def _add_usd(into, key, v):
    if v is not None:
        into[key] = v if into[key] is None else into[key] + v


def _tick(i, n):
    """Rótulo do eixo X: todos até 10 dias; acima, um a cada `ceil(n / 8)`."""
    return i % max(1, math.ceil(n / 8)) == 0 if n > 10 else True


def _cost_of(a):
    return (a["real_usd"] or 0) + (a["estimated_usd"] or 0)


def _tok_of(a):
    return sum(a["tokens"].values())


def _by_day(series):
    """Série (dia × host × agente × modelo) -> acumulador por dia."""
    acc = {}
    for r in series:
        a = acc.setdefault(r["day"], _zero())
        a["calls"] += r["calls"]
        _add_usd(a, "real_usd", r["cost"]["real_usd"])
        _add_usd(a, "estimated_usd", r["cost"]["estimated_usd"])
        for t in TOKENS:
            a["tokens"][t] += r["tokens"][t]
    return acc


def _day_keys(acc):
    """Todos os dias do primeiro ao último com chamada (o dia sem chamada entra, para o gráfico mostrar o buraco)."""
    first, last = (dt.date.fromisoformat(k) for k in (min(acc), max(acc)))
    return [(first + dt.timedelta(days=i)).isoformat() for i in range((last - first).days + 1)]


def _frac(v, top):
    return v / top if top else 0


def _point(k, i, n, a, max_cost, max_tok):
    t = a["tokens"]
    cache = t["cache_read"] + t["cache_creation"]
    label = f"{k[8:10]}/{k[5:7]}"
    return {
        "key": k, "label": label, "tick": label if _tick(i, n) else "", "x": (i + 0.5) / n, "calls": a["calls"],
        "real_usd": a["real_usd"], "estimated_usd": a["estimated_usd"],
        "real_frac": _frac(a["real_usd"] or 0, max_cost), "est_frac": _frac(a["estimated_usd"] or 0, max_cost),
        "input": t["input"], "output": t["output"], "cache": cache,
        "cache_read": t["cache_read"], "cache_creation": t["cache_creation"], "tokens": _tok_of(a),
        "in_frac": _frac(t["input"], max_tok), "out_frac": _frac(t["output"], max_tok), "cache_frac": _frac(cache, max_tok),
    }


def days(series):
    """Série do `usage.usage` -> um item por dia, do primeiro ao último dia com chamada. Cada item: custo real e estimado,
    tokens (`cache` = leitura + escrita), `real_frac`/`est_frac` pelo maior dia de custo e as frações de tokens pelo maior dia."""
    acc = _by_day(series)
    if not acc:
        return {"points": [], "max_cost": 0, "mid_cost": 0, "max_tokens": 0, "mid_tokens": 0}
    keys = _day_keys(acc)
    rows = [acc.get(k) or _zero() for k in keys]
    max_cost = max(_cost_of(a) for a in rows)
    max_tok = max(_tok_of(a) for a in rows)
    points = [_point(k, i, len(keys), a, max_cost, max_tok) for i, (k, a) in enumerate(zip(keys, rows))]
    return {"points": points, "max_cost": max_cost, "mid_cost": max_cost / 2, "max_tokens": max_tok, "mid_tokens": max_tok // 2}


def bars(rows, kind):
    """Linhas `by_role`/`by_phase` (já na ordem de custo) -> barra por linha, com a fração do maior custo."""
    cost_of = lambda r: (r["cost"]["real_usd"] or 0) + (r["cost"]["estimated_usd"] or 0)
    top = max((cost_of(r) for r in rows), default=0)
    return [{
        "name": r[kind], "calls": r["calls"], "cost": r["cost"],
        "priced": r["cost"]["real_usd"] is not None or r["cost"]["estimated_usd"] is not None,
        "real_frac": (r["cost"]["real_usd"] or 0) / top if top else 0,
        "est_frac": (r["cost"]["estimated_usd"] or 0) / top if top else 0,
    } for r in rows]


def build(data, by_role, by_phase, by_subscription=()):
    return {"days": days(data["series"]), "roles": bars(by_role, "role"), "phases": bars(by_phase, "phase"),
            "subscriptions": bars(by_subscription, "subscription")}
