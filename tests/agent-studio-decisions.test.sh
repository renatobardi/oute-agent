#!/usr/bin/env bash
# Testes da decisão pendente do Bardi no agent-studio (#386, ADR-08 §10): rodada com `oute.swarm.round.asked` sem
# `answered` aparece em `decisions` do `GET /v1/tray` (pergunta e idade) e no topo das telas; a respondida, a fechada e
# a resposta sem pergunta não; a pergunta nova depois de uma resposta volta a ser pendente; a pergunta recente conta como
# evento da rodada, então não vira `round_stalled` (#364) antes de `round_stalled_minutes` (30). O DuckDB de exemplo nasce
# pela ingestão de verdade (POST /v1/logs), com horas relativas a agora e folga de minutos do limite. Sem SurrealDB nem Docker.
# Uso: tests/agent-studio-decisions.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init

# ---------------------------------------------------------------- DuckDB de exemplo (minutos antes de agora)
#   r-pend     aberta há 100 min, pergunta há 10 min                        -> pendente (e não parada: a pergunta é evento)
#   r-resp     aberta há 100 min, pergunta há 20, resposta há 15            -> respondida
#   r-nova     pergunta há 50, resposta há 45, pergunta nova há 5           -> pendente, com o texto novo
#   r-velha    aberta há 200 min, pergunta há 120 min                       -> pendente há 2 h (e parada, pelo limite de 30 min)
#   r-fechada  pergunta há 40 min, rodada fechada há 35 min                 -> não pendente
#   r-so-resp  aberta há 100 min, resposta há 30 min, sem pergunta          -> não pendente
#   r-outro    pergunta há 8 min no oute-mac                                -> pendente, host oute-mac
#   r-mesmo    pergunta há 30 min; resposta e pergunta nova na MESMA hora (há 13 min) -> pendente, texto novo
NOW="$(date +%s)"
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" <<'PY'
import json, sys
from otlp_json import kv, rl
tmp, NOW = sys.argv[1], int(sys.argv[2])
n = 0
def sw(host, mins, name, rnd, body=None):
    global n; n += 1
    r = {"timeUnixNano": str((NOW - mins * 60) * 10**9), "severityNumber": 9, "eventName": name,
         "attributes": kv({"oute.event.id": f"d-{n}", "event.name": name, "oute.swarm.round": rnd})}
    if body is not None: r["body"] = {"stringValue": body}
    return host, r
O, A, W, C = ("oute.swarm.round.opened", "oute.swarm.round.asked", "oute.swarm.round.answered", "oute.swarm.round.closed")
evs = [
    sw("oute-server", 100, O, "r-pend"), sw("oute-server", 10, A, "r-pend", "1. aprovar a triagem  2. cortar a #387"),
    sw("oute-server", 100, O, "r-resp"), sw("oute-server", 20, A, "r-resp", "pergunta velha"), sw("oute-server", 15, W, "r-resp"),
    sw("oute-server", 100, O, "r-nova"), sw("oute-server", 50, A, "r-nova", "primeira"), sw("oute-server", 45, W, "r-nova"),
    sw("oute-server", 5, A, "r-nova", "segunda"),
    sw("oute-server", 200, O, "r-velha"), sw("oute-server", 120, A, "r-velha", "lições: 1, 2 ou 3?"),
    sw("oute-server", 100, O, "r-fechada"), sw("oute-server", 40, A, "r-fechada", "antes de fechar"), sw("oute-server", 35, C, "r-fechada"),
    sw("oute-server", 100, O, "r-so-resp"), sw("oute-server", 25, W, "r-so-resp"),
    sw("oute-mac", 8, A, "r-outro", "merge do #99?"),
    sw("oute-server", 100, O, "r-mesmo"), sw("oute-server", 30, A, "r-mesmo", "antes"), sw("oute-server", 13, W, "r-mesmo"),
    sw("oute-server", 13, A, "r-mesmo", "depois, no mesmo segundo da resposta"),
    # sinal recente do host, para o oute-server não ficar "parado" (alerta de rodada só vale com host ativo)
    sw("oute-server", 1, "oute.swarm.tell", "r-nova"),
]
hosts = {}
for h, r in evs: hosts.setdefault(h, []).append(r)
json.dump({"resourceLogs": [rl({"host.name": h, "oute.instance": "oute-agent", "service.name": "oute"}, recs)
                            for h, recs in hosts.items()]}, open(f"{tmp}/logs.json", "w"))
