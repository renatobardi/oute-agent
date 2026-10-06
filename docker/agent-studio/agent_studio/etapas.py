"""Página da rodada (#507, ADR-08 "Página da rodada e do ciclo"): as etapas que o dispatcher publica para o Bardi.

**Etapa** = o texto que o dispatcher escreve num ponto de parada da rodada (`triagem`, `merge` por PR, `kaizen`,
`fechamento`), conferido por um revisor de outro modelo (`oute-swarm step review`) e publicado como o evento operacional
`oute.swarm.step.published`, com o texto no corpo (até 32 KiB). Um papel por banco, como nas sessões e nos pedidos:

- SurrealDB = o estado (D4=1): `etapa:[<rodada>, <tipo>, <chave>]` com a revisão vigente (a mais alta vence, em qualquer
  ordem de chegada: o `UPSERT` só troca os campos quando o `rev` do evento é maior ou igual ao gravado), o sha256, o
  veredito (`aprovado`, `reprovado`, `sem-revisor`), os modelos e o `oute.event.id` da revisão. Link `rodada`.
- DuckDB = o fato: o evento, com o texto no corpo, lido pelo `oute.event.id`. O texto nunca é copiado para o SurrealDB.
- SurrealDB fora ou sem registro: a página sai com o que o DuckDB tem (a revisão mais alta de cada etapa) e um aviso.

O texto é **dado não confiável** (D6=1 e ADR-08): o Markdown é restrito (`## Decisão`, `## Ações`, `## Detalhe`, parágrafos,
listas, `**negrito**`, `código`, links `https://` e blocos de código), o parser devolve só dados (nunca HTML) e o template
escapa tudo. Etapa `reprovado` ou `sem-revisor` sai com um aviso fixo do agent-studio e o texto fechado.

Fatia 3 (#509): o ciclo. O evento da triagem leva `oute.swarm.cycle`, que entra no registro `rodada` (`cycle`), e a página
`GET /ciclo?id=<dono>/<repo>#<n>` lista as rodadas do ciclo e leva a cada uma. O resumo do ciclo é a etapa `ciclo`, publicada
por uma sessão avulsa (`oute-swarm step publish ciclo --cycle …`, sem rodada): a mesma trava do revisor, o mesmo evento, e
ela aparece no topo da página do ciclo (a revisão mais alta vence). `ciclo` não é posição da barra de uma rodada.

Fatia 2 (#508): cada etapa sabe a posição na rodada e a anterior e a seguinte (`navigate`, na página), a barra lista cada
pedido de merge (`bar`) e o `GET /v1/tray` ganha o bloco `steps` (`tray_steps`): as etapas das rodadas não fechadas, só
do SurrealDB, com o título fixo por tipo (`title`) e nunca o texto.

Histórico (#601): a lista `GET /rodadas` sai dos eventos `oute.swarm.*` do DuckDB, e não só das etapas: entra toda rodada
com `oute.swarm.round.opened` (e a rodada com etapa publicada cujo evento de abertura não chegou). A abertura, o fechamento,
o repositório e o número de sessões vêm desses eventos; o SurrealDB só dá o ciclo e completa a rodada sem evento de abertura.
Sem período escolhido, a lista traz todas as rodadas (`ALL_TIME`, #618); o filtro de período restringe quando escolhido.
"""
import re
from urllib.parse import quote, urlsplit

from .conversations import _dicts
from .proposals import age_seconds
from .tabela import Col, Table
from .state import CYCLE_KIND, STEP_EVENT as EVENT, STEP_KINDS as KINDS, iso, step_valid

TITLES = {"triagem": "Triagem", "merge": "Pedido de merge", "kaizen": "Retrospectiva (kaizen)",
          "fechamento": "Fechamento da rodada", "ciclo": "Resumo do ciclo"}
