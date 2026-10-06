#!/usr/bin/env bash
# Testes do `GET /v1/alerts` do agent-studio (#204, ADR-08 §8): fila > 50%, destino recusando, host sem dado e spool
# perto de 50 MB, cada um ligando e desligando; o Mac parado não alerta; a linha "Dropping data" não conta; a cota
# (#347): corte por janela, exceção do reset próximo (só a 5h), ponto velho e ponto sem o par do reset; a rodada
# parada do swarm (#364): ativa, parada com sessão, parada na triagem, fechada, antiga e o evento que volta. O DuckDB de exemplo nasce pela ingestão de verdade (POST /v1/metrics e /v1/logs), com
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
# cota (#347): snapshot = used_pct + reset_in_seconds na mesma hora, por agente e janela. Todos em AT-10m, salvo "volta"
#   claude   5h 99% (reset em 2 h) e 7d 40%        -> alerta (5h)
#   codex    5h 50%                                -> abaixo do corte
#   volta    5h 99% em AT-30m, 40% em AT-5m        -> alerta só até o ponto de 40%
#   velho    7d 99%, reset em 30 min (AT+20m)      -> alerta até o reset; depois, ponto velho
#   ex-reset 5h 98%, reset em 25 min (AT+15m), 7d 40% -> exceção a menos de 20 min do reset (AT-5m a AT+15m)
#   ex-sem7d 5h 98%, reset em 25 min, sem a 7d     -> a exceção vale sem ponto da 7d
#   ex-100   5h 100%, reset em 25 min              -> 100%: sem exceção
#   ex-7d    5h 98% (reset em 25 min) e 7d 99%     -> a 7d acima do corte: sem exceção na 5h, e a 7d alerta
#   w7d-soon 7d 99%, reset em 25 min               -> a exceção não vale para a 7d
#   p97      5h 97% (reset em 2 h)                 -> abaixo do corte de 98: não alerta (#558)
#   p98      5h 98% (reset em 2 h)                 -> exatamente no corte: alerta (#558)
#   sem-par  5h 99% sem oute.quota.reset_in_seconds -> sem como saber se ainda vale: não alerta
def qrm(agent, snaps):  # snaps = [(t, janela, %, reset_in_s ou None)]
    used = [(t, p, {"oute.quota.window": w}) for t, w, p, r in snaps]
    rst = [(t, r, {"oute.quota.window": w}) for t, w, p, r in snaps if r is not None]
    ms = [gauge("oute.quota.used_pct", used)] + ([gauge("oute.quota.reset_in_seconds", rst)] if rst else [])
    return rm("oute-server", ms, {"oute.agent": agent})
