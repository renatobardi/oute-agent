"""Dashboard `/` (#469, Kubo 4/4 do épico #465): KPIs, insights por regra e os dados dos 6 gráficos, só leitura.

Tudo vem do mesmo DuckDB e das mesmas regras do `/uso` e do `/v1/usage`: os totais saem do `usage.aggregate` (mesma
janela, mesmo escopo de chamada ao modelo, mesmo custo real e estimado), então os números da tela batem com os de lá.
O que é novo aqui são as agregações que o `usage` não dá: série por hora ou dia, percentis por modelo, dia da semana
× hora e os erros por ferramenta e host. Nenhuma chamada a LLM nem à internet: os insights são regras fixas sobre esses números.

- **Janela e comparação:** `[from, to)` e, sempre, a janela anterior de mesmo tamanho (`[from - tamanho, from)`).
- **Série:** por hora quando a janela tem até 48 h; por dia acima disso. Hora e dia no fuso configurado (#415).
- **Heatmap:** sempre os 7 dias até `to` (dia da semana × hora), qualquer que seja a janela.
- **Gate pendente:** vem do SurrealDB (pedido pendente) e dos eventos da rodada (decisão pendente); entra em `insights`
  como as idades em segundos. Sem o SurrealDB a regra não dispara e a tela avisa.
"""
import math
from datetime import timedelta
from urllib.parse import quote

from . import alert_text, tz as tz_mod, usage as usage_mod
from .cost import MODEL_CALL_PARAMS, MODEL_CALL_SQL, SPAN_STATUS_ERROR

HOUR_NS = 3_600_000_000_000
HOURLY_MAX_NS = 48 * HOUR_NS   # até aqui a série é por hora; acima, por dia
HEAT_NS = 7 * 24 * HOUR_NS
DAYS = ("seg", "ter", "qua", "qui", "sex", "sáb", "dom")
MODELS_SHOWN = 8
TOP_SESSIONS = 5
# regras dos insights (#469)
P95_WORSE = 0.25               # p95 de um modelo subiu mais que isto sobre a janela anterior
P95_MIN_CALLS = 5              # e o modelo tem ao menos isto de chamadas com duração nas duas janelas
GATE_MIN_AGE_S = 10 * 60       # Gate pendente há mais que isto
MODEL_MAX_CALLS_SHARE = 0.10   # modelo com menos que isto das chamadas…
MODEL_MIN_COST_SHARE = 0.35    # …e mais que isto do custo
TOOL_MIN_ERRORS = 2            # erros da mesma ferramenta no mesmo host
NO_MODEL = "(sem modelo)"

_WINDOW = "time_unix_nano >= ? AND time_unix_nano < ?"
_CALL = f"{_WINDOW} AND {MODEL_CALL_SQL}"
_DUR = "CAST(duration_ns AS DOUBLE) / 1e6"


