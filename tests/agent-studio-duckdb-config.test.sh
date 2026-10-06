#!/usr/bin/env bash
# Testes da configuração explícita do DuckDB e do parse fora do laço de eventos no agent-studio (#570, bloco 5).
# (1) O app não configurava o DuckDB: o `memory_limit` padrão é 80% da memória do container (4,7 GiB de 6g), que somado ao
# heap do Python cabe mal no limite; e o `checkpoint_threshold` padrão de 16 MiB faz um checkpoint a cada poucos minutos,
# que é o que deixava o COMMIT lento (6 a 7 s no disco do oute-server). Agora o Store aplica `memory_limit`, `threads` e
# `checkpoint_threshold`, com padrão no código e troca por variável de ambiente, e recusa valor fora do formato.
# (2) O parse do lote (descompressão, JSON, linhas) rodava no laço de eventos: um lote grande congelava todas as rotas.
# Agora roda no threadpool, e as recusas (JSON inválido, corpo grande demais) seguem com o mesmo código.
# Chama o Store e o app pelo ASGI; sem servidor de verdade, sem rede e sem Docker.
# Uso: tests/agent-studio-duckdb-config.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import asyncio, gzip, json, sys, threading, time
from agent_studio import app as APP, store as ST
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN

tmp = sys.argv[1]

def setting(st, name):
    return st.read_free(lambda c: c.execute("SELECT current_setting(?)", [name]).fetchone()[0], "t")

# ------------------------------------------------------------------------------ (1) configuração do DuckDB
st = ST.Store(f"{tmp}/padrao.duckdb")
check("padrão: memory_limit de 3 GB (abaixo dos 6g do container, com folga para o Python)", setting(st, "memory_limit") in ("2.7 GiB", "3.0 GiB", "2.8 GiB"))
check("padrão: 2 threads", setting(st, "threads") == 2)
check("padrão: checkpoint_threshold de 256 MB (um checkpoint por dia, não um a cada poucos minutos)", setting(st, "checkpoint_threshold") in ("244.1 MiB", "256.0 MiB"))
st2 = ST.Store(f"{tmp}/outro.duckdb", settings={"memory_limit": "1GB", "threads": "3", "checkpoint_threshold": "64MB"})
check("valores passados trocam os três", setting(st2, "threads") == 3 and setting(st2, "memory_limit").startswith(("953", "1.0", "1000"))
      and setting(st2, "checkpoint_threshold").startswith(("61", "64")))
check("a configuração vale também nas leituras fora da trava (cursor próprio)", setting(st2, "threads") == 3)
for bad in ({"memory_limit": "3GB'; DROP TABLE spans; --"}, {"threads": "0"}, {"threads": "muitas"}, {"checkpoint_threshold": "grande"}, {"memory_limit": ""}, {"outra": "1"}):
    try:
        ST.Store(f"{tmp}/ruim-{len(str(bad))}.duckdb", settings=bad); got = "aceitou"
    except ValueError:
        got = "recusou"
    check(f"valor fora do formato é recusado: {bad}", got == "recusou")
env = {"AGENT_STUDIO_DUCKDB_MEMORY": "2GB", "AGENT_STUDIO_DUCKDB_THREADS": "4", "AGENT_STUDIO_DUCKDB_CHECKPOINT": "512MB", "OUTRA": "x"}
check("ambiente: as três variáveis viram a configuração", ST.settings_from_env(env) == {"memory_limit": "2GB", "threads": "4", "checkpoint_threshold": "512MB"})
check("ambiente: sem variável, nada é trocado (valem os padrões do código)", ST.settings_from_env({}) == {})
check("ambiente: variável vazia não troca", ST.settings_from_env({"AGENT_STUDIO_DUCKDB_THREADS": ""}) == {})

# ------------------------------------------------------------------------------ (2) parse fora do laço de eventos
async def post(app, path, body, headers=()):
    msgs = []
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST", "scheme": "http", "path": path,
             "raw_path": path.encode(), "query_string": b"", "root_path": "", "server": ("t", 80), "client": ("t", 1),
             "headers": [(b"authorization", f"Bearer {TOKEN}".encode()), (b"content-type", b"application/json"), *headers]}
    sent = [False]
    async def receive():
        if sent[0]:
            return {"type": "http.disconnect"}
        sent[0] = True
        return {"type": "http.request", "body": body, "more_body": False}
    async def send(m):
        msgs.append(m)
    await app(scope, receive, send)
    return msgs[0]["status"], dict((k.decode(), v.decode()) for k, v in msgs[0].get("headers", []))

where = {}
real = APP.SIGNALS["logs"]
def spy(payload, received_ns):
    where["thread"] = threading.current_thread()
    where["loop"] = None
    try:
        where["loop"] = asyncio.get_running_loop()
    except RuntimeError:
        pass
    return real[0](payload, received_ns)
APP.SIGNALS["logs"] = (spy, real[1])
st3 = ST.Store(f"{tmp}/parse.duckdb")
seen = []
class Tel:
    def __getattr__(self, name):
        return (lambda phase, seconds, label=None: seen.append((phase, label))) if name == "phase" else (lambda *a, **k: None)
app = create_app(st3, TOKEN, tel=Tel())
NOW = time.time_ns()
payload = {"resourceLogs": [{"resource": {"attributes": [{"key": "host.name", "value": {"stringValue": "h"}}]},
           "scopeLogs": [{"logRecords": [{"timeUnixNano": str(NOW), "body": {"stringValue": "oi"}, "attributes": []}]}]}]}
status, headers = asyncio.run(post(app, "/v1/logs", json.dumps(payload).encode()))
check("ingestão: o lote entra (200, 1 gravado)", status == 200 and headers.get("x-agent-studio-written") == "1")
check("ingestão: o parse roda fora da thread do laço de eventos", where.get("thread") is not None and where["thread"] is not threading.main_thread())
check("ingestão: e sem laço de eventos naquela thread (não bloqueia as outras rotas)", where.get("loop") is None)
check("ingestão: a fase parse segue sendo medida, com o sinal", ("parse", "logs") in seen)
status, headers = asyncio.run(post(app, "/v1/logs", gzip.compress(json.dumps(payload).encode()), [(b"content-encoding", b"gzip")]))
check("ingestão: gzip segue aceito e o reenvio é repetido", status == 200 and headers.get("x-agent-studio-duplicate") == "1")
APP.SIGNALS["logs"] = real
check("recusa: JSON inválido segue 400", asyncio.run(post(app, "/v1/logs", b"{nao e json"))[0] == 400)
check("recusa: gzip corrompido segue 400", asyncio.run(post(app, "/v1/logs", b"lixo", [(b"content-encoding", b"gzip")]))[0] == 400)
old = APP.MAX_BODY
APP.MAX_BODY = 10
check("recusa: corpo acima do limite segue 413", asyncio.run(post(app, "/v1/logs", json.dumps(payload).encode()))[0] == 413)
APP.MAX_BODY = old
check("recusa: nada das recusas foi gravado", st3.read_free(lambda c: c.execute("SELECT count(*) FROM logs").fetchone()[0], "t") == 1)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL ' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 23
check_end
