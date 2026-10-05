#!/usr/bin/env bash
# Testes do fuso de exibição do agent-studio (#415, ADR-08 "Fuso de exibição"): a hora do fato segue em UTC no banco, e
# a leitura converte para o `timezone` do config.toml (America/Sao_Paulo): o dia da série do `/v1/usage`, o "custo de
# hoje" do `/v1/tray`, as horas das telas (com o rótulo do fuso no cabeçalho) e a hora da decisão pendente. A API segue
# com ISO 8601 com `Z`, diz o fuso dos dias em `timezone` e aceita `tz=<IANA>`. Fuso inválido ou ausente = UTC.
# O DuckDB de exemplo nasce pela ingestão de verdade; a conversão é conferida pela API, pelas telas e, para a hora
# de "agora" escolhida, direto em Python. Sem Docker.
# Uso: tests/agent-studio-fuso.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init
SP=America/Sao_Paulo

# ---------------------------------------------------------------- DuckDB de exemplo
# T1 = 2025-09-27T02:30:00Z = 26/09 23:30 em São Paulo; T2 = T1 + 1 h = 27/09 00:30 em São Paulo: em UTC os dois são do
# dia 27, no fuso de São Paulo cada um é de um dia. Horas fixas (o histórico), nenhuma relativa a agora, menos a
# pergunta pendente da decisão (a regra de pendente olha o relógio): há 10 min, o instante exato é conferido.
T1=1758940200; T2=$((T1 + 3600)); ASKED=$(( $(date +%s) - 600 ))
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$T1" "$T2" "$ASKED" <<'PY'
import json, sys
from otlp_json import claude_call, event, rl, rs
tmp, T1, T2, ASKED = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
claude = {"host.name": "oute-server", "service.name": "claude-code", "oute.agent": "claude"}
cl = lambda conv, task: {"model": "claude-sonnet-5", "input_tokens": 10, "session.id": conv, "oute.task.id": task}
c1, l1 = claude_call(T1, 2, cl("conv-1", "task-1"), 0.10)
c2, l2 = claude_call(T2, 2, cl("conv-2", "task-2"), 0.20)
json.dump({"resourceSpans": [rs(claude, [c1, c2])]}, open(f"{tmp}/traces.json", "w"))
asked = event(ASKED, "oute.swarm.round.asked", "fuso-asked", {"oute.swarm.round": "r-fuso"}, "merge do #1?")
json.dump({"resourceLogs": [rl(claude, [l1, l2]),
                            rl({"host.name": "oute-server", "service.name": "oute"}, [asked])]}, open(f"{tmp}/logs.json", "w"))
PY
studio_prices "$TMP/prices.toml"
{ printf 'timezone = "%s"\n' "$SP"; cat "$TMP/prices.toml"; } > "$TMP/cfg-sp.toml"
{ echo 'timezone = "Marte/Olimpo"'; cat "$TMP/prices.toml"; } > "$TMP/cfg-ruim.toml"
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
get() { studio_page "${A[@]}" "$STUDIO_URL$1"; }
status() { curl -s -o /dev/null -w '%{http_code}' "${A[@]}" "$STUDIO_URL$1"; }
WIN='from=2025-09-26T00:00:00Z&to=2025-09-29T00:00:00Z'
CONV="/conversas?$WIN"

studio_start "$TMP/sp" AGENT_STUDIO_CONFIG="$TMP/cfg-sp.toml" || { cat "$TMP/sp/stderr"; die "agent-studio não subiu"; }
check "ingestão: traces e logs = 200" test "$(post traces "$TMP/traces.json") $(post logs "$TMP/logs.json")" = "200 200"

