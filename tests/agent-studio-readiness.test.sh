#!/usr/bin/env bash
# Testes do `GET /readyz` do agent-studio (#570, bloco 7). O `/healthz` responde "ok" sem tocar no banco: em produção o
# container ficou "healthy" com quase tudo dando 499. O `/readyz` mede o que o serviço precisa para funcionar: a trava
# do escritor livre dentro do prazo, uma leitura no DuckDB e, se há ingestão chegando, que ela esteja sendo gravada.
# Sem credencial, como o /healthz, e por isso a resposta não leva dado do banco: só pronto ou não, o motivo e tempos.
# Período sem ingestão é pronto (ninguém mandando nada não é defeito do serviço). O /healthz segue igual, para o
# healthcheck do container: readiness que falha não pode reiniciar o serviço.
# Chama o app pelo ASGI; sem servidor de verdade, sem rede e sem Docker.
# Uso: tests/agent-studio-readiness.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import asyncio, json, sys, threading, time
from agent_studio import store as ST
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN

tmp = sys.argv[1]
NOW = time.time_ns()

def payload(i):
    return json.dumps({"resourceLogs": [{"resource": {"attributes": []}, "scopeLogs": [{"logRecords": [
        {"timeUnixNano": str(NOW + i), "body": {"stringValue": f"segredo-do-log {i}"}, "attributes": []}]}]}]}).encode()

async def call(app, path, body=b"", method="GET", auth=True):
    msgs, read = [], [0]
    headers = [(b"content-type", b"application/json")] + ([(b"authorization", f"Bearer {TOKEN}".encode())] if auth else [])
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method, "scheme": "http", "path": path,
             "raw_path": path.encode(), "query_string": b"", "root_path": "", "server": ("t", 80), "client": ("t", 1), "headers": headers}
    async def receive():
        read[0] += 1
        return {"type": "http.request", "body": body, "more_body": False} if read[0] == 1 else {"type": "http.disconnect"}
    async def send(m):
        msgs.append(m)
    t = time.perf_counter()
    await app(scope, receive, send)
    return msgs[0]["status"], b"".join(m.get("body", b"") for m in msgs[1:]).decode(), time.perf_counter() - t

def ready(app):
    status, body, dt = asyncio.run(call(app, "/readyz", auth=False))
    return status, json.loads(body), dt

class Tel:
    def __getattr__(self, name): return lambda *a, **k: None

# ------------------------------------------------------------------------------ pronto
st = ST.Store(f"{tmp}/a.duckdb")
app = create_app(st, TOKEN, tel=Tel(), ready_lock_wait=0.3, ready_max_write_age=0.5)
status, body, dt = ready(app)
check("recém-subido, sem ingestão nenhuma: pronto (200), sem credencial", status == 200 and body["ready"] is True)
check("a resposta traz os tempos das checagens, em números", isinstance(body["lock_wait_ms"], (int, float)) and isinstance(body["read_ms"], (int, float)))
asyncio.run(call(app, "/v1/logs", payload(1), method="POST"))
status, body, dt = ready(app)
check("depois de uma gravação: pronto, com a idade da última gravação", status == 200 and 0 <= body["last_write_age_s"] < 5)
check("nada do banco na resposta (rota sem credencial)", "segredo-do-log" not in json.dumps(body) and set(body) <= {"ready", "reason", "lock_wait_ms", "read_ms", "last_write_age_s"})
time.sleep(0.7)
check("tempo sem ingestão chegando não é defeito: segue pronto", ready(app)[0] == 200)

# ------------------------------------------------------------------------------ trava presa
held = threading.Event(); release = threading.Event()
def hold():
    with st.lock:
        held.set(); release.wait(5)
t = threading.Thread(target=hold); t.start(); held.wait(2)
status, body, dt = ready(app)
release.set(); t.join()
check("trava do escritor presa além do prazo: 503 com o motivo lock", status == 503 and body["ready"] is False and body["reason"] == "lock")
check("e responde no prazo, sem ficar pendurado na trava", dt < 1.5)
check("liberada a trava, volta a pronto", ready(app)[0] == 200)

# ------------------------------------------------------------------------------ leitura que falha
st2 = ST.Store(f"{tmp}/b.duckdb")
app2 = create_app(st2, TOKEN, tel=Tel(), ready_lock_wait=0.3, ready_max_write_age=0.5)
real = st2.ping
st2.ping = lambda: (_ for _ in ()).throw(RuntimeError("segredo-da-falha"))
status, body, dt = ready(app2)
check("leitura no DuckDB que falha: 503 com o motivo read, sem a causa na resposta", status == 503 and body["reason"] == "read" and "segredo-da-falha" not in json.dumps(body))
st2.ping = real

# ------------------------------------------------------------------------------ ingestão chegando e não gravando
st3 = ST.Store(f"{tmp}/c.duckdb")
app3 = create_app(st3, TOKEN, tel=Tel(), ready_lock_wait=0.3, ready_max_write_age=0.4)
asyncio.run(call(app3, "/v1/logs", payload(10), method="POST"))
good = st3.write
st3.write = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("disco"))
asyncio.run(call(app3, "/v1/logs", payload(11), method="POST"))
check("uma falha de gravação recente ainda não derruba o readiness", ready(app3)[0] == 200)
time.sleep(0.6)
asyncio.run(call(app3, "/v1/logs", payload(12), method="POST"))
status, body, dt = ready(app3)
check("ingestão chegando e nada gravado além do limite: 503 com o motivo ingest", status == 503 and body["reason"] == "ingest")
st3.write = good
asyncio.run(call(app3, "/v1/logs", payload(13), method="POST"))
check("voltou a gravar: pronto de novo", ready(app3)[0] == 200)

# ------------------------------------------------------------------------------ /healthz não muda
t2 = threading.Thread(target=lambda: (st.lock.acquire(), time.sleep(0.4), st.lock.release())); t2.start(); time.sleep(0.05)
status, body, dt = asyncio.run(call(app, "/healthz", auth=False))
t2.join()
check("/healthz segue só 'ok', mesmo com a trava presa (o healthcheck do container não pode reiniciar por readiness)", status == 200 and body == "ok")
check("/readyz só aceita GET", asyncio.run(call(app, "/readyz", method="POST", auth=False))[0] == 405)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL ' | grep -v "^Traceback\|^  \|^RuntimeError\|^$" || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 14
check_end
