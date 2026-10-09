"""Alertas de custo de lista (#747, ADR-08 "Custo de lista"), no pipeline do `alerts.evaluate` (#204): calculados do
histórico de chamadas e de preços na hora da consulta, sem estado próprio. Olham as chamadas das três assinaturas
(`claude`, `codex`, `zai`) dos últimos `COST_DAYS` (7) dias.

- **`cost_claude_diff`** (`custo do claude difere da tabela`): por modelo, o `cost_usd` que o Claude Code informou
  somado nas chamadas com custo informado, comparado com os tokens dessas mesmas chamadas × a tabela de preços (o preço
  da hora de cada chamada). Diferença relativa acima de `claude_cost_diff_pct` (`[alerts]`, padrão 10%) liga o alerta.
  Modelo sem preço não entra aqui: cai no alerta de baixo. A tabela usa a escrita de cache de 5 min: a de 1 h custa
  mais, então uma diferença pequena e positiva é esperada.
- **`cost_subscription_unpriced`** (`modelo de assinatura sem preço`): modelo de chamada de assinatura sem preço na
  tabela. A chamada não entra como estimada nem como zero (fica em `unpriced_calls`); o alerta é o aviso.

Todo alerta leva `evidence.model` e `evidence.note` (só o que é nosso: nome de modelo validado, números).
"""
from . import alerts as alerts_mod, cost as cost_mod, prices as prices_mod

CLAUDE_DIFF, SUBSCRIPTION_UNPRICED = alerts_mod.COST_TYPES
COST_DAYS = 7
DAY_NS = 86_400_000_000_000


def _calls(con, lo, at_ns, prices):
    """Grupos (assinatura, modelo, faixa de preço) das chamadas de assinatura em [lo, at_ns]: chamadas, tokens de todas
    e, à parte, as chamadas com custo informado (`rep_*`) com os tokens delas e a soma do custo."""
    aggs = ["count(*) AS calls", "count(cost_usd) AS calls_rep", "COALESCE(sum(cost_usd), 0) AS cost_rep",
            "min(time_unix_nano) AS first_ns"]
    for t in ("input", "output", "cache_read", "cache_creation"):
        aggs.append(f"COALESCE(sum({t}_tokens), 0) AS {t}")
        aggs.append(f"COALESCE(sum({t}_tokens) FILTER (WHERE cost_usd IS NOT NULL), 0) AS rep_{t}")
    bounds = prices.boundaries()
    epoch = ("0" if not bounds else
             f"len(list_filter([{', '.join(str(int(b)) for b in bounds)}]::UBIGINT[], x -> x <= time_unix_nano))")
    table, params = cost_mod.window_spans_with_cost(lo, at_ns + 1)
    cur = con.execute(
        f"SELECT {cost_mod.SUBSCRIPTION_EXPR} AS sub, model, {epoch} AS epoch, {', '.join(aggs)} FROM {table} "
        f"WHERE {cost_mod.MODEL_CALL_SQL} AND {cost_mod.SUBSCRIPTION_SQL} AND model IS NOT NULL GROUP BY ALL",
        [*params, *cost_mod.MODEL_CALL_PARAMS])
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()], bounds


def _fmt(v):
    return f"{v:,.4f}".replace(",", "_").replace(".", ",").replace("_", ".")


def evaluate(con, at_ns, cfg):
    """Os alertas de custo ativos na hora `at_ns`."""
    prices = prices_mod.load_table(con)
    rows, bounds = _calls(con, max(0, at_ns - COST_DAYS * DAY_NS), at_ns, prices)
    unpriced, claude = {}, {}
    for r in rows:
        price = prices.lookup(r["model"], bounds[r["epoch"] - 1] if r["epoch"] else 0)
        if price is None:
            u = unpriced.setdefault(r["model"], {"calls": 0, "since": r["first_ns"], "subs": set()})
            u["calls"] += r["calls"]
            u["since"] = min(u["since"], r["first_ns"])
            u["subs"].add(r["sub"])
        elif r["sub"] == "claude" and r["calls_rep"]:
            c = claude.setdefault(r["model"], {"calls": 0, "reported": 0.0, "table": 0.0, "since": r["first_ns"]})
            c["calls"] += r["calls_rep"]
            c["reported"] += r["cost_rep"]
            c["table"] += cost_mod.estimate_cost_usd(r["rep_input"], r["rep_output"], r["rep_cache_read"],
                                                     r["rep_cache_creation"], price)
            c["since"] = min(c["since"], r["first_ns"])
    out = []
    for model, u in sorted(unpriced.items()):
        out.append(alerts_mod._alert(
            SUBSCRIPTION_UNPRICED, None, None, u["calls"], "calls", None, u["since"],
            {"model": model, "subscriptions": sorted(u["subs"]), "level": "problem",
             "note": f"{model}: {u['calls']} chamadas de assinatura sem preço na tabela (fora da soma)"}))
    for model, c in sorted(claude.items()):
        if c["table"] <= 0:
            continue
        pct = (c["reported"] - c["table"]) / c["table"] * 100
        if abs(pct) > cfg.claude_cost_diff_pct:
            out.append(alerts_mod._alert(
                CLAUDE_DIFF, None, None, round(pct, 2), "pct", cfg.claude_cost_diff_pct, c["since"],
                {"model": model, "calls": c["calls"], "reported_usd": c["reported"], "table_usd": c["table"],
                 "level": "problem",
                 "note": f"{model}: informado US$ {_fmt(c['reported'])} × tabela US$ {_fmt(c['table'])} em {c['calls']} chamadas"}))
    return out
