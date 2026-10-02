"""Pedidos do canal de aprovação para a tela (ADR-08 §10, #208): a lista (pendentes e decididos recentes) e a página
"ver script" de um pedido.

**Pedido** = `oute.canal.id` (o id que o `oute-propose` imprime). Um papel por banco, como nas sessões (#207):

- SurrealDB = o estado (`pedido:<oute.canal.id>`, #187): pendente ou decidido e, se decidido, decisão, rc, duração,
  tamanho da saída e aprovador. A lista sai só dele.
- DuckDB = o fato: o evento `oute.canal.proposed`, com o **script no corpo** (ADR-04) e título, como, agente e origem.

A saída do host nunca aparece: ela não chega ao pipeline (o `oute.canal.decided` não tem corpo). Só leitura: aprovar
e recusar continuam no `oute approve` (ADR-01).

O evento vem do container do agente: um `proposed` forjado com o mesmo id pode trocar o script que a página mostra.
A tela não decide qual é o verdadeiro; ela dá o que permite conferir: o sha256 do que está exibido, no formato do
`oute approve` (`approve_sha`), e quantas versões diferentes do pedido chegaram (`versions`).
"""
import hashlib
from datetime import datetime, timezone

from .conversations import _dicts
from .state import iso

PENDING_LIMIT = 200  # pedidos pendentes na lista (os mais recentes)
RECENT_LIMIT = 50    # pedidos decididos na lista (os últimos, pela hora da decisão)

PROPOSED = "oute.canal.proposed"
# o que a página aceita do registro do SurrealDB (o script, o sha256 dele e as versões são só do evento)
_RECORD = ("title", "as", "agent", "host", "instance", "size", "state", "proposed_at", "decided_at", "decision", "rc",
           "duration_s", "output_bytes", "approver", "sha256")

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
# versões diferentes do pedido: tudo o que entra no arquivo que o `oute approve` lê (script e cabeçalho)
_VERSIONS = f"""
    SELECT count(*) FROM (
      SELECT DISTINCT body, oute_agent, time_unix_nano // 1000000000,
             json_extract_string(attributes, '$."oute.canal.title"'),
             json_extract_string(attributes, '$."oute.canal.as"')
      FROM logs
      WHERE event_name = '{PROPOSED}' AND json_extract_string(attributes, '$."oute.canal.id"') = ?)"""

APPROVE_READ = 65536  # o `oute approve` lê no máximo isto do arquivo do pedido (`head -c` no scripts/oute)


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


def approve_sha(ev):
    """Os 12 primeiros hex do sha256 que o `oute approve` imprime para o pedido deste evento; `None` sem script.

    O `oute approve` (scripts/oute) calcula o sha256 do **arquivo** do pedido: o cabeçalho do `oute-propose`
    (título, como, agente, criado) + linha em branco + script. O evento leva essas mesmas partes (`oute-emit`), então
    o arquivo é refeito aqui. Pedido que não nasceu do `oute-propose` (cabeçalho diferente) dá outro valor."""
    if ev.get("script") is None:
        return None
    agent = ev.get("agent") or "unknown"
    created = datetime.fromtimestamp(ev["time_unix_nano"] // 1_000_000_000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    text = (f"# oute-propose\n# titulo: {ev.get('title') or ''}\n# como: {ev.get('as') or 'user'}\n"
            f"# agente: {'desconhecido' if agent == 'unknown' else agent}\n# criado: {created}\n\n{ev['script']}")
    return hashlib.sha256(text.encode()[:APPROVE_READ]).hexdigest()[:12]


def event(con, proposal_id):
    """O primeiro evento `oute.canal.proposed` do pedido no DuckDB (pela hora do fato), com o script, o sha256 dele
    como o `oute approve` mostra (`shown_sha256`) e quantas versões diferentes do pedido chegaram (`versions`: mais
    de uma = há `proposed` com script ou cabeçalho diferente para o mesmo id). `None` se nenhum chegou."""
    rows = _dicts(con.execute(_EVENT, [proposal_id]))
    if not rows:
        return None
    ev = rows[0]
    ev["shown_sha256"] = approve_sha(ev)
    ev["versions"] = con.execute(_VERSIONS, [proposal_id]).fetchone()[0]
    return ev


def merged(proposal_id, ev, record):
    """Evento do DuckDB + registro do SurrealDB -> o pedido da página. O registro vale; o que ele não tem (ou o
    pedido inteiro, sem SurrealDB) vem do evento. `state` nulo = estado não lido ou sem registro. `sha256` é o do
    script executado (do `decided`); `shown_sha256` e `versions` são sempre do evento."""
    p = {"id": proposal_id, **dict.fromkeys((*_RECORD, "script", "shown_sha256")), "versions": 0}
    if ev:
        p.update({k: v for k, v in ev.items() if k in p}, proposed_at=iso(ev["time_unix_nano"]))
    p.update({k: v for k, v in (record or {}).items() if k in _RECORD and v is not None})
    return p