# ---------------------------------------------------------------- 1. /v1/usage: o dia do fuso
U="$(get "/v1/usage?$WIN")"
check "usage: o fuso dos dias vem em timezone"          jqe --arg z "$SP" '.timezone == $z' <<<"$U"
check "usage: 23:30 e 00:30 de São Paulo caem em dias diferentes (26 e 27, uma chamada cada)" jqe '[.series[] | {day, calls}] == [{day: "2025-09-26", calls: 1}, {day: "2025-09-27", calls: 1}]' <<<"$U"
check "usage: o custo de cada dia é o da chamada dele" jqe "$(usd '.series[0].cost.real_usd') == 100000 and $(usd '.series[1].cost.real_usd') == 200000" <<<"$U"
check "usage: o total não muda com o fuso (2 chamadas, 0,30)" jqe "$(usd '.totals.cost.real_usd') == 300000 and .totals.calls == 2" <<<"$U"
check "usage: from e to seguem em ISO com Z (contrato de máquina)" jqe '(.from | test("Z$")) and (.to | test("Z$"))' <<<"$U"
check "usage: o tz= UTC junta as duas chamadas no dia 27 (o dia UTC de antes)" jqe '[.series[] | {day, calls}] == [{day: "2025-09-27", calls: 2}]' <<<"$(get "/v1/usage?$WIN&tz=UTC")"
check "usage: tz= igual ao do config dá o mesmo resultado" test "$(get "/v1/usage?$WIN&tz=$SP" | jq -c '.series')" = "$(jq -c '.series' <<<"$U")"
check "usage: tz= de outro fuso (Pacific/Auckland, +13: 27 às 15:30 e 16:30)" jqe '.timezone == "Pacific/Auckland" and ([.series[] | {day, calls}] == [{day: "2025-09-27", calls: 2}])' <<<"$(get "/v1/usage?$WIN&tz=Pacific/Auckland")"
check "usage: tz= inexistente: 400"                     test "$(status "/v1/usage?$WIN&tz=Marte/Olimpo")" = 400
check "usage: tz= com caminho: 400"                     test "$(status "/v1/usage?$WIN&tz=../etc/passwd")" = 400
check "usage: tz= vazio: 400"                           test "$(status "/v1/usage?$WIN&tz=")" = 400
check "usage: tz= inválido: a mensagem não repete o valor" bash -c '! grep -q Olimpo <<<"$1"' _ "$(get "/v1/usage?$WIN&tz=Marte/Olimpo")"
check "usage: from/to sem fuso seguem lidos como UTC (02:00Z a 03:00Z pega só a de 02:30Z)" jqe '.totals.calls == 1' <<<"$(get "/v1/usage?from=2025-09-27T02:00:00&to=2025-09-27T03:00:00")"

# ---------------------------------------------------------------- 2. /v1/tray: o fuso do dia de hoje
TR="$(get /v1/tray)"
check "tray: o fuso do dia vem em timezone"             jqe --arg z "$SP" '.timezone == $z' <<<"$TR"
AT="$(jq -r '.at' <<<"$TR")"; AT_S="$(date -u -d "$AT" +%s)"
DAY_SP="$(TZ=$SP date -d "@$AT_S" +%F)"
check "tray: cost_today.day é o dia de agora em São Paulo, de meia-noite a meia-noite do fuso" jqe --arg d "$DAY_SP" --arg f "$(date -u -d "TZ=\"$SP\" $DAY_SP 00:00" +%FT%TZ)" --arg t "$(date -u -d "TZ=\"$SP\" $(date -d "$DAY_SP + 1 day" +%F) 00:00" +%FT%TZ)" '.cost_today | .day == $d and .from == $f and .to == $t' <<<"$TR"
check "tray: tz=UTC troca o dia (day = dia UTC de agora, de 00:00Z a 00:00Z)" jqe --arg d "$(date -u -d "$AT" +%F)" '.timezone == "UTC" and (.cost_today | .day == $d and (.from | test("T00:00:00Z$")) and (.to | test("T00:00:00Z$")))' <<<"$(get "/v1/tray?tz=UTC")"
check "tray: tz= inválido: 400"                         test "$(status "/v1/tray?tz=Marte/Olimpo")" = 400
check "tray: as horas seguem em ISO com Z"              jqe '(.at | test("Z$")) and (.cost_today.from | test("Z$")) and (.errors_last_hour.from | test("Z$"))' <<<"$TR"
check "tray: asked_at da decisão segue em ISO com Z, na hora exata da pergunta" jqe --arg a "$(date -u -d "@$ASKED" +%FT%TZ)" '.decisions.pending[0].asked_at == $a' <<<"$TR"

