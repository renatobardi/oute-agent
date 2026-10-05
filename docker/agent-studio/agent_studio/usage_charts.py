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


def days(series):
    """Série do `usage.usage` (dia × host × agente × modelo) -> um item por dia, do primeiro ao último dia com chamada
    (dia sem chamada entra zerado, para o gráfico mostrar o buraco). Cada item: custo real e estimado, tokens (com o cache
    junto: `cache` = leitura + escrita), `real_frac`/`est_frac` pelo maior dia de custo e `*_frac` de tokens pelo maior dia."""
    acc = {}
    for r in series:
        a = acc.setdefault(r["day"], _zero())
        a["calls"] += r["calls"]
        _add_usd(a, "real_usd", r["cost"]["real_usd"])
        _add_usd(a, "estimated_usd", r["cost"]["estimated_usd"])
        for t in TOKENS:
            a["tokens"][t] += r["tokens"][t]
    if not acc:
        return {"points": [], "max_cost": 0, "mid_cost": 0, "max_tokens": 0, "mid_tokens": 0}
    first, last = (dt.date.fromisoformat(k) for k in (min(acc), max(acc)))
    keys = [(first + dt.timedelta(days=i)).isoformat() for i in range((last - first).days + 1)]
    n = len(keys)
    cost_of = lambda a: (a["real_usd"] or 0) + (a["estimated_usd"] or 0)
    tok_of = lambda a: sum(a["tokens"][t] for t in ("input", "output")) + a["tokens"]["cache_read"] + a["tokens"]["cache_creation"]
    max_cost = max(cost_of(acc.get(k) or _zero()) for k in keys)
    max_tok = max(tok_of(acc.get(k) or _zero()) for k in keys)
    points = []
    for i, k in enumerate(keys):
        a = acc.get(k) or _zero()
        t = a["tokens"]
        cache = t["cache_read"] + t["cache_creation"]
        points.append({
            "key": k, "label": f"{k[8:10]}/{k[5:7]}", "tick": f"{k[8:10]}/{k[5:7]}" if _tick(i, n) else "",
            "x": (i + 0.5) / n, "calls": a["calls"],
            "real_usd": a["real_usd"], "estimated_usd": a["estimated_usd"],
            "real_frac": (a["real_usd"] or 0) / max_cost if max_cost else 0,
            "est_frac": (a["estimated_usd"] or 0) / max_cost if max_cost else 0,
            "input": t["input"], "output": t["output"], "cache": cache,
            "cache_read": t["cache_read"], "cache_creation": t["cache_creation"],
            "tokens": tok_of(a),
            "in_frac": t["input"] / max_tok if max_tok else 0,
            "out_frac": t["output"] / max_tok if max_tok else 0,
            "cache_frac": cache / max_tok if max_tok else 0,
        })
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


def build(data, by_role, by_phase):
    return {"days": days(data["series"]), "roles": bars(by_role, "role"), "phases": bars(by_phase, "phase")}
