# Funções dos testes do agent-studio (ADR-08, #185), para `source`. Precisa de python3; as dependências (duckdb,
# fastapi, uvicorn) vêm do docker/agent-studio/requirements.txt (hashes fixados), num venv em cache.
# studio_venv: prepara o venv e define STUDIO_PY. studio_start <dir> [env…]: sobe o app em 127.0.0.1 (porta livre),
# DuckDB em <dir>/db.duckdb, e define STUDIO_URL; studio_stop: derruba. studio_sql <db> <sql>: uma linha JSON por
# registro (com o servidor parado: o DuckDB aceita um processo só). post <sinal> <arquivo> [curl args…]: POST com o
# token certo; imprime o código HTTP.
STUDIO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUDIO_ROOT="$(cd "$STUDIO_LIB/../.." && pwd)"
# token só do teste, aleatório a cada execução
STUDIO_TOKEN="$(python3 -c "import secrets; print(secrets.token_hex(16))")"
studio_venv() {
  local req="$STUDIO_ROOT/docker/agent-studio/requirements.txt" h d
  h="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "$req")"
  d="${XDG_CACHE_HOME:-$HOME/.cache}/oute-tests/agent-studio-$h"
  if ! "$d/bin/python" -c 'import duckdb, fastapi, uvicorn' 2>/dev/null; then
    rm -rf "$d"; mkdir -p "$(dirname "$d")"
    if command -v uv >/dev/null; then
      uv venv -q "$d" --python python3 && uv pip install -q --python "$d/bin/python" --require-hashes -r "$req"
    else
      python3 -m venv "$d" && "$d/bin/pip" install -q --require-hashes -r "$req"
    fi || return 1
  fi
  STUDIO_PY="$d/bin/python"
}
studio_start() {
  STUDIO_DIR="$1"; shift; mkdir -p "$STUDIO_DIR"
  local port i
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  env "$@" AGENT_STUDIO_TOKEN="${AGENT_STUDIO_TOKEN-$STUDIO_TOKEN}" AGENT_STUDIO_DB="$STUDIO_DIR/db.duckdb" \
    AGENT_STUDIO_BIND=127.0.0.1 AGENT_STUDIO_PORT="$port" PYTHONPATH="$STUDIO_ROOT/docker/agent-studio" \
    "$STUDIO_PY" "$STUDIO_LIB/agent-studio-run.py" 2>>"$STUDIO_DIR/stderr" & STUDIO_PID=$!
  STUDIO_URL="http://127.0.0.1:$port"
  for i in $(seq 1 100); do
    curl -fsS "$STUDIO_URL/healthz" >/dev/null 2>&1 && return 0
    kill -0 "$STUDIO_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
studio_stop() { [[ -z "${STUDIO_PID:-}" ]] || { kill "$STUDIO_PID" 2>/dev/null; wait "$STUDIO_PID" 2>/dev/null; STUDIO_PID=""; }; }
studio_sql() {
  "$STUDIO_PY" - "$1" "$2" <<'PY'
import json, sys, duckdb
con = duckdb.connect(sys.argv[1], read_only=True)
con.execute("SET TimeZone='UTC'")
# to_json no próprio DuckDB: TIMESTAMPTZ vira texto sem precisar do pytz
for (row,) in con.execute(f"SELECT to_json(t)::VARCHAR FROM ({sys.argv[2]}) t").fetchall():
    print(row)
PY
}
post() {
  local sig="$1" f="$2"; shift 2
  curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $STUDIO_TOKEN" \
    -H 'Content-Type: application/json' --data-binary "@$f" "$@" "$STUDIO_URL/v1/$sig"
}