# ---------------------------------------------------------------- 3. telas: hora convertida e rótulo do fuso
P="$(get "$CONV")"
check "conversas: cabeçalho Início (GMT-3), nunca (UTC)" bash -c 'grep -q ">Início (GMT-3)<" <<<"$1" && ! grep -q "(UTC)" <<<"$1"' _ "$P"
check "conversas: conv-1 às 23:30 do dia 26 (e não 02:30 do 27)" bash -c 'grep -q "2025-09-26 23:30:00" <<<"$1" && ! grep -q "2025-09-27 02:30:00" <<<"$1"' _ "$P"
check "conversas: conv-2 às 00:30 do dia 27 (e não 03:30)" bash -c 'grep -q "2025-09-27 00:30:00" <<<"$1" && ! grep -q "2025-09-27 03:30:00" <<<"$1"' _ "$P"
check "conversas: a nota diz a hora do fato em GMT-3, e a janela também é convertida" bash -c 'grep -q " · GMT-3" <<<"$1" && grep -q "2025-09-25 21:00:00" <<<"$1"' _ "$P"
D="$(get "/conversa?id=conv-1")"
check "conversa: início e início do span em GMT-3, 23:30 do dia 26" bash -c 'grep -q "<dt>Início (GMT-3)</dt><dd>2025-09-26 23:30:00</dd>" <<<"$1" && ! grep -q "2025-09-27 02:30" <<<"$1"' _ "$D"
check "conversa: o título do tempo relativo leva o rótulo" bash -c 'grep -q "title=\"2025-09-26 23:30:00 GMT-3\"" <<<"$1"' _ "$D"
S="$(get "/sessoes?$WIN")"
check "sessões: cabeçalho Início (GMT-3) e a hora convertida" bash -c 'grep -q "Início (GMT-3)" <<<"$1" && grep -q "2025-09-26 23:30:00" <<<"$1" && ! grep -q "(UTC)" <<<"$1"' _ "$S"
SD="$(get "/sessao?id=task-1")"
check "sessão: Início (GMT-3) na hora convertida"        bash -c 'grep -q "<dt>Início (GMT-3)</dt><dd>2025-09-26 23:30:00</dd>" <<<"$1"' _ "$SD"
PR="$(get /precos)"
check "preços: vigência e conferência com o rótulo do fuso, sem (UTC)" bash -c 'grep -q "Desde (GMT-3)" <<<"$1" && grep -q "Última conferência (GMT-3)" <<<"$1" && grep -q "Último sucesso (GMT-3)" <<<"$1" && ! grep -q "(UTC)" <<<"$1"' _ "$PR"
WANT_ASKED="$(TZ=$SP date -d "@$ASKED" '+%F %T')"
check "decisão pendente: a hora da pergunta em GMT-3 no topo, e o data-since segue em ISO com Z" bash -c 'grep -qF "perguntada em $1 GMT-3" <<<"$2" && grep -qF "data-since=\"$3\"" <<<"$2"' _ "$WANT_ASKED" "$P" "$(date -u -d "@$ASKED" +%FT%TZ)"
studio_stop

# ---------------------------------------------------------------- 4. fuso inválido ou ausente cai em UTC
studio_start "$TMP/ruim" AGENT_STUDIO_CONFIG="$TMP/cfg-ruim.toml" || { cat "$TMP/ruim/stderr"; die "agent-studio não subiu"; }
post traces "$TMP/traces.json" >/dev/null; post logs "$TMP/logs.json" >/dev/null
U="$(get "/v1/usage?$WIN")"
check "fuso inválido: timezone UTC e o dia UTC (as duas chamadas no 27)" jqe '.timezone == "UTC" and ([.series[] | {day, calls}] == [{day: "2025-09-27", calls: 2}])' <<<"$U"
check "fuso inválido: o motivo vai em prices.errors"     jqe '.prices.errors | any(test("timezone inválido"))' <<<"$U"
check "fuso inválido: o motivo vai ao stderr"            grep -q "timezone inválido" "$TMP/ruim/stderr"
check "fuso inválido: o tray também diz UTC"             jqe '.timezone == "UTC"' <<<"$(get /v1/tray)"
P="$(get "$CONV")"
check "fuso inválido: telas em UTC, com (UTC) no cabeçalho e a hora do fato" bash -c 'grep -q ">Início (UTC)<" <<<"$1" && grep -q "2025-09-27 02:30:00" <<<"$1"' _ "$P"
studio_stop
studio_start "$TMP/sem" AGENT_STUDIO_CONFIG="$TMP/prices.toml" || { cat "$TMP/sem/stderr"; die "agent-studio não subiu"; }
check "fuso ausente: timezone UTC"                       jqe '.timezone == "UTC"' <<<"$(get "/v1/usage?$WIN")"
check "fuso ausente: aviso no log, fora de prices.errors" bash -c 'grep -q "sem .timezone." "$1" && ! jq -e ".prices.errors | any(test(\"timezone\"))" <<<"$2" >/dev/null' _ "$TMP/sem/stderr" "$(get "/v1/usage?$WIN")"
studio_stop