def _rows(con, sql, params):
    cur = con.execute(sql, params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _cost(a):
    """Custo de lista de um acumulador do `usage.aggregate`: real + estimado (`None` se nenhum dos dois existe)."""
    if a["real_usd"] is None and a["estimated_usd"] is None:
        return None
    return (a["real_usd"] or 0.0) + (a["estimated_usd"] or 0.0)


def _div(a, b):
    """a / b, ou 0.0 quando não há base (divisão por zero nunca chega à tela)."""
    return a / b if b else 0.0


def _rel(cur, prev):
    """Variação relativa sobre a janela anterior; `None` quando não há base (anterior vazia ou zero)."""
    if cur is None or not prev:
        return None
    return (cur - prev) / prev


def _pct(frac, digits=0, signed=False):
    text = alert_text.br(f"{abs(frac) * 100:.{digits}f}")
    if not signed:
        return f"{text}%"
    return ("−" if frac < 0 and float(text.replace(",", ".")) else "+") + f"{text}%"


def _cache_share(a):
    t = a["tokens"]
    total = t["input"] + t["cache_read"] + t["cache_creation"]
    return _div(t["cache_read"], total) if total else None


def _error_rate(a):
    """Spans com erro ÷ todos os spans da janela: a mesma população do `errors.spans` e `spans` do `/v1/usage` (#525)."""
    return _div(a["span_errors"], a["spans"]) if a["spans"] else None


def _span_label(span_ns):
    hours = span_ns / HOUR_NS
    if hours >= 48 and abs(hours / 24 - round(hours / 24)) < 1e-9:
        return f"{round(hours / 24)} d"
    if hours >= 1 and abs(hours - round(hours)) < 1e-9:
        return f"{round(hours)} h"
    return alert_text.dur(span_ns)


def _trend(rel, flat=0.005):
    if rel is None or abs(rel) < flat:
        return "flat"
    return "up" if rel > 0 else "down"


def _delta_badge(rel):
    return "—" if rel is None else _pct(rel, signed=True)


def _kpi(key, label, icon, cur, prev, rel, badge, variant, note, **extra):
    return {"key": key, "label": label, "icon": icon, "value": cur, "prev": prev, "delta": rel, "badge": badge,
            "trend": _trend(rel), "variant": variant, "note": note, **extra}


def _kpi_calls(cur, prev, before):
    rel = _rel(cur["calls"], prev["calls"])
    badge = _delta_badge(rel)
    if rel is None and cur["calls"]:
        badge = "novo"
    return _kpi("calls", "Chamadas ao modelo", "activity", cur["calls"], prev["calls"], rel, badge, "secundario", before)


def _kpi_cost(cur, prev, before):
    total, ptotal = _cost(cur), _cost(prev)
    est_share = _div((cur["estimated_usd"] or 0), total) if total else None
    note = before if est_share is None else f"{_pct(est_share)} estimado"
    rel = _rel(total, ptotal)
    return _kpi("cost", "Custo (lista)", "receipt", total, ptotal, rel, _delta_badge(rel), "secundario", note,
                hint="Preço de lista, não gasto: os agentes rodam por assinatura.", real_usd=cur["real_usd"], estimated_usd=cur["estimated_usd"], estimated_share=est_share,
                unpriced_calls=cur["unpriced_calls"])


def _p95_note(rel):
    if rel is None:
        return None
    if rel > P95_WORSE:
        return "piorou"
    if rel > 0.05:
        return "subiu"
    return "melhorou" if rel < -0.05 else "estável"


def _kpi_p95(cur, prev, before):
    rel = _rel(cur["p95"], prev["p95"])
    variant = "destrutivo" if rel is not None and rel > P95_WORSE else "secundario"
    return _kpi("p95", "p95 das chamadas", "timer", cur["p95"], prev["p95"], rel, _delta_badge(rel), variant,
                _p95_note(rel) or before)


def _kpi_errors(cur, prev, before):
    rate, prate = _error_rate(cur), _error_rate(prev)
    rel = _rel(rate, prate)
    n = cur["span_errors"]
    worse = n >= TOOL_MIN_ERRORS and rel is not None and rel > P95_WORSE
    return _kpi("errors", "Taxa de erro", "circle-alert", rate, prate, rel,
                f"{alert_text.num(n)} {'erro' if n == 1 else 'erros'}", "destrutivo" if worse else "contorno", before,
                hint="Spans com erro ÷ todos os spans da janela (chamadas ao modelo, ferramentas e o resto).", errors=n, prev_errors=prev["span_errors"])


def _pp_badge(pp):
    if pp is None:
        return "—"
    sign = "−" if pp < 0 and round(pp) else "+"
    return f"{sign}{alert_text.br(f'{abs(pp):.0f}')} pp"


def _kpi_cache(cur, prev, _before):
    share, pshare = _cache_share(cur), _cache_share(prev)
    pp = None if share is None or pshare is None else (share - pshare) * 100
    kpi = _kpi("cache", "Leitura de cache", "database-zap", share, pshare, None if pp is None else pp / 100,
               _pp_badge(pp), "secundario", "do contexto vem do cache",
               hint="Tokens lidos do cache ÷ (entrada nova + leitura de cache + escrita de cache). O agente relê o contexto "
                    "do cache a cada chamada, então o valor alto é o normal; não mede economia.")
    kpi["trend"] = _trend(pp, 0.5)
    return kpi


def _kpis(cur, prev, span_ns):
    """Os 5 KPIs com o valor, o da janela anterior e o Badge de variação (texto, tendência e variante)."""
    before = f"vs. {_span_label(span_ns)} antes"
    return [f(cur, prev, before) for f in (_kpi_calls, _kpi_cost, _kpi_p95, _kpi_errors, _kpi_cache)]


def _nice(v):
    """Teto do eixo: um valor redondo ≥ v com metade inteira (2, 4, 6, 8, 10, 20, 40…)."""
    if v <= 2:
        return 2
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 2, 4, 6, 8, 10):
        if v <= m * e:
            return m * e
    return 10 * e


