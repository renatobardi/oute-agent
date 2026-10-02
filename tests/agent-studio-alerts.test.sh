#!/usr/bin/env bash
# Testes do `GET /v1/alerts` do agent-studio (#204, ADR-08 §8): fila > 50%, destino recusando, host sem dado e spool
# perto de 50 MB, cada um ligando e desligando; o Mac parado não alerta; a linha "Dropping data" não conta; a cota
# (#55) prevista e desligada. O DuckDB de exemplo nasce pela ingestão de verdade (POST /v1/metrics e /v1/logs), com
# uma linha do tempo em volta de AT; a consulta roda com `at=` em vários pontos dela. Sem Docker.
# Uso: tests/agent-studio-alerts.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init

# ---------------------------------------------------------------- DuckDB de exemplo
# AT = 2025-09-28T12:00:00Z. oute-server (sempre ligado) manda métricas do collector de 5 em 5 min de AT-120m a
# AT+40m; oute-mac (não é sempre ligado) para em AT-60m.
AT=1759060800
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$AT" <<'PY'
import json, sys
from otlp_json import kv
tmp, AT = sys.argv[1], int(sys.argv[2])
M = 60
MiB = 2**20
def ns(t): return str(int(t * 1e9))
res = lambda host: {"host.name": host, "oute.instance": "oute-agent", "service.name": "otelcol-contrib"}
def gauge(name, pts, off=0):  # pts = [(t, valor, atributos)]; off = deslocamento em ns
    return {"name": name, "gauge": {"dataPoints": [
        {"timeUnixNano": str(t * 10**9 + off), "asInt": str(x), "attributes": kv(a)} for t, x, a in pts]}}
# como no collector real (0.161.0): a capacidade da mesma coleta sai uns µs antes do tamanho, nunca na mesma hora
CAP_OFF = -12640
def counter(name, pts, temporality=2):  # pts = [(t, start, valor, atributos)]
    return {"name": name, "sum": {"isMonotonic": True, "aggregationTemporality": temporality, "dataPoints": [
        {"timeUnixNano": ns(t), "startTimeUnixNano": ns(s), "asInt": str(x), "attributes": kv(a)} for t, s, x, a in pts]}}
def rm(host, metrics, extra=None):
    return {"resource": {"attributes": kv({**res(host), **(extra or {})})}, "scopeMetrics": [{"metrics": metrics}]}

STUDIO_LOGS, S3_LOGS = {"exporter": "otlp_http/studio_logs"}, {"exporter": "awss3/logs"}
STUDIO_TRACES, S3_TRACES = {"exporter": "otlp_http/studio_traces"}, {"exporter": "awss3/traces"}
CAP = 629145600
server_times = [AT + m * M for m in range(-120, 41, 5)] + [AT - 1 * M, AT + 2 * M]
server_times.sort()
def ratio(t):
    if t <= AT - 10 * M: return 0.3
    if t <= AT - 5 * M: return 0.6
    if t <= AT: return 0.7
    return 0.2
size, cap = [], []
for t in server_times:
    size += [(t, int(CAP * ratio(t)), STUDIO_LOGS), (t, int(CAP * 0.1), S3_LOGS)]
    cap += [(t, CAP, STUDIO_LOGS), (t, CAP, S3_LOGS)]
# send_failed: 0 até AT-15m, 3 em AT-10m, 5 de AT-5m em diante; o collector reinicia em AT+38m e manda 2 em AT+40m
START1, START2 = AT - 3 * 3600, AT + 38 * M
def failed(t):
    if t <= AT - 15 * M: return 0
    if t <= AT - 10 * M: return 3
    return 5
