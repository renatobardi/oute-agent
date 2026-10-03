"""Texto dos alertas (#344): o título e o valor por extenso, num módulo só. Usado pela tela (`web.py`, filtros do
`base.html`) e pelo `GET /v1/tray` (`title` e `text` de cada alerta), para o tray não repetir a regra em Swift.

Só apresentação: quem decide se há alerta é o `alerts.evaluate` (#204). Tipo novo de alerta ganha o título aqui.
Também mora aqui a formatação em português (`br`, `num`, `dur`, `mib`) que o texto usa e a tela reaproveita.
"""
from . import alerts as alerts_mod

TITLES = {alerts_mod.QUEUE: "Fila do collector acima do limite", alerts_mod.REFUSING: "Destino recusando",
          alerts_mod.NO_DATA: "Host sem dado", alerts_mod.SPOOL: "Spool do oute-emit",
          alerts_mod.QUOTA: "Cota da assinatura"}


def br(text):
    # 1,234.5 -> 1.234,5
    return text.translate(str.maketrans(",.", ".,"))


def num(n):
    return "—" if n is None else br(f"{n:,}")


def dur(ns):
    if ns is None:
        return "—"
    s = ns / 1e9
    if s < 1:
        return f"{br(f'{s * 1000:.0f}')} ms"
    if s < 60:
        return f"{br(f'{s:.1f}')} s"
    m, s = divmod(int(s), 60)
    h, m = divmod(m, 60)
    return f"{h} h {m:02d} min" if h else f"{m} min {s:02d} s"


def mib(n):
    return f"{br(f'{n / 2**20:,.1f}')} MiB"


def title(alert):
    return TITLES.get(alert["type"], alert["type"])


def text(alert):
    """Valor e limite do alerta por extenso, pela unidade do `/v1/alerts`. Unidade nova sai crua (`valor unidade`)."""
    v, unit, limit, ev = alert["value"], alert["unit"], alert["limit"], alert["evidence"]
    if v is None:
        return ev.get("note") or "sem valor"
    if unit == "ratio":
        return f"{br(f'{v * 100:.0f}')}% da fila (limite {br(f'{limit * 100:.0f}')}%)"
    if unit == "pct":
        return f"{br(f'{v:g}')}% (limite {br(f'{limit:g}')}%)"
    if unit == "bytes":
        return f"{mib(v)} (limite {mib(limit)})"
    if unit == "seconds":
        return f"há {dur(int(v * 1e9))} (limite {dur(int(limit * 1e9))})"
    if unit in ("failed_items", "dropped_events"):
        what = "itens recusados" if unit == "failed_items" else "eventos descartados"
        return f"{num(round(v))} {what} nos últimos {br(format(ev.get('window_minutes', 0), 'g'))} min"
    return f"{v} {unit}"


def with_text(alerts):
    """Os alertas do `alerts.evaluate` com `title` e `text` a mais; os outros campos, como vieram."""
    return [{**a, "title": title(a), "text": text(a)} for a in alerts]