def _bucket_keys(from_ns, to_ns, tz, hourly):
    """Chaves (e rótulos) dos baldes locais que cobrem [from_ns, to_ns), na mesma forma do `strftime` da consulta."""
    fmt = "%Y-%m-%d %H" if hourly else "%Y-%m-%d"
    out = {}
    if hourly:
        cursor = from_ns // HOUR_NS * HOUR_NS
        while cursor < to_ns:
            d = tz_mod.local(cursor, tz)
            out.setdefault(d.strftime(fmt), d)
            cursor += HOUR_NS
    else:
        d, last = tz_mod.local(from_ns, tz), tz_mod.local(to_ns - 1, tz)
        while d.date() <= last.date():
            out.setdefault(d.strftime(fmt), d)
            d = d + timedelta(days=1)
    return fmt, out


def _tick(i, n, d, hourly):
    """Rótulo do eixo x do balde `i` de `n` (vazio = sem rótulo): a cada 6 h na série por hora, ~6 rótulos na por dia."""
    text = f"{d:%H}h" if hourly else f"{d:%d/%m}"
    if hourly and n > 8:
        return text if d.hour % 6 == 0 else ""
    return text if i % (1 if n <= 8 else math.ceil(n / 6)) == 0 else ""


def _series(con, from_ns, to_ns, tz):
    hourly = to_ns - from_ns <= HOURLY_MAX_NS
    fmt, keys = _bucket_keys(from_ns, to_ns, tz, hourly)
    found = {r["b"]: r for r in _rows(
        con, f"SELECT strftime({usage_mod.local_expr(tz)}, '{fmt}') AS b, count(*) AS calls, "
             f"quantile_cont({_DUR}, 0.95) AS p95 FROM spans WHERE {_CALL} GROUP BY b",
        [from_ns, to_ns, *MODEL_CALL_PARAMS])}
    n = len(keys)
    points = []
    for i, (key, d) in enumerate(keys.items()):
        r = found.get(key) or {"calls": 0, "p95": None}
        points.append({"key": key, "label": f"{d:%d/%m} {d:%H}h" if hourly else f"{d:%d/%m}", "tick": _tick(i, n, d, hourly),
                       "calls": r["calls"], "p95": r["p95"], "x": (i + 0.5) / n})
    top = _nice(max((p["calls"] for p in points), default=0))
    for p in points:
        p["frac"] = _div(p["calls"], top)
    return {"unit": "hour" if hourly else "day", "points": points, "max": top, "mid": top // 2,
            "total": sum(p["calls"] for p in points)}


def _model_latency(con, from_ns, to_ns):
    return {r["model"]: r for r in _rows(
        con, f"SELECT model, count(*) AS n, quantile_cont({_DUR}, 0.5) AS p50, quantile_cont({_DUR}, 0.9) AS p90, "
             f"quantile_cont({_DUR}, 0.95) AS p95, quantile_cont({_DUR}, 0.99) AS p99 FROM spans "
             f"WHERE {_CALL} AND duration_ns IS NOT NULL GROUP BY model", [from_ns, to_ns, *MODEL_CALL_PARAMS])}


def _level(v, peak):
    """Degrau 0 a 4 do heatmap: 0 só sem chamada; o pico é sempre 4."""
    return math.ceil(_div(v, peak) * 4) if v else 0


def _heat(con, to_ns, tz):
    grid = [[0] * 24 for _ in DAYS]
    local = usage_mod.local_expr(tz)
    for r in _rows(con, f"SELECT isodow({local}) AS d, hour({local}) AS h, count(*) AS n FROM spans WHERE {_CALL} GROUP BY ALL",
                   [to_ns - HEAT_NS, to_ns, *MODEL_CALL_PARAMS]):
        grid[r["d"] - 1][r["h"]] = r["n"]
    peak = max(max(row) for row in grid)
    return {"peak": peak, "total": sum(map(sum, grid)), "rows": [
        {"day": DAYS[i], "cells": [{"hour": h, "calls": v, "level": _level(v, peak)} for h, v in enumerate(row)]}
        for i, row in enumerate(grid)]}