PY
printf '[alerts]\nalways_on_hosts = ["oute-server"]\n' > "$TMP/config.toml"
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/config.toml" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
tray() { curl -s "${A[@]}" "$STUDIO_URL/v1/tray"; }
# dec <rodada>: a decisão pendente daquela rodada, ou nada
dec() { printf '[.decisions.pending[] | select(.round == "%s")]' "$1"; }
R="$(tray)"

# ---------------------------------------------------------------- 1. /v1/tray
check "tray: decisions com total e pending"            jqe '.decisions | keys == ["pending", "total"] and .total == (.pending | length)' <<<"$R"
check "tray: pendentes = r-mesmo, r-nova, r-outro, r-pend e r-velha, nada mais" jqe '[.decisions.pending[].round] | sort == ["r-mesmo", "r-nova", "r-outro", "r-pend", "r-velha"]' <<<"$R"
check "tray: campos de cada decisão"                   jqe '.decisions.pending | all(keys == ["age_seconds", "asked_at", "host", "instance", "question", "round"])' <<<"$R"
check "tray: pergunta pendente com o texto e a idade (~10 min)" jqe "$(dec r-pend)"' | length == 1 and (.[0] | .question == "1. aprovar a triagem  2. cortar a #387" and .host == "oute-server" and .instance == "oute-agent" and .age_seconds >= 600 and .age_seconds < 720)' <<<"$R"
check "tray: asked_at é a hora do fato (UTC)"          jqe --argjson now "$NOW" "$(dec r-pend)"' | .[0].asked_at | fromdate | (. - $now) as $d | $d <= -590 and $d > -720' <<<"$R"
check "tray: respondida não aparece"                   jqe "$(dec r-resp) | length == 0" <<<"$R"
check "tray: pergunta nova depois da resposta: pendente, com o texto novo" jqe "$(dec r-nova)"' | length == 1 and .[0].question == "segunda" and .[0].age_seconds >= 300 and .[0].age_seconds < 420' <<<"$R"
check "tray: rodada fechada não aparece"               jqe "$(dec r-fechada) | length == 0" <<<"$R"
check "tray: resposta sem pergunta não aparece"        jqe "$(dec r-so-resp) | length == 0" <<<"$R"
check "tray: pergunta velha (2 h) segue pendente, com a idade" jqe "$(dec r-velha)"' | length == 1 and .[0].age_seconds >= 7200 and .[0].age_seconds < 7320' <<<"$R"
check "tray: outro host, com o host dele"              jqe "$(dec r-outro)"' | length == 1 and .[0].host == "oute-mac" and .[0].question == "merge do #99?"' <<<"$R"
check "tray: do mais novo para o mais antigo"          jqe '[.decisions.pending[].round] == ["r-nova", "r-outro", "r-pend", "r-mesmo", "r-velha"]' <<<"$R"
check "tray: resposta e pergunta no mesmo instante: a pergunta vale (pendente, texto novo)" jqe "$(dec r-mesmo)"' | length == 1 and .[0].question == "depois, no mesmo segundo da resposta"' <<<"$R"
check "tray: a barra segue com os dois contadores"     jqe '.bar | keys == ["alerts", "pending"]' <<<"$R"

# ---------------------------------------------------------------- 2. rodada parada (#364) × pergunta recente
rs() { printf '[.alerts[] | select((.type == "round_stalled" or .type == "round_old") and .evidence.round == "%s")]' "$1"; }
ALERTS="$(curl -s "${A[@]}" "$STUDIO_URL/v1/alerts")"
check "alerta: r-pend (aberta há 100 min, pergunta há 10) não é rodada parada" jqe "$(rs r-pend) | length == 0" <<<"$ALERTS"
check "alerta: r-nova (pergunta há 5 min) não é rodada parada" jqe "$(rs r-nova) | length == 0" <<<"$ALERTS"
check "alerta: r-resp (resposta há 15 min) não é rodada parada" jqe "$(rs r-resp) | length == 0" <<<"$ALERTS"
check "alerta: r-velha (pergunta há 120 min, passou do limite) é rodada parada" jqe "$(rs r-velha)"' | length == 1 and .[0].type == "round_stalled"' <<<"$ALERTS"
check "alerta: a decisão pendente não é alerta"        jqe 'all(.alerts[]; (.type | test("decision") | not))' <<<"$ALERTS"
check "tray: round_stalled só de r-velha, junto da decisão" jqe '[.alerts[] | select(.type == "round_stalled") | .evidence.round] == ["r-velha"]' <<<"$R"

