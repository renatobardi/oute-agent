# S3 falso (base: lab do #137, docs/research/137-medir-collector no 13e79ba). Aceita PUT path-style de objetos
# OTLP-JSON (gzip ou não) e grava em <dir>/received.jsonl um registro por objeto com os ids que chegaram:
# body do log, nome do span, nome da métrica; em <dir>/objects.jsonl, uma linha {path, otlp} por linha OTLP-JSON do
# objeto (#162: prefixo e atributos das métricas; path decodificado, sem query). Controle pelo arquivo <dir>/mode: "ok" | "down" (503).
# Cada PUT recusado soma uma linha em <dir>/refused (só o código, nada da requisição). Porta livre escolhida pelo SO, escrita em <dir>/port.
import gzip, json, os, sys, threading, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
D = sys.argv[1]
lock = threading.Lock()
def mode():
    try: return open(os.path.join(D, 'mode')).read().strip()
    except FileNotFoundError: return 'ok'
def ids_of(j):
    for r in j.get('resourceLogs', []):
        for s in r.get('scopeLogs', []):
            for x in s.get('logRecords', []): yield x['body']['stringValue']
    for r in j.get('resourceSpans', []):
        for s in r.get('scopeSpans', []):
            for x in s.get('spans', []): yield x['name']
    for r in j.get('resourceMetrics', []):
        for s in r.get('scopeMetrics', []):
            for x in s.get('metrics', []): yield x['name']
class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def _reply(self, code, body=b''):
        self.send_response(code); self.send_header('Content-Length', str(len(body)))
        if code == 200: self.send_header('ETag', '"x"')
        self.end_headers(); self.wfile.write(body)
    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if mode() == 'down':
            with lock, open(os.path.join(D, 'refused'), 'a') as f: f.write('503\n')
            return self._reply(503, b'<Error><Code>ServiceUnavailable</Code></Error>')
        try:
            raw = gzip.decompress(data) if data[:2] == b'\x1f\x8b' else data
            objs = [json.loads(line) for line in raw.splitlines() if line.strip()]
            ids = [i for o in objs for i in ids_of(o)]
        except Exception:
            objs, ids = [], ['PARSE-ERR']
        with lock:
            with open(os.path.join(D, 'received.jsonl'), 'a') as f:
                f.write(json.dumps({'ids': ids}) + '\n')
            with open(os.path.join(D, 'objects.jsonl'), 'a') as f:
                path = urllib.parse.unquote(self.path.split('?')[0])
                for o in objs: f.write(json.dumps({'path': path, 'otlp': o}) + '\n')
        self._reply(200)
    def do_HEAD(self): self._reply(200)
    def do_GET(self): self._reply(200)
srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
open(os.path.join(D, 'port.tmp'), 'w').write(str(srv.server_address[1])); os.rename(os.path.join(D, 'port.tmp'), os.path.join(D, 'port'))
srv.serve_forever()