Q, H, D3 = AT - 10 * M, 7200, 3 * 86400
quota = [
    qrm("claude", [(Q, "5h", 99, H), (Q, "7d", 40, D3)]),
    qrm("codex", [(Q, "5h", 50, H)]),
    qrm("volta", [(AT - 30 * M, "5h", 99, H), (AT - 5 * M, "5h", 40, H)]),
    qrm("velho", [(Q, "7d", 99, 1800)]),
    qrm("ex-reset", [(Q, "5h", 98, 1500), (Q, "7d", 40, D3)]),
    qrm("ex-sem7d", [(Q, "5h", 98, 1500)]),
    qrm("ex-100", [(Q, "5h", 100, 1500)]),
    qrm("ex-7d", [(Q, "5h", 98, 1500), (Q, "7d", 99, D3)]),
    qrm("w7d-soon", [(Q, "7d", 99, 1500)]),
    qrm("p97", [(Q, "5h", 97, H)]),
    qrm("p98", [(Q, "5h", 98, H)]),
    qrm("sem-par", [(Q, "5h", 99, None)]),
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
# rodada do swarm (#364): eventos oute.swarm.* do oute-server, pela hora do fato (limite: round_stalled_minutes = 30)
#   r-ativa    aberta AT-20m, sessão a-1 em AT-15m, tell em AT-5m   -> último evento há 5 min: sem alerta
#   r-sess     aberta AT-100m, sessões a-1 e b-2 em AT-90m, b-2 fechada em AT-80m -> parada com a-1 aberta (80 min)
#   r-triagem  aberta AT-45m, sem sessão                            -> parada na triagem (45 min)
#   r-fechada  aberta AT-3h, sessão e rodada fechadas em AT-2h      -> sem alerta
#   r-volta    aberta AT-60m, sessão v-1 em AT-50m; tell em AT+10m  -> parada em AT, volta em AT+10m, para de novo depois
#   r-antiga   aberta AT-30h, sessão o-1 em AT-26h                  -> mais de 24 h sem evento: "antiga sem fechamento"
#   r-velha    aberta AT-60h, sem mais nada                         -> mais de 48 h: nem como antiga
#   r-sem-open só session.spawned em AT-100m (a abertura nunca chegou) -> sem alerta
#   r-por-fechar aberta AT-70m, sessão p-1 aberta em AT-60m e fechada em AT-40m, sem round.closed -> parada, com as sessões
#              fechadas e sem fechamento (#654: `unclosed`, 40 min)
n2 = 0
def sw(t, name, rnd, slug=None):
    global n2; n2 += 1
    a = {"oute.event.id": f"sw-{n2}", "event.name": name, "oute.swarm.round": rnd}
    if slug: a["oute.swarm.session"] = slug
    return {"timeUnixNano": ns(t), "severityNumber": 9, "eventName": name, "body": {"stringValue": name},
            "attributes": kv(a)}
O, SP, CL = "oute.swarm.round.opened", "oute.swarm.session.spawned", "oute.swarm.session.closed"
swarm = [
    sw(AT - 20 * M, O, "r-ativa"), sw(AT - 15 * M, SP, "r-ativa", "a-1"), sw(AT - 5 * M, "oute.swarm.tell", "r-ativa", "a-1"),
    sw(AT - 100 * M, O, "r-sess"), sw(AT - 90 * M, SP, "r-sess", "a-1"), sw(AT - 90 * M, SP, "r-sess", "b-2"),
    sw(AT - 80 * M, CL, "r-sess", "b-2"),
    sw(AT - 45 * M, O, "r-triagem"),
    sw(AT - 180 * M, O, "r-fechada"), sw(AT - 150 * M, SP, "r-fechada", "f-1"), sw(AT - 120 * M, CL, "r-fechada", "f-1"),
    sw(AT - 120 * M, "oute.swarm.round.closed", "r-fechada"),
    sw(AT - 60 * M, O, "r-volta"), sw(AT - 50 * M, SP, "r-volta", "v-1"), sw(AT + 10 * M, "oute.swarm.tell", "r-volta", "v-1"),
    sw(AT - 30 * 60 * M, O, "r-antiga"), sw(AT - 26 * 60 * M, SP, "r-antiga", "o-1"),
    sw(AT - 60 * 60 * M, O, "r-velha"),
    sw(AT - 100 * M, SP, "r-sem-open", "x-1"),
    sw(AT - 70 * M, O, "r-por-fechar"), sw(AT - 60 * M, SP, "r-por-fechar", "p-1"), sw(AT - 40 * M, CL, "r-por-fechar", "p-1"),
]
logs = {"resourceLogs": [
    rl("oute-server", "oute", swarm),
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

# ---------------------------------------------------------------- 8. cota (#347)
# qa <agente>: os alertas de cota daquele agente
qa() { printf '[.alerts[] | select(.type == "quota" and .evidence.agent == "%s")]' "$1"; }
check "cota ligada no checks"                          jqe '.checks.quota == true' <<<"$R0"
check "cota: Claude 5h 99% alerta (corte 98, desde AT-10m, reset em 2 h)" jqe --arg s "$(T -10)" --arg r "$(T 110)" "$(qa claude)"' | length == 1 and (.[0] | .host == "oute-server" and .value == 99 and .unit == "pct" and .limit == 98 and .since == $s and .evidence.metric == "oute.quota.used_pct" and .evidence.attributes == "{\"oute.quota.window\":\"5h\"}" and .evidence.resets_at == $r)' <<<"$R0"
check "cota: 97% não alerta (corte 98, #558)"          jqe "$(qa p97) | length == 0" <<<"$R0"
check "cota: 98% exatos alertam"                       jqe "$(qa p98)"' | length == 1 and .[0].value == 98 and .[0].limit == 98' <<<"$R0"
check "cota: a 7d do Claude em 40% não alerta (corte por janela)" jqe "$(qa claude) | length == 1" <<<"$R0"
check "cota: Codex em 50% não alerta"                  jqe "$(qa codex) | length == 0" <<<"$R0"
check "cota: sem o par do reset não alerta"            jqe "$(qa sem-par) | length == 0" <<<"$R0"
check "cota: último ponto abaixo do corte desliga (40% em AT-5m)" jqe "$(qa volta) | length == 0" <<<"$R0"
check "cota: antes do ponto de 40% ainda alertava"     jqe --arg s "$(T -30)" "$(qa volta)"' | length == 1 and .[0].since == $s and .[0].value == 99' <<<"$(at -10)"
check "cota: 7d com reset adiante alerta"              jqe "$(qa velho) | length == 1" <<<"$(at 19)"
check "cota: ponto velho (reset em AT+20m já passou) some" jqe "$(qa velho) | length == 0" <<<"$(at 21)"
check "cota: Claude ainda alerta uma hora depois (reset em 2 h)" jqe "$(qa claude) | length == 1" <<<"$(at 60)"
check "cota: Claude some depois do reset (AT+110m)"    jqe "$(qa claude) | length == 0" <<<"$(at 111)"
# o servidor manda métricas até AT+40m; depois disso o host está parado e nada de cota liga (valor velho)
check "cota: host parado não alerta"                   jqe '[.alerts[] | select(.type == "quota")] == []' <<<"$(at 80)"
# exceção do reset próximo (só a 5h): reset em AT+15m, limite de 20 min
check "exceção: reset a 25 min (AT-10m) ainda alerta"  jqe "$(qa ex-reset) | length == 1" <<<"$(at -10)"
check "exceção: reset a 19 min (AT-4m) não alerta"     jqe "$(qa ex-reset) | length == 0" <<<"$(at -4)"
check "exceção: reset a 15 min (AT) não alerta"        jqe "$(qa ex-reset) | length == 0" <<<"$R0"
check "exceção: sem ponto da 7d também não alerta"     jqe "$(qa ex-sem7d) | length == 0" <<<"$R0"
check "exceção: 5h em 100% alerta mesmo perto do reset" jqe "$(qa ex-100)"' | length == 1 and .[0].value == 100' <<<"$R0"
check "exceção: 7d acima do corte tira a exceção da 5h" jqe "$(qa ex-7d)"' | length == 2 and ([.[].evidence.attributes] | sort == ["{\"oute.quota.window\":\"5h\"}", "{\"oute.quota.window\":\"7d\"}"])' <<<"$R0"
check "exceção: não vale para a 7d (reset a 15 min)"   jqe "$(qa w7d-soon)"' | length == 1 and (.[0].evidence.attributes | contains("7d"))' <<<"$R0"
check "exceção: depois do reset a 5h do ex-reset some" jqe "$(qa ex-reset) | length == 0" <<<"$(at 16)"

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
out("config do repo: cota ligada, corte 98% e exceção de 20 min", c.alerts.quota_enabled is True and c.alerts.quota_max_pct == 98 and c.alerts.quota_reset_grace_minutes == 20)
out("config do repo = padrões do código", c.alerts == C())
out("config ausente: alertas com os padrões", config.load("/nao/existe.toml").alerts == C())
for raw, why in (({"always_on_hosts": "oute-server"}, "hosts não lista"), ({"no_data_minutes": 0}, "zero"),
                 ({"queue_max_ratio": 50}, "percentual em vez de fração"), ({"quota_enabled": 1}, "bool"),
                 ({"spool_max_bytes": True}, "bool no lugar de número"), ({"quota_metric": ""}, "texto vazio"),
                 ({"quota_reset_grace_minutes": 0}, "zero"), ({"quota_reset_metric": 5}, "número no lugar de texto")):
    cfg, errs = C.parse(raw)
    out(f"valor inválido ({why}): padrão + erro", cfg == C() and len(errs) == 1)
cfg, errs = C.parse({"always_on_hosts": ["a", "b"], "no_data_minutes": 10})
out("valores válidos entram", cfg.always_on_hosts == ("a", "b") and cfg.no_data_minutes == 10.0 and not errs)
out("[alerts] que não é tabela: padrões + erro", C.parse([1]) == (C(), ["[alerts] não é tabela"]))
con = duckdb.connect(db, read_only=True)
at = AT * 10**9
r = alerts.evaluate(con, at, dataclasses.replace(C(), quota_enabled=True))
q = [a for a in r["alerts"] if a["type"] == "quota"]
out("cota ligada: Claude 99% alerta, Codex 50% não", any(a["evidence"]["agent"] == "claude" and a["value"] == 99 for a in q) and not any(a["evidence"]["agent"] == "codex" for a in q) and r["checks"]["quota"])
r = alerts.evaluate(con, at, dataclasses.replace(C(), quota_enabled=False))
out("cota desligada: sem alerta de cota e checks.quota falso", not any(a["type"] == "quota" for a in r["alerts"]) and r["checks"]["quota"] is False)
no_round = lambda r: [a["type"] for a in r["alerts"] if not a["type"].startswith("round_")]
out("evaluate: tipos na ordem fixa", no_round(r) == ["queue", "destination_refusing", "spool"])
r = alerts.evaluate(con, at, C())
out("evaluate: cota depois dos outros, rodada parada por último (padrão ligado)", no_round(r)[:3] == ["queue", "destination_refusing", "spool"] and no_round(r)[-1] == "quota" and [a["type"] for a in r["alerts"]][-5:] == ["round_stalled"] * 4 + ["round_old"])
out("evaluate: host sem host_name nunca quebra (hosts só com nome)", all(h["host"] for h in r["hosts"]))
PY
check_py_lines "$TMP/py.out"

# ---------------------------------------------------------------- 12. rodada parada (#364)
studio_start "$TMP/r" AGENT_STUDIO_CONFIG="$TMP/config.toml" || { echo "FAIL agent-studio não subiu"; exit 1; }
post metrics "$TMP/metrics.json" >/dev/null
post logs "$TMP/logs.json" >/dev/null
# rs <rodada>: os alertas de rodada (parada ou antiga) daquela rodada
rs() { printf '[.alerts[] | select((.type == "round_stalled" or .type == "round_old") and .evidence.round == "%s")]' "$1"; }
R="$(at 0)"
check "rodada: checks lista os dois tipos"             jqe '.checks.round_stalled and .checks.round_old' <<<"$R"
check "rodada ativa (último evento há 5 min): sem alerta" jqe "$(rs r-ativa) | length == 0" <<<"$R"
check "rodada parada com sessão: a-1 aberta (b-2 fechada), há 80 min, desde o último evento" jqe --arg s "$(T -80)" "$(rs r-sess)"' | length == 1 and (.[0] | .type == "round_stalled" and .host == "oute-server" and .value == 4800 and .unit == "seconds" and .limit == 1800 and .since == $s and .evidence.kind == "sessions" and .evidence.sessions == ["a-1"] and .evidence.last_event == $s)' <<<"$R"
check "rodada parada na triagem: sem sessão, 45 min"   jqe --arg s "$(T -45)" "$(rs r-triagem)"' | length == 1 and (.[0] | .type == "round_stalled" and .value == 2700 and .since == $s and .evidence.kind == "triage" and .evidence.sessions == [] and .evidence.spawned == 0)' <<<"$R"
check "rodada com as sessões fechadas e sem fechamento (#654): unclosed, 40 min, 1 sessão aberta na rodada" jqe --arg s "$(T -40)" "$(rs r-por-fechar)"' | length == 1 and (.[0] | .type == "round_stalled" and .value == 2400 and .since == $s and .evidence.kind == "unclosed" and .evidence.sessions == [] and .evidence.spawned == 1 and .evidence.round == "r-por-fechar")' <<<"$R"
check "rodada parada com sessão: o motivo segue sessions, com as duas sessões que abriu" jqe "$(rs r-sess)"' | .[0].evidence | .kind == "sessions" and .spawned == 2' <<<"$R"
check "rodada fechada: sem alerta"                     jqe "$(rs r-fechada) | length == 0" <<<"$R"
check "rodada antiga (26 h sem evento): round_old, uma entrada" jqe --arg s "$(T -1560)" "$(rs r-antiga)"' | length == 1 and (.[0] | .type == "round_old" and .evidence.kind == "old" and .value == 93600 and .since == $s)' <<<"$R"
check "rodada com mais de 48 h: nem como antiga"       jqe "$(rs r-velha) | length == 0" <<<"$R"
check "rodada sem a abertura: sem alerta"              jqe "$(rs r-sem-open) | length == 0" <<<"$R"
check "rodada ativa 20 min depois do último evento: sem alerta" jqe "$(rs r-ativa) | length == 0" <<<"$(at 15)"
check "rodada ativa 31 min depois do último evento: alerta com a-1" jqe "$(rs r-ativa)"' | length == 1 and .[0].evidence.sessions == ["a-1"]' <<<"$(at 26)"
check "rodada parada: evidência traz a abertura"       jqe --arg o "$(T -100)" "$(rs r-sess)"' | .[0].evidence.opened_at == $o' <<<"$R"
# o evento que volta: parada em AT (50 min), tell em AT+10m zera, alerta de novo 30 min depois do tell
check "evento que volta: r-volta parada em AT"         jqe --arg s "$(T -50)" "$(rs r-volta)"' | length == 1 and .[0].since == $s and .[0].evidence.sessions == ["v-1"]' <<<"$R"
check "evento que volta: tell em AT+10m, alerta some"  jqe "$(rs r-volta) | length == 0" <<<"$(at 11)"
check "evento que volta: ainda sem alerta aos 29 min do tell" jqe "$(rs r-volta) | length == 0" <<<"$(at 39)"
check "evento que volta: para de novo, desde o tell"   jqe --arg s "$(T 10)" "$(rs r-volta)"' | length == 1 and .[0].since == $s' <<<"$(at 41)"
studio_stop

PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/r/db.duckdb" "$AT" "$ROOT/config/agent-studio/config.toml" > "$TMP/py2.out" 2>&1 <<'PY'
import sys, logging, duckdb
from agent_studio import alert_text, alerts, config, tray
from pycheck import check as out
db, at, repo_cfg = sys.argv[1], int(sys.argv[2]) * 10**9, sys.argv[3]
C = alerts.AlertConfig
con = duckdb.connect(db, read_only=True)
rnd = lambda r: [a for a in r["alerts"] if a["type"].startswith("round_")]
cfg, errs = C.parse({"round_stalled_minutes": 0})
out("round_stalled_minutes: padrão 30; zero cai no padrão com erro; 90 vale", C().round_stalled_minutes == 30 and cfg == C() and len(errs) == 1
    and C.parse({"round_stalled_minutes": 90})[0].round_stalled_minutes == 90)
out("config do repo: round_stalled_minutes = 30 sem erro", config.load(repo_cfg).alerts.round_stalled_minutes == 30 and not config.load(repo_cfg).errors)
out("limite de 90 min: r-sess (80 min), r-triagem (45) e r-por-fechar (40) não alertam", [a["evidence"]["round"] for a in rnd(alerts.evaluate(con, at, C(round_stalled_minutes=90)))] == ["r-antiga"])
r = alerts.evaluate(con, at, C())
out("ordem: round_stalled antes de round_old, por rodada", [(a["type"], a["evidence"]["round"]) for a in rnd(r)] == [("round_stalled", "r-por-fechar"), ("round_stalled", "r-sess"), ("round_stalled", "r-triagem"), ("round_stalled", "r-volta"), ("round_old", "r-antiga")])
t = {a["evidence"]["round"]: a for a in rnd(r)}
out("título e texto: parada com sessão", alert_text.title(t["r-sess"]) == "Rodada parada" and alert_text.text(t["r-sess"]) == "rodada r-sess com 1 sessão aberta (a-1); último evento há 1 h 20 min (limite 30 min 00 s)")
out("texto: sessões fechadas e rodada sem fechamento (#654)", alert_text.text(t["r-por-fechar"]) == "rodada r-por-fechar com as sessões fechadas e sem fechamento (oute-swarm close --all --yes); último evento há 40 min 00 s (limite 30 min 00 s)")
out("texto: alerta de rodada antigo, sem o motivo novo, segue como triagem", "triagem sem resposta" in alert_text.text({**t["r-por-fechar"], "evidence": {k: v for k, v in t["r-por-fechar"]["evidence"].items() if k != "kind"}}))
out("texto: triagem", alert_text.text(t["r-triagem"]) == "rodada r-triagem sem sessão aberta, triagem sem resposta; último evento há 45 min 00 s (limite 30 min 00 s)")
out("título e texto: rodada antiga", alert_text.title(t["r-antiga"]) == "Rodada antiga sem fechamento" and alert_text.text(t["r-antiga"]) == "rodada r-antiga aberta e sem fechamento; último evento há 26 h 00 min")
out("texto: duas sessões abertas no plural", "2 sessões abertas (a, b)" in alert_text.text({**t["r-sess"], "evidence": {**t["r-sess"]["evidence"], "sessions": ["a", "b"]}}))
snap = tray.snapshot(con, at, config.load(repo_cfg).prices, C())
out("tray: os alertas de rodada saem com title e text", [(a["title"], bool(a["text"])) for a in snap["alerts"] if a["type"].startswith("round_")] == [("Rodada parada", True)] * 4 + [("Rodada antiga sem fechamento", True)])
out("rodada antiga some depois de 48 h sem evento", [a for a in alerts._rounds(con, at + 30 * 3600 * 10**9, C()) if a["evidence"]["round"] == "r-antiga"] == [])
out("23 h sem evento ainda é parada, não antiga", [a["type"] for a in alerts._rounds(con, at - 3 * 3600 * 10**9, C()) if a["evidence"]["round"] == "r-antiga"] == ["round_stalled"])
class Boom:  # a consulta das rodadas falha; as outras seguem
    def execute(self, sql, params=None):
        if "oute_swarm_round" in sql:
            raise RuntimeError("falha injetada")
        return con.execute(sql, params) if params is not None else con.execute(sql)
class Cap(logging.Handler):
    seen = []
    def emit(self, rec): Cap.seen.append(rec.getMessage())
logging.getLogger("agent_studio.alerts").addHandler(Cap())
rb = alerts.evaluate(Boom(), at, C())
out("falha do cálculo da rodada: os outros alertas seguem e a falha vai ao log", [a["type"] for a in rb["alerts"] if a["type"] != "quota"] == ["queue", "destination_refusing", "spool"] and not rnd(rb) and any("rodada parada falhou" in m for m in Cap.seen))
PY
check_py_lines "$TMP/py2.out"

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
