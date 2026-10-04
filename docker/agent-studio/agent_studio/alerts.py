"""Alertas do pipeline (ADR-08 §8, #204): calculados do DuckDB na hora da consulta, sem estado guardado. Um alerta
liga quando o dado mostra o problema e desliga sozinho quando o dado seguinte não mostra mais.

- **Fila > 50%** (`queue`): último `otelcol_exporter_queue_size` ÷ `otelcol_exporter_queue_capacity` de cada exporter
  do collector (#162), por host.
- **Destino recusando** (`destination_refusing`): `otelcol_exporter_send_failed_*` de um exporter subiu nos últimos
  `refused_window_minutes` (contador acumulado; reinício do collector zera e conta como subida desde o zero).
- **Host sem dado** (`host_no_data`): só os hosts de `always_on_hosts`, depois de `no_data_minutes` sem nenhum
  registro (log, span ou métrica). Os outros hosts (Mac) nunca alertam: aparecem só em `hosts` com o último dado.
- **Spool perto de 50 MB** (`spool`): `oute.emit.spool.bytes` do último evento do `oute-emit` acima de
  `spool_max_bytes`, **ou** `oute.emit.spool.dropped` subiu entre dois eventos nos últimos
  `spool_dropped_window_minutes` (#166).
- **Cota** (`quota`, #347, ligado no `config.toml`): último ponto de `quota_metric` ≥ `quota_max_pct`, por host, agente
  e janela (`oute.quota.window`, 5h e 7d). O snapshot sai na abertura e no fechamento de sessão, sem coleta periódica;
  então o ponto vale só até o reset da janela: `quota_reset_metric` (`oute.quota.reset_in_seconds`, mesma hora do
  ponto) dá a hora do reset, e ponto cujo reset já passou **não alerta** (ponto velho). Sem esse par, não alerta.
  Exceção: a janela de **5h** com reset em menos de `quota_reset_grace_minutes` (20), abaixo de 100% e com a 7d do
  mesmo agente abaixo do corte, não alerta; a 7d nunca tem exceção.
- **Rodada parada** (`round_stalled`, #364): rodada do swarm aberta (`oute.swarm.round.opened`, sem `round.closed`) sem
  nenhum evento `oute.swarm.*` há mais de `round_stalled_minutes`, por host e rodada: com sessão aberta
  (`session.spawned` sem `session.closed`; `evidence.kind = "sessions"`) ou sem nenhuma (triagem sem resposta;
  `kind = "triage"`). Passadas `lookback_hours` sem evento a rodada deixa de ser "parada" e vira, por mais
  `lookback_hours`, `round_old` ("rodada antiga sem fechamento"); depois some. Falha deste cálculo não derruba os outros.
  A pergunta ao Bardi (`oute.swarm.round.asked`, #386) também é evento `oute.swarm.*`: rodada com a pergunta de menos de
  `round_stalled_minutes` não conta como parada. A decisão pendente em si não é alerta (`decisions.py`).

**Host parado** = sem nenhum registro há mais de `no_data_minutes`. Host parado não liga fila, recusa, spool nem cota
(o último valor dele é velho): o Mac fechado não alerta; o host sempre ligado parado alerta só "host sem dado".

**Nunca** a linha `Exporting failed. Dropping data` do log do collector (#137): nenhuma consulta daqui lê o corpo
de log. Tudo pela hora do fato; "desde quando" volta no máximo `lookback_hours`.

`evaluate(con, at_ns, cfg)` é a peça reusável (tray #205, tela #208); `AlertConfig.parse` lê a seção `[alerts]`.
O tray reusa também `last_data`, `stopped` e `hosts` para as máquinas (pela hora de chegada).
"""
import json
import logging
from dataclasses import dataclass, fields
from datetime import datetime, timezone

MIN_NS = 60 * 1_000_000_000

QUEUE, REFUSING, NO_DATA, SPOOL, QUOTA = "queue", "destination_refusing", "host_no_data", "spool", "quota"
ROUND_STALLED, ROUND_OLD = "round_stalled", "round_old"
TYPES = (QUEUE, REFUSING, NO_DATA, SPOOL, QUOTA, ROUND_STALLED, ROUND_OLD)
# alertas de preço (#339): critérios e texto em `price_alerts.py`; aqui só os tipos, na ordem de exibição
PRICE_TYPES = ("price_changed", "price_sources_diverge", "price_source_down", "price_model_unpriced",
               "price_fixed_differs")