BAR_LABELS = {"triagem": "Triagem", "merge": "Pedidos de merge", "kaizen": "Kaizen", "fechamento": "Fechamento"}
ROUND_KINDS = tuple(k for k in KINDS if k != CYCLE_KIND)   # as posições da barra: o resumo do ciclo não é etapa de rodada
ROUND_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\Z", re.ASCII)   # o id de uma rodada (`swarm-1004-1944`), como a pasta dela
CYCLE_ID = re.compile(r"^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}#\d{1,9}\Z", re.ASCII)   # `<dono>/<repo>#<n>`
SECTIONS = ("Decisão", "Ações", "Detalhe")
TEXT_MAX = 32768   # o mesmo teto do `oute-swarm step publish` e do `oute-emit`
LIST_LIMIT = 100   # rodadas na lista (a tela, que pagina, pede `tabela.ALL`)
ALL_TIME = (0, 2**63 - 1)   # a janela de `/rodadas` sem período escolhido (#618): todas as rodadas, sem limite de data
SWARM_PREFIX = "oute.swarm."
OPENED, CLOSED, SPAWNED = "oute.swarm.round.opened", "oute.swarm.round.closed", "oute.swarm.session.spawned"
TRAY_LIMIT = 50    # etapas no bloco `steps` do tray (as mais novas); `total` diz quantas há

# a tabela da tela das rodadas (#529, #601): a aberta mais recente primeiro; estado e veredito filtram. A ordem de `opened` é a
# hora da abertura ou, sem o evento de abertura, a do primeiro evento da rodada
TABLE = Table([Col("rodada", "text", lambda x: x["round"]), Col("repo", "text", lambda x: x["repo"]),
               Col("opened", "time", lambda x: x["start_ns"]),
               Col("state", "text", lambda x: x["status"], lambda x: [x["status"]]), Col("sessions", "num", lambda x: x["sessions"]),
               Col("prs", "num", lambda x: x["prs"]), Col("steps", "num", lambda x: x["steps"]),
               Col("cycle", "text", lambda x: x["cycle"]), Col("kind", "text", lambda x: x["kind"]),
               Col("review", "text", lambda x: x["review"], lambda x: [x["review"]])],
              default=("opened", "desc"))

# ---------------------------------------------------------------- leitura
# antes do primeiro evento a tabela não existe, e ler tabela que não existe é erro no SurrealDB: sem ela, lista vazia
_IF_TABLE = "IF (INFO FOR DB).tables.etapa THEN ({}) ELSE [] END;"
_FIELDS = "kind, key, rev, sha256, review, writer, reviewer, refcheck, cycle, event, host, instance, published_at"
_STEPS = _IF_TABLE.format(f'SELECT {_FIELDS} FROM etapa WHERE rodada = type::record("rodada", $id)')
_ROUND = 'SELECT repo, label, state, cycle, agent, host, instance, opened_at, closed_at FROM [type::record("rodada", $id)];'
_ROUNDS = ("IF (INFO FOR DB).tables.rodada THEN (SELECT record::id(id) AS id, repo, label, state, cycle, opened_at FROM rodada "
           "WHERE record::id(id) IN $ids) ELSE [] END;")

# etapas das rodadas que ainda não fecharam (rodada sem registro de estado conta como aberta: o Bardi ainda não leu a etapa)
_OPEN = '(rodada.state ?? "aberta") != "fechada"'
_TRAY_ROWS = _IF_TABLE.format(f'SELECT record::id(rodada) AS round, kind, key, rev, review, cycle, published_at FROM etapa WHERE {_OPEN} '
                              "ORDER BY published_at DESC, id LIMIT $limit")
# o resumo do ciclo (`ciclo`) fica fora do total: a pasta do ciclo não tem registro `rodada`, então ele contaria como aberto para sempre (#575)
_TRAY_TOTAL = _IF_TABLE.format(f'SELECT count() AS n FROM etapa WHERE {_OPEN} AND kind != "{CYCLE_KIND}" GROUP ALL')

# o ciclo (#509): as rodadas com `rodada.cycle` e o resumo (a etapa `ciclo`) do ciclo; sem a tabela, listas vazias
_CYCLE_ROUNDS = ("IF (INFO FOR DB).tables.rodada THEN (SELECT record::id(id) AS id, repo, label, state, opened_at, closed_at FROM rodada "
                 "WHERE cycle = $c ORDER BY opened_at, id) ELSE [] END;")
_CYCLE_SUMMARY = _IF_TABLE.format(f'SELECT {_FIELDS} FROM etapa WHERE kind = "ciclo" AND cycle = $c ORDER BY rev DESC LIMIT 1')

