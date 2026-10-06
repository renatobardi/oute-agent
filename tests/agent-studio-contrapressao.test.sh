#!/usr/bin/env bash
# Testes do limite de ingestões simultâneas no agent-studio (#570, bloco 3). O DuckDB tem um escritor só: os POSTs do
# collector esperavam na trava sem limite, cada um segurando o lote na memória, e respondiam depois que o cliente já
# tinha desistido (o lote era gravado e reenviado mesmo assim). Agora há um número de vagas de ingestão
# (AGENT_STUDIO_INGEST_SLOTS); quem não consegue vaga em AGENT_STUDIO_INGEST_WAIT_S recebe 503 com Retry-After, antes
# de ler o corpo e bem antes do prazo do collector, que retenta da fila em disco. Leituras e /healthz não usam vaga.
# Chama o app pelo ASGI, com uma gravação lenta de mentira; sem servidor de verdade, sem rede e sem Docker.
# Uso: tests/agent-studio-contrapressao.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import asyncio, json, sys, time
from agent_studio import store as ST
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN

tmp = sys.argv[1]
NOW = time.time_ns()

def payload(i):
    return json.dumps({"resourceLogs": [{"resource": {"attributes": []}, "scopeLogs": [{"logRecords": [
        {"timeUnixNano": str(NOW + i), "body": {"stringValue": f"linha {i}"}, "attributes": []}]}]}]}).encode()

async def call(app, path, body=b"", method="POST"):
    msgs, read = [], [0]
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method, "scheme": "http", "path": path,
             "raw_path": path.encode(), "query_string": b"", "root_path": "", "server": ("t", 80), "client": ("t", 1),
             "headers": [(b"authorization", f"Bearer {TOKEN}".encode()), (b"content-type", b"application/json")]}
    async def receive():
        read[0] += 1
        return {"type": "http.request", "body": body, "more_body": False} if read[0] == 1 else {"type": "http.disconnect"}
    async def send(m):
        msgs.append(m)
    t = time.perf_counter()
    await app(scope, receive, send)
    return msgs[0]["status"], dict((k.decode(), v.decode()) for k, v in msgs[0].get("headers", [])), time.perf_counter() - t, read[0]

class Tel:
    def __init__(self): self.warned = []
    def warn(self, kind, *a, **k): self.warned.append(kind)
    def __getattr__(self, name): return lambda *a, **k: None

def slow_store(name, hold):
    st = ST.Store(f"{tmp}/{name}.duckdb")
    real = st.write
    def write(batch, before_commit=None):
        time.sleep(hold)
        return real(batch, before_commit)
    st.write = write
    return st

# ------------------------------------------------------------------------------ uma vaga, espera curta
tel = Tel()
app = create_app(slow_store("a", 0.6), TOKEN, tel=tel, ingest_slots=1, ingest_wait=0.15)
async def two():
    return await asyncio.gather(call(app, "/v1/logs", payload(1)), call(app, "/v1/logs", payload(2)))
r = sorted(asyncio.run(two()), key=lambda x: x[0])
check("uma vaga: a primeira ingestão grava (200)", r[0][0] == 200)
check("uma vaga: a segunda recebe 503 com Retry-After", r[1][0] == 503 and r[1][1].get("retry-after", "").isdigit())
check("uma vaga: a recusa vem no prazo da espera, não depois da gravação lenta", r[1][2] < 0.45)
check("uma vaga: a recusa vira aviso de telemetria (ingest-busy)", "ingest-busy" in tel.warned)
check("uma vaga: depois que a vaga libera, a próxima entra", asyncio.run(call(app, "/v1/logs", payload(3)))[0] == 200)

# ------------------------------------------------------------------------------ a espera cabe: ninguém é recusado
app2 = create_app(slow_store("b", 0.15), TOKEN, tel=Tel(), ingest_slots=1, ingest_wait=5.0)
async def three():
    return await asyncio.gather(*(call(app2, "/v1/logs", payload(10 + i)) for i in range(3)))
check("espera que cabe: três ingestões em fila, todas gravadas", [x[0] for x in asyncio.run(three())] == [200, 200, 200])

# ------------------------------------------------------------------------------ vagas bastam: sem espera
app3 = create_app(slow_store("c", 0.3), TOKEN, tel=Tel(), ingest_slots=3, ingest_wait=0.05)
async def three3():
    return await asyncio.gather(*(call(app3, "/v1/logs", payload(20 + i)) for i in range(3)))
check("três vagas: três ingestões ao mesmo tempo, nenhuma recusada", [x[0] for x in asyncio.run(three3())] == [200, 200, 200])

# ------------------------------------------------------------------------------ o que não usa vaga
app4 = create_app(slow_store("d", 0.6), TOKEN, tel=Tel(), ingest_slots=1, ingest_wait=0.05)
async def mixed():
    w = asyncio.create_task(call(app4, "/v1/logs", payload(30)))
    await asyncio.sleep(0.1)
    h = await call(app4, "/healthz", method="GET")
    u = await call(app4, "/v1/alerts", method="GET")
    return h, u, await w
h, u, w = asyncio.run(mixed())
check("com a vaga ocupada, /healthz responde na hora", h[0] == 200 and h[2] < 0.3)
check("com a vaga ocupada, a leitura não é recusada", u[0] == 200)
check("e a ingestão em andamento termina", w[0] == 200)

# ------------------------------------------------------------------------------ vaga devolvida em toda saída
app5 = create_app(ST.Store(f"{tmp}/e.duckdb"), TOKEN, tel=Tel(), ingest_slots=1, ingest_wait=0.05)
for label, body in (("JSON inválido", b"{nao e json"), ("gravação boa", payload(40))):
    asyncio.run(call(app5, "/v1/logs", body))
check("a vaga volta depois de recusa por JSON inválido e depois de sucesso", asyncio.run(call(app5, "/v1/logs", payload(41)))[0] == 200)
broken = ST.Store(f"{tmp}/f.duckdb")
broken.write = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("disco"))
app6 = create_app(broken, TOKEN, tel=Tel(), ingest_slots=1, ingest_wait=0.05)
s1 = asyncio.run(call(app6, "/v1/logs", payload(50)))[0]
s2 = asyncio.run(call(app6, "/v1/logs", payload(51)))
check("a vaga volta depois de gravação que falha (503 da gravação, não da fila)", s1 == 503 and s2[0] == 503 and s2[2] < 0.04)
check("padrão: sem os parâmetros, 4 vagas", create_app(ST.Store(f"{tmp}/g.duckdb"), TOKEN).state.ingest_slots == 4)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL ' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 13
check_end
