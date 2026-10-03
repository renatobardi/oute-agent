"""Alertas de preço (#339, ADR-08 §8 e adendo "Preços"), no pipeline do `alerts.evaluate` (#204): calculados do histórico
de preços na hora da consulta, sem estado próprio.

- **`price_changed`** (`preço trocado`, informativo): a conferência trocou o preço de um modelo nos últimos
  `CHANGED_DAYS` (7) dias; some sozinho depois. Um alerta por modelo e campo, com valor antigo e novo.
- **`price_sources_diverge`** (`fontes divergem`): na última conferência as duas fontes tinham valores diferentes.
- **`price_source_down`** (`fonte fora do ar`): a fonte falhou em conferências de `SOURCE_DOWN_DAYS` (2) dias UTC
  diferentes seguidos (desde o último sucesso dela).
- **`price_model_unpriced`** (`modelo em uso sem preço`): modelo com chamada sem custo real nos últimos 30 dias que
  segue sem preço depois da última conferência.
- **`price_fixed_differs`** (`preço fixo difere da fonte`): modelo com `fixed = true` cujo preço as duas fontes
  concordam em outro valor.

Os de problema ficam ligados até a conferência seguinte não os repetir. Todo alerta de preço leva `evidence.level`
(`info` ou `problem`). Textos em `evidence.note` só levam o que é nosso: nomes de modelo que passaram pela validação
de nome, campos, fontes e números.
"""
import json

from . import alerts as alerts_mod, price_sources as src, prices as prices_mod

CHANGED, DIVERGE, SOURCE_DOWN, UNPRICED, FIXED_DIFFERS = alerts_mod.PRICE_TYPES

CHANGED_DAYS = 7
SOURCE_DOWN_DAYS = 2
USD_PER_MTOK = "usd_per_mtok"


def _fmt(v):
    return f"{v:g}"


def _alert(kind, value, unit, limit, since, evidence, level="problem"):
    return alerts_mod._alert(kind, None, None, value, unit, limit, since, {**evidence, "level": level})


def _changed(con, at_ns):
    lo = at_ns - CHANGED_DAYS * prices_mod.DAY_NS
    out = []
    rows = prices_mod.history_rows(con)
    for prev, row in zip(rows, rows[1:]):
        if row["model"] != prev["model"] or row["origin"] != prices_mod.ORIGIN_SOURCES:
            continue
        if not lo < row["start_unix_nano"] <= at_ns:
            continue
        for f in src.FIELDS:
            if abs(row[f] - prev[f]) > 1e-9 * max(1.0, abs(row[f]), abs(prev[f])):
                out.append(_alert(CHANGED, row[f], USD_PER_MTOK, None, row["start_unix_nano"],
                                  {"model": row["model"], "field": f, "old": prev[f], "new": row[f],
                                   "changed_at": alerts_mod.iso(row["start_unix_nano"])}, level="info"))
    return out


def _last_checks(con, at_ns):
    return prices_mod._rows(con, """
        SELECT model, status, detail, checked_unix_nano FROM price_checks
        WHERE checked_unix_nano = (SELECT max(checked_unix_nano) FROM price_checks WHERE checked_unix_nano <= ?)
        ORDER BY model""", [at_ns])


def _from_checks(con, at_ns):
    out = []
    for r in _last_checks(con, at_ns):
        info = json.loads(r["detail"]) if r["detail"] else {}
        since, m = r["checked_unix_nano"], r["model"]
        if r["status"] == prices_mod.DIVERGE:
            fields = info.get("fields", {})
            note = "; ".join(f"{m} {f}: " + " × ".join(f"{s} {_fmt(v)}" for s, v in vals.items() if v is not None)
                             for f, vals in sorted(fields.items()))
            out.append(_alert(DIVERGE, None, None, None, since, {"model": m, "fields": fields, "note": note}))
        elif r["status"] == prices_mod.FIXED_DIFFERS:
            fx, fonte = info.get("fixed", {}), info.get("sources", {})
            diff = [f for f in src.FIELDS if f in fx and f in fonte and fx[f] != fonte[f]]
            note = f"{m}: fixo no config.toml e as fontes concordam em outro valor (" + "; ".join(
                f"{f} {_fmt(fx[f])} → {_fmt(fonte[f])}" for f in diff) + ")"
            out.append(_alert(FIXED_DIFFERS, None, None, None, since,
                              {"model": m, "fixed": fx, "sources": fonte, "note": note}))
        if info.get("unpriced"):
            out.append(_alert(UNPRICED, None, None, None, since,
                              {"model": m, "note": f"{m}: chamadas sem custo real e sem preço na tabela"}))
    return out


def _source_down(con, at_ns):
    out = []
    for source in src.SOURCES:
        ok = prices_mod._rows(con, "SELECT max(checked_unix_nano) AS t FROM price_runs WHERE source = ? AND ok "
                                   "AND checked_unix_nano <= ?", [source, at_ns])[0]["t"]
        runs = prices_mod._rows(con, "SELECT checked_unix_nano AS t, reason FROM price_runs WHERE source = ? "
                                     "AND NOT ok AND checked_unix_nano > ? AND checked_unix_nano <= ? "
                                     "ORDER BY checked_unix_nano", [source, ok or 0, at_ns])
        latest = prices_mod._rows(con, "SELECT ok FROM price_runs WHERE source = ? AND checked_unix_nano <= ? "
                                       "ORDER BY checked_unix_nano DESC LIMIT 1", [source, at_ns])
        days = len({r["t"] // prices_mod.DAY_NS for r in runs})
        if latest and not latest[0]["ok"] and days >= SOURCE_DOWN_DAYS:
            out.append(_alert(SOURCE_DOWN, days, "days", SOURCE_DOWN_DAYS, runs[0]["t"],
                              {"source": source, "reason": runs[-1]["reason"], "last_ok": alerts_mod.iso(ok)}))
    return out


def evaluate(con, at_ns):
    """Os alertas de preço ativos na hora `at_ns`."""
    return _changed(con, at_ns) + _from_checks(con, at_ns) + _source_down(con, at_ns)