# ---------------------------------------------------------------- 3. topo das telas
PAGE="$(curl -s "${A[@]}" "$STUDIO_URL/conversas")"
check "tela: bloco de decisões no topo, com 5 pendentes" bash -c 'grep -qF "id=\"decisoes\" data-decisoes=\"5\"" <<<"$1"' _ "$PAGE"
check "tela: r-pend com a pergunta e o host"           bash -c 'grep -A1 -F "data-decisao=\"r-pend\" data-host=\"oute-server\"" <<<"$1" | grep -qF "1. aprovar a triagem  2. cortar a #387"' _ "$PAGE"
check "tela: respondida e fechada fora do bloco"       bash -c '! grep -qF "data-decisao=\"r-resp\"" <<<"$1" && ! grep -qF "data-decisao=\"r-fechada\"" <<<"$1"' _ "$PAGE"
check "tela: texto 'Decisão pendente na rodada'"       bash -c 'grep -qF "Decisão pendente na rodada r-velha" <<<"$1"' _ "$PAGE"
check "tela: o topo vem antes do conteúdo"             bash -c 'a="$(grep -bo "id=\"decisoes\"" <<<"$1" | head -1 | cut -d: -f1)"; b="$(grep -bo "id=\"conteudo\"" <<<"$1" | head -1 | cut -d: -f1)"; [ -n "$a" ] && [ "$a" -lt "$b" ]' _ "$PAGE"
check "tela: pedido do htmx não leva o topo"           bash -c '! grep -qF "id=\"decisoes\"" <<<"$1"' _ "$(curl -s "${A[@]}" -H 'HX-Request: true' "$STUDIO_URL/conversas")"
check "login: sem decisões no topo"                    bash -c '! grep -qF "id=\"decisoes\"" <<<"$1"' _ "$(curl -s "$STUDIO_URL/login")"
studio_stop

# ---------------------------------------------------------------- 4. a lógica direto: hora da consulta, limite e script de quem lê o banco
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/s/db.duckdb" "$NOW" > "$TMP/py.out" 2>&1 <<'PY'
import sys, logging, duckdb
from agent_studio import alerts, decisions
from pycheck import check as out
db, now = sys.argv[1], int(sys.argv[2])
con = duckdb.connect(db, read_only=True)
C = alerts.AlertConfig
M = 60 * 10**9
at = now * 10**9
rounds = lambda r: [d["round"] for d in r["pending"]]
r = decisions.pending(con, at, C())
out("agora: 5 pendentes, total 5", r["total"] == 5 and rounds(r) == ["r-nova", "r-outro", "r-pend", "r-mesmo", "r-velha"])
r = decisions.pending(con, at - 12 * M, C())
out("12 min atrás: a pergunta de r-pend (há 10) ainda não existia, r-resp já tinha resposta (há 15) e r-mesmo já voltou a perguntar (há 13)",
    rounds(r) == ["r-mesmo", "r-velha"])
r = decisions.pending(con, at - 18 * M, C())
out("18 min atrás: r-resp pendente (resposta só há 15), r-mesmo também (resposta há 13), r-nova já respondida (resposta há 45)",
    set(rounds(r)) == {"r-resp", "r-velha", "r-mesmo"} and r["total"] == 3)
r = decisions.pending(con, at - 60 * M, C())
out("1 h atrás: só r-velha (pergunta há 120); r-fechada, r-nova e r-outro ainda não perguntaram", rounds(r) == ["r-velha"])
r = decisions.pending(con, at, C(), limit=2)
out("limite: o total diz quantas há, a lista só as mais novas", r["total"] == 5 and rounds(r) == ["r-nova", "r-outro"])
r = decisions.pending(con, at, C(lookback_hours=0.5))
out("lookback_hours = 0,5: pergunta mais velha que 1 h fica de fora (r-velha, há 2 h)", "r-velha" not in rounds(r) and r["total"] == 4)
# tray: falha do cálculo das decisões não derruba o menu (cai em NO_DECISIONS)
from agent_studio import config, tray
real = decisions.pending
def boom(*a, **k): raise RuntimeError("falha injetada")
decisions.pending = boom
logging.disable(logging.CRITICAL)
snap = tray.snapshot(con, at, config.load("/nonexistent").prices, C())
logging.disable(logging.NOTSET)
decisions.pending = real
out("tray: decisions falhando = NO_DECISIONS e o resto do menu segue", snap["decisions"] == {"total": 0, "pending": []} and "machines" in snap and "alerts" in snap)
out("sem dado no banco da hora: lista vazia", decisions.pending(con, at - 24 * 3600 * 10**9, C()) == {"total": 0, "pending": []})
PY
check_py_lines "$TMP/py.out"

check_end
