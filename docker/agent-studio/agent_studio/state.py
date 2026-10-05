"""Estado derivado para o SurrealDB (ADR-08 §3, #187): rodadas, workers, sessões, pedidos, conversas.

Tudo sai dos eventos que já estão no DuckDB (`oute.swarm.*`, `oute.canal.*`, `oute.task.*`) e dos ids de sessão
dos registros; nada existe só no SurrealDB, que pode ser remontado reenviando os logs. Cada registro tem id
determinístico (o do fato: rodada, pedido, `oute.task.id`, `session.id`) e toda escrita é `UPSERT … MERGE` com
valores do próprio fato: reenviar o mesmo lote, em qualquer ordem, dá o mesmo resultado. O estado inicial
(`pendente`, `aberta`) só entra se o registro ainda não tem estado (`??`): um `proposed` atrasado não desfaz um
`decided`.

Tabelas: `rodada` (id = rodada), `worker` (id = [rodada, slug]), `sessao` (id = `oute.task.id`), `pedido`
(id = `oute.canal.id`), `conversa` (id = `session.id`), `etapa` (id = [rodada, tipo, chave], #507: a revisão vigente de uma
etapa da rodada; a mais alta vence em qualquer ordem de chegada; o texto fica só no DuckDB), `acao` (id = [rodada, tipo, chave, id da
ação], #510: o estado da marca do Bardi, derivado da tabela `action_marks` do DuckDB e não dos logs; a marca mais nova vence em
qualquer ordem). Ligações por record link: `worker.rodada`, `worker.sessao`, `sessao.rodada`, `sessao.worker`,
`conversa.sessao`, `etapa.rodada`, `acao.rodada`, `acao.etapa`.
"""
import base64
import re
from datetime import datetime, timezone

# tabelas e campos são constantes deste módulo; valores vão sempre em variáveis
UPSERT = 'UPSERT type::record("{t}", $v.id) MERGE $v.d;'
TIMES = 'UPDATE type::record("{t}", $v.id) SET {sets};'


# etapa da rodada (#507, ADR-08 "Página da rodada e do ciclo"): o evento `oute.swarm.step.published`
STEP_EVENT = "oute.swarm.step.published"
STEP_KINDS = ("triagem", "merge", "kaizen", "fechamento", "ciclo")
CYCLE_KIND = "ciclo"   # #509: o resumo do ciclo; a "rodada" dele é a pasta `ciclo-<dono>_<repo>-<n>` da sessão avulsa, não uma rodada
STEP_REVIEWS = ("aprovado", "reprovado", "sem-revisor")
STEP_REFCHECKS = ("ok", "falhou", "ausente")
_STEP_TEXT = ("kind", "key", "sha256", "review", "writer", "reviewer", "refcheck", "cycle", "event", "host", "instance")
_SHA = re.compile(r"^[0-9a-f]{64}$")
_STEP_KEY = re.compile(r"^[1-9]\d{0,8}$")
STEP_KEY = _STEP_KEY   # a chave da etapa `merge` (número do PR); `marcar.py` confere o campo `etapa` com ela
_CYCLE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#\d+\Z", re.ASCII)   # `<dono>/<repo>#<n>`, a issue do ciclo
# `IF … THEN { UPSERT … } END`: só grava se o `rev` do evento é maior ou igual ao da revisão que já está lá (a revisão mais
# alta vence, em qualquer ordem de chegada). Texto em base64, decodificado no SurrealDB (#337)
STEP_UPSERT = (
    'IF (array::first(SELECT VALUE rev FROM [type::record("etapa", $v.id)]) ?? 0) <= $v.rev THEN { '
    'UPSERT type::record("etapa", $v.id) SET rev = $v.rev, '
    + ", ".join(f"`{k}` = <string>encoding::base64::decode($v.b.`{k}`)" for k in _STEP_TEXT)
    + ', published_at = <datetime> $v.t, rodada = type::record("rodada", $v.r); } END;')
# #509: o ciclo da rodada é o da revisão vigente da triagem (sem ciclo, o campo sai): só grava depois do STEP_UPSERT, se a
# revisão deste evento é a vigente, para o reenvio e a ordem de chegada não mudarem o resultado
STEP_CYCLE = (
    'IF (array::first(SELECT VALUE rev FROM [type::record("etapa", $v.id)]) ?? 0) = $v.rev THEN { '
    'UPSERT type::record("rodada", $v.r) SET cycle = IF $v.c = "" THEN NONE ELSE <string>encoding::base64::decode($v.c) END; } END;')


