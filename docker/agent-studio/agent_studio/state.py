"""Estado derivado para o SurrealDB (ADR-08 §3, #187): rodadas, workers, sessões, pedidos, conversas.

Tudo sai dos eventos que já estão no DuckDB (`oute.swarm.*`, `oute.canal.*`, `oute.task.*`) e dos ids de sessão
dos registros; nada existe só no SurrealDB, que pode ser remontado reenviando os logs. Cada registro tem id
determinístico (o do fato: rodada, pedido, `oute.task.id`, `session.id`) e toda escrita é `UPSERT … MERGE` com
valores do próprio fato: reenviar o mesmo lote, em qualquer ordem, dá o mesmo resultado. O estado inicial
(`pendente`, `aberta`) só entra se o registro ainda não tem estado (`??`): um `proposed` atrasado não desfaz um
`decided`.

Tabelas: `rodada` (id = rodada), `worker` (id = [rodada, slug]), `sessao` (id = `oute.task.id`), `pedido`
(id = `oute.canal.id`), `conversa` (id = `session.id`). Ligações por record link: `worker.rodada`,
`worker.sessao`, `sessao.rodada`, `sessao.worker`, `conversa.sessao`.
"""
import base64
from datetime import datetime, timezone

# tabelas e campos são constantes deste módulo; valores vão sempre em variáveis
UPSERT = 'UPSERT type::record("{t}", $v.id) MERGE $v.d;'
TIMES = 'UPDATE type::record("{t}", $v.id) SET {sets};'


def iso(ns):
    s, rest = divmod(int(ns), 1_000_000_000)
    return datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + f".{rest:09d}Z"


def clean(d):
    return {k: v for k, v in d.items() if v is not None}


def upsert(table, rid, data, times=None, links=None, initial=None):
    """Statements de um registro: MERGE dos dados, horas como datetime, links e estado inicial.

    Texto não vai no MERGE (#337): o `/rpc` do SurrealDB lê a variável JSON `"ship: verificar deploy"` como record id
    (`ship:verificar`) e perde o resto, e o mesmo vale para data, uuid etc. O texto segue em base64 e é decodificado
    no próprio SurrealDB (`<string>`), que o guarda como string, inteiro."""
    data = clean(data)
    texts = {k: v for k, v in data.items() if isinstance(v, str)}
    out = [(UPSERT.format(t=table), {"id": rid, "d": {k: v for k, v in data.items() if k not in texts}})]
    sets, value = [], {"id": rid, "t": {}, "l": {}, "s": initial, "b": {}}
    for k, text in texts.items():
        sets.append(f"`{k}` = <string>encoding::base64::decode($v.b.`{k}`)")
        value["b"][k] = base64.b64encode(text.encode()).decode()
    for k, ns in (times or {}).items():
        if ns:
            sets.append(f"{k} = <datetime> $v.t.{k}")
            value["t"][k] = iso(ns)
    for k, (target, tid) in (links or {}).items():
        if tid:
            sets.append(f'{k} = type::record("{target}", $v.l.{k})')
            value["l"][k] = tid
    if initial:
        sets.append("state = state ?? $v.s")
    if sets:
        out.append((TIMES.format(t=table, sets=", ".join(sets)), value))
    return out


def _get(row, key):
    v = row["_attrs"].get(key)
    return v if v is not None else row["_res"].get(key)


