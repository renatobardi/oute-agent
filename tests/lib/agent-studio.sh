# Funções dos testes do agent-studio (ADR-08, #185), para `source` depois do tests/lib/check.sh (usa o die).
# Precisa de python3; as dependências (duckdb, fastapi, uvicorn) vêm do docker/agent-studio/requirements.txt (hashes
# fixados), num venv em cache. As credenciais do agent-studio do ambiente saem: vale o token do teste (STUDIO_TOKEN),
# que sobe como credencial de ingestão; sem AGENT_STUDIO_READ_TOKEN nos [env…] do studio_start, ele também lê (uma
# credencial só, #256).
# studio_init: confere jq, python3 e curl e prepara o venv (studio_venv, que define STUDIO_PY); sem eles, sai com 1.
# studio_start <dir> [env…]: sobe o app em 127.0.0.1 (porta livre), DuckDB em <dir>/db.duckdb, e define STUDIO_URL;
# espera o health por STARTUP_TIMEOUT e, se o processo morre antes (porta tomada), tenta outra, até START_TRIES
# (tests/lib/parallel.sh, que também monta o venv no cache sem corrida entre testes em paralelo, #336);
# studio_stop: derruba. studio_sql <db> <sql>: uma linha JSON por registro (com o servidor parado: o DuckDB aceita um
# processo só). post <sinal> <arquivo> [curl args…]: POST com o token certo; imprime o código HTTP.
# code [curl args…]: só o código HTTP. hdr <nome> [curl args…]: o valor de um cabeçalho da resposta, sem \r.
# data: HTML (stdin) -> JSON dos elementos com data-* (tests/lib/html-data.py). enc <texto>: para a query string.
# usd <filtro jq>: filtro jq do valor em micro-dólar inteiro. studio_prices <arquivo>: tabela de preços de exemplo.
# compose_service <serviço>: o bloco do serviço no docker/compose.yaml.
# studio_oute_funcs: as funções do agent-studio do scripts/oute (o script inteiro roda o case no fim).
# studio_oute_up <fim> [VAR=valor…]: roda o agent_studio_up dessas funções (em $FUNCS) num ambiente só com as VAR dadas
# (HOME e ROOT = $TMP, de onde sai o .env) e depois o trecho <fim>, que imprime o que o teste confere; define OUT e RC.
STUDIO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUDIO_ROOT="$(cd "$STUDIO_LIB/../.." && pwd)"
. "$STUDIO_LIB/parallel.sh"
# token só do teste, aleatório a cada execução
STUDIO_TOKEN="$(python3 -c "import secrets; print(secrets.token_hex(16))")"
# o token do teste, nunca um do ambiente (dentro do container, o agent.env traz o de verdade)
unset AGENT_STUDIO_TOKEN AGENT_STUDIO_INGEST_TOKEN AGENT_STUDIO_READ_TOKEN
studio_init() {
  command -v jq >/dev/null && command -v python3 >/dev/null && command -v curl >/dev/null || die "precisa de jq, python3 e curl"
  studio_venv || die "não montei o venv do agent-studio (docker/agent-studio/requirements.txt)"
}
studio_venv() {
  local req="$STUDIO_ROOT/docker/agent-studio/requirements.txt" h d
  h="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "$req")"
  d="$(cache_dir)/agent-studio-$h"
  cache_publish "$d" studio_venv_ok studio_venv_build "$req" || return 1
  STUDIO_PY="$d/bin/python"
}
studio_venv_ok() { "$1/bin/python" -c 'import duckdb, fastapi, uvicorn' 2>/dev/null; }
studio_venv_build() {
  local d="$1" req="$2"
  if command -v uv >/dev/null; then
    uv venv -q "$d" --python python3 && uv pip install -q --only-binary :all: --python "$d/bin/python" --require-hashes -r "$req"
  else
    python3 -m venv "$d" && "$d/bin/pip" install -q --only-binary :all: --require-hashes -r "$req"
  fi
}
studio_health() { curl -fsS --max-time 2 "http://127.0.0.1:$1/healthz"; }
studio_launch() {
  env ${STUDIO_ENV[@]+"${STUDIO_ENV[@]}"} AGENT_STUDIO_INGEST_TOKEN="${AGENT_STUDIO_INGEST_TOKEN-$STUDIO_TOKEN}" AGENT_STUDIO_DB="$STUDIO_DIR/db.duckdb" \
    AGENT_STUDIO_BIND=127.0.0.1 AGENT_STUDIO_PORT="$1" PYTHONPATH="$STUDIO_ROOT/docker/agent-studio" \
    "$STUDIO_PY" "$STUDIO_LIB/agent-studio-run.py" 2>>"$STUDIO_DIR/stderr" & SPAWN_PID=$! STUDIO_PID=$!
}
studio_start() {
  STUDIO_DIR="$1"; shift; mkdir -p "$STUDIO_DIR"
  STUDIO_ENV=("$@")
  spawn_try "$START_TRIES" "" studio_launch studio_health || return 1
  STUDIO_URL="http://127.0.0.1:$SPAWN_PORT"
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
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
hdr() { local name="$1"; shift; curl -s -o /dev/null -D - "$@" | tr -d '\r' | grep -i "^$name:" | sed 's/^[^:]*: *//'; }
data() { python3 "$STUDIO_LIB/html-data.py"; }
enc() { jq -rn --arg s "$1" '$s | @uri'; }
# dinheiro em micro-dólar inteiro: compara float sem erro de arredondamento (número da API ou texto de um data-*)
usd() { printf '(%s | tonumber * 1e6 | round)' "$1"; }
studio_prices() {
  cat > "$1" <<'EOF'
[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
[prices."gpt-5-codex"]
input = 1.25
output = 10.0
cache_read = 0.125
EOF
}
# nome <id>: o nome amigável da conversa (#530), pela mesma função do agent-studio
nome() {
  local id="$1"
  PYTHONPATH="$STUDIO_ROOT/docker/agent-studio" python3 -c 'import sys; from agent_studio.names import friendly; print(friendly(sys.argv[1]))' "$id"
  return $?
}
compose_service() { awk -v s="  $1:" '$0 == s {on=1; print; next} on && /^  [a-z]/ {exit} on {print}' "$STUDIO_ROOT/docker/compose.yaml"; }
studio_oute_funcs() { sed -n '/^# --- agent-studio (ADR-08/,/^legacy_cleanup()/p' "$STUDIO_ROOT/scripts/oute" | sed '$d'; }
studio_oute_up() {
  local fim="$1"; shift
  OUT="$(cd "$TMP" && env -i PATH="$PATH" HOME="$TMP" "$@" bash -c "set -euo pipefail; ROOT=$TMP; AGENT_ENV_FILE=~/.oute/agent.env
  SERVICES_ENV_FILE=~/.oute/services.env; SERVICES_FOLDER=oute-services
  env_get() { sed -n \"s/^[[:space:]]*\$1=//p\" \"\$ROOT/.env\" 2>/dev/null | tail -1; }
  $FUNCS"$'\n'"agent_studio_up; $fim" 2>&1)"; RC=$?
}