ALL_TYPES = TYPES + PRICE_TYPES
# só estes recolhem por tempo na faixa da tela (#524); os outros ficam abertos enquanto durarem
BAND_AGING_TYPES = (ROUND_STALLED, ROUND_OLD) + PRICE_TYPES

# métricas do próprio collector (#162), nomes da versão fixada no compose
QUEUE_SIZE = "otelcol_exporter_queue_size"
QUEUE_CAPACITY = "otelcol_exporter_queue_capacity"
SEND_FAILED = ("otelcol_exporter_send_failed_spans", "otelcol_exporter_send_failed_metric_points",
               "otelcol_exporter_send_failed_log_records")
# atributos que o `oute-emit` põe em todo evento (ADR-04, adendo #124)
SPOOL_BYTES = "oute.emit.spool.bytes"
SPOOL_DROPPED = "oute.emit.spool.dropped"
DELTA = 1  # AGGREGATION_TEMPORALITY_DELTA do OTLP


@dataclass(frozen=True)
class AlertConfig:
    """Limites e hosts sempre ligados (`[alerts]` do `config/agent-studio/config.toml`). Os padrões são os do
    arquivo do repo: sem a seção (ou com um valor inválido), os alertas seguem ligados com eles."""
    always_on_hosts: tuple = ("oute-server",)
    no_data_minutes: float = 30
    queue_max_ratio: float = 0.5
    refused_window_minutes: float = 15
    spool_max_bytes: int = 40 * 2**20
    spool_dropped_window_minutes: float = 60
    lookback_hours: float = 24
    quota_enabled: bool = True
    quota_max_pct: float = 98
    quota_metric: str = "oute.quota.used_pct"
    quota_reset_metric: str = "oute.quota.reset_in_seconds"
    quota_reset_grace_minutes: float = 20
    round_stalled_minutes: float = 30
    band_recent_hours: float = 2

    @classmethod
    def parse(cls, raw):
        """dict do TOML -> (AlertConfig, [erros]). Chave desconhecida ou valor inválido entra em erros e fica o
        padrão daquela chave; o resto vale."""
        if not isinstance(raw, dict):
            return cls(), ["[alerts] não é tabela"]
        known = {f.name: f for f in fields(cls)}
        values, errors = {}, []
        for k, v in raw.items():
            if k not in known:
                errors.append(f"[alerts] chave desconhecida: {k}")
                continue
            try:
                values[k] = _check(k, v, known[k].default)
            except ValueError as e:
                errors.append(f"[alerts] {k} inválido: {e}")
        return cls(**values), errors


def _check(key, v, default):
    if isinstance(default, bool):
        if not isinstance(v, bool):
            raise ValueError("use true ou false")
        return v
    if isinstance(default, tuple):
        if not isinstance(v, list) or not all(isinstance(h, str) and h for h in v):
            raise ValueError("lista de nomes de host")
        return tuple(v)
    if isinstance(default, str):
        if not isinstance(v, str) or not v:
            raise ValueError("texto não vazio")
        return v
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0:
        raise ValueError("número maior que zero")
    if key == "queue_max_ratio" and v >= 1:
        raise ValueError("fração entre 0 e 1 (0.5 = 50%)")
    return type(default)(v) if isinstance(default, float) else v


