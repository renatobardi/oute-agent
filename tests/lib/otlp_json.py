"""Peças do OTLP JSON para os testes montarem os lotes de exemplo (o que o collector manda ao agent-studio).
`v(x)` -> AnyValue; `kv(dict)` -> lista de atributos; `rs(recurso, spans)` -> um ResourceSpans; `rl(recurso, logs)`
-> um ResourceLogs. `span(nome, início, duração, atributos, err)` -> um span (trace e span novos a cada chamada).
`api_request(t, request_id, custo, atributos)` -> o log `api_request` do Claude Code (formato de produção, #157);
`claude_call(início, duração, atributos, custo)` -> (span, log) de uma chamada do Claude Code como chega em produção:
o span `claude_code.llm_request` com o `request_id` e sem custo, e o log com o custo (ou `None`, chamada sem log).
`event(t, nome, id do evento, atributos, corpo)` -> o log de um evento operacional (`oute-emit`);
`canal_proposed`/`canal_decided` -> os eventos `oute.canal.*` de um pedido. `queue_metrics(host, t, tamanho,
capacidade)` -> o lote de métricas da fila do collector (#162) num instante.
Uso: PYTHONPATH=tests/lib."""


def v(x):
    if isinstance(x, bool): return {"boolValue": x}
    if isinstance(x, int): return {"intValue": str(x)}
    if isinstance(x, float): return {"doubleValue": x}
    return {"stringValue": x}


def kv(d): return [{"key": k, "value": v(x)} for k, x in d.items()]


def rs(res, spans): return {"resource": {"attributes": kv(res)}, "scopeSpans": [{"spans": spans}]}


def rl(res, recs): return {"resource": {"attributes": kv(res)}, "scopeLogs": [{"logRecords": recs}]}


_spans = 0


def span(name, start, dur, attrs, err=False):
    global _spans
    _spans += 1
    s = {"traceId": f"{_spans:032x}", "spanId": f"{_spans:016x}", "name": name,
         "startTimeUnixNano": str(int(start * 1e9)), "endTimeUnixNano": str(int((start + dur) * 1e9)),
         "attributes": kv(attrs)}
    if err: s["status"] = {"code": 2, "message": "falhou"}
    return s


def api_request(t, request_id, cost_usd, attrs=None):
    # como o Claude Code manda (conferido no oute-server, 2026-10): `event.name` sem prefixo, corpo com prefixo
    return {"timeUnixNano": str(int(t * 1e9)), "body": {"stringValue": "claude_code.api_request"},
            "attributes": kv({**(attrs or {}), "event.name": "api_request", "request_id": request_id, "cost_usd": cost_usd})}


_requests = 0


def claude_call(start, dur, attrs, cost_usd=None, err=False):
    global _requests
    _requests += 1
    rid = f"req_{_requests:024d}"
    s = span("claude_code.llm_request", start, dur, {**attrs, "request_id": rid}, err)
    # o log sai no fim da chamada, com os mesmos modelo, tokens e conversa
    return s, None if cost_usd is None else api_request(start + dur, rid, cost_usd, attrs)


def event(t, name, eid, attrs, body=None):
    r = {"timeUnixNano": str(t * 10**9), "severityNumber": 9, "eventName": name,
         "attributes": kv({"event.name": name, "oute.event.id": eid, **attrs})}
    if body is not None: r["body"] = {"stringValue": body}
    return r


def canal_proposed(t, pid, eid, title, how, script):
    return event(t, "oute.canal.proposed", eid, {"oute.canal.id": pid, "oute.canal.title": title, "oute.canal.as": how,
                                                 "oute.canal.size": len(script.encode())}, script)


def canal_decided(t, pid, eid, decision, body=None, **attrs):
    return event(t, "oute.canal.decided", eid, {"oute.canal.id": pid, "oute.canal.decision": decision,
                                                "oute.canal.approver": "bardi@oute-server", **attrs}, body)


def queue_metrics(host, t, size, cap=1000, exporter="otlp_http/studio_logs"):
    # como no collector real: a capacidade da mesma coleta sai uns µs antes do tamanho
    point = lambda x, off: {"timeUnixNano": str(t * 10**9 + off), "asInt": str(x), "attributes": kv({"exporter": exporter})}
    return {"resourceMetrics": [{
        "resource": {"attributes": kv({"host.name": host, "oute.instance": "oute-agent", "service.name": "otelcol-contrib"})},
        "scopeMetrics": [{"metrics": [
            {"name": "otelcol_exporter_queue_size", "gauge": {"dataPoints": [point(size, 0)]}},
            {"name": "otelcol_exporter_queue_capacity", "gauge": {"dataPoints": [point(cap, -12640)]}}]}]}]}