def _worst_session(con, model, from_ns, to_ns):
    """A sessão (ou, sem ela, a conversa) com o p95 mais alto do modelo na janela: a "responsável" do insight."""
    rows = _rows(con, f"SELECT oute_task_id AS task, session_id AS conversation, quantile_cont({_DUR}, 0.95) AS p95, count(*) AS n "
                      f"FROM spans WHERE {_CALL} AND duration_ns IS NOT NULL AND model IS NOT DISTINCT FROM ? "
                      "GROUP BY ALL ORDER BY p95 DESC, n DESC, task NULLS LAST, conversation NULLS LAST LIMIT 1",
                 [from_ns, to_ns, *MODEL_CALL_PARAMS, model])
    return rows[0] if rows else None


def _tool_errors(con, from_ns, to_ns):
    """Erros de span por (host, ferramenta) e conversa; a ferramenta é o `tool_name` do span ou, sem ele, o nome do span."""
    return _rows(con, f"SELECT host_name AS host, COALESCE(json_extract_string(attributes, '$.tool_name'), name) AS tool, "
                      f"session_id AS conversation, count(*) AS n FROM spans WHERE {_WINDOW} AND status_code = ? GROUP BY ALL",
                 [from_ns, to_ns, SPAN_STATUS_ERROR])


def _models(by_model, total_cost, total_calls):
    rows = []
    for (model,), a in by_model.items():
        if not a["calls"]:
            continue  # grupo que só tem erro de log (o log não tem modelo) ou span que não é chamada
        cost = _cost(a)
        rows.append({"model": model or NO_MODEL, "calls": a["calls"], "real_usd": a["real_usd"], "estimated_usd": a["estimated_usd"],
                     "cost": cost, "unpriced_calls": a["unpriced_calls"],
                     "calls_share": _div(a["calls"], total_calls), "cost_share": _div(cost or 0, total_cost)})
    rows.sort(key=lambda r: (-(r["cost"] or 0), -r["calls"], r["model"]))
    peak = max((r["cost"] or 0 for r in rows), default=0)
    for r in rows:
        r["real_frac"] = _div(r["real_usd"] or 0, peak)
        r["est_frac"] = _div(r["estimated_usd"] or 0, peak)
    return rows


def _phases(by_phase):
    rows = [{"phase": p, "tokens": a["tokens"]["input"] + a["tokens"]["output"], "calls": a["calls"]}
            for (p,), a in by_phase.items() if a["tokens"]["input"] + a["tokens"]["output"]]
    rows.sort(key=lambda r: (-r["tokens"], r["phase"]))
    peak = rows[0]["tokens"] if rows else 0
    for r in rows:
        r["frac"] = _div(r["tokens"], peak)
    return rows


def _add_session(sessions, task, agent, model, a):
    s = sessions.setdefault(task, {"id": task, "calls": 0, "real": None, "est": None, "agents": set(), "models": {}})
    s["calls"] += a["calls"]
    for k, v in (("real", a["real_usd"]), ("est", a["estimated_usd"])):
        if v is not None:
            s[k] = (s[k] or 0.0) + v
    if agent:
        s["agents"].add(agent)
    if a["calls"]:
        name = model or NO_MODEL
        s["models"][name] = s["models"].get(name, 0) + a["calls"]


def _session_row(s):
    main = max(s["models"].items(), key=lambda kv: (kv[1], kv[0]))[0] if s["models"] else None
    return {"id": s["id"], "calls": s["calls"], "cost": (s["real"] or 0.0) + (s["est"] or 0.0), "estimated": bool(s["est"]),
            "real_usd": s["real"], "estimated_usd": s["est"], "agents": sorted(s["agents"]), "model": main}


def _top_sessions(by_session):
    sessions = {}
    for (task, agent, model), a in by_session.items():
        if task is not None:
            _add_session(sessions, task, agent, model, a)
    rows = [r for r in map(_session_row, sessions.values()) if r["cost"] > 0]
    rows.sort(key=lambda r: (-r["cost"], r["id"]))
    rows = rows[:TOP_SESSIONS]
    for r in rows:
        r["frac"] = _div(r["cost"], rows[0]["cost"])
    return rows


def _cache_saving(by_model, prices):
    """USD a mais que o estimado da janela teria sem cache: a leitura de cache cobrada como entrada, pelo preço vigente de
    cada modelo. Modelo sem preço fica de fora (nunca vira zero na soma, só some dela)."""
    saving, priced = 0.0, False
    for (model,), a in by_model.items():
        price = prices.lookup(model)
        if price is None or not a["tokens"]["cache_read"]:
            continue
        saving += a["tokens"]["cache_read"] * max(price.input - price.cache_read, 0) / 1e6
        priced = True
    return saving if priced else None


