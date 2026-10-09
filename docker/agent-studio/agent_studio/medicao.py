"""Medição por sessão (#751, ADR-08 adendo "Medição por sessão"): as sessões e as conversas mais caras da janela, com o
contexto de cada chamada.

- **Mais caras:** as `TOP` sessões (`oute.task.id`) e as `TOP` conversas (`session.id`) de maior custo na janela. Chamadas, tokens
  e custo vêm do `usage.aggregate` (nenhuma regra de custo mora aqui); o custo de ordem é o real + o de lista calculado + o estimado.
  O que não tem sessão (ou conversa) não é uma sessão (ou conversa): fica fora da lista, e o total da tela o inclui.
- **Contexto por chamada** = `input_tokens` + `cache_read_tokens` da chamada ao modelo (o que o modelo leu); `avg` e `max` por
  sessão e por conversa, das mesmas chamadas que o `aggregate` conta (`cost.MODEL_CALL_SQL`), com o mesmo filtro de repositório e de
  assinatura. Chamada sem os dois campos conta 0; o `max` é o maior contexto de uma chamada, não a soma.
"""
from . import rateio, subscription as sub_mod, usage as usage_mod
from .cost import MODEL_CALL_PARAMS, MODEL_CALL_SQL

TOP = 20
_COL = {"session": "oute_task_id", "conversation": "session_id"}


def _cost_of(a):
    return (a["real_usd"] or 0) + (a["listed_usd"] or 0) + (a["estimated_usd"] or 0)


def _context(con, kind, ids, from_ns, to_ns, repo, sub):
    """{id: {"avg", "max"}} do contexto por chamada (entrada + cache lido) dos `ids` (chave `kind`) na janela."""
    if not ids:
        return {}
    col = _COL[kind]
    rsql, rparams = sub_mod.scope(repo, sub)
    marks = ", ".join("?" * len(ids))
    ctx = "COALESCE(input_tokens, 0) + COALESCE(cache_read_tokens, 0)"
    cur = con.execute(f"SELECT {col}, avg({ctx}), max({ctx}) FROM spans WHERE {usage_mod._WINDOW} AND {MODEL_CALL_SQL}{rsql} "
                      f"AND {col} IN ({marks}) GROUP BY {col}", [from_ns, to_ns, *MODEL_CALL_PARAMS, *rparams, *ids])
    return {k: {"avg": round(avg, 1), "max": int(mx)} for k, avg, mx in cur.fetchall()}


def top(con, kind, from_ns, to_ns, prices, tz, repo=None, paid=False, sub=None, alloc=None, limit=TOP):
    """As `limit` sessões (`kind="session"`) ou conversas (`"conversation"`) mais caras da janela, na ordem do custo (empate pelo id),
    cada uma no formato do `usage.render` com a chave `kind` e o `context` (`avg`, `max`)."""
    groups = usage_mod.aggregate(con, from_ns, to_ns, prices, (kind,), tz, p95=False, repo=repo, paid=paid, sub=sub, alloc=alloc)
    ranked = sorted(((k[0], a) for k, a in groups.items() if k[0] not in (None, rateio.NO_USE)), key=lambda x: (-_cost_of(x[1]), x[0]))[:limit]
    ctx = _context(con, kind, [k for k, _ in ranked], from_ns, to_ns, repo, sub)
    return [{**usage_mod.render((k,), a, (kind,)), "context": ctx.get(k, {"avg": 0.0, "max": 0})} for k, a in ranked]
