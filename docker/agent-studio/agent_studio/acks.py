"""Ack ("visto") de alerta e de decisão pendente (#537, ADR-08 §10, adendo do ack): a tabela `ack_marks` do DuckDB.

**Só de acréscimo** (nenhuma linha é alterada nem apagada) e **escrita só pela rota `POST /ack`**: a ingestão e o replay nunca
fabricam ack. É uma tabela própria, separada da das marcas de ação (`marks.py`). A marca **não vai ao bucket** (perda aceita): volume do DuckDB perdido = os itens
ativos voltam à faixa sem reconhecimento. O `ack` do SurrealDB é derivado daqui (`state.ack_statements`), e o
`rebuild-state` o remonta sem renovar a validade (a linha já traz `expires_unix_nano`).

- **Alvo** (`target`): os 32 primeiros hex do sha256 da identidade (`identity`, JSON). Alerta = tipo, host, instância e as
  dimensões da regra (`DIMS`: exporter, atributo do spool, agente e série da cota, rodada, modelo, fonte). Decisão = host,
  instância e rodada. O valor do alerta e a idade não entram: oscilar dentro da mesma condição não muda o alvo.
- **Versão** da ocorrência: `rule` (unidade e limite da regra) e `since` (alerta: o `since` do `GET /v1/alerts`; decisão:
  a hora da pergunta, `asked_at`).
- **Validade** (`valid`): 24 h contadas no servidor desde o ack (`TTL_NS`), a mesma regra, e a mesma ocorrência (`same`).
  Decisão: a mesma pergunta (`asked_at` igual). Alerta: o `since` igual ao do ack, ou anterior ao ack (o `since` anda quando
  a condição passa de `lookback_hours`, e a conferência diária de preço o regrava: só o primeiro caso continua valendo).
  Recuperação e nova falha depois do ack dão um `since` posterior a ele: ocorrência nova, sem ack. Alerta sem `since` não
  prova continuidade: não tem botão.
- Vencer ou mudar não apaga a linha: só tira o efeito dela.
"""
import hashlib
import json
import re
import time
from datetime import datetime, timezone

from . import alerts as alerts_mod

TTL_NS = 24 * 3600 * 1_000_000_000
BY = "human"
ALERT, DECISION = "alerta", "decisao"
KINDS = (ALERT, DECISION)
DECISION_RULE = "pergunta"
TARGET = re.compile(r"^[0-9a-f]{32}\Z")
SINCE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z", re.ASCII)
# as dimensões da regra de cada tipo de alerta (chaves do `evidence`); tipo fora daqui = só tipo, host e instância
DIMS = {
    alerts_mod.QUEUE: ("exporter",), alerts_mod.REFUSING: ("exporter",), alerts_mod.SPOOL: ("attribute",),
    alerts_mod.QUOTA: ("agent", "attributes"), alerts_mod.ROUND_STALLED: ("round",), alerts_mod.ROUND_OLD: ("round",),
    "price_changed": ("model", "field", "changed_at"), "price_sources_diverge": ("model",), "price_source_down": ("source",),
    "price_model_unpriced": ("model",), "price_fixed_differs": ("model",),
}

SCHEMA = """CREATE TABLE IF NOT EXISTS ack_marks (
    target VARCHAR NOT NULL, kind VARCHAR NOT NULL, identity VARCHAR NOT NULL, since VARCHAR NOT NULL, rule VARCHAR NOT NULL,
    acked_unix_nano UBIGINT NOT NULL, expires_unix_nano UBIGINT NOT NULL, acked_by VARCHAR NOT NULL,
    PRIMARY KEY (target, acked_unix_nano))"""
COLUMNS = ("target", "kind", "identity", "since", "rule", "acked_unix_nano", "expires_unix_nano", "acked_by")
_IF_ACK = ("IF (INFO FOR DB).tables.ack THEN (SELECT target, since, rule, acked_ns, expires_ns, acked_at, expires_at FROM ack "
           "WHERE expires_ns > $now) ELSE [] END;")


def create(con):
    con.execute(SCHEMA)


# ------------------------------------------------ alvo e versão
def _item(kind, identity, since, rule):
    text = json.dumps([kind, *identity], ensure_ascii=True, separators=(",", ":"), default=str)
    return {"kind": kind, "identity": text, "target": hashlib.sha256(text.encode()).hexdigest()[:32],
            "since": since or "", "rule": rule}


def alert_item(a):
    """Um alerta do `alerts.evaluate` -> `{"kind", "identity", "target", "since", "rule"}`. Só lê o alerta."""
    evidence = a.get("evidence") or {}
    dims = [evidence.get(k) for k in DIMS.get(a.get("type"), ())]
    return _item(ALERT, [a.get("type"), a.get("host"), a.get("instance"), *dims], a.get("since"), f"{a.get('unit')}:{a.get('limit')}")


