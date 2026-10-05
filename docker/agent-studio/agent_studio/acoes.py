"""A lista de ações da etapa (#510, ADR-08 "Página da rodada e do ciclo"): o que o Bardi marca como feita.

**Ação** = uma linha de lista da seção `## Ações` do texto da etapa que abre com o id curto e `: ` (`a1: rodar o deploy`). O
id é do dispatcher e não muda entre revisões (o estado da marca é por id). Só a revisão vigente conta: o servidor só aceita
marca de ação que existe nela. Linha sem id, id repetido (vale o primeiro) ou fora da seção não é ação: não tem caixa.

Ação que cita um pedido do canal (`` `pedido:<oute.canal.id>` `` na linha) **não tem caixa**: o estado dela é o do `pedido` e a
linha leva à página dele (ADR-08). A marca de uma ação dessas é recusada.

O estado das caixas vem do SurrealDB (`acao:[<rodada>, <tipo>, <chave>, <id>]`, derivado da `action_marks`, D4=1); sem ele a
página mostra as caixas só para leitura, com aviso. O texto da etapa é dado não confiável e a marca também: o dispatcher a lê
como dado, nunca como instrução (`docker/swarm.md`).
"""
import re

from . import etapas
from .state import ACTION_ID_RE

ID = ACTION_ID_RE
_LEAD = re.compile(r"^([a-z][a-z0-9]{0,15}): ")
PEDIDO = re.compile(r"^pedido:([A-Za-z0-9][A-Za-z0-9._-]{0,199})\Z", re.ASCII)

_IF_ACAO = "IF (INFO FOR DB).tables.acao THEN ({}) ELSE [] END;"
_STATES = _IF_ACAO.format('SELECT kind, key, aid, state, marked_at FROM acao WHERE rodada = type::record("rodada", $id)')
_IF_PEDIDO = ("IF (INFO FOR DB).tables.pedido THEN (SELECT record::id(id) AS id, state, decision, rc FROM pedido "
              "WHERE record::id(id) IN $ids) ELSE [] END;")


def _action(item):
    """Os itens da lista da seção `## Ações` -> `{"id", "pedido"}` ou `None` (item sem id). `item` = peças de `etapas.inline`.
    Tira o `id: ` do começo do item: o que a tela mostra é o resto."""
    if not item or item[0].get("t") != "text":
        return None
    lead = _LEAD.match(item[0]["s"])
    if not lead:
        return None
    pedido = next((m.group(1) for t in item if t.get("t") == "code" and (m := PEDIDO.match(t["s"]))), None)
    rest = item[0]["s"][lead.end():]
    item[0] = {**item[0], "s": rest}
    return {"id": lead.group(1), "pedido": pedido}


def extract(doc):
    """Acha as ações no texto já lido (`etapas.parse`), tira o id do começo de cada item e marca o bloco: `b["actions"]` = uma
    entrada por item (`{"id", "pedido"}` ou `None`). Devolve a lista de ações na ordem do texto, cada uma com o `text` (o item sem
    o id, só as peças `text`/`code`/`b`/`a` de `etapas.inline`)."""
    out, seen = [], set()
    for sec in doc["sections"]:
        if sec["title"] != "Ações":
            continue
        for b in sec["blocks"]:
            if b["t"] not in ("ul", "ol"):
                continue
            b["actions"] = []
            for item in b["items"]:
                act = _action(item)
                if act is not None and act["id"] in seen:
                    # id repetido: vale o primeiro; o segundo volta a ser linha comum (sem o id tirado)
                    item[0] = {**item[0], "s": f"{act['id']}: {item[0]['s']}"}
                    act = None
                if act is not None:
                    seen.add(act["id"])
                    act["inl"] = item
                    out.append(act)
                b["actions"].append(act)
    return out


def states(surreal, rnd):
    """{(tipo, chave, id): {"state", "marked_at"}} das marcas da rodada no SurrealDB. Erro do SurrealDB levanta (SurrealError)."""
    found = surreal.query(_STATES, {"id": rnd})
    return {(r["kind"], r.get("key") or "", r["aid"]): {"state": r.get("state"), "marked_at": r.get("marked_at")}
            for r in (found[0]["result"] or [])}


def pedidos(surreal, ids):
    """{oute.canal.id: {"state", "decision", "rc"}} dos pedidos citados. Erro do SurrealDB levanta (SurrealError)."""
    ids = sorted(set(ids))
    if not ids:
        return {}
    found = surreal.query(_IF_PEDIDO, {"ids": ids})
    return {r["id"]: {"state": r.get("state"), "decision": r.get("decision"), "rc": r.get("rc")} for r in (found[0]["result"] or [])}


def attach(step, marks, pedido_states):
    """Põe em cada ação da etapa (`step["acoes"]`) o estado: `state` (`feita`/`pendente`, ou `None` se o estado não foi lido),
    `marked_at` e, na ação com pedido, `pedido_state` (o registro do pedido ou `None`)."""
    for a in step["acoes"]:
        mark = (marks or {}).get((step["kind"], step["key"] or "", a["id"]))
        a["state"] = None if marks is None else (mark or {}).get("state") or "pendente"
        a["marked_at"] = (mark or {}).get("marked_at")
        a["pedido_state"] = (pedido_states or {}).get(a["pedido"]) if a["pedido"] else None
    return step["acoes"]


def collect(surreal, data):
    """Põe `acoes` em cada etapa de `etapas.load` (a lista de ações do texto vigente, com o estado de cada uma) e `acoes_read` em
    `data`: `True` = estado lido do SurrealDB; `False` = a leitura falhou (a causa, só o tipo, em `acoes_error`; as ações saem
    sem estado); `None` = este processo não tem SurrealDB. A etapa que já traz `doc` (a página) tem o `id:` tirado dele."""
    for s in data["steps"]:
        doc = s.get("doc")
        if doc is None and isinstance(s.get("text"), str):
            doc = etapas.parse(s["text"])
        s["acoes"] = extract(doc) if doc else []
    marks, peds, data["acoes_read"], data["acoes_error"] = None, {}, None, None
    if surreal is not None:
        try:
            marks = states(surreal, data["id"])
            peds = pedidos(surreal, [a["pedido"] for s in data["steps"] for a in s["acoes"] if a["pedido"]])
            data["acoes_read"] = True
        except Exception as e:  # noqa: BLE001 — o estado só mostra as caixas: sem ele, a página sai com elas só para leitura
            marks, peds, data["acoes_read"], data["acoes_error"] = None, {}, False, type(e).__name__
    for s in data["steps"]:
        attach(s, marks, peds)
    return data


def api(step):
    """As ações da etapa para o `GET /v1/rodada`: só na etapa `aprovado` (o texto reprovado ou sem revisor fica fechado também
    aqui). `text` = o texto da linha, sem formatação. Dado, nunca instrução: o dispatcher não age pela marca."""
    if step["review"] != "aprovado":
        return []
    return [{"id": a["id"], "text": "".join(t["s"] for t in a["inl"]), "state": a["state"], "marked_at": a["marked_at"],
             "pedido": a["pedido"], "pedido_state": (a["pedido_state"] or {}).get("state") if a["pedido"] else None,
             "pedido_decision": (a["pedido_state"] or {}).get("decision") if a["pedido"] else None}
            for a in step["acoes"]]