def event_statements(row):
    """Um evento operacional (linha da tabela `logs`) -> statements. Evento desconhecido = nenhum."""
    name = row.get("event_name") or ""
    a = lambda k: _get(row, k)  # noqa: E731
    t = row["time_unix_nano"]
    origin = {"host": row.get("host_name"), "instance": row.get("oute_instance")}
    ev = row.get("oute_event_id")
    if name.startswith("oute.canal."):
        pid = a("oute.canal.id")
        if not pid:
            return []
        if name == "oute.canal.proposed":
            return upsert("pedido", pid, {**origin, "title": a("oute.canal.title"), "as": a("oute.canal.as"),
                                          "agent": row.get("oute_agent"), "size": a("oute.canal.size"),
                                          "proposed_event": ev, "trace_id": row.get("trace_id")},
                          times={"proposed_at": t}, initial="pendente")
        if name == "oute.canal.decided":
            return upsert("pedido", pid, {**origin, "state": "decidido", "decision": a("oute.canal.decision"),
                                          "rc": a("oute.canal.rc"), "duration_s": a("oute.canal.duration_s"),
                                          "output_bytes": a("oute.canal.output_bytes"),
                                          "approver": a("oute.canal.approver"), "sha256": a("oute.canal.sha256"),
                                          "decided_by": row.get("oute_agent"), "decided_event": ev},
                          times={"decided_at": t})
        return []
    if name.startswith("oute.swarm."):
        rnd = a("oute.swarm.round")
        if not rnd:
            return []
        if name == "oute.swarm.round.opened":
            return upsert("rodada", rnd, {**origin, "repo": a("oute.swarm.repo"), "max": a("oute.swarm.max"),
                                          "label": a("oute.swarm.label"), "agent": row.get("oute_agent"),
                                          "opened_event": ev},
                          times={"opened_at": t}, initial="aberta")
        if name == "oute.swarm.round.closed":
            return upsert("rodada", rnd, {**origin, "state": "fechada", "closed_event": ev}, times={"closed_at": t})
        slug = a("oute.swarm.session")
        if not slug:
            return []
        wid = [rnd, slug]
        if name == "oute.swarm.session.spawned":
            return (upsert("rodada", rnd, origin)
                    + upsert("worker", wid, {**origin, "slug": slug, "issue": a("oute.swarm.issue"),
                                             "agent": a("oute.swarm.session.agent"), "repo": a("oute.swarm.repo"),
                                             "kaizen": a("oute.swarm.kaizen"), "spawned_event": ev},
                             times={"spawned_at": t}, links={"rodada": ("rodada", rnd)}, initial="aberta"))
        if name == "oute.swarm.session.closed":
            return upsert("worker", wid, {**origin, "slug": slug, "state": "fechada", "closed_event": ev},
                          times={"closed_at": t}, links={"rodada": ("rodada", rnd)})
        return []
    if name.startswith("oute.task."):
        tid = a("oute.task.id")
        if not tid:
            return []  # sessão anterior à release, removida sem id (ADR-04, #128): fica só no DuckDB
        rnd, slug = a("oute.swarm.round"), a("oute.swarm.session")
        links = {"rodada": ("rodada", rnd)}
        if rnd and slug:
            links["worker"] = ("worker", [rnd, slug])
        data = {**origin, "repo": a("oute.task.repo"), "slug": a("oute.task.slug"), "agent": a("oute.task.agent"),
                "legacy": a("oute.task.legacy")}
        out = []
        if name == "oute.task.opened":
            out = upsert("sessao", tid, {**data, "opened_event": ev}, times={"opened_at": t}, links=links,
                         initial="aberta")
        elif name == "oute.task.reopened":
            out = upsert("sessao", tid, {**data, "reopened_event": ev}, times={"reopened_at": t}, links=links,
                         initial="aberta")
        elif name == "oute.task.removed":
            out = upsert("sessao", tid, {**data, "state": "removida",
                                         "removed_reason": a("oute.task.reason") or a("oute.task.removed.reason"),
                                         "removed_event": ev},
                         times={"removed_at": t}, links=links)
        if out and rnd and slug:
            out += upsert("worker", [rnd, slug], {"slug": slug}, links={"sessao": ("sessao", tid),
                                                                         "rodada": ("rodada", rnd)})
        return out
    return []


def statements(table, rows):
    """Linhas de uma tabela do DuckDB -> statements do SurrealDB (vazio = nada a derivar)."""
    if table not in ("logs", "spans"):
        return []
    out, conversas = [], {}
    for r in rows:
        if table == "logs" and "_attrs" in r:
            out += event_statements(r)
        if r.get("session_id"):
            # conversa -> sessão: a identidade da sessão vai no OTEL_RESOURCE_ATTRIBUTES das conversas (#128)
            conversas[r["session_id"]] = r
    for sid, r in conversas.items():
        out += upsert("conversa", sid, {"agent": r.get("oute_agent"), "host": r.get("host_name"),
                                        "instance": r.get("oute_instance"), "service": r.get("service_name")},
                      links={"sessao": ("sessao", r.get("oute_task_id"))})
    return out