_ATTR = "json_extract_string(attributes, '$.\"%s\"')"
_STEP_COLS = (f"oute_event_id AS event, time_unix_nano, host_name AS host, oute_instance AS instance, "
              f"{_ATTR % 'oute.swarm.step.kind'} AS kind, coalesce({_ATTR % 'oute.swarm.step.key'}, '') AS key, "
              f"TRY_CAST({_ATTR % 'oute.swarm.step.rev'} AS INTEGER) AS rev, {_ATTR % 'oute.swarm.step.sha256'} AS sha256, "
              f"{_ATTR % 'oute.swarm.step.review'} AS review, {_ATTR % 'oute.swarm.step.writer'} AS writer, "
              f"{_ATTR % 'oute.swarm.step.reviewer'} AS reviewer, {_ATTR % 'oute.swarm.step.refcheck'} AS refcheck, "
              f"{_ATTR % 'oute.swarm.cycle'} AS cycle")
_EVENTS = f"SELECT {_STEP_COLS} FROM logs WHERE event_name = ? AND oute_swarm_round = ? ORDER BY time_unix_nano, dedupe_key"
_KIND = _ATTR % 'oute.swarm.step.kind'
_NOT_CYCLE = f"coalesce({_KIND}, '') <> 'ciclo'"   # a pasta do resumo do ciclo (#509) não é rodada
_LIST_COLS = f"""
    SELECT oute_swarm_round AS round, count(*) AS revisions,
           count(DISTINCT {_KIND} || ':' || coalesce({_ATTR % 'oute.swarm.step.key'}, '')) AS steps,
           min(time_unix_nano) AS first_ns, max(time_unix_nano) AS last_ns,
           arg_max({_ATTR % 'oute.swarm.step.review'}, time_unix_nano) AS review,
           arg_max({_KIND}, time_unix_nano) AS kind
    FROM logs WHERE event_name = ? AND oute_swarm_round IS NOT NULL AND {_NOT_CYCLE}"""
# o histórico (#601): uma linha por rodada, de todos os eventos `oute.swarm.*` dela. Entra a rodada com evento de abertura
# ou com etapa publicada, que tem evento entre o início e o fim da janela (ou antes e depois dela: estava em andamento)
_STEP = f"event_name = '{EVENT}' AND {_NOT_CYCLE}"
_HISTORY = f"""
    SELECT oute_swarm_round AS round,
           min(time_unix_nano) FILTER (WHERE event_name = '{OPENED}') AS opened_ns,
           max(time_unix_nano) FILTER (WHERE event_name = '{CLOSED}') AS closed_ns,
           arg_min({_ATTR % 'oute.swarm.repo'}, time_unix_nano) FILTER (WHERE event_name = '{OPENED}') AS repo,
           arg_min({_ATTR % 'oute.swarm.label'}, time_unix_nano) FILTER (WHERE event_name = '{OPENED}') AS label,
           count(DISTINCT {_ATTR % 'oute.swarm.session'}) FILTER (WHERE event_name = '{SPAWNED}') AS sessions,
           count(*) FILTER (WHERE {_STEP}) AS revisions,
           count(DISTINCT {_KIND} || ':' || coalesce({_ATTR % 'oute.swarm.step.key'}, '')) FILTER (WHERE {_STEP}) AS steps,
           count(DISTINCT {_ATTR % 'oute.swarm.step.key'}) FILTER (WHERE {_STEP} AND {_KIND} = 'merge') AS prs,
           arg_max({_ATTR % 'oute.swarm.step.review'}, time_unix_nano) FILTER (WHERE {_STEP}) AS review,
           arg_max({_KIND}, time_unix_nano) FILTER (WHERE {_STEP}) AS kind,
           min(time_unix_nano) AS first_ns, max(time_unix_nano) AS last_ns
    FROM logs WHERE starts_with(event_name, ?) AND oute_swarm_round IS NOT NULL
    GROUP BY oute_swarm_round
    HAVING (opened_ns IS NOT NULL OR revisions > 0) AND first_ns < ? AND last_ns >= ?
    ORDER BY coalesce(opened_ns, first_ns) DESC, round LIMIT ?"""
_CYCLE_STATS = _LIST_COLS + " AND list_contains(?::VARCHAR[], oute_swarm_round) GROUP BY oute_swarm_round ORDER BY first_ns, round"
# as rodadas do ciclo só pelo DuckDB (o SurrealDB fora ou sem o registro): a revisão vigente da triagem leva o ciclo
_CYCLE_IDS = (f"SELECT oute_swarm_round FROM logs WHERE event_name = ? AND oute_swarm_round IS NOT NULL AND {_KIND} = 'triagem' "
              f"GROUP BY oute_swarm_round HAVING arg_max(coalesce({_ATTR % 'oute.swarm.cycle'}, ''), "
              f"[coalesce(TRY_CAST({_ATTR % 'oute.swarm.step.rev'} AS BIGINT), 0), time_unix_nano]) = ? ORDER BY oute_swarm_round")