# marca de ação (#510, ADR-08 "Página da rodada e do ciclo"): vem da `action_marks`, não dos logs. `IF … THEN { UPSERT … } END`: só grava
# se a marca é mais nova que a gravada (a mais nova vence, em qualquer ordem de chegada e no reenvio do `rebuild-state`)
ACTION_ID_RE = re.compile(r"^[a-z][a-z0-9]{0,15}\Z")
MARK_STATES = ("feita", "pendente")
_MARK_TEXT = ("kind", "key", "aid", "state", "by")
ACAO_UPSERT = (
    'IF (array::first(SELECT VALUE marked_ns FROM [type::record("acao", $v.id)]) ?? 0) <= $v.ns THEN { '
    'UPSERT type::record("acao", $v.id) SET marked_ns = $v.ns, marked_at = <datetime> $v.t, '
    + ", ".join(f"`{k}` = <string>encoding::base64::decode($v.b.`{k}`)" for k in _MARK_TEXT)
    + ', rodada = type::record("rodada", $v.r), etapa = type::record("etapa", $v.e); } END;')


def mark_statements(row):
    """Uma linha da `action_marks` (`marks.COLUMNS`) -> statements do `acao`. Linha fora do formato (tipo, chave, id ou estado
    inválidos) não vira estado: o fato continua no DuckDB."""
    kind, key, aid, st = row["kind"], row["key"] or "", row["action_id"], row["state"]
    if (kind not in STEP_KINDS or st not in MARK_STATES or not isinstance(aid, str) or not ACTION_ID_RE.match(aid)
            or (kind == "merge") != bool(key) or (key and not _STEP_KEY.match(key))):
        return []
    rnd, ns = row["rodada"], int(row["marked_unix_nano"])
    b64 = lambda v: base64.b64encode(str(v).encode()).decode()  # noqa: E731
    fields = {"kind": kind, "key": key, "aid": aid, "state": st, "by": row["marked_by"]}
    return [(ACAO_UPSERT, {"id": [rnd, kind, key, aid], "ns": ns, "t": iso(ns), "r": rnd, "e": [rnd, kind, key],
                           "b": {k: b64(fields[k]) for k in _MARK_TEXT}})]


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


def step_valid(kind, key, rev, review, sha):
    """O evento de etapa está no formato do `oute-swarm step publish`? (tipo e veredito conhecidos, sha256 de 64 hex, revisão
    de 1 a 9999 e a chave, número do PR, só no `merge`). Fora dele o fato fica no DuckDB e não vira estado nem página."""
    return (kind in STEP_KINDS and review in STEP_REVIEWS and isinstance(sha, str) and bool(_SHA.match(sha))
            and isinstance(rev, int) and 1 <= rev <= 9999 and (kind == "merge") == bool(key)
            and (not key or bool(_STEP_KEY.match(key))))


def step_statements(rnd, a, t, ev, origin):
    """`oute.swarm.step.published` -> statements. `a(chave)` lê um atributo do evento; `t` = hora do fato (ns); `ev` =
    `oute.event.id`. Evento fora do formato (tipo, veredito, sha256, chave ou revisão inválidos) não vira estado: o fato
    continua no DuckDB."""
    key = str(a("oute.swarm.step.key") or "")
    kind, review, sha = a("oute.swarm.step.kind"), a("oute.swarm.step.review"), a("oute.swarm.step.sha256")
    try:
        rev = int(a("oute.swarm.step.rev"))
    except (TypeError, ValueError):
        return []
    if not step_valid(kind, key, rev, review, sha):
        return []
    refcheck = a("oute.swarm.step.refcheck")
    fields = {"kind": kind, "key": key, "sha256": sha, "review": review, "writer": a("oute.swarm.step.writer"),
              "reviewer": a("oute.swarm.step.reviewer"), "refcheck": refcheck if refcheck in STEP_REFCHECKS else "ausente",
              "cycle": a("oute.swarm.cycle"), "event": ev, "host": origin.get("host"), "instance": origin.get("instance")}
    b64 = lambda v: base64.b64encode(("" if v is None else str(v)).encode()).decode()  # noqa: E731
    value = {"id": [rnd, kind, key], "rev": rev, "r": rnd, "t": iso(t), "b": {k: b64(fields[k]) for k in _STEP_TEXT}}
    if kind == CYCLE_KIND:
        # o resumo do ciclo sem o ciclo não tem onde aparecer; e a pasta dele não é rodada (não ganha registro `rodada`)
        return [(STEP_UPSERT, value)] if _CYCLE.match(fields["cycle"] or "") else []
    out = upsert("rodada", rnd, origin) + [(STEP_UPSERT, value)]
    if kind == "triagem":
        out.append((STEP_CYCLE, {**value, "c": b64(fields["cycle"] if _CYCLE.match(fields["cycle"] or "") else "")}))
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
                                          "name": a("oute.swarm.round.name"), "opened_event": ev},
                          times={"opened_at": t}, initial="aberta")
        if name == "oute.swarm.round.closed":
            return upsert("rodada", rnd, {**origin, "state": "fechada", "closed_event": ev}, times={"closed_at": t})
        if name == STEP_EVENT:
            return step_statements(rnd, a, t, ev, origin)
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