def _latency_rows(latency):
    rows = [{"model": m or NO_MODEL, **{k: r[k] for k in ("n", "p50", "p90", "p95", "p99")}} for m, r in latency.items()]
    rows.sort(key=lambda r: (-r["p95"], r["model"]))
    for r in rows:
        r["frac"] = _div(r["p95"], rows[0]["p95"])
    return rows


def _p95_regression(con, latency, prev_latency, from_ns, to_ns):
    """O modelo cujo p95 mais subiu sobre a janela anterior (> P95_WORSE, com amostra mínima nas duas) e a sessão responsável."""
    found = []
    for m, r in latency.items():
        old = prev_latency.get(m)
        if not old or min(r["n"], old["n"]) < P95_MIN_CALLS:
            continue
        rel = _rel(r["p95"], old["p95"])
        if rel is not None and rel > P95_WORSE:
            found.append({"model": m, "p95": r["p95"], "prev_p95": old["p95"], "rel": rel})
    if not found:
        return None
    worst = min(found, key=lambda r: (-r["rel"], r["model"] or ""))
    worst["session"] = _worst_session(con, worst["model"], from_ns, to_ns)
    return worst

FINE = ("session", "agent", "model", "phase")


def _regroup(fine, keys):
    """O resultado de `usage.aggregate(FINE)` reagrupado por `keys` (subconjunto de FINE): uma leitura só do DuckDB serve
    todos os cortes do Dashboard (#504: eram cinco leituras, cada uma refazendo a junção com os logs de custo)."""
    return usage_mod.regroup(fine, FINE, keys)


def snapshot(con, from_ns, to_ns, prices, tz=tz_mod.UTC):
    """Tudo o que a tela mostra, do DuckDB, na janela [from_ns, to_ns) e na anterior de mesmo tamanho."""
    span = to_ns - from_ns
    prev_from = from_ns - span
    fine = usage_mod.aggregate(con, from_ns, to_ns, prices, FINE, tz, p95=False)
    cur = _regroup(fine, ())[()]
    cur["p95"] = usage_mod.aggregate_p95(con, from_ns, to_ns, tz)
    prev = usage_mod.aggregate(con, prev_from, from_ns, prices, (), tz)[()]
    by_model = _regroup(fine, ("model",))
    total_cost = _cost(cur) or 0.0
    models = _models(by_model, total_cost, cur["calls"])
    latency = _model_latency(con, from_ns, to_ns)
    by_session = _regroup(fine, ("session", "agent", "model"))
    return {
        "from_ns": from_ns, "to_ns": to_ns, "span_ns": span, "prev_from_ns": prev_from,
        "totals": usage_mod.render((), cur, ()), "prev_totals": usage_mod.render((), prev, ()),
        "kpis": _kpis(cur, prev, span), "series": _series(con, from_ns, to_ns, tz),
        "models": models[:MODELS_SHOWN], "models_total": len(models),
        "composition": {"real_usd": cur["real_usd"], "estimated_usd": cur["estimated_usd"], "total": total_cost,
                        "unpriced_calls": cur["unpriced_calls"]},
        "latency": _latency_rows(latency)[:MODELS_SHOWN],
        "phases": _phases(_regroup(fine, ("phase",))),
        "heat": _heat(con, to_ns, tz),
        "top_sessions": _top_sessions(by_session),
        "rules": {"p95": _p95_regression(con, latency, _model_latency(con, prev_from, from_ns), from_ns, to_ns),
                  "tool_errors": _tool_errors(con, from_ns, to_ns),
                  "span_errors": cur["span_errors"], "cache_share": _cache_share(cur),
                  "cache_saving": _cache_saving(by_model, prices.snapshot()),
                  "unpriced_models": sorted(m or NO_MODEL for m in cur["unpriced_models"]),
                  "unpriced_calls": cur["unpriced_calls"], "by_model": models},
    }


def _insight(key, icon, tone, title, text, href, action):
    return {"key": key, "icon": icon, "tone": tone, "title": title, "text": text, "href": href, "action": action}


def _where(s):
    """(texto, link, ação) da sessão ou, sem ela, da conversa responsável; sem nenhuma, a lista de sessões."""
    if s.get("task"):
        return f"a sessão {s['task']}", f"/sessao?id={_q(s['task'])}", "Ver sessão"
    if s.get("conversation"):
        return f"a conversa {s['conversation']}", f"/conversa?id={_q(s['conversation'])}", "Ver conversa"
    return None, "/sessoes", "Ver sessões"