_CYCLE_EVENTS = (f"SELECT {_STEP_COLS} FROM logs WHERE event_name = ? AND {_KIND} = 'ciclo' AND {_ATTR % 'oute.swarm.cycle'} = ? "
                 "ORDER BY time_unix_nano, dedupe_key")


def events(con, rnd):
    """Os eventos de etapa da rodada no DuckDB (todas as revisões), sem o texto, pela hora do fato."""
    return _dicts(con.execute(_EVENTS, [EVENT, rnd]))


def texts(con, event_ids):
    """{oute.event.id: texto} do corpo dos eventos (o texto só mora no DuckDB)."""
    ids = sorted({e for e in event_ids if e})
    if not ids:
        return {}
    rows = con.execute("SELECT oute_event_id, body FROM logs WHERE event_name = ? AND list_contains(?::VARCHAR[], "
                       "oute_event_id) ORDER BY time_unix_nano, dedupe_key", [EVENT, ids]).fetchall()
    out = {}
    for ev, body in rows:
        out.setdefault(ev, body)
    return out


def listing(con, from_ns, to_ns, limit=LIST_LIMIT):
    """O histórico das rodadas (#601) na janela [from_ns, to_ns), da aberta mais recente para a mais antiga: a abertura e o
    fechamento (`None` = sem o evento), o repositório, quantas sessões, etapas, revisões e pedidos de merge, e o veredito e
    o tipo da última etapa. Rodada sem etapa publicada entra, com zeros."""
    return _dicts(con.execute(_HISTORY, [SWARM_PREFIX, to_ns, from_ns, limit]))


def with_state(rows, states):
    """Põe em cada linha do `listing` o que a tela mostra: `status` (`fechada` com o evento de fechamento, `aberta` com o de
    abertura), `start_ns` (a ordem), `prs` (`None` sem etapa: só o pedido de merge publicado leva o PR) e, do registro do
    SurrealDB (`states`, ou `None` se ele não foi lido), o ciclo e o que falta à rodada sem evento de abertura."""
    for r in rows:
        rec = (states or {}).get(r["round"]) or {}
        r["repo"], r["label"] = r["repo"] or rec.get("repo"), r["label"] or rec.get("label")
        r["status"] = "fechada" if r["closed_ns"] else "aberta" if r["opened_ns"] else rec.get("state")
        r["start_ns"] = r["opened_ns"] or r["first_ns"]
        r["prs"] = r["prs"] if r["steps"] else None
        r["cycle"] = rec.get("cycle") if cycle_url(rec.get("cycle")) else None
        r["cycle_url"] = cycle_url(rec.get("cycle"))
    return rows


def _int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def sort_key(step):
    return (KINDS.index(step["kind"]) if step["kind"] in KINDS else len(KINDS), _int(step.get("key")) or 0)


def current(rows):
    """A revisão vigente de cada etapa (tipo, chave) entre os eventos do DuckDB: a mais alta, e a mais recente entre
    iguais. É o que o SurrealDB guarda, para o caso de ele estar fora."""
    best = {}
    for r in rows:
        if not step_valid(r["kind"], r["key"] or "", r["rev"], r["review"], r["sha256"]):
            continue
        k = (r["kind"], r["key"] or "")
        if k not in best or (r["rev"], r["time_unix_nano"]) >= (best[k]["rev"], best[k]["time_unix_nano"]):
            best[k] = r
    return sorted(best.values(), key=sort_key)


def _step_from_record(rec):
    return {"kind": rec.get("kind"), "key": rec.get("key") or "", "rev": rec.get("rev"), "sha256": rec.get("sha256"),
            "review": rec.get("review"), "writer": rec.get("writer") or None, "reviewer": rec.get("reviewer") or None,
            "refcheck": rec.get("refcheck") or "ausente", "cycle": rec.get("cycle") or None,
            "event": rec.get("event"), "published_at": rec.get("published_at"), "host": rec.get("host")}


def _step_from_event(r):
    return {"kind": r["kind"], "key": r["key"] or "", "rev": r["rev"], "sha256": r["sha256"], "review": r["review"],
            "writer": r["writer"], "reviewer": r["reviewer"], "refcheck": r["refcheck"] or "ausente", "cycle": r["cycle"],
            "event": r["event"], "published_at": iso(r["time_unix_nano"]), "host": r["host"]}


