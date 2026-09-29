# Gerador OTLP/HTTP JSON (base: lab do #137): manda <n> itens de cada sinal (logs, traces, metrics) em lotes de 100,
# com id "<run>-<sinal>-<i>" no body do log, no nome do span e no nome da métrica. Grava em <accepted> só os ids
# que o collector aceitou (2xx); um lote recusado não conta. Uso: otlp-send.py <porta> <run> <n> <accepted>
import json, sys, time, urllib.request
port, run, n, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
res = {'attributes': [{'key': 'service.name', 'value': {'stringValue': 'otelcol-queue-test'}}]}
now = str(time.time_ns())
def logs(ids):    return {'resourceLogs': [{'resource': res, 'scopeLogs': [{'logRecords': [
                      {'timeUnixNano': now, 'body': {'stringValue': i}} for i in ids]}]}]}
def traces(ids):  return {'resourceSpans': [{'resource': res, 'scopeSpans': [{'spans': [
                      {'traceId': '%032x' % (hash(i) & (2**128 - 1) or 1), 'spanId': '%016x' % (hash(i) & (2**64 - 1) or 1),
                       'name': i, 'kind': 1, 'startTimeUnixNano': now, 'endTimeUnixNano': now} for i in ids]}]}]}
def metrics(ids): return {'resourceMetrics': [{'resource': res, 'scopeMetrics': [{'metrics': [
                      {'name': i, 'gauge': {'dataPoints': [{'timeUnixNano': now, 'asInt': '1'}]}} for i in ids]}]}]}
ok = fail = 0
with open(out, 'a') as acc:
    for sig, build in (('logs', logs), ('traces', traces), ('metrics', metrics)):
        for b in range(0, n, 100):
            ids = [f'{run}-{sig}-{i}' for i in range(b, min(b + 100, n))]
            req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{sig}', json.dumps(build(ids)).encode(),
                                         {'Content-Type': 'application/json'})
            try:
                urllib.request.urlopen(req, timeout=5).read(); acc.write('\n'.join(ids) + '\n'); ok += len(ids)
            except Exception:
                fail += len(ids)
print(f'aceitos={ok} recusados={fail}')
