"""Cadastro de planos de assinatura, com histórico de valores (#746, ADR-08, adendo "Planos de assinatura").

**Uma tabela no DuckDB, só de acréscimo** (nunca `UPDATE` nem `DELETE`): `plan_history`, uma linha por mudança de plano ou de
valor de uma assinatura (`claude`, `zai`, `codex`): nome do plano, valor mensal em dólar, data em que passa a valer (`start_date`,
dia `AAAA-MM-DD`) e quando a linha foi registrada (`registered_unix_nano`, hora do servidor). Corrigir um valor é acrescentar outra
linha; para o mesmo `start_date` vale a registrada por último.

**Consulta "valor do plano no dia D"** (`lookup`): a linha com o maior `start_date` menor ou igual a D (desempate: a registrada por
último). Antes da primeira linha, ou sem nenhuma linha, a assinatura está **sem plano**: o resultado é `None`, nunca US$ 0.
US$ 0 só existe quando alguém cadastrou o valor 0 (o Codex gratuito).

**Escrita** só pela rota `POST /planos/novo` (`marcar.py`, credencial de marcação; sem ela a rota não existe) e pela semente da subida
(`sync`, `[[plans]]` do `config.toml`, só para a assinatura que ainda não tem linha nenhuma). A tabela **não vai ao bucket**: volume
do DuckDB perdido = cadastro perdido, e a semente repõe só a carga inicial. O `plano` do SurrealDB é derivado daqui
(`state.plan_statements`) e o `rebuild-state` o remonta.

Este módulo não toca no custo: o rateio do valor do plano é de outra issue (#747, #749).
"""
import logging
import math
import re
import time
from datetime import date

from . import state
from .alerts import iso

detail_log = logging.getLogger("agent_studio_detail")

SUBSCRIPTIONS = ("claude", "zai", "codex")
ORIGIN_CONFIG, ORIGIN_SCREEN = "config", "tela"
MAX_USD = 100_000.0
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._×x+-]{0,59}\Z")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}\Z", re.ASCII)
MONEY = re.compile(r"^\d{1,6}([.,]\d{1,2})?\Z", re.ASCII)

SCHEMA = """CREATE TABLE IF NOT EXISTS plan_history (
    subscription VARCHAR NOT NULL, plan VARCHAR NOT NULL, monthly_usd DOUBLE NOT NULL, start_date VARCHAR NOT NULL,
    origin VARCHAR NOT NULL, registered_unix_nano UBIGINT NOT NULL,
    PRIMARY KEY (subscription, start_date, registered_unix_nano))"""
COLUMNS = ("subscription", "plan", "monthly_usd", "start_date", "origin", "registered_unix_nano")


def create(con):
    con.execute(SCHEMA)


def parse_day(text):
    """`AAAA-MM-DD` -> o mesmo texto se é um dia que existe; senão `None`."""
    if not isinstance(text, str) or not DAY.match(text):
        return None
    try:
        date.fromisoformat(text)
    except ValueError:
        return None
    return text


def parse_money(text):
    """`18`, `18.5` ou `18,50` -> float (0 a 100000, até 2 casas); fora disso `None`. Aceita também número (a semente)."""
    if isinstance(text, bool):
        return None
    if isinstance(text, (int, float)):
        value = float(text)
        return value if math.isfinite(value) and 0 <= value <= MAX_USD and round(value, 2) == value else None
    if not isinstance(text, str) or not MONEY.match(text.strip()):
        return None
    value = float(text.strip().replace(",", "."))
    return value if value <= MAX_USD else None


def validate(subscription, plan, usd, start):
    """-> `(subscription, plan, usd, start, None)` normalizados, ou `(None, None, None, None, motivo)`. O motivo é texto fixo."""
    plan = plan.strip() if isinstance(plan, str) else plan
    value, day = parse_money(usd), parse_day(start)
    if subscription not in SUBSCRIPTIONS:
        reason = "assinatura desconhecida"
    elif not isinstance(plan, str) or not NAME.match(plan):
        reason = "nome do plano inválido"
    elif value is None:
        reason = "valor inválido"
    elif day is None:
        reason = "data inválida"
    else:
        return subscription, plan, value, day, None
    return None, None, None, None, reason


def _rows(con, sql, params=()):
    cur = con.execute(sql, list(params))
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def history_rows(con):
    """Todas as linhas, por assinatura, início e hora do registro."""
    return _rows(con, f"SELECT {', '.join(COLUMNS)} FROM plan_history ORDER BY subscription, start_date, registered_unix_nano")