def surreal_steps(surreal, rnd):
    """(registro da rodada ou None, etapas vigentes do SurrealDB). Erro do SurrealDB levanta (SurrealError)."""
    found = surreal.query(_STEPS + " " + _ROUND, {"id": rnd})
    recs = [_step_from_record(r) for r in (found[0]["result"] or []) if r.get("kind") in KINDS]
    rounds = [r for r in (found[1]["result"] or []) if any(v is not None for v in r.values())]
    return (rounds[0] if rounds else None), sorted(recs, key=sort_key)


def round_states(surreal, ids):
    """{rodada: registro} do SurrealDB para a lista. Erro do SurrealDB levanta (SurrealError)."""
    if not ids:
        return {}
    found = surreal.query(_ROUNDS, {"ids": list(ids)})
    return {r["id"]: r for r in (found[0]["result"] or [])}


def load(store, surreal, rnd):
    """Tudo o que a página e o `GET /v1/rodada` mostram. -> `None` se nenhum dos dois bancos conhece a rodada; senão
    {id, record, steps, state_read, state_error}. `state_read`: `True` = etapas do SurrealDB; `False` = o SurrealDB falhou ou
    não tinha registro de etapa e a página saiu do DuckDB (`state_error` = tipo do erro, para o log, ou `None`); `None` =
    este processo não tem SurrealDB. Falha do DuckDB levanta."""
    rows = store.read(lambda con: events(con, rnd))
    record, recs, state_read, error = None, [], None, None
    if surreal is not None:
        try:
            record, recs = surreal_steps(surreal, rnd)
            state_read = True
        except Exception as e:  # noqa: BLE001
            # o estado só dá a revisão vigente: sem ele, a página sai do DuckDB
            state_read, error = False, type(e).__name__
    if recs:
        steps = [_step_from_record(r) for r in recs]
    else:
        steps = [_step_from_event(r) for r in current(rows)]
        if surreal is not None and state_read and steps:
            state_read = False  # o DuckDB tem etapa que o SurrealDB não tem (estado a remontar: `rebuild-state`)
    if not steps and record is None:
        return None
    body = store.read(lambda con: texts(con, [s["event"] for s in steps]))
    for s in steps:
        text = body.get(s["event"])
        s["text"] = text if isinstance(text, str) and len(text.encode()) <= TEXT_MAX else None
    return {"id": rnd, "record": record, "steps": sorted(steps, key=sort_key), "state_read": state_read,
            "state_error": error, "cycle_url": cycle_url((record or {}).get("cycle"))}


def cycle_url(cycle):
    """O destino da página do ciclo, ou `None` se o texto não é um ciclo (`<dono>/<repo>#<n>`): o link só nasce do formato."""
    return f"/ciclo?id={quote(cycle, safe='')}" if isinstance(cycle, str) and CYCLE_ID.match(cycle) else None


def _cycle_from_state(surreal, cycle):
    """(registros das rodadas, registros do resumo, `state_read`, tipo do erro) do SurrealDB. Falha do SurrealDB não levanta:
    o estado só liga rodada e ciclo, e sem ele a página sai do DuckDB (`state_read` falso)."""
    if surreal is None:
        return [], [], None, None
    try:
        found = surreal.query(_CYCLE_ROUNDS + " " + _CYCLE_SUMMARY, {"c": cycle})
        return found[0]["result"] or [], found[1]["result"] or [], True, None
    except Exception as e:  # noqa: BLE001
        return [], [], False, type(e).__name__


def _cycle_round_rows(store, recs):
    """As rodadas do ciclo, uma linha por registro, com as contagens e as horas das etapas no DuckDB (rodada sem etapa fica com
    zeros), na ordem em que abriram."""
    ids = [r["id"] for r in recs]
    stats = {}
    if ids:
        stats = {r["round"]: r for r in store.read(lambda con: _dicts(con.execute(_CYCLE_STATS, [EVENT, sorted(ids)])))}
    rounds = []
    for r in recs:
        st = stats.get(r["id"], {})
        rounds.append({"round": r["id"], "repo": r.get("repo"), "label": r.get("label"), "state": r.get("state"),
                       "steps": st.get("steps", 0), "revisions": st.get("revisions", 0), "kind": st.get("kind"),
                       "review": st.get("review"), "first_ns": st.get("first_ns"), "last_ns": st.get("last_ns")})
    return sorted(rounds, key=lambda r: (r["first_ns"] is None, r["first_ns"] or 0, r["round"]))