def decision_item(d):
    """Uma decisão pendente do `decisions.pending` -> o mesmo formato. A versão é a hora da pergunta."""
    return _item(DECISION, [d.get("host"), d.get("instance"), d.get("round")], d.get("asked_at"), DECISION_RULE)


def since_ns(text):
    """`2026-10-06T12:00:00Z` -> ns; fora desse formato, `None`."""
    if not isinstance(text, str) or not SINCE.match(text):
        return None
    try:
        return int(datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()) * 1_000_000_000
    except ValueError:
        return None


def same(kind, since_then, at_ns, since_now):
    """A ocorrência de agora (`since_now`) é a que foi vista em `at_ns` com `since_then`? Sem `since` nos dois lados, não."""
    if not since_now or not since_then:
        return False
    if since_now == since_then:
        return True
    if kind != ALERT:
        return False
    now_ns = since_ns(since_now)
    return now_ns is not None and now_ns <= at_ns


def valid(mark, item, now_ns):
    """A marca `mark` (`{"since", "rule", "acked_ns", "expires_ns"}` ou `None`) ainda vale para o item de agora?"""
    if not mark:
        return False
    try:
        acked, expires = int(mark["acked_ns"]), int(mark["expires_ns"])
    except (KeyError, TypeError, ValueError):
        return False
    return now_ns < expires and mark.get("rule") == item["rule"] and same(item["kind"], mark.get("since"), acked, item["since"])


# ------------------------------------------------ DuckDB
def last(con, target):
    """A marca mais nova do alvo, no formato do `valid`, ou `None`."""
    row = con.execute(f"SELECT {', '.join(COLUMNS)} FROM ack_marks WHERE target = ? ORDER BY acked_unix_nano DESC LIMIT 1", [target]).fetchone()
    return None if row is None else dict(zip(COLUMNS, row))


def as_mark(row):
    return {"since": row["since"], "rule": row["rule"], "acked_ns": row["acked_unix_nano"], "expires_ns": row["expires_unix_nano"]}


def append(con, item):
    """Acrescenta o ack do item (dentro de uma transação do chamador) e devolve a linha. A hora e o prazo são do servidor;
    a hora cresce sempre, então a marca mais nova de um alvo é sempre a última."""
    newest = con.execute("SELECT max(acked_unix_nano) FROM ack_marks").fetchone()[0] or 0
    ns = max(time.time_ns(), int(newest) + 1)
    row = dict(zip(COLUMNS, (item["target"], item["kind"], item["identity"], item["since"], item["rule"], ns, ns + TTL_NS, BY)))
    con.execute(f"INSERT INTO ack_marks ({', '.join(COLUMNS)}) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [row[c] for c in COLUMNS])
    return row


def has_table(con):
    return con.execute("SELECT count(*) FROM information_schema.tables WHERE table_name = 'ack_marks'").fetchone()[0] > 0


def rows(con, chunk):
    """Todas as marcas, na ordem em que entraram, em blocos (o `rebuild-state`). Sem a tabela (banco anterior à #537): nada."""
    if not has_table(con):
        return
    cur = con.execute(f"SELECT {', '.join(COLUMNS)} FROM ack_marks ORDER BY acked_unix_nano")
    while True:
        block = cur.fetchmany(chunk)
        if not block:
            return
        yield [dict(zip(COLUMNS, b)) for b in block]


# ------------------------------------------------ SurrealDB (o estado derivado, lido pela tela)
def states(surreal, now_ns):
    """{alvo: marca} dos acks ainda dentro do prazo, do SurrealDB. Erro do SurrealDB levanta (SurrealError)."""
    found = surreal.query(_IF_ACK, {"now": int(now_ns)})
    return {r["target"]: r for r in (found[0]["result"] or []) if isinstance(r.get("target"), str)}


def split(items, to_item, marks, now_ns):
    """As linhas da faixa -> (na faixa, vistos). Cada linha sai copiada (o alerta do cache do `/v1/alerts` não muda) com `ack`:
    `target`, `since`, `can` (dá para reconhecer: tem `since`) e, nos vistos, `acked_at` e `expires_at`. `marks` = `None`
    (estado não lido) deixa tudo na faixa; `items` = `None` (o cálculo falhou) passa como está."""
    if items is None:
        return None, []
    shown, seen = [], []
    for it in items:
        item = to_item(it)
        mark = (marks or {}).get(item["target"])
        ok = valid(mark, item, now_ns)
        info = {"target": item["target"], "since": item["since"], "can": bool(item["since"]),
                "acked_at": mark.get("acked_at") if ok else None, "expires_at": mark.get("expires_at") if ok else None}
        (seen if ok else shown).append({**it, "ack": info})
    return shown, seen
