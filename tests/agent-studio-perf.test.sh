#!/usr/bin/env bash
# Testes dos três custos de CPU do agent-studio achados no flamegraph (#570): (1) o DuckDB procurava `pandas` no disco
# a cada execute (não está instalado): a subida põe um sentinela em `sys.modules` e a busca some; (2) o tray e as telas
# refaziam os alertas a cada chamada: com AGENT_STUDIO_READ_TTL_S, o resultado vale por alguns segundos e uma chamada só
# o refaz (as demais esperam e recebem o mesmo); (3) a gravação ia linha a linha (`executemany`, ~1,3 ms por linha, sob a
# trava): agora uma instrução por tabela, com colunas em listas, e o que entra é igual ao de antes.
# Chama o Store direto (tests/lib/studio_db.py); sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-perf.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import importlib.abc, json, sys, threading, time
from agent_studio import store as ST
from pycheck import check

tmp = sys.argv[1]
SEC = 10**9
NOW = time.time_ns()

# ------------------------------------------------------------------------------ (1) pandas
check("pandas: o sentinela está em sys.modules (módulo não instalado)", "pandas" in sys.modules and sys.modules["pandas"] is None)
searched = []
class Spy(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path=None, target=None):
        searched.append(name)
        return None
sys.meta_path.insert(0, Spy())
db = ST.Store(f"{tmp}/pandas.duckdb")
for _ in range(20):
    db.read_free(lambda con: con.execute("SELECT count(*) FROM spans").fetchall(), "t")
check("pandas: o execute não procura mais o pandas no disco", "pandas" not in searched)
check("pandas: o DuckDB segue funcionando", db.read_free(lambda con: con.execute("SELECT 1 + 1").fetchall(), "t") == [(2,)])
sys.meta_path.pop(0)

# ------------------------------------------------------------------------------ (3) gravação em lote
def value(col, typ, i):
    t = typ.split()[0]
    if t == "VARCHAR": return None if i % 7 == 0 and col not in ("dedupe_key", "trace_id", "span_id", "metric_name", "metric_type") else f"{col}-{i}"
    if t == "JSON": return json.dumps({"k": f"{col}-{i}", "n": i, "ç": "é\n\"q\""})
    if t == "UBIGINT": return NOW + i * SEC if col.endswith("unix_nano") else 2**63 + i  # acima do máximo do BIGINT
    if t == "BIGINT": return i * 1000003
    if t == "INTEGER": return i % 5
    if t == "DOUBLE": return i + 0.125
    if t == "BOOLEAN": return i % 2 == 0
    raise AssertionError(f"tipo novo na tabela: {col} {typ}")

def make_rows(table, n, offset=0):
    rows = []
    for i in range(offset, offset + n):
        r = {}
        for col, typ in ST.TABLES[table]:
            if col in ST.DERIVED: continue
            r[col] = value(col, typ, i)
        r["dedupe_key"] = f"{table[0]}:{i}"
        r["time_unix_nano"] = NOW + i * SEC + 422       # com nanossegundos, como o relógio do Linux
        r["received_unix_nano"] = NOW + i * SEC + 7
        rows.append(r)
    return rows

