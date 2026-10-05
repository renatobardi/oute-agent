#!/usr/bin/env bash
# Testes das leituras fora da trava do escritor no agent-studio (#570). O `/v1/tray` (a cada 15 s), o `/v1/usage`, o
# `/v1/alerts`, as decisões e os repositórios liam sob a mesma trava da ingestão: uma leitura lenta segurava a gravação
# (o collector desistia em 30 s e reenviava o lote) e a gravação lenta segurava o tray. Aqui a trava é segurada à mão,
# como um escritor em andamento, e a leitura tem de responder sem esperar por ela; o resultado é o mesmo de antes; a
# leitura que passa do prazo é interrompida; e o escritor segue exclusivo (duas gravações não se misturam).
# Chama o Store direto (tests/lib/studio_db.py); sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-trava.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init

cat > "$TMP/config.toml" <<'TOML'
[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
cache_read = 0.3
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import sys, threading, time
from agent_studio import config as CF, store as ST
from pycheck import check
from studio_db import StudioDB

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
NOW = time.time_ns()

db = StudioDB(tmp, "trava")
db.span(NOW - 60 * SEC, 2, model="claude-sonnet-5", task="t1", conv="c1", input=1000, output=100)
st = db.flush()

CALLS = {
    "tray": lambda: st.tray(NOW, cfg.prices, cfg.alerts),
    "usage": lambda: st.usage(NOW - 3600 * SEC, NOW + SEC, cfg.prices),
    "alerts": lambda: st.alerts(NOW, cfg.alerts),
    "decisions": lambda: st.decisions(NOW, cfg.alerts),
    "repos": lambda: st.repos(NOW - 3600 * SEC, NOW + SEC),
}
before = {name: fn() for name, fn in CALLS.items()}


def under_writer_lock(fn, wait=5):
    """Roda `fn` numa thread com a trava do escritor ocupada; devolve (terminou, resultado)."""
    out = {}
    t = threading.Thread(target=lambda: out.update(r=fn()), daemon=True)
    with st.lock:
        t.start()
        t.join(wait)
        done = not t.is_alive()
    t.join(wait)
    return done, out.get("r")


for name, fn in CALLS.items():
    done, result = under_writer_lock(fn)
    check(f"{name}: responde com a trava do escritor ocupada", done)
    check(f"{name}: o resultado é o mesmo de antes", result == before[name])

# a leitura que passa do prazo é interrompida (e a trava do escritor não é tocada)
ST.READ_DEADLINE_S = 0.3
t0 = time.time()
try:
    st.read_free(lambda con: con.execute("SELECT count(*) FROM range(100000000000)").fetchall())
    stopped = False
except AttributeError:
    stopped = False
except Exception:
    stopped = True
check("leitura que passa do prazo é interrompida", stopped and time.time() - t0 < 5)

# o escritor segue exclusivo: uma gravação espera a outra
order = []
def writer(tag, hold):
    with st.lock:
        order.append(f"{tag}+")
        time.sleep(hold)
        order.append(f"{tag}-")
a = threading.Thread(target=writer, args=("a", 0.4))
b = threading.Thread(target=writer, args=("b", 0))
a.start(); time.sleep(0.1); b.start(); a.join(); b.join()
check("duas gravações não se misturam", order == ["a+", "a-", "b+", "b-"])
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL ' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 12
check_end
