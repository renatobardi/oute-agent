"""Fuso de exibição do agent-studio (#415): a leitura converte; o que está gravado (hora do fato em UTC, ADR-08) não muda.

O fuso vem de `timezone` no `config.toml` (nome IANA, por `zoneinfo`: nunca deslocamento fixo) e, nas rotas que dão dia
(`/v1/usage`, `/v1/tray`), pode ser trocado por `tz=<IANA>`. Inválido ou ausente = UTC, com aviso. A API segue com
ISO 8601 com `Z`: o fuso só decide a meia-noite dos dias e a hora das telas.
"""
import re
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

UTC = ZoneInfo("UTC")
DEFAULT = "UTC"
_NAME = re.compile(r"^[A-Za-z0-9_+\-]+(/[A-Za-z0-9_+\-]+){0,2}$")  # só o que um nome IANA tem: vai literal no SQL


def parse(name):
    """`ZoneInfo` do nome IANA; `ValueError` se não existe (inclusive caminho, vazio e nome com símbolo)."""
    if not isinstance(name, str) or not _NAME.match(name.strip()):
        raise ValueError(f"fuso inválido: {str(name)[:40]!r}")
    try:
        return ZoneInfo(name.strip())
    except (ZoneInfoNotFoundError, ValueError, OSError):
        raise ValueError(f"fuso inválido: {name.strip()[:40]!r}") from None


def label(zone, at_ns=None):
    """Rótulo curto do fuso para cabeçalho de coluna: `GMT-3`, `GMT+5:30`; `UTC` para o UTC."""
    if zone.key == "UTC":
        return "UTC"
    dt = datetime.fromtimestamp((at_ns or datetime.now(timezone.utc).timestamp() * 1e9) // 1_000_000_000, zone)
    mins = int(dt.utcoffset().total_seconds() // 60)
    sign, mins = ("-" if mins < 0 else "+"), abs(mins)
    return f"GMT{sign}{mins // 60}" + (f":{mins % 60:02d}" if mins % 60 else "")


def local(ns, zone):
    """ns desde a época -> datetime no fuso."""
    return datetime.fromtimestamp(ns // 1_000_000_000, zone)


def day_bounds(at_ns, zone):
    """(início, fim) em ns UTC do dia do fuso que contém `at_ns`: meia-noite local a meia-noite local seguinte."""
    today = local(at_ns, zone).date()

    def midnight(d):
        # `zoneinfo` resolve a hora local sem ambiguidade na meia-noite dos fusos sem DST à meia-noite
        return int(datetime(d.year, d.month, d.day, tzinfo=zone).timestamp()) * 1_000_000_000

    return midnight(today), midnight(today + timedelta(days=1))