st = ST.Store(f"{tmp}/lote.duckdb")
for table in ST.TABLES:
    rows = make_rows(table, 50)
    got = st.write({table: rows})[table]
    check(f"{table}: 50 linhas novas entram", got == (50, 0))
    got = st.write({table: rows + make_rows(table, 5, 50)})[table]
    check(f"{table}: reenvio ignora as 50 repetidas e grava só as 5 novas", got == (5, 50))
    dup = make_rows(table, 3, 100)
    got = st.write({table: dup + dup})[table]
    check(f"{table}: repetida dentro do próprio lote entra uma vez", got == (3, 3))
    cols = [c for c, _ in ST.TABLES[table]]
    sel = ", ".join(f"epoch_ns({c})" if c in ST.DERIVED else c for c in cols)  # TIMESTAMPTZ -> Python pediria o pytz
    back = {r[0]: dict(zip(cols, r)) for r in st.read_free(lambda con: con.execute(f"SELECT {sel} FROM {table}").fetchall(), "t")}
    check(f"{table}: 58 linhas na tabela", len(back) == 58)
    expect = {r["dedupe_key"]: r for r in rows + make_rows(table, 5, 50) + dup}
    ok = True
    for key, r in expect.items():
        b = back[key]
        for col, typ in ST.TABLES[table]:
            if col in ST.DERIVED:
                ok &= b[col] == r[ST.DERIVED[col]] // 1000 * 1000  # TIMESTAMPTZ guarda microssegundos
            elif typ.startswith("JSON"):
                ok &= b[col] is None if r[col] is None else json.loads(b[col]) == json.loads(r[col])
            else:
                ok &= b[col] == r[col]
    check(f"{table}: cada coluna volta igual ao que entrou (nulos, JSON com acento, UBIGINT grande, horas)", ok)

st2 = ST.Store(f"{tmp}/velocidade.duckdb")
rows = make_rows("metrics", 2000)
t0 = time.perf_counter()
st2.write({"metrics": rows})
dt = time.perf_counter() - t0
check(f"velocidade: 2000 métricas novas em menos de 2 s (antes ~2,6 s num Mac; agora {dt:.2f} s)", dt < 2.0)

# ------------------------------------------------------------------------------ (2) cache de leitura
calls = {"tray": 0, "alerts": 0}
ST.tray_mod.snapshot = lambda con, at_ns, prices, cfg, tz: (calls.__setitem__("tray", calls["tray"] + 1), time.sleep(0.3), {"n": calls["tray"]})[2]
ST.alerts_mod.evaluate = lambda con, at_ns, cfg: (calls.__setitem__("alerts", calls["alerts"] + 1), time.sleep(0.3), {"alerts": [], "n": calls["alerts"]})[2]
cs = ST.Store(f"{tmp}/cache.duckdb")
check("cache: desligado por padrão (TTL 0): cada chamada refaz", (cs.tray(1, None, None), cs.tray(2, None, None)) and calls["tray"] == 2)
cs.read_ttl = 60.0
calls["tray"] = 0
a, b = cs.tray(NOW, None, None), cs.tray(NOW + 5 * SEC, None, None)
check("cache: a segunda chamada dentro do TTL recebe o mesmo resultado, sem refazer", a is b and calls["tray"] == 1)
cs.alerts(NOW, None); cs.alerts(NOW + SEC, None)
check("cache: o mesmo vale para os alertas", calls["alerts"] == 1)
calls["tray"] = 0
cs2 = ST.Store(f"{tmp}/cache2.duckdb"); cs2.read_ttl = 60.0
out = []
threads = [threading.Thread(target=lambda: out.append(cs2.tray(NOW, None, None))) for _ in range(6)]
for t in threads: t.start()
for t in threads: t.join()
check("cache: 6 chamadas ao mesmo tempo refazem uma vez só e todas recebem o resultado", calls["tray"] == 1 and len({id(o) for o in out}) == 1)
cs3 = ST.Store(f"{tmp}/cache3.duckdb"); cs3.read_ttl = 0.2
calls["tray"] = 0
cs3.tray(NOW, None, None); time.sleep(0.5); cs3.tray(NOW, None, None)
check("cache: vencido o TTL, refaz", calls["tray"] == 2)
class Zone:  # fuso diferente = outra entrada
    key = "America/Sao_Paulo"
calls["tray"] = 0
cs4 = ST.Store(f"{tmp}/cache4.duckdb"); cs4.read_ttl = 60.0
cs4.tray(NOW, None, None); cs4.tray(NOW, None, None, Zone())
check("cache: fuso diferente não reaproveita o resultado", calls["tray"] == 2)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL ' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 25
check_end
