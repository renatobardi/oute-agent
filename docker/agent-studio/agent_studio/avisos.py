"""O que pede atenção do Bardi nas rodadas abertas (#776, ADR-08 §10): o bloco `attention` do `GET /v1/tray`. Só leitura, sem
regra nova: lê do DuckDB os eventos que o `oute-swarm watch` e o `ask` já gravam e diz, por rodada que não fechou, o que está
valendo agora.

- `ci`: o último evento de CI do PR (`oute.swarm.watch.ci`) é `fail` e o PR não foi mergeado nem fechado depois dele. CI verde
  depois, ou falha do head já substituído, tira o item.
- `blocked`: o último evento da sessão (`oute.swarm.watch.sessao`) é `blocked`. Qualquer estado seguinte, ou o
  `oute.swarm.session.closed` da sessão, tira o item.
- `question`: a pergunta pendente do dispatcher (`decisions.pending`); some quando o Bardi responde.
- `merged`: o PR foi mergeado (`oute.swarm.watch.pr`); fica enquanto a rodada está aberta.

Cada item traz o `id` por ocorrência (`rodada|tipo|chave|hora`): o tray avisa uma vez por `id`, e o `id` muda quando o fato volta
(nova falha de CI depois de verde). O texto vem do tipo, nunca do corpo do evento; só o número do PR e o rótulo da sessão
(validado) passam. Ação não existe aqui: o item só mostra e leva à página da rodada.
"""
import re
from datetime import datetime
from urllib.parse import quote

from . import alerts as alerts_mod, decisions as decisions_mod, etapas as etapas_mod

WATCH_PR, WATCH_CI, WATCH_SESSION = "oute.swarm.watch.pr", "oute.swarm.watch.ci", "oute.swarm.watch.sessao"
SESSION_CLOSED = "oute.swarm.session.closed"
LIMIT = 50  # itens na resposta (os mais novos); `total` diz quantos há

_PR = re.compile(r"^PR #(\d{1,9}) (aberto|mergeado|fechado sem merge)\b")
_CI = re.compile(r"^PR #(\d{1,9}) · ([^:]{1,100}): fail$")
_CI_OK = re.compile(r"^PR #(\d{1,9}) · ")
_SESSION = re.compile(r"^#(\d{1,9}) ([a-z0-9][a-z0-9-]{0,80}): (idle|done|blocked|working|sem agente)\b")

TITLES = {"ci": "CI reprovado no PR #%s", "blocked": "Sessão #%s parada (blocked)", "question": "Pergunta pendente do dispatcher",
          "merged": "PR #%s mergeado"}
_ORDER = {"question": 0, "blocked": 1, "ci": 2, "merged": 3}


def _item(rnd, kind, key, t, at_ns, name):
    title = TITLES[kind] % key if "%s" in TITLES[kind] else TITLES[kind]
    return {"id": f"{rnd}|{kind}|{key}|{t}", "round": rnd, "name": name, "kind": kind, "key": key or None, "title": title,
            "at": alerts_mod.iso(t), "age_seconds": max(0, (at_ns - t) // 1_000_000_000),
            "url": f"/rodada?id={quote(rnd, safe='')}"}


def _round_items(events, rnd, at_ns, name):
    """Os itens de uma rodada, dos eventos dela em ordem de hora. O último fato de cada PR e de cada sessão decide."""
    pr, ci, sess = {}, {}, {}  # n -> (estado, t); n -> (fail?, t); rótulo -> (estado, t)
    for e in events:
        body, t = e["body"] or "", e["t"]
        if e["event_name"] == WATCH_PR and (m := _PR.match(body)):
            pr[m.group(1)] = (m.group(2), t)
        elif e["event_name"] == WATCH_CI:
            if m := _CI.match(body):
                ci[m.group(1)] = (True, t)
            elif m := _CI_OK.match(body):
                ci[m.group(1)] = (False, t)
        elif e["event_name"] == WATCH_SESSION and (m := _SESSION.match(body)):
            sess[f"{m.group(1)}-{m.group(2)}"] = (m.group(3), t)
        elif e["event_name"] == SESSION_CLOSED and e["slug"]:
            sess[e["slug"]] = ("fechada", t)
    out = []
    for n, (state, t) in pr.items():
        if state == "mergeado":
            out.append(_item(rnd, "merged", n, t, at_ns, name))
    for n, (failed, t) in ci.items():
        done = pr.get(n)
        if failed and not (done and done[0] != "aberto" and done[1] >= t):
            out.append(_item(rnd, "ci", n, t, at_ns, name))
    for slug, (state, t) in sess.items():
        if state == "blocked":
            out.append(_item(rnd, "blocked", slug.split("-", 1)[0], t, at_ns, name))
    return out


def pending(con, at_ns, cfg, limit=LIMIT):
    """{"total": n, "rows": [...]}: o que pede atenção na hora `at_ns` (ns, hora do fato); os `limit` mais prioritários e
    mais novos. Levanta se a leitura falha (quem chama cai em `NONE`)."""
    lo = max(0, at_ns - 2 * int(cfg.lookback_hours * 60 * alerts_mod.MIN_NS))
    events = alerts_mod._rows(con, """
        SELECT oute_swarm_round AS round, event_name, body, time_unix_nano AS t,
               json_extract_string(attributes, '$."oute.swarm.session"') AS slug
        FROM logs
        WHERE event_name IN (?, ?, ?, ?, ?) AND oute_swarm_round IS NOT NULL AND time_unix_nano <= ? AND time_unix_nano >= ?
          AND oute_swarm_round NOT IN (SELECT oute_swarm_round FROM logs
                                        WHERE event_name = ? AND oute_swarm_round IS NOT NULL AND time_unix_nano <= ?)
        ORDER BY t, event_name""", [WATCH_PR, WATCH_CI, WATCH_SESSION, SESSION_CLOSED, SESSION_CLOSED, at_ns, lo,
                                    decisions_mod.CLOSED, at_ns])
    by_round = {}
    for e in events:
        by_round.setdefault(e["round"], []).append(e)
    rows = []
    for rnd, evs in by_round.items():
        rows.extend(_round_items(evs, rnd, at_ns, etapas_mod.round_name(con, rnd)))
    for d in decisions_mod.pending(con, at_ns, cfg, limit=10_000)["pending"]:
        t = _iso_ns(d["asked_at"])
        rows.append(_item(d["round"], "question", "", t, at_ns, d.get("name")))
    rows.sort(key=lambda r: (r["age_seconds"], _ORDER[r["kind"]], r["round"], r["key"] or ""))
    return {"total": len(rows), "rows": rows[:limit]}


def _iso_ns(text):
    return int(datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()) * 1_000_000_000


NONE = {"total": 0, "rows": []}
