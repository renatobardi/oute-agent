"""Pedidos do canal de aprovação para a tela (ADR-08 §10, #208): a lista (pendentes e decididos recentes) e a página
"ver script" de um pedido.

**Pedido** = `oute.canal.id` (o id que o `oute-propose` imprime). Um papel por banco, como nas sessões (#207):

- SurrealDB = o estado (`pedido:<oute.canal.id>`, #187): pendente ou decidido e, se decidido, decisão, rc, duração,
  tamanho da saída e aprovador. A lista sai só dele.
- DuckDB = o fato: o evento `oute.canal.proposed`, com o **script no corpo** (ADR-04) e título, como, agente e origem.

A saída do host nunca aparece: ela não chega ao pipeline (o `oute.canal.decided` não tem corpo). Só leitura: aprovar
e recusar continuam no `oute approve` (ADR-01).
"""
from .conversations import _dicts
from .state import iso

PENDING_LIMIT = 200  # pedidos pendentes na lista (os mais recentes)
RECENT_LIMIT = 50    # pedidos decididos na lista (os últimos, pela hora da decisão)

PROPOSED = "oute.canal.proposed"

_FIELDS = ("record::id(id) AS id, title, as, agent, host, instance, size, state, proposed_at, decided_at, decision, "
           "rc, duration_s, output_bytes, approver, sha256")
# antes do primeiro `oute.canal.*` a tabela não existe, e ler tabela que não existe é erro no SurrealDB: sem ela,
# lista vazia. Os valores vão sempre em variáveis.
_IF_TABLE = "IF (INFO FOR DB).tables.pedido THEN ({}) ELSE [] END;"
_LIST = " ".join(_IF_TABLE.format(q) for q in (
    f'SELECT {_FIELDS} FROM pedido WHERE state = "pendente" ORDER BY proposed_at DESC LIMIT $pending',
    f'SELECT {_FIELDS} FROM pedido WHERE state = "decidido" ORDER BY decided_at DESC LIMIT $recent',
    'SELECT count() AS n FROM pedido WHERE state = "pendente" GROUP ALL'))
# pelo id do registro: sem varrer a tabela (e tabela que ainda não existe = nenhum registro)
_ONE = f'SELECT {_FIELDS} FROM [type::record("pedido", $id)];'

_EVENT = f"""
    SELECT time_unix_nano, host_name AS host, oute_instance AS instance, oute_agent AS agent, body AS script,
           json_extract_string(attributes, '$."oute.canal.title"') AS title,
           json_extract_string(attributes, '$."oute.canal.as"') AS "as",
           TRY_CAST(json_extract_string(attributes, '$."oute.canal.size"') AS BIGINT) AS size
    FROM logs
    WHERE event_name = '{PROPOSED}' AND json_extract_string(attributes, '$."oute.canal.id"') = ?
    ORDER BY time_unix_nano, dedupe_key LIMIT 1"""


def listing(surreal, pending_limit=PENDING_LIMIT, recent_limit=RECENT_LIMIT):
    """Pedidos pendentes (do mais novo para o mais antigo; `pending_total` diz quantos há) e os últimos decididos.
    Erro do SurrealDB levanta (SurrealError): sem o estado não há lista."""
    found = surreal.query(_LIST, {"pending": pending_limit, "recent": recent_limit})
    count = found[2]["result"] or [{}]
    return {"pending": found[0]["result"] or [], "recent": found[1]["result"] or [],
            "pending_total": count[0].get("n", 0)}


def state(surreal, proposal_id):
    """O registro `pedido` do SurrealDB; `None` = sem registro. Erro do SurrealDB levanta (SurrealError)."""
    found = surreal.query(_ONE, {"id": proposal_id})[0]["result"] or []
    return next((r for r in found if r.get("state")), None)


def event(con, proposal_id):
    """O evento `oute.canal.proposed` do pedido no DuckDB, com o script; `None` se ele não chegou."""
    rows = _dicts(con.execute(_EVENT, [proposal_id]))
    return rows[0] if rows else None


def merged(proposal_id, ev, record):
    """Evento do DuckDB + registro do SurrealDB -> o pedido da página. O registro vale; o que ele não tem (ou o
    pedido inteiro, sem SurrealDB) vem do evento. `state` nulo = estado não lido ou sem registro."""
    p = {"id": proposal_id, **dict.fromkeys(("title", "as", "agent", "host", "instance", "size", "state",
                                             "proposed_at", "decided_at", "decision", "rc", "duration_s",
                                             "output_bytes", "approver", "sha256", "script"))}
    if ev:
        p.update({k: v for k, v in ev.items() if k in p}, proposed_at=iso(ev["time_unix_nano"]))
    p.update({k: v for k, v in (record or {}).items() if k in p and v is not None})
    return p
