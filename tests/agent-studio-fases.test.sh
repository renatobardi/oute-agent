#!/usr/bin/env bash
# Testes do tempo por fase e do nome das threads no agent-studio (#570). A gravação lenta de métricas travava o studio
# sem dizer onde o tempo ia, e as threads eram todas `python`. Agora: (1) cada fase da gravação (espera pela trava,
# `existing`, `INSERT`, gancho do SurrealDB, `COMMIT`) e cada leitura fora da trava reportam o tempo à telemetria;
# (2) fase acima de AGENT_STUDIO_SLOW_S sai como aviso, com teto por tipo; (3) a thread que grava ou lê leva um nome
# (`studio-write`, `studio-<leitura>`) no Python (`py-spy dump`) e no kernel (`top -H`).
# Chama o Store e o Telemetry direto (tests/lib/studio_db.py); sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-fases.test.sh   (sai != 0 se algum caso falhar)
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
import logging, os, sys, threading, time
from agent_studio import config as CF, store as ST, telemetry as TEL
from pycheck import check
from studio_db import StudioDB

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
NOW = time.time_ns()

# ------------------------------------------------------------------------------ fases da gravação
db = StudioDB(tmp, "fases")
db.span(NOW - 60 * SEC, 2, model="claude-sonnet-5", task="t1", conv="c1", input=1000, output=100)
st = db.flush()
seen = []
st.obs = lambda phase, seconds, label=None: seen.append((phase, label, seconds))
row = dict(db.spans[0], dedupe_key="s:novo", span_id="f" * 16)
st.write({"spans": [row]}, before_commit=lambda: None)
phases = [(p, l) for p, l, _ in seen]
check("gravação: reporta a espera pela trava", ("lock_wait", None) in phases)
check("gravação: reporta existing e insert, com a tabela", ("existing", "spans") in phases and ("insert", "spans") in phases)
check("gravação: reporta o gancho do SurrealDB e o commit", ("surreal", None) in phases and ("commit", None) in phases)
check("gravação: as fases vêm na ordem", [p for p, _ in phases] == ["lock_wait", "existing", "insert", "surreal", "commit"])
check("gravação: o tempo é um número não negativo", seen and all(isinstance(s, float) and s >= 0 for _, _, s in seen))
seen.clear()
st.write({"spans": [row]})  # só repetido: nada a inserir, sem gancho
check("só repetidos: não reporta insert nem surreal", [p for p, _ in [(p, l) for p, l, _ in seen]] == ["lock_wait", "existing", "commit"])

# ------------------------------------------------------------------------------ leituras: fase e nome da thread
seen.clear()
names = {}
st.read_free(lambda con: names.update(py=threading.current_thread().name), "tray")
check("leitura: a thread leva o nome studio-tray no Python", names.get("py") == "studio-tray")
check("leitura: reporta read_wait e read, com o nome", [(p, l) for p, l, _ in seen] == [("read_wait", "tray"), ("read", "tray")])
if sys.platform.startswith("linux"):
    got = {}
    def probe(con):
        got["native"] = open(f"/proc/self/task/{threading.get_native_id()}/comm").read().strip()
    st.read_free(probe, "usage")
    check("leitura: a thread leva o nome studio-usage no kernel (top -H)", got["native"] == "studio-usage")
else:
    check("leitura: nome no kernel só no Linux (conferido no CI)", True)
out = {}
def in_write():
    with st.lock:
        pass
th = threading.Thread(target=lambda: st.write({"spans": []}), name="outro")
th.start(); th.join()
check("gravação: a thread de quem grava passa a studio-write", th.name == "studio-write")

# ------------------------------------------------------------------------------ telemetria: histograma e aviso de fase lenta
class Rec:
    def __init__(self): self.calls = []
    def add(self, *a): self.calls.append(("add", a))
    def record(self, v, attrs): self.calls.append(("record", v, attrs))
class Meter:
    def __init__(self): self.made = {}
    def create_counter(self, name, **k): return self.made.setdefault(name, Rec())
    def create_histogram(self, name, **k): return self.made.setdefault(name, Rec())
class Catch(logging.Handler):
    def __init__(self): super().__init__(); self.msgs = []
    def emit(self, r): self.msgs.append(r.getMessage())
m = Meter()
tel = TEL.Telemetry(m, [], 60.0, slow=1.0)
h = m.made["agent_studio.phase.duration"]
catch = Catch(); logging.getLogger("agent_studio").addHandler(catch)
tel.phase("existing", 0.2, "spans")
tel.phase("commit", 0.1)
check("telemetria: o histograma recebe a fase e o rótulo", ("record", 0.2, {"phase": "existing", "label": "spans"}) in h.calls)
check("telemetria: sem rótulo, só a fase", ("record", 0.1, {"phase": "commit"}) in h.calls)
check("telemetria: fase rápida não vira aviso", catch.msgs == [])
tel.phase("existing", 3.0, "metrics"); tel.phase("existing", 4.0, "metrics")
slow = [x for x in catch.msgs if "lento" in x]
check("telemetria: fase acima do limite vira um aviso, com o nome e o tempo", len(slow) == 1 and "existing" in slow[0] and "3.0" in slow[0])
check("telemetria: o aviso tem teto por tipo (o segundo é suprimido)", len(slow) == 1)
check("telemetria: sem endpoint (Noop) a fase não faz nada", TEL.Noop().phase("commit", 9.0) is None)
catch.msgs.clear()
tel.phase("backup", 99.0)
check("telemetria: a cópia de segurança é longa por natureza: vai ao histograma, sem aviso de lento",
      ("record", 99.0, {"phase": "backup"}) in h.calls and catch.msgs == [])
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL ' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 17
check_end
