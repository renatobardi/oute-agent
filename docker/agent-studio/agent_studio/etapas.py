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
"""
import re
from urllib.parse import quote, urlsplit

from .conversations import _dicts
from .state import STEP_EVENT as EVENT, STEP_KINDS as KINDS, iso, step_valid

TITLES = {"triagem": "Triagem", "merge": "Pedido de merge", "kaizen": "Retrospectiva (kaizen)",
          "fechamento": "Fechamento da rodada"}
BAR_LABELS = {"triagem": "Triagem", "merge": "Pedidos de merge", "kaizen": "Kaizen", "fechamento": "Fechamento"}
SECTIONS = ("Decisão", "Ações", "Detalhe")
TEXT_MAX = 32768   # o mesmo teto do `oute-swarm step publish` e do `oute-emit`
LIST_LIMIT = 100   # rodadas na lista

# ---------------------------------------------------------------- leitura
# antes do primeiro evento a tabela não existe, e ler tabela que não existe é erro no SurrealDB: sem ela, lista vazia
_IF_TABLE = "IF (INFO FOR DB).tables.etapa THEN ({}) ELSE [] END;"
_FIELDS = "kind, key, rev, sha256, review, writer, reviewer, refcheck, cycle, event, host, instance, published_at"
_STEPS = _IF_TABLE.format(f'SELECT {_FIELDS} FROM etapa WHERE rodada = type::record("rodada", $id)')
_ROUND = 'SELECT repo, label, state, agent, host, instance, opened_at, closed_at FROM [type::record("rodada", $id)];'
_ROUNDS = ("IF (INFO FOR DB).tables.rodada THEN (SELECT record::id(id) AS id, repo, label, state, opened_at FROM rodada "
           "WHERE record::id(id) IN $ids) ELSE [] END;")

_ATTR = "json_extract_string(attributes, '$.\"%s\"')"
_STEP_COLS = (f"oute_event_id AS event, time_unix_nano, host_name AS host, oute_instance AS instance, "
              f"{_ATTR % 'oute.swarm.step.kind'} AS kind, coalesce({_ATTR % 'oute.swarm.step.key'}, '') AS key, "
              f"TRY_CAST({_ATTR % 'oute.swarm.step.rev'} AS INTEGER) AS rev, {_ATTR % 'oute.swarm.step.sha256'} AS sha256, "
              f"{_ATTR % 'oute.swarm.step.review'} AS review, {_ATTR % 'oute.swarm.step.writer'} AS writer, "
              f"{_ATTR % 'oute.swarm.step.reviewer'} AS reviewer, {_ATTR % 'oute.swarm.step.refcheck'} AS refcheck, "
              f"{_ATTR % 'oute.swarm.cycle'} AS cycle")
_EVENTS = f"SELECT {_STEP_COLS} FROM logs WHERE event_name = ? AND oute_swarm_round = ? ORDER BY time_unix_nano, dedupe_key"
_LIST = f"""
    SELECT oute_swarm_round AS round, count(*) AS revisions,
           count(DISTINCT {_ATTR % 'oute.swarm.step.kind'} || ':' || coalesce({_ATTR % 'oute.swarm.step.key'}, '')) AS steps,
           max(time_unix_nano) AS last_ns,
           arg_max({_ATTR % 'oute.swarm.step.review'}, time_unix_nano) AS review,
           arg_max({_ATTR % 'oute.swarm.step.kind'}, time_unix_nano) AS kind
    FROM logs WHERE event_name = ? AND oute_swarm_round IS NOT NULL
    GROUP BY oute_swarm_round ORDER BY last_ns DESC, round LIMIT ?"""


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


def listing(con, limit=LIST_LIMIT):
    """Rodadas com etapa publicada, da mais recente para a mais antiga: quantas etapas e revisões, e o veredito e o tipo
    da última."""
    return _dicts(con.execute(_LIST, [EVENT, limit]))


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
            "state_error": error}


# ---------------------------------------------------------------- a página: barra de etapas, títulos e Markdown restrito
def anchor(step):
    return "etapa-" + step["kind"] + (f"-{step['key']}" if step["key"] else "")


def title(step):
    return TITLES[step["kind"]] + (f" #{step['key']}" if step["key"] else "")


def bar(steps):
    """A barra fixa de etapas, desenhada pelo agent-studio (nenhum diagrama vem do modelo): uma posição por tipo, na ordem
    da rodada. `done` = há etapa publicada; `review` = o pior veredito entre as do tipo; `current` = a última posição com etapa."""
    out = []
    for kind in KINDS:
        mine = [s for s in steps if s["kind"] == kind]
        worst = next((r for r in ("reprovado", "sem-revisor", "aprovado") if any(s["review"] == r for s in mine)), None)
        out.append({"kind": kind, "label": BAR_LABELS[kind], "count": len(mine), "done": bool(mine), "review": worst,
                    "anchor": anchor(mine[0]) if mine else None, "current": False})
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
_CTRL = re.compile("[\x00-\x08\x0b-\x1f\x7f\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]")


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
            out.append({"t": "a", "s": link.group(1), "href": link.group(2), "host": urlsplit(link.group(2)).hostname or ""})
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
    for line in _CTRL.sub("", text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ")).split("\n"):
        p.line(line)
    return p.finish()


def render(steps):
    """Põe em cada etapa o texto lido (`doc`) e o que a página mostra de fixo: título, âncora e sha256 curto."""
    for s in steps:
        s["title"], s["anchor"] = title(s), anchor(s)
        s["sha_short"] = (s["sha256"] or "")[:12]
        s["doc"] = parse(s["text"]) if s["text"] is not None else None
    return steps


def api(data):
    """`GET /v1/rodada`: a rodada em JSON. O texto só vai nas etapas `aprovado` (D6: o texto reprovado ou sem revisor fica
    fechado também aqui); `url` leva à página."""
    steps = [{"kind": s["kind"], "key": s["key"] or None, "rev": s["rev"], "review": s["review"], "sha256": s["sha256"],
              "writer": s["writer"], "reviewer": s["reviewer"], "refcheck": s["refcheck"], "cycle": s["cycle"],
              "published_at": s["published_at"], "url": f"/rodada?id={quote(data['id'], safe='')}#{anchor(s)}",
              "text": s["text"] if s["review"] == "aprovado" else None, "text_withheld": s["review"] != "aprovado"}
             for s in data["steps"]]
    rec = data["record"] or {}
    return {"round": data["id"], "state": rec.get("state"), "repo": rec.get("repo"), "label": rec.get("label"),
            "state_read": data["state_read"], "steps": steps}
