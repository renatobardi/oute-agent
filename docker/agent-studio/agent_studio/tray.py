"""Endpoint do tray (ADR-08 §10, #205): tudo o que o menu do tray no Mac (#158) mostra, numa chamada só, lida a cada
15 s. Só leitura e sem regra própria: cada bloco sai da peça que já decide aquilo.

- **Máquinas** (`machines`): os hosts do `alerts.hosts`, pela hora de **chegada** do registro mais recente (qualquer
  sinal): `active` ou `stopped` pela regra de host parado do #204 (`alerts.stopped`, `no_data_minutes`).
- **Pedidos pendentes** (`proposals`): o estado do SurrealDB (`proposals.pending`, as consultas da lista do #208),
  com a idade e o caminho da página "ver script" (`proposals.page_path`).
- **Custo de hoje** (`cost_today`): `usage.aggregate` (#203) no dia UTC de agora, total e por agente; `estimated`
  marca o valor que tem parte estimada pela tabela de preços.
- **Erros na última hora** (`errors_last_hour`): os erros do mesmo `usage.aggregate`, por host × agente.
- **Alertas** (`alerts`): os do `alerts.evaluate` (#204), como no `GET /v1/alerts`, mais `title` e `text` prontos
  (`alert_text`, o mesmo texto da tela; #344).
- **Decisões pendentes** (`decisions`, #386): rodada do swarm parada esperando uma resposta do Bardi
  (`decisions.pending`), com a pergunta e a idade; do DuckDB, junto dos pedidos.
- **Barra** (`bar`): nº de pedidos pendentes e nº de alertas (as decisões pendentes têm o `decisions.total`).

`snapshot` lê o DuckDB (uma passada, sob a trava do `store`); `pending` lê o SurrealDB; `response` junta os dois.
SurrealDB fora não derruba a resposta: `proposals.available` = `false` e `bar.pending` = `null` (nunca zero por
palpite).
"""
from . import alert_text, alerts as alerts_mod, decisions as decisions_mod, proposals as prop_mod, usage as usage_mod

HOUR_NS = 3_600_000_000_000
PENDING_LIMIT = 50  # pedidos pendentes na resposta (os mais novos); `proposals.total` diz quantos há


def _cost(group):
    """Grupo do `usage.render` -> custo do tray. `usd` = real + estimado (`None` = nada com custo); `estimated` =
    parte dele é estimada; chamada sem custo real e sem preço fica fora da soma (`unpriced_calls`), nunca zero."""
    c = group["cost"]
    real, est = c["real_usd"], c["estimated_usd"]
    return {"usd": None if real is None and est is None else (real or 0) + (est or 0),
            "real_usd": real, "estimated_usd": est, "estimated": c["estimated_calls"] > 0,
            "unpriced_calls": c["unpriced_calls"]}


def _name(v):
    return (v is None, v or "")


def snapshot(con, at_ns, prices, cfg):
    """Os blocos que saem do DuckDB na hora `at_ns` (ns): máquinas, custo de hoje, erros na última hora e alertas."""
    received = alerts_mod.last_data(con, alerts_mod.lookback(at_ns, cfg), at_ns, by=alerts_mod.RECEIVED)
    machines = [{**h, "state": "stopped" if alerts_mod.stopped(received.get(h["host"], (None,))[0], at_ns, cfg)
                 else "active"} for h in alerts_mod.hosts(received, at_ns, cfg)]

    day = at_ns // usage_mod.DAY_NS * usage_mod.DAY_NS
    today = day, day + usage_mod.DAY_NS
    total = usage_mod.aggregate(con, *today, prices, ())
    by_agent = usage_mod.aggregate(con, *today, prices, ("agent",))
    agents = [{"agent": agent, "calls": a["calls"], **_cost(usage_mod.render((), a, ()))}
              for (agent,), a in sorted(by_agent.items(), key=lambda kv: _name(kv[0][0])) if a["calls"]]

    hour = at_ns - HOUR_NS, at_ns + 1  # [from, to): o fato da própria hora entra
    errors = []
    for (host, agent), a in usage_mod.aggregate(con, *hour, prices, ("host", "agent")).items():
        e = usage_mod.render((), a, ())["errors"]
        if e["total"]:
            errors.append({"host": host, "agent": agent, **e})
    errors.sort(key=lambda e: (_name(e["host"]), _name(e["agent"])))

    return {
        "machines": machines,
        "cost_today": {"day": alerts_mod.iso(day)[:10], "from": alerts_mod.iso(today[0]),
                       "to": alerts_mod.iso(today[1]), **_cost(usage_mod.render((), total[()], ())), "agents": agents},
        "errors_last_hour": {"from": alerts_mod.iso(hour[0]), "to": alerts_mod.iso(at_ns),
                             "total": sum(e["total"] for e in errors), "rows": errors},
        "alerts": alert_text.with_text(alerts_mod.evaluate(con, at_ns, cfg)["alerts"]),
        "decisions": decisions_mod.pending(con, at_ns, cfg),
    }


def pending(surreal, at_ns, limit=PENDING_LIMIT):
    """Pedidos pendentes do SurrealDB para o menu: os `limit` mais novos e o total. Levanta se a leitura falha."""
    found = prop_mod.pending(surreal, limit)
    rows = []
    for p in found["pending"]:
        age = prop_mod.age_seconds(p.get("proposed_at"), at_ns)
        rows.append({"id": p["id"], "title": p.get("title"), "as": p.get("as"), "agent": p.get("agent"),
                     "host": p.get("host"), "instance": p.get("instance"),
                     "proposed_at": None if age is None else p["proposed_at"][:19] + "Z",
                     "age_seconds": age, "url": prop_mod.page_path(p["id"])})
    return {"available": True, "total": found["pending_total"], "pending": rows}


NO_DECISIONS = {"total": 0, "pending": []}
UNAVAILABLE = {"available": False, "total": None, "pending": []}


def response(at_ns, snap, proposals, config_errors):
    """A resposta do `GET /v1/tray`. `proposals` = o `pending(…)` ou `None` (sem SurrealDB ou leitura que falhou)."""
    proposals = proposals or UNAVAILABLE
    return {"at": alerts_mod.iso(at_ns),
            "bar": {"pending": proposals["total"], "alerts": len(snap["alerts"])},
            "machines": snap["machines"], "proposals": proposals, "decisions": snap.get("decisions") or NO_DECISIONS, "cost_today": snap["cost_today"],
            "errors_last_hour": snap["errors_last_hour"], "alerts": snap["alerts"],
            "config": {"errors": config_errors}}
