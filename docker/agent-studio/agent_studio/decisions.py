"""Decisão pendente do Bardi (#386): rodada do swarm que parou esperando uma resposta dele. O dispatcher grava a
pergunta (`oute-swarm ask`, evento `oute.swarm.round.asked`, com o texto no corpo) e a resposta (`oute-swarm answered`,
`oute.swarm.round.answered`). Pendente = rodada aberta (sem `round.closed`) cuja última pergunta é igual ou mais nova que a última
resposta (no mesmo instante vale a pergunta: o dispatcher responde e pergunta de novo no mesmo segundo). Calculado dos eventos pela hora do fato, por host e rodada; só leitura.

Aparece no `GET /v1/tray` (`decisions`, junto dos pedidos do canal) e no topo das telas. Não é alerta: a pergunta pendente
já conta como evento da rodada, então o `round_stalled` (#364) só dispara depois de `round_stalled_minutes` sem nada.
"""
from . import alerts as alerts_mod, etapas as etapas_mod

ASKED, ANSWERED = "oute.swarm.round.asked", "oute.swarm.round.answered"
CLOSED = "oute.swarm.round.closed"
LIMIT = 50  # decisões na resposta (as mais novas); `total` diz quantas há


def pending(con, at_ns, cfg, limit=LIMIT):
    """{"total": n, "pending": [...]}: as `limit` decisões pendentes mais novas na hora `at_ns` (ns, hora do fato).
    Pergunta mais velha que o dobro de `lookback_hours` fica de fora (a rodada esquecida aparece como `round_old`)."""
    lo = at_ns - 2 * int(cfg.lookback_hours * 60 * alerts_mod.MIN_NS)
    rows = alerts_mod._rows(con, """
        SELECT host_name AS host, oute_instance AS instance, oute_swarm_round AS round,
               max(time_unix_nano) FILTER (WHERE event_name = ?) AS asked_t,
               arg_max(body, time_unix_nano) FILTER (WHERE event_name = ?) AS question,
               max(time_unix_nano) FILTER (WHERE event_name = ?) AS answered_t,
               max(time_unix_nano) FILTER (WHERE event_name = ?) AS closed_t
        FROM logs
        WHERE event_name IN (?, ?, ?) AND oute_swarm_round IS NOT NULL AND time_unix_nano <= ?
        GROUP BY host_name, oute_instance, oute_swarm_round
        HAVING asked_t >= ? AND asked_t >= coalesce(answered_t, 0) AND closed_t IS NULL
        ORDER BY asked_t DESC, round""", [ASKED, ASKED, ANSWERED, CLOSED, ASKED, ANSWERED, CLOSED, at_ns, lo])
    out = [{"round": r["round"], "host": r["host"], "instance": r["instance"], "question": r["question"],
            "asked_at": alerts_mod.iso(r["asked_t"]), "age_seconds": max(0, (at_ns - r["asked_t"]) // 1_000_000_000)}
           for r in rows]
    # nome amigável da rodada (#605), do evento de abertura; rodada antiga ou sem o evento: `None`
    for d in out[:limit]:
        d["name"] = etapas_mod.round_name(con, d["round"])
    return {"total": len(out), "pending": out[:limit]}