sf = [(t, START1, failed(t), STUDIO_TRACES) for t in server_times if t < START2]
sf += [(AT + 40 * M, START2, 2, STUDIO_TRACES)]
# awss3/traces: 7 parado desde antes da janela lida (sem subida)
sf += [(t, AT - 10 * 3600, 7, S3_TRACES) for t in server_times]
# cota (#55, prevista): Claude em 95% na janela de 5h, Codex em 50%
quota = [
    rm("oute-server", [gauge("oute.quota.used_pct", [(AT - M, 95, {"oute.quota.window": "5h"})])], {"oute.agent": "claude"}),
    rm("oute-server", [gauge("oute.quota.used_pct", [(AT - M, 50, {"oute.quota.window": "5h"})])], {"oute.agent": "codex"}),
]
# Mac: fila a 90% e última métrica em AT-60m
mac_t = [AT - 65 * M, AT - 60 * M]
mac = rm("oute-mac", [gauge("otelcol_exporter_queue_size", [(t, int(CAP * 0.9), STUDIO_LOGS) for t in mac_t]),
                      gauge("otelcol_exporter_queue_capacity", [(t, CAP, STUDIO_LOGS) for t in mac_t], CAP_OFF)])
metrics = {"resourceMetrics": [
    rm("oute-server", [gauge("otelcol_exporter_queue_size", size), gauge("otelcol_exporter_queue_capacity", cap, CAP_OFF),
                       counter("otelcol_exporter_send_failed_spans", sf)]),
    mac, *quota,
]}
json.dump(metrics, open(f"{tmp}/metrics.json", "w"))

# eventos do oute-emit com o estado do spool; o Mac com o spool em 48 MiB e a linha "Dropping data" do collector
n = 0
def ev(t, name, b, d):
    global n; n += 1
    return {"timeUnixNano": ns(t), "severityNumber": 9, "eventName": name, "body": {"stringValue": name},
            "attributes": kv({"oute.event.id": f"ev-{n}", "event.name": name,
                              "oute.emit.spool.bytes": b, "oute.emit.spool.dropped": d})}
def rl(host, service, recs):
    return {"resource": {"attributes": kv({"host.name": host, "oute.instance": "oute-agent", "service.name": service})},
            "scopeLogs": [{"logRecords": recs}]}
drop = {"timeUnixNano": ns(AT - 60 * M), "severityNumber": 17, "severityText": "ERROR",
        "body": {"stringValue": "Exporting failed. Dropping data."},
        "attributes": kv({"otelcol.component.id": "otlp_http/studio_logs", "dropped_items": 500})}