def append(con, subscription, plan, usd, start, origin=ORIGIN_SCREEN, now_ns=None):
    """Acrescenta a linha (dentro de uma transação do chamador) e a devolve como dict. A hora do registro é a do servidor e cresce
    sempre: duas linhas da mesma assinatura e do mesmo dia nunca empatam, e a mais nova vence. Os valores já foram `validate`."""
    last = con.execute("SELECT max(registered_unix_nano) FROM plan_history").fetchone()[0] or 0
    ns = max(time.time_ns() if now_ns is None else int(now_ns), int(last) + 1)
    con.execute("INSERT INTO plan_history VALUES (?, ?, ?, ?, ?, ?)", [subscription, plan, usd, start, origin, ns])
    return dict(zip(COLUMNS, (subscription, plan, usd, start, origin, ns)))


def lookup(con, subscription, day):
    """A linha que valia para `subscription` no dia `day` (`AAAA-MM-DD`), ou `None` (sem plano naquele dia)."""
    rows = _rows(con, f"SELECT {', '.join(COLUMNS)} FROM plan_history WHERE subscription = ? AND start_date <= ? "
                      "ORDER BY start_date DESC, registered_unix_nano DESC LIMIT 1", [subscription, day])
    return rows[0] if rows else None


def _entry(row):
    return {"plan": row["plan"], "monthly_usd": row["monthly_usd"], "since": row["start_date"], "origin": row["origin"],
            "registered": iso(row["registered_unix_nano"])}


def view(con, today):
    """Resposta do `GET /v1/plans` e dado da tela: por assinatura o plano vigente em `today` (`None` = sem plano) e o histórico.
    Assinatura sem linha vigente aparece com `current = None` e `label = "sem plano"`. Só leitura."""
    by = {s: [] for s in SUBSCRIPTIONS}
    for r in history_rows(con):
        by[r["subscription"]].append(_entry(r))
    out = []
    for s in SUBSCRIPTIONS:
        row = lookup(con, s, today)
        out.append({"subscription": s, "current": None if row is None else _entry(row),
                    "label": "sem plano" if row is None else row["plan"], "history": by[s]})
    return {"today": today, "unit": "USD por mês", "subscriptions": out}


def at_day(con, subscription, day):
    """Resposta de "valor do plano no dia D": `{"subscription", "day", "plan": linha | None, "label"}`."""
    row = lookup(con, subscription, day)
    return {"subscription": subscription, "day": day, "plan": None if row is None else _entry(row),
            "label": "sem plano" if row is None else row["plan"]}


def parse_seed(raw, errors):
    """`[[plans]]` do `config.toml` -> lista de `(assinatura, plano, valor, início)`. Entrada inválida vai em `errors` e fica de fora."""
    if raw is None:
        return []
    if not isinstance(raw, list):
        errors.append("[[plans]] não é lista de tabelas")
        return []
    out = []
    for i, entry in enumerate(raw):
        fields = entry if isinstance(entry, dict) else {}
        s, p, v, d, reason = validate(fields.get("subscription"), fields.get("plan"), fields.get("monthly_usd"), fields.get("start"))
        if reason:
            errors.append(f"plano inválido na entrada {i + 1} de [[plans]]: {reason}")
        else:
            out.append((s, p, v, d))
    return out


def sync(store, surreal, config, now_ns=None):
    """Na subida: a semente do `[[plans]]` entra nas assinaturas sem histórico (e no `plano` do SurrealDB, na mesma transação).
    Falha não derruba a subida: o cadastro fica como está e a causa vai ao stderr."""
    if not config.plans:
        return 0
    now = time.time_ns() if now_ns is None else now_ns

    def write(con):
        have = {r[0] for r in con.execute("SELECT DISTINCT subscription FROM plan_history").fetchall()}
        added = [r for r in config.plans if r[0] not in have]
        done = [append(con, s, p, v, d, ORIGIN_CONFIG, now) for s, p, v, d in added]
        if surreal is not None:
            surreal.apply([st for row in done for st in state.plan_statements(row)])
        return len(done)
    try:
        return store.transact(write)
    except Exception:  # noqa: BLE001 — a semente dos planos nunca derruba a subida; a causa só no stderr
        detail_log.exception("planos: semente do cadastro falhou, o cadastro fica como está")
        return 0


def rows(con, chunk):
    """Todas as linhas na ordem em que entraram, em blocos (o `rebuild-state`). Sem a tabela: nada."""
    n = con.execute("SELECT count(*) FROM information_schema.tables WHERE table_name = 'plan_history'").fetchone()[0]
    if not n:
        return
    cur = con.execute(f"SELECT {', '.join(COLUMNS)} FROM plan_history ORDER BY registered_unix_nano")
    while True:
        block = cur.fetchmany(chunk)
        if not block:
            return
        yield [dict(zip(COLUMNS, b)) for b in block]