# ---------------------------------------------------------------- leitura (só colunas e constantes deste módulo)
def _rows(con, sql, params):
    cur = con.execute(sql, params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _series(rows, key):
    out = {}
    for r in rows:
        out.setdefault(tuple(r[k] for k in key), []).append(r)
    return out


def _run_start(points, bad):
    """Início da sequência final de pontos em que `bad(p)` vale (os pontos em ordem de hora)."""
    since = None
    for p in reversed(points):
        if not bad(p):
            break
        since = p["t"]
    return since


def _chain_start(rises, window_ns):
    """Hora da primeira subida da sequência final, com intervalos de até `window_ns` entre subidas."""
    since = rises[-1]
    for t in reversed(rises[:-1]):
        if since - t > window_ns:
            break
        since = t
    return since


def iso(ns):
    if ns is None:
        return None
    dt = datetime.fromtimestamp(ns // 1_000_000_000, timezone.utc)
    return dt.isoformat().replace("+00:00", "Z")


def _alert(kind, host, instance, value, unit, limit, since, evidence):
    return {"type": kind, "host": host, "instance": instance, "value": value, "unit": unit, "limit": limit,
            "since": iso(since), "evidence": evidence}


# pontos de uma métrica do collector por host, instância e exporter (chaves sem nulo: o ASOF JOIN só casa `=`)
_GAUGE = """SELECT COALESCE(host_name, '') AS host, COALESCE(oute_instance, '') AS instance,
                   COALESCE(json_extract_string(attributes, '$.exporter'), '') AS exporter,
                   time_unix_nano AS t, value
            FROM metrics WHERE metric_name = ? AND time_unix_nano BETWEEN ? AND ?"""


def _queue(con, lo, at, cfg):
    # o collector grava tamanho e capacidade da mesma coleta com ns diferentes (a capacidade uns µs antes): cada
    # tamanho casa com a última capacidade até a hora dele (ASOF JOIN), nunca por hora exata
    rows = _rows(con, f"""
        SELECT NULLIF(s.host, '') AS host, NULLIF(s.instance, '') AS instance, NULLIF(s.exporter, '') AS exporter,
               s.t, s.value AS size, c.value AS capacity
        FROM ({_GAUGE}) s ASOF LEFT JOIN ({_GAUGE}) c
          ON c.host = s.host AND c.instance = s.instance AND c.exporter = s.exporter AND s.t >= c.t
        ORDER BY host, instance, exporter, t""", [QUEUE_SIZE, lo, at, QUEUE_CAPACITY, lo, at])
    out = []
    for (host, instance, exporter), pts in _series(rows, ("host", "instance", "exporter")).items():
        pts = [dict(p, ratio=p["size"] / p["capacity"]) for p in pts if p["capacity"] and p["size"] is not None]
        if not pts:
            continue
        last = pts[-1]
        if last["ratio"] > cfg.queue_max_ratio:
            out.append(_alert(QUEUE, host, instance, round(last["ratio"], 4), "ratio", cfg.queue_max_ratio,
                              _run_start(pts, lambda p: p["ratio"] > cfg.queue_max_ratio), {
                                  "exporter": exporter, "metrics": [QUEUE_SIZE, QUEUE_CAPACITY],
                                  "size": last["size"], "capacity": last["capacity"], "at": iso(last["t"])}))
    return out


def _rises(pts):
    """Subidas de um contador em ordem de hora: [(t, quanto subiu)]. Cumulativo: diferença entre pontos seguidos;
    valor menor ou `start` diferente = reinício, sobe o valor inteiro. O primeiro ponto só conta se o contador
    começou dentro da janela lida (`start` >= o primeiro ponto possível); senão não há base para comparar."""
    out, prev = [], None
    for p in pts:
        v = p["value"] or 0
        if p["temporality"] == DELTA:
            d = v
        elif prev is None:
            d = v if p["start"] is not None and p["start"] >= p["lo"] else 0
        elif v < prev["value"] or (p["start"] is not None and p["start"] != prev["start"]):
            d = v
        else:
            d = v - prev["value"]
        if d > 0:
            out.append((p["t"], d))
        prev = dict(p, value=v)
    return out


def _refusing(con, lo, at, cfg):
    rows = _rows(con, f"""
        SELECT host_name AS host, oute_instance AS instance,
               json_extract_string(attributes, '$.exporter') AS exporter, metric_name AS metric,
               time_unix_nano AS t, start_unix_nano AS start, value,
               aggregation_temporality AS temporality, ? AS lo
        FROM metrics
        WHERE metric_name IN ({', '.join('?' * len(SEND_FAILED))}) AND time_unix_nano BETWEEN ? AND ?
        ORDER BY host, instance, exporter, metric, t""", [lo, *SEND_FAILED, lo, at])
    window = int(cfg.refused_window_minutes * MIN_NS)
    per_exporter = {}
    for (host, instance, exporter, metric), pts in _series(rows, ("host", "instance", "exporter", "metric")).items():
        rises = _rises(pts)
        if rises:
            per_exporter.setdefault((host, instance, exporter), []).append((metric, rises))
    out = []
    for (host, instance, exporter), per_metric in per_exporter.items():
        recent = [(m, t, d) for m, rises in per_metric for t, d in rises if t > at - window]
        if not recent:
            continue
        times = sorted(t for _, rises in per_metric for t, _ in rises)
        # limite 0: qualquer subida na janela liga
        out.append(_alert(REFUSING, host, instance, sum(d for _, _, d in recent), "failed_items", 0,
                          _chain_start(times, window), {
                              "exporter": exporter, "metrics": sorted({m for m, _, _ in recent}),
                              "window_minutes": cfg.refused_window_minutes,
                              "last_rise": iso(max(t for _, t, _ in recent))}))
    return out


# coluna da hora de cada registro: a do fato (os alertas) ou a de chegada ao agent-studio (as máquinas do tray, #205)
FACT, RECEIVED = "time_unix_nano", "received_unix_nano"


def last_data(con, lo, at, by=FACT):
    """{host: (hora do último registro, sinal)} de todo host com dado em [lo, at] (logs, spans e métricas), pela
    hora do fato ou, com `by=RECEIVED`, pela de chegada. Só a janela lida (`lookback_hours`): a consulta não varre
    o banco inteiro; host sem nada nela fica de fora."""
    if by not in (FACT, RECEIVED):
        raise ValueError(f"coluna de hora inválida: {by}")
    rows = _rows(con, f"""
        SELECT host, max(t) AS t, arg_max(signal, t) AS signal FROM (
          SELECT host_name AS host, max({by}) AS t, 'logs' AS signal FROM logs
           WHERE {by} BETWEEN ? AND ? GROUP BY ALL
          UNION ALL SELECT host_name, max({by}), 'traces' FROM spans
           WHERE {by} BETWEEN ? AND ? GROUP BY ALL
          UNION ALL SELECT host_name, max({by}), 'metrics' FROM metrics
           WHERE {by} BETWEEN ? AND ? GROUP BY ALL
        ) WHERE host IS NOT NULL GROUP BY host""", [lo, at] * 3)
    return {r["host"]: (r["t"], r["signal"]) for r in rows}


def lookback(at_ns, cfg):
    """Início da janela lida (`lookback_hours` antes de `at_ns`)."""
    return max(0, at_ns - int(cfg.lookback_hours * 60 * MIN_NS))


def stopped(t, at_ns, cfg):
    """Host parado = sem nenhum registro há mais de `no_data_minutes` (`t` = hora do último; `None` = nenhum)."""
    return t is None or at_ns - t > int(cfg.no_data_minutes * MIN_NS)


def hosts(last, at_ns, cfg):
    """Todo host de `last` (o `last_data`) mais os sempre ligados, com o último dado e há quanto tempo."""
    always_on = set(cfg.always_on_hosts)
    return [{"host": h, "always_on": h in always_on, "last_data": iso(last.get(h, (None,))[0]),
             "idle_seconds": None if h not in last else (at_ns - last[h][0]) // 1_000_000_000}
            for h in sorted(set(last) | always_on)]


def _no_data(last, at, cfg):
    out = []
    for host in cfg.always_on_hosts:
        t, signal = last.get(host, (None, None))
        if not stopped(t, at, cfg):
            continue
        out.append(_alert(NO_DATA, host, None, None if t is None else (at - t) // 1_000_000_000, "seconds",
                          cfg.no_data_minutes * 60, t, {
                              "last_data": iso(t), "signal": signal,
                              "note": None if t is not None
                              else f"nenhum registro nas últimas {cfg.lookback_hours:g} h"}))
    return out


def _spool(con, lo, at, cfg):
    rows = _rows(con, f"""
        SELECT host_name AS host, oute_instance AS instance, time_unix_nano AS t, event_name, oute_event_id,
               TRY_CAST(json_extract_string(attributes, '$."{SPOOL_BYTES}"') AS BIGINT) AS bytes,
               TRY_CAST(json_extract_string(attributes, '$."{SPOOL_DROPPED}"') AS BIGINT) AS dropped
        FROM logs
        WHERE time_unix_nano BETWEEN ? AND ?
          AND (json_exists(attributes, '$."{SPOOL_BYTES}"') OR json_exists(attributes, '$."{SPOOL_DROPPED}"'))
        ORDER BY host, instance, t, oute_event_id""", [lo, at])
    window = int(cfg.spool_dropped_window_minutes * MIN_NS)
    out = []
    for (host, instance), evs in _series(rows, ("host", "instance")).items():
        def event(e):
            return {"event_name": e["event_name"], "event_id": e["oute_event_id"], "at": iso(e["t"])}
        sized = [e for e in evs if e["bytes"] is not None]
        if sized and sized[-1]["bytes"] > cfg.spool_max_bytes:
            last = sized[-1]
            out.append(_alert(SPOOL, host, instance, last["bytes"], "bytes", cfg.spool_max_bytes,
                              _run_start(sized, lambda e: e["bytes"] > cfg.spool_max_bytes),
                              {"attribute": SPOOL_BYTES, **event(last)}))
        # o contador do spool nunca zera: sem evento anterior na janela lida, não há base (não liga)
        counted = [e for e in evs if e["dropped"] is not None]
        rises = [(b, b["dropped"] - a["dropped"] if b["dropped"] >= a["dropped"] else b["dropped"])
                 for a, b in zip(counted, counted[1:])]
        rises = [(e, d) for e, d in rises if d > 0]
        recent = [(e, d) for e, d in rises if e["t"] > at - window]
        if recent:
            last = recent[-1][0]
            out.append(_alert(SPOOL, host, instance, sum(d for _, d in recent), "dropped_events", 0,
                              _chain_start([e["t"] for e, _ in rises], window),
                              {"attribute": SPOOL_DROPPED, "counter": last["dropped"],
                               "window_minutes": cfg.spool_dropped_window_minutes, **event(last)}))
    return out


QUOTA_WINDOW = "oute.quota.window"
QUOTA_SHORT = "5h"  # a única janela com a exceção de reset próximo


def _quota(con, lo, at, cfg):
    sql = """
        SELECT host_name AS host, oute_instance AS instance, oute_agent AS agent, attributes, time_unix_nano AS t, value
        FROM metrics WHERE metric_name = ? AND time_unix_nano BETWEEN ? AND ?
        ORDER BY host, instance, agent, attributes, t"""
    key = ("host", "instance", "agent", "attributes")
    # reset de cada ponto: o par de mesma série e mesma hora (os dois saem do mesmo snapshot)
    resets = {k: {p["t"]: p["value"] for p in pts}
              for k, pts in _series(_rows(con, sql, [cfg.quota_reset_metric, lo, at]), key).items()}
    series = _series(_rows(con, sql, [cfg.quota_metric, lo, at]), key)
    grace = int(cfg.quota_reset_grace_minutes * MIN_NS)

    def window(attrs):
        try:
            return json.loads(attrs or "{}").get(QUOTA_WINDOW)
        except (TypeError, ValueError, AttributeError):
            return None

    def over(p):
        return p["value"] is not None and p["value"] >= cfg.quota_max_pct

    # último ponto de cada série com o reset dele ainda no futuro (ponto velho e ponto sem par ficam de fora)
    live = {}
    for k, pts in series.items():
        reset_in = resets.get(k, {}).get(pts[-1]["t"])
        if reset_in is not None and pts[-1]["t"] + int(reset_in * 1_000_000_000) > at:
            live[k] = (pts, pts[-1]["t"] + int(reset_in * 1_000_000_000))

    out = []
    for k, (pts, reset_at) in live.items():
        host, instance, agent, attrs = k
        last = pts[-1]
        if not over(last):
            continue
        if window(attrs) == QUOTA_SHORT and last["value"] < 100 and reset_at - at < grace:
            # exceção: a 5h está a menos de `grace` do reset e a 7d do agente não passou do corte
            if not any(over(p[-1]) for (h, i, a, at2), (p, _) in live.items()
                       if (h, i, a) == (host, instance, agent) and window(at2) != QUOTA_SHORT):
                continue
        out.append(_alert(QUOTA, host, instance, last["value"], "pct", cfg.quota_max_pct, _run_start(pts, over),
                          {"metric": cfg.quota_metric, "agent": agent, "attributes": attrs, "at": iso(last["t"]),
                           "resets_at": iso(reset_at)}))
    return out


SWARM_PREFIX = "oute.swarm."
SWARM_SESSION = "oute.swarm.session"


def _rounds(con, at, cfg):
    """Rodadas abertas e sem evento há mais de `round_stalled_minutes` (hora do fato, até `at`). Sem sessão aberta =
    triagem parada. Sem evento há mais de `lookback_hours` = `round_old`, só até o dobro disso."""
    day = int(cfg.lookback_hours * 60 * MIN_NS)
    rows = _rows(con, """
        SELECT host_name AS host, oute_instance AS instance, oute_swarm_round AS round, max(time_unix_nano) AS last_t,
               max(time_unix_nano) FILTER (WHERE event_name = 'oute.swarm.round.opened') AS opened_t,
               max(time_unix_nano) FILTER (WHERE event_name = 'oute.swarm.round.closed') AS closed_t
        FROM logs
        WHERE starts_with(event_name, ?) AND oute_swarm_round IS NOT NULL AND time_unix_nano <= ?
        GROUP BY host_name, oute_instance, oute_swarm_round
        HAVING last_t >= ? AND opened_t IS NOT NULL AND closed_t IS NULL""", [SWARM_PREFIX, at, max(0, at - 2 * day)])
    if not rows:
        return []
    marks = ", ".join("?" * len(rows))
    life = _series(_rows(con, f"""
        SELECT host_name AS host, oute_swarm_round AS round,
               json_extract_string(attributes, '$."{SWARM_SESSION}"') AS slug, event_name, time_unix_nano AS t
        FROM logs
        WHERE event_name IN ('oute.swarm.session.spawned', 'oute.swarm.session.closed') AND time_unix_nano <= ?
          AND oute_swarm_round IN ({marks})
        ORDER BY t""", [at, *[r["round"] for r in rows]]), ("host", "round"))
    out = []
    for r in rows:
        idle = at - r["last_t"]
        if idle <= int(cfg.round_stalled_minutes * MIN_NS):
            continue
        state = {}
        for e in life.get((r["host"], r["round"]), []):
            if e["slug"]:
                state[e["slug"]] = e["event_name"].endswith(".spawned")
        slugs = sorted(k for k, v in state.items() if v)
        kind = ROUND_OLD if idle > day else ROUND_STALLED
        out.append(_alert(kind, r["host"], r["instance"], idle // 1_000_000_000, "seconds",
                          cfg.round_stalled_minutes * 60, r["last_t"], {
                              "round": r["round"], "sessions": slugs,
                              "kind": "old" if kind == ROUND_OLD else ("sessions" if slugs else "triage"),
                              "last_event": iso(r["last_t"]), "opened_at": iso(r["opened_t"])}))
    return out


def enabled(cfg):
    return {t: (cfg.quota_enabled if t == QUOTA else True) for t in ALL_TYPES}


def evaluate(con, at_ns, cfg):
    """Alertas ativos na hora `at_ns` (ns, hora do fato) e o último dado de cada host. Só lê."""
    lo = lookback(at_ns, cfg)
    last = last_data(con, lo, at_ns)
    alerts = _queue(con, lo, at_ns, cfg) + _refusing(con, lo, at_ns, cfg) + _no_data(last, at_ns, cfg) \
        + _spool(con, lo, at_ns, cfg)
    if cfg.quota_enabled:
        alerts += _quota(con, lo, at_ns, cfg)
    try:
        alerts += _rounds(con, at_ns, cfg)
    except Exception:  # noqa: BLE001 — o cálculo da rodada parada não derruba os outros alertas (#364)
        logging.getLogger(__name__).exception("alerta de rodada parada falhou; os outros seguem")
    from . import price_alerts  # aqui e não no topo: o `price_alerts` importa este módulo
    alerts += price_alerts.evaluate(con, at_ns)
    idle = {h for h, (t, _) in last.items() if stopped(t, at_ns, cfg)}
    alerts = [a for a in alerts if a["type"] == NO_DATA or a["host"] not in idle]
    alerts.sort(key=lambda a: (ALL_TYPES.index(a["type"]), a["host"] or "", a["instance"] or "",
                               str(a["evidence"].get("exporter") or a["evidence"].get("attribute")
                                   or a["evidence"].get("round") or "")))
    return {"alerts": alerts, "hosts": hosts(last, at_ns, cfg), "checks": enabled(cfg)}