def _cycle_summary(store, sums, events_):
    """A revisão vigente do resumo do ciclo, com o texto lido no DuckDB, ou `None` se ninguém o publicou."""
    if sums:
        summary = _step_from_record(sums[0])
    elif events_:
        summary = _step_from_event(events_[-1])
    else:
        return None
    body = store.read(lambda con: texts(con, [summary["event"]]))
    text = body.get(summary["event"])
    summary["text"] = text if isinstance(text, str) and len(text.encode()) <= TEXT_MAX else None
    return summary


def load_cycle(store, surreal, cycle):
    """Tudo o que `GET /ciclo?id=` mostra: as rodadas do ciclo e o resumo dele. `cycle` já passou por `CYCLE_ID`. -> `None` se
    nenhum dos dois bancos conhece o ciclo; senão {id, rounds, summary, state_read, state_error}. `rounds` na ordem em que
    abriram; `summary` = a revisão vigente da etapa `ciclo` (com `text`) ou `None`. `state_read`: como em `load`. Falha do DuckDB
    levanta."""
    recs, sums, state_read, error = _cycle_from_state(surreal, cycle)
    events_ = []
    if not recs or not sums:
        # o que o SurrealDB não tem sai do DuckDB: a triagem vigente de cada rodada e as revisões do resumo
        duck_ids = [] if recs else [r[0] for r in store.read(lambda con: con.execute(_CYCLE_IDS, [EVENT, cycle]).fetchall())]
        if not sums:
            events_ = current(store.read(lambda con: _dicts(con.execute(_CYCLE_EVENTS, [EVENT, cycle]))))
        recs = recs or [{"id": i} for i in duck_ids]
        if state_read and (duck_ids or events_):
            state_read = False   # o DuckDB tem o que o SurrealDB não tem (estado a remontar: `rebuild-state`)
    rounds = _cycle_round_rows(store, recs)
    summary = _cycle_summary(store, sums, events_)
    if summary is None and not rounds:
        return None
    return {"id": cycle, "rounds": rounds, "summary": summary, "state_read": state_read, "state_error": error}


# ---------------------------------------------------------------- a página: barra de etapas, títulos e Markdown restrito
def anchor(step):
    return "etapa-" + step["kind"] + (f"-{step['key']}" if step["key"] else "")


def title(step):
    return TITLES[step["kind"]] + (f" #{step['key']}" if step["key"] else "")


def bar(steps):
    """A barra fixa de etapas, desenhada pelo agent-studio (nenhum diagrama vem do modelo): uma posição por tipo, na ordem
    da rodada. `done` = há etapa publicada; `review` = o pior veredito entre as do tipo; `current` = a última posição com etapa;
    `items` = uma entrada por etapa do tipo (o `merge` leva um link por PR)."""
    out = []
    for kind in ROUND_KINDS:
        mine = [s for s in steps if s["kind"] == kind]
        worst = next((r for r in ("reprovado", "sem-revisor", "aprovado") if any(s["review"] == r for s in mine)), None)
        out.append({"kind": kind, "label": BAR_LABELS[kind], "count": len(mine), "done": bool(mine), "review": worst,
                    "anchor": anchor(mine[0]) if mine else None, "current": False,
                    "items": [{"anchor": anchor(s), "label": f"#{s['key']}" if s["key"] else BAR_LABELS[kind]} for s in mine]})
    last = max((i for i, b in enumerate(out) if b["done"]), default=None)
    if last is not None:
        out[last]["current"] = True
    return out


_INLINE = re.compile(r"`[^`\n]{1,500}`|\*\*[^*\n]{1,500}\*\*|\[[^\]\n]{1,500}\]\(https://[^\s()<>\"'`]{1,1000}\)")
_LINK = re.compile(r"^\[([^\]]*)\]\((https://.*)\)$")
_ITEM = re.compile(r"^(?:[-*]|\d{1,3}[.)]) (.*)$")
_ORDERED = re.compile(r"^\d{1,3}[.)] ")
# controles e as marcas de direção e separadores Unicode (U+200B-200F, U+2028-202E, U+2060-2069, U+FEFF): não aparecem na
# tela, mas trocam a ordem do texto ou quebram a linha de quem lê
# exceção: o ZWJ (U+200D) entre pictogramas (emoji composto, ex.: família) fica; ZWJ solto, no começo ou no fim, sai
_PIC = "\U0001F300-\U0001FAFF\u2600-\u27bf"
_ZWJ_SOLTO = re.compile(f"(?<![{_PIC}\ufe0f])\u200d|\u200d(?![{_PIC}])")
_CTRL = re.compile("[\x00-\x08\x0b-\x1f\x7f\u200b\u200c\u200e\u200f\u2028-\u202e\u2060-\u2069\ufeff]")


