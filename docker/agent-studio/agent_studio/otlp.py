"""OTLP/HTTP JSON -> linhas das tabelas do DuckDB (ADR-08 §3).

Cada linha leva as colunas fixas (hora do fato, origem, agente, sessão…) e, em JSON, os atributos completos de
resource e do registro, para que campo novo não quebre nada. A chave de dedupe de cada linha sai do próprio fato,
nunca da hora de chegada: o mesmo registro reenviado pelo collector (pelo menos uma vez) leva a mesma chave.
"""
import hashlib
import json

# atributos que viram coluna fixa: procurados primeiro no registro, depois no resource
FIXED = {
    "host_name": "host.name",
    "oute_instance": "oute.instance",
    "oute_agent": "oute.agent",
    "service_name": "service.name",
    "session_id": "session.id",
    "oute_task_id": "oute.task.id",
    "oute_swarm_round": "oute.swarm.round",
}


class BadPayload(ValueError):
    """Corpo que não é OTLP JSON: erro permanente (400), o collector não reenvia."""


def any_value(v):
    """AnyValue do OTLP JSON -> valor JSON simples (int64 chega como string no JSON do OTLP)."""
    if not isinstance(v, dict) or not v:
        return None
    if "stringValue" in v:
        return v["stringValue"]
    if "boolValue" in v:
        return bool(v["boolValue"])
    if "intValue" in v:
        return int(v["intValue"])
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "arrayValue" in v:
        return [any_value(x) for x in (v["arrayValue"] or {}).get("values") or []]
    if "kvlistValue" in v:
        return attrs((v["kvlistValue"] or {}).get("values"))
    if "bytesValue" in v:
        return v["bytesValue"]
    return None


def attrs(kvs):
    out = {}
    for kv in kvs or []:
        if isinstance(kv, dict) and "key" in kv:
            out[kv["key"]] = any_value(kv.get("value"))
    return out


def to_int(x):
    if x is None or x == "":
        return 0
    try:
        return int(x)
    except (TypeError, ValueError):
        raise BadPayload(f"inteiro inválido: {x!r}")


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)


def content_hash(obj):
    return hashlib.sha256(canon(obj).encode()).hexdigest()


def text(v):
    """Coluna de texto: string como está; outro valor em JSON; ausente = NULL."""
    if v is None:
        return None
    return v if isinstance(v, str) else canon(v)


def fixed(rec, res):
    return {col: text(rec[key] if rec.get(key) is not None else res.get(key)) for col, key in FIXED.items()}


def _list(obj, key):
    v = obj.get(key) if isinstance(obj, dict) else None
    if v is None:
        return []
    if not isinstance(v, list):
        raise BadPayload(f"{key} não é lista")
    return v


def _payload(payload, key):
    if not isinstance(payload, dict):
        raise BadPayload("corpo não é um objeto JSON")
    return _list(payload, key)


def fact_time(t, observed, received_ns):
    """Hora do fato: timeUnixNano; sem ela, a hora em que a fonte observou; só em último caso, a chegada."""
    return t or observed or received_ns


