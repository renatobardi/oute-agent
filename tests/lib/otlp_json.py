"""Peças do OTLP JSON para os testes montarem os lotes de exemplo (o que o collector manda ao agent-studio).
`v(x)` -> AnyValue; `kv(dict)` -> lista de atributos; `rs(recurso, spans)` -> um ResourceSpans.
Uso: PYTHONPATH=tests/lib."""


def v(x):
    if isinstance(x, bool): return {"boolValue": x}
    if isinstance(x, int): return {"intValue": str(x)}
    if isinstance(x, float): return {"doubleValue": x}
    return {"stringValue": x}


def kv(d): return [{"key": k, "value": v(x)} for k, x in d.items()]


def rs(res, spans): return {"resource": {"attributes": kv(res)}, "scopeSpans": [{"spans": spans}]}