def _rule_p95(rules, _uso, _gates):
    r = rules["p95"]
    if not r:
        return None
    who, href, action = _where(r["session"] or {})
    text = f"{alert_text.dur(r['p95'] * 1e6)} contra {alert_text.dur(r['prev_p95'] * 1e6)} na janela anterior"
    text += f"; o p95 mais alto é d{who}." if who else "."
    return _insight("p95", "timer", "bad", f"p95 do {r['model'] or NO_MODEL} subiu {_pct(r['rel'])}", text, href, action)


def _rule_gate(_rules, _uso, ages):
    old = [a for a in ages or [] if a > GATE_MIN_AGE_S]
    if not old:
        return None
    text = (f"{len(old)} {'Gate espera' if len(old) == 1 else 'Gates esperam'} o Bardi há mais de "
            f"{GATE_MIN_AGE_S // 60} min ({len(ages)} no total).")
    return _insight("gate", "hand", "gate", f"Gate parado há {max(old) // 60} min", text, "/pedidos", "Ver pedidos")


def _rule_model_cost(rules, uso, _gates):
    for m in rules["by_model"]:
        if m["calls_share"] < MODEL_MAX_CALLS_SHARE and m["cost_share"] > MODEL_MIN_COST_SHARE:
            return _insight("model_cost", "chart-pie", "neutral",
                            f"{m['model']} é {_pct(m['calls_share'])} das chamadas e {_pct(m['cost_share'])} do custo",
                            "Custo de lista na janela. O uso por papel e por fase mostra onde ele entrou.", uso, "Ver uso por fase")
    return None


def _rule_cache(rules, uso, _gates):
    saving = rules["cache_saving"]
    if rules["cache_share"] is None or saving is None:
        return None
    text = f"Sem cache, o custo estimado da janela seria cerca de US$ {alert_text.br(f'{saving:,.2f}')} maior."
    return _insight("cache", "database-zap", "neutral", f"Cache cobre {_pct(rules['cache_share'])} dos tokens de entrada",
                    text, uso, "Ver uso")


def _tool_groups(rows):
    groups = {}
    for r in rows:
        g = groups.setdefault((r["host"], r["tool"]), {"n": 0, "by_conv": {}})
        g["n"] += r["n"]
        if r["conversation"]:
            g["by_conv"][r["conversation"]] = g["by_conv"].get(r["conversation"], 0) + r["n"]
    return groups


def _rule_tool_errors(rules, _uso, _gates):
    groups = _tool_groups(rules["tool_errors"])
    if not groups:
        return None
    (host, tool), g = max(groups.items(), key=lambda kv: (kv[1]["n"], str(kv[0])))
    if g["n"] < TOOL_MIN_ERRORS:
        return None
    conv = max(g["by_conv"].items(), key=lambda kv: (kv[1], kv[0]))[0] if g["by_conv"] else None
    title = f"{g['n']} de {rules['span_errors']} erros vêm de {tool or 'ferramenta sem nome'} em {host or '—'}"
    href, action = (f"/conversa?id={_q(conv)}", "Ver conversa") if conv else ("/conversas", "Ver conversas")
    return _insight("tool_errors", "terminal", "bad", title, "Mesma ferramenta e mesmo host na janela.", href, action)


def _rule_unpriced(rules, _uso, _gates):
    n = rules["unpriced_calls"]
    if not n:
        return None
    title = f"{alert_text.num(n)} {'chamada sem preço' if n == 1 else 'chamadas sem preço'} na janela"
    return _insight("unpriced", "receipt", "neutral", title,
                    f"Modelos: {', '.join(rules['unpriced_models'])}. Ficam fora da soma do custo.", "/precos", "Ver preços")


_RULES = (_rule_p95, _rule_gate, _rule_model_cost, _rule_cache, _rule_tool_errors, _rule_unpriced)


def insights(snap, gate_ages, window_qs):
    """Insights da janela por regra fixa, na ordem do #469. `gate_ages` = idades (s) de cada Gate pendente (pedido do canal
    e decisão da rodada), `None` = o estado não foi lido; `window_qs` = a janela na query string, para os links."""
    found = (rule(snap["rules"], f"/uso?{window_qs}", gate_ages) for rule in _RULES)
    return [i for i in found if i]


def _q(v):
    return quote(str(v), safe="")