def log_rows(payload, received_ns):
    """ExportLogsServiceRequest -> linhas da tabela `logs`.

    Dedupe: `oute.event.id` quando existe (evento do oute-emit, o mesmo ao vivo, no spool e no backfill); senão,
    hash do conteúdo (hora em ns + origem + registro inteiro)."""
    rows = []
    for rl in _payload(payload, "resourceLogs"):
        res = attrs((rl.get("resource") or {}).get("attributes"))
        for sl in _list(rl, "scopeLogs"):
            scope = sl.get("scope") or {}
            scope_id = {"name": scope.get("name"), "version": scope.get("version")}
            for lr in _list(sl, "logRecords"):
                if not isinstance(lr, dict):
                    raise BadPayload("logRecord não é objeto")
                rec = attrs(lr.get("attributes"))
                t = to_int(lr.get("timeUnixNano"))
                observed = to_int(lr.get("observedTimeUnixNano"))
                body = any_value(lr.get("body"))
                event_name = lr.get("eventName") or rec.get("event.name")
                event_id = rec.get("oute.event.id")
                if event_id:
                    key = "ev:" + str(event_id)
                else:
                    key = "h:" + content_hash({
                        "time": t, "observed": observed, "resource": res, "scope": scope_id,
                        "severityNumber": lr.get("severityNumber"), "severityText": lr.get("severityText"),
                        "body": body, "attributes": rec, "eventName": lr.get("eventName"),
                        "traceId": lr.get("traceId"), "spanId": lr.get("spanId"), "flags": lr.get("flags"),
                    })
                row = {
                    "dedupe_key": key,
                    "time_unix_nano": fact_time(t, observed, received_ns),
                    "observed_unix_nano": observed or None,
                    **fixed(rec, res),
                    "event_name": text(event_name),
                    "oute_event_id": text(event_id),
                    "severity_number": to_int(lr.get("severityNumber")) or None,
                    "severity_text": lr.get("severityText") or None,
                    "body": text(body),
                    "trace_id": lr.get("traceId") or None,
                    "span_id": lr.get("spanId") or None,
                    "scope_name": scope.get("name") or None,
                    "resource_attributes": canon(res),
                    "attributes": canon(rec),
                    "received_unix_nano": received_ns,
                    # só para o estado derivado (SurrealDB); não viram coluna
                    "_attrs": rec,
                    "_res": res,
                }
                rows.append(row)
    return rows


# modelo, tokens e custo nas colunas fixas de `spans`: primeiro atributo presente, na ordem
# (Claude Code: claude_code.llm_request; Codex: session_task.turn). Histórico até 2026-09-30 (#218): jev.decision e
# spans do LiteLLM, do jev-router que saiu do stack; as chaves deles ficam para reingerir o que está no bucket
SPAN_MODEL = ("gen_ai.response.model", "oute.served_model", "model", "gen_ai.request.model", "llm.model_name")
SPAN_TOKENS = {
    "input_tokens": ("gen_ai.usage.input_tokens", "input_tokens", "codex.turn.token_usage.non_cached_input_tokens"),
    "output_tokens": ("gen_ai.usage.output_tokens", "output_tokens", "codex.turn.token_usage.output_tokens"),
    "cache_read_tokens": ("gen_ai.usage.cache_read_input_tokens", "cache_read_tokens",
                          "codex.turn.token_usage.cached_input_tokens"),
    "cache_creation_tokens": ("gen_ai.usage.cache_creation_input_tokens", "cache_creation_tokens"),
}
# custo real (Claude manda cost_usd; oute.cost_usd = OpenRouter no jev.decision, histórico até 2026-09-30);
# estimado fica para a API (#156)
SPAN_COST = ("oute.cost_usd", "cost_usd", "gen_ai.usage.cost")


def first(d, keys):
    for k in keys:
        if d.get(k) is not None:
            return d[k]
    return None


def number(v, conv):
    if v is None:
        return None
    try:
        return conv(v)
    except (TypeError, ValueError):
        return None