# ---------------------------------------------------------------- 5. nada armazenado muda
check "armazenamento: a hora do fato segue em UTC no DuckDB (ns exatos)" test "$(studio_sql "$TMP/sp/db.duckdb" "SELECT time_unix_nano::VARCHAR AS ns FROM spans ORDER BY 1" | jq -sc "map(.ns)")" = "[\"${T1}000000000\",\"${T2}000000000\"]"
check "armazenamento: a coluna time é a mesma hora em UTC"  test "$(studio_sql "$TMP/sp/db.duckdb" "SELECT strftime(time AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M:%S') AS h FROM spans ORDER BY time" | jq -sc 'map(.h)')" = '["2025-09-27 02:30:00","2025-09-27 03:30:00"]'

# ---------------------------------------------------------------- 6. lógica direto em Python (hora de "agora" escolhida)
cp "$TMP/sp/db.duckdb" "$TMP/copy.duckdb"
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/copy.duckdb" "$TMP/cfg-sp.toml" "$T1" > "$TMP/py.out" 2>&1 <<'PY'
import logging, sys, duckdb
logging.disable(logging.CRITICAL)
from agent_studio import config, tray, tz, usage, web
from pycheck import check as out
db, cfg_path, T1 = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = config.load(cfg_path)
con = duckdb.connect(db)
SP, UTC = tz.parse("America/Sao_Paulo"), tz.UTC
NS = 10**9
out("config: timezone lido como ZoneInfo (nome IANA)", cfg.tz.key == "America/Sao_Paulo" and cfg.errors == [] and cfg.warnings == [])
# custo de hoje às 22:00 de São Paulo (01:00Z do dia 27): o dia de lá ainda é o 26; em UTC já seria o 27
at = (T1 - 5400) * NS
c = tray.snapshot(con, at, cfg.prices, cfg.alerts, SP)["cost_today"]
out("hoje às 22:00 de São Paulo: o dia é 26, de 03:00Z a 03:00Z, só a chamada das 23:30 (0,10)",
    c["day"] == "2025-09-26" and c["from"] == "2025-09-26T03:00:00Z" and c["to"] == "2025-09-27T03:00:00Z" and c["real_usd"] == 0.1 and [a["calls"] for a in c["agents"]] == [1])
u = tray.snapshot(con, at, cfg.prices, cfg.alerts, UTC)["cost_today"]
out("hoje às 22:00 de São Paulo em UTC: já é o dia 27, com as duas chamadas (0,30)", u["day"] == "2025-09-27" and u["from"] == "2025-09-27T00:00:00Z" and round(u["real_usd"], 6) == 0.3)
c = tray.snapshot(con, (T1 + 3600) * NS, cfg.prices, cfg.alerts, SP)["cost_today"]
out("hoje às 00:30 de São Paulo: o dia vira 27 (03:00Z), só a chamada das 00:30 (0,20)", c["day"] == "2025-09-27" and c["from"] == "2025-09-27T03:00:00Z" and c["real_usd"] == 0.2)
# dia de 23 h (horário de verão dos EUA, 09/03/2025): o fuso é por nome, não por deslocamento fixo
NY = tz.parse("America/New_York")
lo, hi = tz.day_bounds(1741530000 * NS, NY)
out("zoneinfo: o dia da virada do horário de verão tem 23 h", (hi - lo) // (3600 * NS) == 23)
out("zoneinfo: o rótulo acompanha o horário de verão (GMT-5 no inverno, GMT-4 no verão)", tz.label(NY, 1736000000 * NS) == "GMT-5" and tz.label(NY, 1752000000 * NS) == "GMT-4")
out("rótulos: São Paulo GMT-3, Índia GMT+5:30, UTC UTC", tz.label(SP) == "GMT-3" and tz.label(tz.parse("Asia/Kolkata")) == "GMT+5:30" and tz.label(UTC) == "UTC")
s = usage.usage(con, 0, 2**62, cfg.prices, NY)
out("usage direto com New_York: dia 26 (22:30 e 23:30 de lá) e o fuso no resultado", s["timezone"] == "America/New_York" and [r["day"] for r in s["series"]] == ["2025-09-26"])
out("usage sem fuso: UTC por padrão", usage.usage(con, 0, 2**62, cfg.prices)["timezone"] == "UTC")
for bad in ("Marte/Olimpo", "", "../etc/passwd", "America/", "/etc/passwd", None):
    try:
        tz.parse(bad)
        ok = False
    except ValueError:
        ok = True
    out(f"tz.parse recusa {bad!r}", ok)
con.close()
when, ts = web._when_in(SP), web._ts_in(SP)
out("tela: hora do SurrealDB com fração e Z convertida (07:43Z = 04:43 em São Paulo)", when("2026-09-29T07:43:00.5Z") == "2026-09-29 04:43:00")
out("tela: valor que não é hora segue como veio (sem quebrar) e vazio vira traço", when("lixo") == "lixo" and when(None) == "—" and when("") == "—" and ts(None) == "—")
PY
check_py_lines "$TMP/py.out"

check_end
