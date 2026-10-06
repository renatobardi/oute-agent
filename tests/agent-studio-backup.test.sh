#!/usr/bin/env bash
# Testes da cópia de segurança do DuckDB do agent-studio (#570). O agent-studio guarda tudo, sem retenção, e é o único
# processo que abre o arquivo: a cópia sai de dentro dele (`ATTACH` + `COPY FROM DATABASE` num cursor próprio), é um
# retrato consistente e não segura a ingestão. `POST /v1/backup` (credencial de ingestão) grava em `<pasta do banco>/backup/`,
# uma por vez, e o `python -m agent_studio.backup` é o cliente que o `oute studio backup` roda no container; com
# `--check`, abre uma cópia (stdin) só para leitura e conta as linhas.
# Chama o Store e o app pelo ASGI (tests/lib/studio_asgi.py); sem servidor de verdade, sem rede e sem Docker.
# Uso: tests/agent-studio-backup.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import contextlib, http.server, io, json, os, sys, threading, time
import duckdb
from agent_studio import backup as BK, store as ST
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, raw_get
from studio_db import StudioDB

tmp = sys.argv[1]
SEC = 10**9
NOW = time.time_ns()

def filled(name, n=400):
    db = StudioDB(tmp, name)
    for i in range(n):
        db.span(NOW - i * SEC, 1, model="m", task=f"t{i % 7}", conv=f"c{i % 5}", input=10, output=1)
        db.log(NOW - i * SEC, "evento", {"i": i}, conv=f"c{i % 5}")
    return db, db.flush()

def counts(path):
    con = duckdb.connect(path, read_only=True)
    try:
        return {t: con.execute(f"SELECT count(*) FROM {t}").fetchone()[0] for t in ST.TABLES}
    finally:
        con.close()

# ------------------------------------------------------------------------------ Store.backup
db, st = filled("a")
seen = []
st.obs = lambda phase, seconds, label=None: seen.append(phase)
dest = f"{tmp}/a-copia.duckdb"
names = {}
orig = ST.name_thread
ST.name_thread = lambda label: (names.setdefault("n", label), orig(label))[1]
rows = st.backup(dest)
ST.name_thread = orig
check("cópia: devolve as linhas de cada tabela", rows == {"spans": 400, "logs": 400, "metrics": 0})
check("cópia: o arquivo abre sozinho, só leitura, com as mesmas linhas", counts(dest) == rows)
con = duckdb.connect(dest, read_only=True)
pk = {r[0] for r in con.execute("SELECT table_name FROM duckdb_constraints() WHERE constraint_type = 'PRIMARY KEY'").fetchall()}
con.close()
check("cópia: mantém a chave primária das tabelas de fatos", {"spans", "logs", "metrics"} <= pk)
check("cópia: reporta a fase backup e nomeia a thread", "backup" in seen and names.get("n") == "studio-backup")
check("cópia: o banco vivo segue gravando depois", st.write({"spans": [dict(db.spans[0], dedupe_key="s:depois")]})["spans"] == (1, 0))
try:
    st.backup(dest); again = "sem erro"
except FileExistsError:
    again = "recusou"
check("cópia: não escreve por cima de um arquivo que já existe", again == "recusou")
try:
    st.backup(f"{tmp}/pasta-que-nao-existe/x.duckdb"); bad = "sem erro"
except Exception:
    bad = "falhou"
check("cópia: destino impossível falha e não deixa resto", bad == "falhou" and not os.path.exists(f"{tmp}/pasta-que-nao-existe"))
check("cópia: depois da falha, a próxima funciona", st.backup(f"{tmp}/a-copia2.duckdb")["spans"] == 401)
st._backup_lock.acquire()
try:
    st.backup(f"{tmp}/a-copia3.duckdb"); busy = "sem erro"
except ST.BackupBusy:
    busy = "ocupado"
finally:
    st._backup_lock.release()
check("cópia: uma por vez (a segunda recebe BackupBusy)", busy == "ocupado" and not os.path.exists(f"{tmp}/a-copia3.duckdb"))

# gravações durante a cópia não falham nem esperam por ela
db2, st2 = filled("b", 3000)
stop, lat, err, n = threading.Event(), [], [], [0]
def writer():
    while not stop.is_set():
        n[0] += 1
        t = time.perf_counter()
        try:
            st2.write({"spans": [dict(db2.spans[0], dedupe_key=f"s:w{n[0]}-{i}", span_id=f"{n[0]:08x}{i:08x}") for i in range(50)]})
        except Exception as e:  # noqa: BLE001
            err.append(repr(e)); return
        lat.append(time.perf_counter() - t)
w = threading.Thread(target=writer); w.start(); time.sleep(0.2)
before = st2.read_free(lambda c: c.execute("SELECT count(*) FROM spans").fetchone()[0], "t")
got = st2.backup(f"{tmp}/b-copia.duckdb")
time.sleep(0.2); stop.set(); w.join()
after = st2.read_free(lambda c: c.execute("SELECT count(*) FROM spans").fetchone()[0], "t")
check("concorrência: nenhuma gravação falha durante a cópia", err == [] and len(lat) > 0)
check("concorrência: a cópia é um retrato entre o antes e o depois", before <= got["spans"] <= after and counts(f"{tmp}/b-copia.duckdb")["spans"] == got["spans"])
check("concorrência: gravação não espera a cópia (pior caso abaixo de 2 s)", max(lat) < 2.0)