def span_rows(payload, received_ns):
    """ExportTraceServiceRequest -> linhas da tabela `spans`. Dedupe por trace_id + span_id."""
    rows = []
    for rs in _payload(payload, "resourceSpans"):
        res = attrs((rs.get("resource") or {}).get("attributes"))
        for ss in _list(rs, "scopeSpans"):
            scope = ss.get("scope") or {}
            for sp in _list(ss, "spans"):
                if not isinstance(sp, dict):
                    raise BadPayload("span não é objeto")
                trace_id, span_id = sp.get("traceId"), sp.get("spanId")
                if not trace_id or not span_id:
                    raise BadPayload("span sem traceId/spanId")
                rec = attrs(sp.get("attributes"))
                start, end = to_int(sp.get("startTimeUnixNano")), to_int(sp.get("endTimeUnixNano"))
                status = sp.get("status") or {}
                row = {
                    "dedupe_key": f"s:{trace_id.lower()}:{span_id.lower()}",
                    "time_unix_nano": start or end or received_ns,
                    "end_unix_nano": end or None,
                    "duration_ns": (end - start) if start and end >= start else None,
                    **fixed(rec, res),
                    "trace_id": trace_id.lower(),
                    "span_id": span_id.lower(),
                    "parent_span_id": (sp.get("parentSpanId") or "").lower() or None,
                    "name": sp.get("name"),
                    "kind": to_int(sp.get("kind")) or None,
                    "status_code": to_int(status.get("code")) or None,
                    "status_message": status.get("message") or None,
                    "model": text(first(rec, SPAN_MODEL)),
                    **{col: number(first(rec, keys), int) for col, keys in SPAN_TOKENS.items()},
                    "cost_usd": number(first(rec, SPAN_COST), float),
                    "scope_name": scope.get("name") or None,
                    "resource_attributes": canon(res),
                    "attributes": canon(rec),
                    "events": canon([{"time_unix_nano": to_int(e.get("timeUnixNano")), "name": e.get("name"),
                                      "attributes": attrs(e.get("attributes"))} for e in _list(sp, "events")]),
                    "links": canon([{"trace_id": ln.get("traceId"), "span_id": ln.get("spanId"),
                                     "attributes": attrs(ln.get("attributes"))} for ln in _list(sp, "links")]),
                    "received_unix_nano": received_ns,
                }
                rows.append(row)
    return rows


METRIC_TYPES = {"gauge": "gauge", "sum": "sum", "histogram": "histogram",
                "exponentialHistogram": "exponential_histogram", "summary": "summary"}


def metric_rows(payload, received_ns):
    """ExportMetricsServiceRequest -> linhas da tabela `metrics`, uma por ponto.

    Dedupe por hash do conteúdo (hora em ns + origem + métrica + ponto inteiro)."""
    rows = []
    for rm in _payload(payload, "resourceMetrics"):
        res = attrs((rm.get("resource") or {}).get("attributes"))
        for sm in _list(rm, "scopeMetrics"):
            scope = sm.get("scope") or {}
            scope_id = {"name": scope.get("name"), "version": scope.get("version")}
            for m in _list(sm, "metrics"):
                if not isinstance(m, dict):
                    raise BadPayload("metric não é objeto")
                kind = next((k for k in METRIC_TYPES if isinstance(m.get(k), dict)), None)
                if kind is None:
                    continue  # métrica sem dados (tipo vazio): nada a gravar
                data = m[kind]
                for p in _list(data, "dataPoints"):
                    if not isinstance(p, dict):
                        raise BadPayload("dataPoint não é objeto")
                    pa = attrs(p.get("attributes"))
                    t = to_int(p.get("timeUnixNano"))
                    start = to_int(p.get("startTimeUnixNano"))
                    point = {k: v for k, v in p.items() if k != "attributes"}
                    if "asInt" in p:
                        value = float(to_int(p["asInt"]))
                    elif "asDouble" in p:
                        value = number(p["asDouble"], float)
                    else:
                        value = number(p.get("sum"), float)  # histogram/summary: a soma; o resto fica em `point`
                    key = "h:" + content_hash({
                        "time": t, "start": start, "resource": res, "scope": scope_id, "name": m.get("name"),
                        "type": kind, "unit": m.get("unit"), "attributes": pa, "point": point,
                    })
                    rows.append({
                        "dedupe_key": key,
                        "time_unix_nano": t or start or received_ns,
                        "start_unix_nano": start or None,
                        **fixed(pa, res),
                        "metric_name": m.get("name"),
                        "metric_type": METRIC_TYPES[kind],
                        "unit": m.get("unit") or None,
                        "value": value,
                        "count": number(p.get("count"), int),
                        "is_monotonic": data.get("isMonotonic") if kind == "sum" else None,
                        "aggregation_temporality": to_int(data.get("aggregationTemporality")) or None,
                        "scope_name": scope.get("name") or None,
                        "resource_attributes": canon(res),
                        "attributes": canon(pa),
                        "point": canon(point),
                        "received_unix_nano": received_ns,
                    })
    return rows