def _limpa(text):
    """Tira os controles e as marcas de direção; o ZWJ só fica entre pictogramas."""
    return _CTRL.sub("", _ZWJ_SOLTO.sub("", text))


def _host(url):
    """Host do destino do link; vazio se a URL não tem host que o `urlsplit` aceite (ex.: `https://[abc` lança ValueError)."""
    try:
        return urlsplit(url).hostname or ""
    except ValueError:
        return ""


def inline(text):
    """Texto de uma linha -> peças `{"t": "text"|"code"|"b"|"a", "s": …, "href": …}`. Nada é HTML: o template escapa. Link só
    `https://`, sem espaço nem aspas; o resto do que parece Markdown fica como texto."""
    out, pos = [], 0
    for m in _INLINE.finditer(text):
        if m.start() > pos:
            out.append({"t": "text", "s": text[pos:m.start()]})
        tok = m.group(0)
        if tok.startswith("`"):
            out.append({"t": "code", "s": tok[1:-1]})
        elif tok.startswith("**"):
            out.append({"t": "b", "s": tok[2:-2]})
        else:
            link = _LINK.match(tok)
            out.append({"t": "a", "s": link.group(1), "href": link.group(2), "host": _host(link.group(2))})
        pos = m.end()
    if pos < len(text):
        out.append({"t": "text", "s": text[pos:]})
    return out


class _Parser:
    """Estado do `parse`: seções, parágrafo e lista em andamento e a cerca de código aberta."""

    def __init__(self):
        self.sections, self.cur, self.para, self.items, self.ordered, self.fence = [], None, [], [], False, None

    def section(self, name):
        self.cur = {"title": name, "blocks": []}
        self.sections.append(self.cur)

    def blocks(self):
        if self.cur is None:
            self.section(None)
        return self.cur["blocks"]

    def flush(self):
        if self.para:
            self.blocks().append({"t": "p", "inl": inline(" ".join(self.para))})
        if self.items:
            self.blocks().append({"t": "ol" if self.ordered else "ul", "items": [inline(i) for i in self.items]})
        self.para, self.items = [], []

    def in_fence(self, line):
        if line.strip().startswith("```"):
            self.blocks().append({"t": "pre", "s": "\n".join(self.fence)})
            self.fence = None
        else:
            self.fence.append(line)

    def item(self, s):
        if self.para or (self.items and self.ordered != bool(_ORDERED.match(s))):
            self.flush()
        self.ordered = bool(_ORDERED.match(s))
        self.items.append(_ITEM.match(s).group(1).strip())

    def line(self, line):
        if self.fence is not None:
            return self.in_fence(line)
        s = line.strip()
        if s.startswith("```"):
            self.flush()
            self.fence = []
        elif s.startswith("## ") and s[3:].strip() in SECTIONS:
            self.flush()
            self.section(s[3:].strip())
        elif s.startswith("### ") and s[4:].strip():
            self.flush()
            self.blocks().append({"t": "h", "inl": inline(s[4:].strip())})
        elif not s:
            self.flush()
        elif _ITEM.match(s) and not line.startswith("    "):
            self.item(s)
        elif self.items and line.startswith(" "):
            self.items[-1] += " " + s
        else:
            if self.items:
                self.flush()
            self.para.append(s)
        return None

    def finish(self):
        if self.fence is not None:
            self.blocks().append({"t": "pre", "s": "\n".join(self.fence)})
        self.flush()
        found = {sec["title"] for sec in self.sections}
        return {"sections": self.sections, "missing": [name for name in SECTIONS if name not in found]}