# ------------------------------------------------------------------------------ POST /v1/backup
db3, st3 = filled("c", 50)
app = create_app(st3, TOKEN)
bdir = f"{tmp}/backup"
os.makedirs(bdir, exist_ok=True)
open(f"{bdir}/agent-studio-20260101T000000Z.duckdb", "w").write("resto de uma cópia antiga")
open(f"{bdir}/outro-arquivo.txt", "w").write("não é cópia")
status, body = raw_get(app, "/v1/backup", method="POST")
out = json.loads(body) if status == 200 else {}
check("rota: 200 com o nome, o tamanho, o tempo e as linhas", status == 200 and out.get("rows") == {"spans": 50, "logs": 50, "metrics": 0}
      and out.get("bytes", 0) > 0 and isinstance(out.get("seconds"), float) and out.get("file", "").startswith("agent-studio-"))
check("rota: o arquivo fica em <pasta do banco>/backup/, com o tamanho dito", os.path.getsize(f"{bdir}/{out.get('file', 'x')}") == out.get("bytes"))
check("rota: a cópia antiga some, o que não é cópia fica", not os.path.exists(f"{bdir}/agent-studio-20260101T000000Z.duckdb") and os.path.exists(f"{bdir}/outro-arquivo.txt"))
check("rota: GET não existe", raw_get(app, "/v1/backup")[0] == 405)
# o raw_get manda sempre o Bearer do TOKEN: o app é que muda de credencial
check("rota: credencial errada = 401", raw_get(create_app(st3, "outra-" + TOKEN), "/v1/backup", method="POST")[0] == 401)
check("rota: credencial de leitura = 403 (quem lê não copia o banco)",
      raw_get(create_app(st3, "ingestao-" + TOKEN, read_token=TOKEN), "/v1/backup", method="POST")[0] == 403)
check("rota: recusada, nenhuma cópia nova aparece", len([f for f in os.listdir(bdir) if f.endswith(".duckdb")]) == 1)
st3._backup_lock.acquire()
status, body = raw_get(app, "/v1/backup", method="POST")
st3._backup_lock.release()
check("rota: cópia em andamento = 409", status == 409)

# ------------------------------------------------------------------------------ cliente (python -m agent_studio.backup)
def run(argv, stdin=b""):
    out, errs = io.StringIO(), io.StringIO()
    old = sys.stdin
    sys.stdin = io.TextIOWrapper(io.BytesIO(stdin))
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(errs):
            rc = BK.main(argv)
    finally:
        sys.stdin = old
    return rc, out.getvalue(), errs.getvalue()

class Stub(http.server.BaseHTTPRequestHandler):
    reply = (200, {"file": "agent-studio-x.duckdb", "bytes": 5, "seconds": 0.1, "rows": {"spans": 1}})
    seen = {}
    def do_POST(self):
        Stub.seen = {"path": self.path, "auth": self.headers.get("Authorization")}
        code, payload = Stub.reply
        data = json.dumps(payload).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), Stub)
threading.Thread(target=srv.serve_forever, daemon=True).start()
os.environ["AGENT_STUDIO_PORT"] = str(srv.server_address[1])
os.environ["AGENT_STUDIO_INGEST_TOKEN"] = "segredo-do-teste"
rc, o, e = run([])
check("cliente: pede a cópia com a credencial do ambiente e imprime a resposta", rc == 0 and json.loads(o)["file"] == "agent-studio-x.duckdb"
      and Stub.seen == {"path": "/v1/backup", "auth": "Bearer segredo-do-teste"})
check("cliente: a credencial nunca vai à saída", "segredo-do-teste" not in o + e)
Stub.reply = (409, {"message": "cópia em andamento"})
rc, o, e = run([])
check("cliente: 409 sai com código 3 e o motivo", rc == 3 and "andamento" in e)
Stub.reply = (503, {"message": "x"})
rc, o, e = run([])
check("cliente: outra falha sai com código 1", rc == 1 and o == "")
os.environ["AGENT_STUDIO_INGEST_TOKEN"] = ""
os.environ.pop("AGENT_STUDIO_TOKEN", None)
check("cliente: sem credencial não chama o serviço", run([])[0] == 2)
srv.shutdown()

good = open(f"{tmp}/a-copia.duckdb", "rb").read()
rc, o, e = run(["--check"], good)
check("--check: cópia boa imprime as linhas e sai com 0", rc == 0 and json.loads(o)["rows"] == {"spans": 400, "logs": 400, "metrics": 0})
rc, o, e = run(["--check"], b"isto nao e um banco" * 100)
check("--check: arquivo que não é um banco sai com 1, sem o conteúdo na saída", rc == 1 and "isto nao e" not in o + e)
rc, o, e = run(["--check"], b"")
check("--check: vazio sai com 1", rc == 1)
leftover = [f for f in os.listdir(BK.tempfile.gettempdir()) if f.startswith("agent-studio-check-")]
check("--check: não deixa arquivo temporário", leftover == [])
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL ' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 29
check_end