logs = {"resourceLogs": [
    rl("oute-server", "oute", [ev(AT - 30 * M, "oute.canal.proposed", 1 * MiB, 4),
                               ev(AT - 20 * M, "oute.canal.proposed", 45 * MiB, 4),
                               ev(AT - 10 * M, "oute.canal.decided", 46 * MiB, 4),
                               ev(AT + 10 * M, "oute.canal.proposed", 2 * MiB, 7)]),
    rl("oute-mac", "oute", [ev(AT - 61 * M, "oute.swarm.spawn", 48 * MiB, 0)]),
    rl("oute-mac", "otelcol-contrib", [drop]),
]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
PY
cat > "$TMP/config.toml" <<'EOF'
[alerts]
always_on_hosts = ["oute-server", "oute-nunca"]
spool_dropped_window_minutes = 20
queue_max_ratio = 2
foo = 1
EOF

studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/config.toml" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
check "ingestão: métricas = 200"                       test "$(post metrics "$TMP/metrics.json")" = 200
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200

A=(-H "Authorization: Bearer $STUDIO_TOKEN")
iso() { python3 -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
# at <minutos a partir de AT>: resposta do /v1/alerts naquela hora
at() { curl -s "${A[@]}" "$STUDIO_URL/v1/alerts?at=$(iso $((AT + $1 * 60)))"; }
T() { iso $((AT + $1 * 60)); }
# sel <tipo> [host]: os alertas daquele tipo (e host)
sel() { printf '[.alerts[] | select(.type == "%s"%s)]' "$1" "${2:+ and .host == \"$2\"}"; }

# ---------------------------------------------------------------- 1. token, método e `at`
check "sem token: 401"                                 test "$(code "$STUDIO_URL/v1/alerts")" = 401
check "token errado: 401"                              test "$(code -H "Authorization: Bearer ${STUDIO_TOKEN}x" "$STUDIO_URL/v1/alerts")" = 401
check "com token, sem at (agora): 200"                 test "$(code "${A[@]}" "$STUDIO_URL/v1/alerts")" = 200
check "at inválido: 400"                               test "$(code "${A[@]}" "$STUDIO_URL/v1/alerts?at=ontem")" = 400
check "at antes de 1970: 400"                          test "$(code "${A[@]}" "$STUDIO_URL/v1/alerts?at=1900-01-01")" = 400
check "POST no /v1/alerts: 405 (só leitura)"           test "$(code -X POST "${A[@]}" "$STUDIO_URL/v1/alerts")" = 405

R0="$(at 0)"
echo "$R0" > "$TMP/at0.json"
check "resposta: at, alerts, hosts, checks e config"   jqe --arg t "$(T 0)" '.at == $t and (.alerts | type == "array") and (.hosts | type == "array") and .checks.queue and (.config | has("errors"))' <<<"$R0"
check "config: chave desconhecida e valor inválido avisados" jqe '[.config.errors[] | select(test("foo") or test("queue_max_ratio"))] | length == 2' <<<"$R0"
check "cada alerta: host, tipo, valor, desde e evidência" jqe '.alerts | length > 0 and all(has("host") and has("type") and has("value") and has("since") and has("evidence") and has("limit"))' <<<"$R0"

# ---------------------------------------------------------------- 2. fila > 50%
check "fila liga: 0,7 em studio_logs do oute-server desde AT-5m" jqe --arg s "$(T -5)" "$(sel queue oute-server)"' | length == 1 and (.[0] | .value == 0.7 and .since == $s and .limit == 0.5 and .evidence.exporter == "otlp_http/studio_logs" and .evidence.capacity == 629145600)' <<<"$R0"
check "fila: awss3/logs a 10% não alerta"              jqe "$(sel queue)"' | all(.evidence.exporter != "awss3/logs")' <<<"$R0"
check "fila: 0,6 em AT-5m já liga (valor inválido do config = padrão 0,5)" jqe "$(sel queue oute-server) | length == 1" <<<"$(at -5)"
check "fila: 0,3 em AT-10m não liga"                   jqe "$(sel queue oute-server) | length == 0" <<<"$(at -10)"
check "fila desliga: 0,2 em AT+2m"                     jqe "$(sel queue oute-server) | length == 0" <<<"$(at 3)"

# ---------------------------------------------------------------- 3. destino recusando
check "recusa liga: send_failed subiu 5 desde AT-10m"  jqe --arg s "$(T -10)" --arg l "$(T -5)" "$(sel destination_refusing oute-server)"' | length == 1 and (.[0] | .value == 5 and .since == $s and .evidence.exporter == "otlp_http/studio_traces" and .evidence.metrics == ["otelcol_exporter_send_failed_spans"] and .evidence.last_rise == $l)' <<<"$R0"
check "recusa: contador parado (awss3/traces em 7) não alerta" jqe "$(sel destination_refusing) | all(.evidence.exporter != \"awss3/traces\")" <<<"$R0"
check "recusa: ainda ligada 14 min depois da subida"   jqe "$(sel destination_refusing oute-server) | length == 1" <<<"$(at 9)"
check "recusa desliga: 15 min sem subir"               jqe "$(sel destination_refusing oute-server) | length == 0" <<<"$(at 25)"
check "recusa: reinício do collector conta desde o zero" jqe --arg s "$(T 40)" "$(sel destination_refusing oute-server)"' | length == 1 and .[0].value == 2 and .[0].since == $s' <<<"$(at 41)"

# ---------------------------------------------------------------- 4. host sem dado
check "sem dado: oute-server ativo não alerta"         jqe "$(sel host_no_data oute-server) | length == 0" <<<"$(at 69)"
check "sem dado liga: oute-server 31 min sem registro" jqe --arg s "$(T 40)" "$(sel host_no_data oute-server)"' | length == 1 and .[0].value == 1860 and .[0].since == $s and .[0].evidence.signal == "metrics"' <<<"$(at 71)"
check "sem dado: sempre ligado que nunca mandou nada"  jqe "$(sel host_no_data oute-nunca)"' | length == 1 and .[0].value == null and .[0].since == null' <<<"$R0"
check "sem dado desliga: oute-server voltou a mandar"  jqe "$(sel host_no_data oute-server) | length == 0" <<<"$R0"
check "hosts: oute-server sempre ligado, último dado"  jqe --arg t "$(T 0)" '.hosts[] | select(.host == "oute-server") | .always_on and .last_data == $t and .idle_seconds == 0' <<<"$R0"

# ---------------------------------------------------------------- 5. Mac parado não alerta
check "Mac parado: nenhum alerta (fila 90%, spool 48 MiB, sem dado há 1 h)" jqe '[.alerts[] | select(.host == "oute-mac")] == []' <<<"$R0"
check "Mac parado: só o último dado há X em hosts"     jqe --arg t "$(T -60)" '.hosts[] | select(.host == "oute-mac") | (.always_on | not) and .last_data == $t and .idle_seconds == 3600' <<<"$R0"
check "Mac parado 2 h depois: continua sem alerta"     jqe '[.alerts[] | select(.host == "oute-mac")] == []' <<<"$(at 60)"
RM="$(at -59)"
check "Mac ativo: fila e spool alertam (ele não é sempre ligado, mas está no ar)" jqe '[.alerts[] | select(.host == "oute-mac") | .type] == ["queue", "spool"]' <<<"$RM"

# ---------------------------------------------------------------- 6. nada usa a linha "Dropping data"
check "Dropping data no log do Mac não vira recusa"    jqe "$(sel destination_refusing oute-mac) | length == 0" <<<"$RM"
AL="$ROOT/docker/agent-studio/agent_studio/alerts.py"
check "alerts.py não lê a coluna body dos logs"        bash -c "! grep -qw body '$AL'"

# ---------------------------------------------------------------- 7. spool perto de 50 MB
check "spool liga: 46 MiB desde AT-20m (acima de 40 MiB)" jqe --arg s "$(T -20)" "$(sel spool oute-server)"' | length == 1 and (.[0] | .value == 48234496 and .since == $s and .limit == 41943040 and .evidence.attribute == "oute.emit.spool.bytes" and .evidence.event_name == "oute.canal.decided" and .evidence.event_id == "ev-3")' <<<"$R0"
check "spool: 1 MiB em AT-30m não liga (e o contador inicial 4 não é subida)" jqe "$(sel spool oute-server) | length == 0" <<<"$(at -25)"
R11="$(at 11)"
check "spool bytes desliga: 2 MiB em AT+10m"           jqe "$(sel spool oute-server) | all(.evidence.attribute != \"oute.emit.spool.bytes\")" <<<"$R11"
check "spool dropped liga: subiu 3 (4 -> 7) em AT+10m" jqe --arg s "$(T 10)" "$(sel spool oute-server)"' | length == 1 and (.[0] | .value == 3 and .unit == "dropped_events" and .since == $s and .evidence.counter == 7 and .evidence.attribute == "oute.emit.spool.dropped")' <<<"$R11"
check "spool dropped desliga: fora da janela (20 min no config do teste)" jqe "$(sel spool oute-server) | length == 0" <<<"$(at 31)"

# ---------------------------------------------------------------- 8. cota (#55): prevista e desligada
check "cota: desligada no checks e sem alerta (Claude em 95%)" jqe '.checks.quota == false and ([.alerts[] | select(.type == "quota")] == [])' <<<"$R0"

# ---------------------------------------------------------------- 9. hora do fato × agora
check "agora (2026): só host sem dado dos sempre ligados" jqe '[.alerts[] | .type + ":" + .host] | sort == ["host_no_data:oute-nunca", "host_no_data:oute-server"]' <<<"$(curl -s "${A[@]}" "$STUDIO_URL/v1/alerts")"
studio_stop

# ---------------------------------------------------------------- 10. lógica reusável (tray #205, tela #208)
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/s/db.duckdb" "$ROOT/config/agent-studio/config.toml" "$AT" > "$TMP/py.out" 2>&1 <<'PY'
import sys, dataclasses, duckdb
from agent_studio import alerts, config
from pycheck import check as out
db, repo_cfg, AT = sys.argv[1], sys.argv[2], int(sys.argv[3])
C = alerts.AlertConfig
c = config.load(repo_cfg)
out("config do repo: [alerts] sem erro, oute-server sempre ligado", not c.errors and c.alerts.always_on_hosts == ("oute-server",))
out("config do repo: limites da issue (50%, 15 min, 30 min, 40 MiB)", (c.alerts.queue_max_ratio, c.alerts.refused_window_minutes, c.alerts.no_data_minutes, c.alerts.spool_max_bytes) == (0.5, 15, 30, 40 * 2**20))
out("config do repo: cota prevista e desligada em 90%", c.alerts.quota_enabled is False and c.alerts.quota_max_pct == 90)
out("config do repo = padrões do código", c.alerts == C())
out("config ausente: alertas com os padrões", config.load("/nao/existe.toml").alerts == C())
for raw, why in (({"always_on_hosts": "oute-server"}, "hosts não lista"), ({"no_data_minutes": 0}, "zero"),
                 ({"queue_max_ratio": 50}, "percentual em vez de fração"), ({"quota_enabled": 1}, "bool"),
                 ({"spool_max_bytes": True}, "bool no lugar de número"), ({"quota_metric": ""}, "texto vazio")):
    cfg, errs = C.parse(raw)
    out(f"valor inválido ({why}): padrão + erro", cfg == C() and len(errs) == 1)
cfg, errs = C.parse({"always_on_hosts": ["a", "b"], "no_data_minutes": 10})
out("valores válidos entram", cfg.always_on_hosts == ("a", "b") and cfg.no_data_minutes == 10.0 and not errs)
out("[alerts] que não é tabela: padrões + erro", C.parse([1]) == (C(), ["[alerts] não é tabela"]))
con = duckdb.connect(db, read_only=True)
at = AT * 10**9
r = alerts.evaluate(con, at, dataclasses.replace(C(), quota_enabled=True))
q = [a for a in r["alerts"] if a["type"] == "quota"]
out("cota ligada: Claude 95% alerta, Codex 50% não", len(q) == 1 and q[0]["value"] == 95 and q[0]["evidence"]["agent"] == "claude" and r["checks"]["quota"])
r = alerts.evaluate(con, at, C())
out("evaluate: tipos na ordem fixa", [a["type"] for a in r["alerts"]] == ["queue", "destination_refusing", "spool"])
out("evaluate: host sem host_name nunca quebra (hosts só com nome)", all(h["host"] for h in r["hosts"]))
PY
check_py_lines "$TMP/py.out"

# ---------------------------------------------------------------- 11. sem config e leitura que falha
studio_start "$TMP/n" AGENT_STUDIO_CONFIG="$TMP/nao-existe.toml" || { echo "FAIL agent-studio não subiu sem config"; exit 1; }
post metrics "$TMP/metrics.json" >/dev/null
R="$(at 0)"
check "sem config: 200 com o motivo e os padrões (oute-server sempre ligado)" jqe '(.config.errors[0] | test("não encontrada")) and ([.hosts[] | select(.always_on) | .host] == ["oute-server"])' <<<"$R"
studio_stop
studio_start "$TMP/f" STUDIO_FAIL_USAGE=1 AGENT_STUDIO_CONFIG="$TMP/config.toml" || { echo "FAIL agent-studio não subiu"; exit 1; }
check "leitura que falha: 500"                         test "$(code "${A[@]}" "$STUDIO_URL/v1/alerts")" = 500
studio_stop
check "leitura que falha: causa no stderr"             grep -q "consulta de alertas falhou" "$TMP/f/stderr"

check_end
