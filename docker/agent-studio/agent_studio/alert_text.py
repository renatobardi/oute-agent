"""Texto dos alertas (#344): o título e o valor por extenso, num módulo só. Usado pela tela (`web.py`, filtros do
`base.html`) e pelo `GET /v1/tray` (`title` e `text` de cada alerta), para o tray não repetir a regra em Swift.

Só apresentação: quem decide se há alerta é o `alerts.evaluate` (#204). Tipo novo de alerta ganha o título aqui.
Também mora aqui a formatação em português (`br`, `num`, `dur`, `mib`) que o texto usa e a tela reaproveita.
"""
from . import alerts as alerts_mod

TITLES = {alerts_mod.QUEUE: "Fila do collector acima do limite", alerts_mod.REFUSING: "Destino recusando",
          alerts_mod.NO_DATA: "Host sem dado", alerts_mod.SPOOL: "Spool do oute-emit",
          alerts_mod.QUOTA: "Cota da assinatura",
          alerts_mod.ROUND_STALLED: "Rodada parada", alerts_mod.ROUND_OLD: "Rodada antiga sem fechamento",
          # preços (#339): critérios em `price_alerts.py`
          "price_changed": "Preço trocado", "price_sources_diverge": "Fontes de preço divergem",
          "price_source_down": "Fonte de preço fora do ar", "price_model_unpriced": "Modelo em uso sem preço",
          "price_fixed_differs": "Preço fixo difere da fonte"}


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
    if alert["type"] in (alerts_mod.ROUND_STALLED, alerts_mod.ROUND_OLD):  # rodada do swarm (#364)
        n, ago = len(ev["sessions"]), f"último evento há {dur(int(v * 1e9))}"
        if alert["type"] == alerts_mod.ROUND_OLD:
            return f"rodada {ev['round']} aberta e sem fechamento; {ago}"
        if not n:
            return f"rodada {ev['round']} sem sessão aberta, triagem sem resposta; {ago} (limite {dur(int(limit * 1e9))})"
        return (f"rodada {ev['round']} com {n} {'sessão aberta' if n == 1 else 'sessões abertas'} "
                f"({', '.join(ev['sessions'])}); {ago} (limite {dur(int(limit * 1e9))})")
    if unit == "seconds":
        return f"há {dur(int(v * 1e9))} (limite {dur(int(limit * 1e9))})"
    if unit == "usd_per_mtok":  # preço trocado (#339): o campo, o valor antigo e o novo
        old, new = br(format(ev["old"], "g")), br(format(v, "g"))
        return f"{ev['model']} · {ev['field']}: US$ {old} → US$ {new} por 1M tokens"
    if unit == "days":  # fonte de preço fora do ar (#339)
        return f"falhou em {num(round(v))} dias seguidos (limite {num(round(limit))})"
    if unit in ("failed_items", "dropped_events"):
        what = "itens recusados" if unit == "failed_items" else "eventos descartados"
        return f"{num(round(v))} {what} nos últimos {br(format(ev.get('window_minutes', 0), 'g'))} min"
    return f"{v} {unit}"


def with_text(alerts):
    """Os alertas do `alerts.evaluate` com `title` e `text` a mais; os outros campos, como vieram."""
    return [{**a, "title": title(a), "text": text(a)} for a in alerts]