def parse(text):
    """Texto da etapa -> `{"sections": [{"title": …|None, "blocks": […]}], "missing": [seções que faltam]}`.

    Gramática (a da `design` da fatia 1): `## Decisão`, `## Ações` e `## Detalhe` abrem seção (outro `## …` é texto);
    `### …` é subtítulo; parágrafo; lista com `- ` ou `1. ` (linha seguinte indentada continua o item); bloco entre cercas
    ``` ; `**negrito**`, `` `código` `` e `[texto](https://…)` dentro da linha (o link mostra o host do destino ao lado do texto, para o texto não esconder o destino). HTML, tabela e imagem não existem: viram texto."""
    p = _Parser()
    for line in _limpa(text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ")).split("\n"):
        p.line(line)
    return p.finish()


def _near(steps, j):
    """A etapa `j` como destino de link (âncora e título fixo), ou `None` fora da lista."""
    return {"anchor": steps[j]["anchor"], "title": steps[j]["title"]} if 0 <= j < len(steps) else None


def navigate(steps):
    """Põe em cada etapa (já em ordem de rodada) a posição (`pos` de `total`) e a anterior e a seguinte (`prev`, `next`:
    `{"anchor", "title"}` ou `None` nas pontas). Só âncoras e títulos fixos por tipo: nada vem do texto."""
    for i, s in enumerate(steps):
        s["pos"], s["total"], s["prev"], s["next"] = i + 1, len(steps), _near(steps, i - 1), _near(steps, i + 1)
    return steps


def render(steps):
    """Põe em cada etapa o texto lido (`doc`) e o que a página mostra de fixo: título, âncora, sha256 curto e a navegação."""
    for s in steps:
        s["title"], s["anchor"] = title(s), anchor(s)
        s["sha_short"] = (s["sha256"] or "")[:12]
        s["cycle_url"] = cycle_url(s.get("cycle"))
        s["doc"] = parse(s["text"]) if s["text"] is not None else None
    return navigate(steps)


def actions_api(step):
    """As ações da etapa (#510) para o JSON; `[]` se `acoes.collect` não rodou."""
    from . import acoes   # `acoes` importa este módulo: o import fica aqui para não fechar o laço
    return acoes.api(step) if "acoes" in step else []


def api(data):
    """`GET /v1/rodada`: a rodada em JSON. O texto só vai nas etapas `aprovado` (D6: o texto reprovado ou sem revisor fica
    fechado também aqui); `url` leva à página."""
    steps = [{"kind": s["kind"], "key": s["key"] or None, "rev": s["rev"], "review": s["review"], "sha256": s["sha256"],
              "writer": s["writer"], "reviewer": s["reviewer"], "refcheck": s["refcheck"], "cycle": s["cycle"],
              "published_at": s["published_at"], "url": f"/rodada?id={quote(data['id'], safe='')}#{anchor(s)}",
              "text": s["text"] if s["review"] == "aprovado" else None, "text_withheld": s["review"] != "aprovado",
              "actions": actions_api(s)}
             for s in data["steps"]]
    rec = data["record"] or {}
    return {"round": data["id"], "state": rec.get("state"), "repo": rec.get("repo"), "label": rec.get("label"),
            "cycle": rec.get("cycle") if cycle_url(rec.get("cycle")) else None, "state_read": data["state_read"],
            "actions_read": data.get("acoes_read"), "steps": steps}


def tray_steps(surreal, at_ns, limit=TRAY_LIMIT):
    """O bloco `steps` do `GET /v1/tray`: as `limit` etapas mais novas das rodadas que não fecharam e quantas há ao todo. Só
    o SurrealDB (a revisão vigente de cada etapa); título fixo por tipo, `review` e `url` da página, nunca o texto. Erro do
    SurrealDB levanta (SurrealError)."""
    found = surreal.query(_TRAY_ROWS + " " + _TRAY_TOTAL, {"limit": limit})
    rows = []
    for r in found[0]["result"] or []:
        if not step_valid(r.get("kind"), r.get("key") or "", r.get("rev"), r.get("review"), "0" * 64):
            continue
        step = {"kind": r["kind"], "key": r.get("key") or ""}
        # o resumo do ciclo abre a página do ciclo (sem ciclo válido, a etapa não entra); as outras, a página da rodada
        url = cycle_url(r.get("cycle")) if step["kind"] == CYCLE_KIND else f"/rodada?id={quote(r['round'], safe='')}#{anchor(step)}"
        if url is None:
            continue
        age = age_seconds(r.get("published_at"), at_ns)
        rows.append({"round": r["round"], "kind": step["kind"], "key": step["key"] or None, "rev": r["rev"],
                     "review": r["review"], "title": title(step), "published_at": (r.get("published_at") or "")[:19] + "Z",
                     "age_seconds": age, "url": url})
    total = (found[1]["result"] or [{}])[0].get("n", 0)
    return {"available": True, "total": total, "rows": rows}
