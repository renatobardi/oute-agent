#!/usr/bin/env bash
# Testes do `GET /v1/usage` do agent-studio (#203, ADR-08 §9): custo real × estimado, tokens, erros, p95 e série
# diária por host × agente × modelo, pela hora do fato. O DuckDB de exemplo nasce pela ingestão de verdade
# (POST /v1/traces e /v1/logs); a consulta é conferida pela API. Mais a lógica reusável (cost/config/usage) direto
# em Python e o mount só leitura no compose. Sem Docker.
# Uso: tests/agent-studio-usage.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init
usage() { curl -s -H "Authorization: Bearer $STUDIO_TOKEN" "$STUDIO_URL/v1/usage${1:-}"; }

# ---------------------------------------------------------------- DuckDB de exemplo
# D1 = 2025-09-27T19:06:40Z, D2 = D1 + 1 dia. Tudo chega agora: a janela de 2025 só acha os fatos pela hora do fato.
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import api_request, claude_call, kv, rl, rs, span
tmp = sys.argv[1]
D1, D2 = 1759000000, 1759000000 + 86400
claude = {"host.name": "oute-server", "service.name": "claude-code", "oute.agent": "claude"}
codex = {"host.name": "oute-mac", "service.name": "codex_exec", "oute.agent": "codex"}
# histórico até 2026-09-30 (#218): o jev-router saiu do stack; o que ele gravou (jev.decision, spans do LiteLLM com
# oute.agent=router) segue no DuckDB e o /v1/usage tem que continuar somando o custo passado
router = {"host.name": "oute-server", "service.name": "jev-router", "oute.agent": "router"}
cl = lambda **a: {"model": "claude-sonnet-5", **a}
cx = lambda m, i=0, o=0, c=0: {"model": m, "codex.turn.token_usage.non_cached_input_tokens": i,
                               "codex.turn.token_usage.output_tokens": o, "codex.turn.token_usage.cached_input_tokens": c}
# Claude no formato de produção (#157): o span chega sem cost_usd; o custo vem no log api_request de mesmo request_id
calls = [
  claude_call(D1, 2, cl(input_tokens=100, output_tokens=50, cache_read_tokens=1000, cache_creation_tokens=10), 0.01),
  claude_call(D1 + 60, 4, cl(input_tokens=200, output_tokens=20), 0.02),   # log em D1 + 64
  claude_call(D2, 1, cl(input_tokens=10, output_tokens=5), 0.03),
  # sem log api_request: estimado pela tabela (claude-sonnet-5 = 3/M de entrada)
  claude_call(D2 + 60, 3, cl(input_tokens=1_000_000)),
  # fora da janela (hora do fato em janeiro)
  claude_call(1735689600, 1, cl(input_tokens=5), 100.0),
]
rid = lambda s: next(a["value"]["stringValue"] for a in s["attributes"] if a["key"] == "request_id")
traces = {"resourceSpans": [
  rs(claude, [
    *(s for s, _ in calls),
    # não é chamada ao modelo: fora das somas
    span("claude_code.tool", D1, 1, {"cost_usd": 50.0, "input_tokens": 999}),
  ]),
  rs(codex, [
    span("session_task.turn", D1, 10, cx("gpt-5-codex", 1_000_000, 100_000, 2_000_000)),   # 1,25 + 1,00 + 0,25
    span("session_task.turn", D2, 5, cx("OpenAI/GPT-5-Codex", o=1000), err=True),          # prefixo e caixa: 0,01
    span("session_task.turn", D1 + 30, 1, cx("gpt-9-sem-preco", 500)),                      # sem preço
  ]),
  rs(router, [
    # jev.decision com o cliente real (pi) e o custo do OpenRouter
    span("jev.decision", D1, 0.5, {"oute.agent": "pi", "gen_ai.response.model": "openai/gpt-oss-20b",
         "gen_ai.usage.input_tokens": 50, "gen_ai.usage.output_tokens": 10, "oute.cost_usd": 0.0004}),
    # span do LiteLLM da mesma chamada (oute.agent=router): fora das somas, mas o erro conta
    span("litellm_request", D1, 0.5, {"gen_ai.response.model": "openai/gpt-oss-20b", "gen_ai.usage.input_tokens": 50,
         "gen_ai.usage.output_tokens": 10, "gen_ai.usage.cost": 0.0004}, err=True),
    # jev.decision que chegou sem o oute.agent do cliente (ficou o do resource, router): conta mesmo assim
    span("jev.decision", D2, 0.5, {"gen_ai.response.model": "openai/gpt-oss-20b", "gen_ai.usage.input_tokens": 60,
         "gen_ai.usage.output_tokens": 12, "oute.cost_usd": 0.0006}),
  ]),
]}
json.dump(traces, open(f"{tmp}/traces.json", "w"))
def log(t, sev, body): return {"timeUnixNano": str(int(t * 1e9)), "severityNumber": sev, "body": {"stringValue": body}}
logs = {"resourceLogs": [{"resource": {"attributes": kv(codex)}, "scopeLogs": [{"logRecords": [
  log(D1, 17, "erro"), log(D2, 21, "fatal"), log(D1, 9, "info"), log(1735689600, 17, "erro fora da janela")]}]},
  rl(claude, [l for _, l in calls if l] + [
    # o mesmo api_request repetido (outra hora, não é dedupe da ingestão): o custo conta uma vez
    api_request(D1 + 3, rid(calls[0][0]), 0.01, cl()),
    # log sem span: não é chamada
    api_request(D1 + 10, "req_sem_span", 7.0, cl()),
  ]),
]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
PY
studio_prices "$TMP/prices.toml"
printf '[prices."ruim"]\ninput = 1.0\n' >> "$TMP/prices.toml"
WIN='?from=2025-09-27T00:00:00Z&to=2025-09-29'

studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/prices.toml" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
check "ingestão: traces = 200"                         test "$(post traces "$TMP/traces.json")" = 200
check "ingestão: mesmo lote reenviado = 200"           test "$(post traces "$TMP/traces.json")" = 200
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200

# ---------------------------------------------------------------- 1. token e janela
check "sem token: 401"                                 test "$(code "$STUDIO_URL/v1/usage$WIN")" = 401
check "token errado: 401"                              test "$(code -H "Authorization: Bearer ${STUDIO_TOKEN}x" "$STUDIO_URL/v1/usage$WIN")" = 401
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
check "com token: 200"                                 test "$(code "${A[@]}" "$STUDIO_URL/v1/usage$WIN")" = 200
check "padrão (24 h): 200"                             test "$(code "${A[@]}" "$STUDIO_URL/v1/usage")" = 200
check "from sem to: 400"                               test "$(code "${A[@]}" "$STUDIO_URL/v1/usage?from=2025-09-27")" = 400
check "from inválido: 400"                             test "$(code "${A[@]}" "$STUDIO_URL/v1/usage?from=ontem&to=2025-09-29")" = 400
check "from antes de 1970: 400"                        test "$(code "${A[@]}" "$STUDIO_URL/v1/usage?from=1900-01-01&to=2025-09-29")" = 400
check "to além de 2262: 400"                           test "$(code "${A[@]}" "$STUDIO_URL/v1/usage?from=2025-09-27&to=9999-01-01")" = 400
check "from depois de to: 400"                         test "$(code "${A[@]}" "$STUDIO_URL/v1/usage?from=2025-09-29&to=2025-09-27")" = 400
check "from/to junto com hours: 400"                   test "$(code "${A[@]}" "$STUDIO_URL/v1/usage$WIN&hours=3")" = 400
check "hours inválido: 400"                            test "$(code "${A[@]}" "$STUDIO_URL/v1/usage?hours=x")" = 400
check "hours fora do limite: 400"                      test "$(code "${A[@]}" "$STUDIO_URL/v1/usage?hours=0")" = 400
check "POST no /v1/usage: 405 (só leitura)"            test "$(code -X POST "${A[@]}" "$STUDIO_URL/v1/usage")" = 405

# ---------------------------------------------------------------- 2. totais, custo, não contar duas vezes
R="$(usage "$WIN")"
echo "$R" > "$TMP/usage.json"
T='.totals'
check "janela devolvida na resposta"                   jqe '.from == "2025-09-27T00:00:00Z" and .to == "2025-09-29T00:00:00Z"' <<<"$R"
check "hora do fato: 9 chamadas (fora da janela e tool fora)" jqe "$T.calls == 9" <<<"$R"
check "spans: todos os da janela (chamada ou não)"     jqe "$T.spans == 11" <<<"$R"
check "custo real = 0,061 (Claude + jev.decision)"     jqe "$T.cost.real_usd | $(usd .) == 61000" <<<"$R"
check "estimado = 5,51 (Claude sem custo + Codex)"     jqe "$T.cost.estimated_usd | $(usd .) == 5510000" <<<"$R"
check "chamadas: 5 reais, 3 estimadas, 1 sem preço"    jqe "$T.cost | .real_calls == 5 and .estimated_calls == 3 and .unpriced_calls == 1" <<<"$R"
check "sem preço listado (nunca zero)"                 jqe '.unpriced_models == ["gpt-9-sem-preco"]' <<<"$R"
check "tokens: LiteLLM e span fora do modelo não somam" jqe "$T.tokens | .input == 2000920 and .output == 101097 and .cache_read == 2001000 and .cache_creation == 10" <<<"$R"
check "erros: 2 spans (Codex + LiteLLM) e 2 logs"      jqe "$T.errors == {spans: 2, logs: 2, total: 4}" <<<"$R"
check "preços carregados e entrada inválida avisada"   jqe '.prices.models == 2 and (.prices.errors | length == 1 and (.[0] | test("ruim.*output")))' <<<"$R"

# ---------------------------------------------------------------- 3. linhas host × agente × modelo
row() { jq -c --arg h "$1" --arg a "$2" --arg m "$3" '.rows[] | select(.host == $h and .agent == $a and (.model // "") == $m)' <<<"$R"; }
C="$(row oute-server claude claude-sonnet-5)"
check "Claude: real e estimado separados na mesma linha" jqe "$(usd .cost.real_usd) == 60000 and $(usd .cost.estimated_usd) == 3000000 and .cost.real_calls == 3 and .cost.estimated_calls == 1" <<<"$C"
check "Claude: custo real do log api_request; repetido e log sem span não somam" jqe ".calls == 4 and .spans == 4" <<<"$C"
check "Claude: p95 das chamadas = 3850 ms"             jqe '(.latency_p95_ms | round) == 3850' <<<"$C"
X="$(row oute-mac codex gpt-5-codex)"
check "Codex: só estimado (2,50), real null"           jqe ".cost.real_usd == null and $(usd .cost.estimated_usd) == 2500000 and .cost.estimated_calls == 1" <<<"$X"
check "Codex: tokens de entrada, saída e cache"        jqe '.tokens == {input: 1000000, output: 100000, cache_read: 2000000, cache_creation: 0}' <<<"$X"
check "Codex: preço achado sem prefixo e sem caixa"    jqe "$(usd .cost.estimated_usd) == 10000 and .errors.spans == 1" <<<"$(row oute-mac codex OpenAI/GPT-5-Codex)"
U="$(row oute-mac codex gpt-9-sem-preco)"
check "sem preço: estimado null, nunca 0"              jqe '.cost.estimated_usd == null and .cost.unpriced_calls == 1 and .tokens.input == 500' <<<"$U"
# histórico até 2026-09-30 (#218): custo passado do jev.decision continua no /v1/usage
check "jev.decision conta para o cliente (pi)"         jqe ".calls == 1 and $(usd .cost.real_usd) == 400 and .tokens.input == 50" <<<"$(row oute-server pi openai/gpt-oss-20b)"
RT="$(row oute-server router openai/gpt-oss-20b)"
check "router: só o jev.decision sem cliente soma"     jqe ".calls == 1 and $(usd .cost.real_usd) == 600 and .tokens.input == 60" <<<"$RT"
check "router: erro do LiteLLM conta como erro"        jqe '.errors.spans == 1' <<<"$RT"
check "logs de erro: host × agente, modelo null"       jqe '.calls == 0 and .spans == 0 and .errors == {spans: 0, logs: 2, total: 2}' <<<"$(row oute-mac codex "")"
check "spans fora do modelo: linha própria (modelo null), sem chamada" jqe '.calls == 0 and .spans == 1 and .errors.spans == 0' <<<"$(row oute-server claude "")"
check "spans por linha: denominador do erro (router: 1 de 2)" jqe '.spans == 2 and .errors.spans == 1' <<<"$RT"
check "spans por linha somam os da janela"             jqe '([.rows[].spans] | add) == .totals.spans' <<<"$R"

# ---------------------------------------------------------------- 4. série diária (UTC, hora do fato)
ser() { jq -c --arg d "$1" --arg h "$2" --arg a "$3" --arg m "$4" '.series[] | select(.day == $d and .host == $h and .agent == $a and (.model // "") == $m)' <<<"$R"; }
check "série: só os dois dias da janela"               jqe '[.series[].day] | unique == ["2025-09-27", "2025-09-28"]' <<<"$R"
check "série Claude D1: 2 chamadas, real 0,03, p95 3900" jqe ".calls == 2 and $(usd .cost.real_usd) == 30000 and .cost.estimated_usd == null and (.latency_p95_ms | round) == 3900" <<<"$(ser 2025-09-27 oute-server claude claude-sonnet-5)"
check "série Claude D2: real 0,03 + estimado 3,00"     jqe ".calls == 2 and $(usd .cost.real_usd) == 30000 and $(usd .cost.estimated_usd) == 3000000" <<<"$(ser 2025-09-28 oute-server claude claude-sonnet-5)"
check "série: log de erro no dia do fato"              jqe '.errors.logs == 1' <<<"$(ser 2025-09-28 oute-mac codex "")"
check "série soma o mesmo que os totais"               jqe "([.series[].calls] | add) == 9 and ([.series[].cost.real_usd // 0] | add | $(usd .)) == 61000" <<<"$R"

# ---------------------------------------------------------------- 4.1 custo do Claude na borda da janela (#157)
# a chamada de D1 + 60 dura 4 s: o log com o custo sai em D1 + 64, depois do fim da janela
iso() { python3 -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
D1=1759000000
E="$(usage "?from=$(iso $D1)&to=$(iso $((D1 + 62)))")"
check "borda: o span na janela mantém o custo do log de depois do fim" jqe ".rows[] | select(.agent == \"claude\" and .model == \"claude-sonnet-5\") | .calls == 2 and .cost.real_calls == 2 and $(usd .cost.real_usd) == 30000" <<<"$E"
E="$(usage "?from=$(iso $((D1 + 61)))&to=$(iso $((D1 + 120)))")"
check "borda: log na janela sem o span dele não é chamada" jqe '.totals.calls == 0 and .totals.cost.real_usd == null' <<<"$E"

# ---------------------------------------------------------------- 5. hora do fato × chegada
check "últimas 24 h: nada (tudo chegou agora, fato em 2025)" jqe '.totals.calls == 0 and .rows == [] and .series == [] and .totals.cost.real_usd == null and .totals.latency_p95_ms == null' <<<"$(usage)"
# ---------------------------------------------------------------- 5.1 os gráficos da tela /uso (#533)
UH="$(studio_page "${A[@]}" "$STUDIO_URL/uso$WIN")"
G="$(data <<<"$UH")"
check "/uso: os quatro gráficos"                       jqe '[.[] | select(.grafico) | .grafico] == ["uso-custo-dia", "uso-tokens-dia", "uso-custo-role", "uso-custo-phase"]' <<<"$G"
check "/uso: custo por dia = um item por dia (2 dias, 2 colunas)" jqe '([.[] | select(.grafico == "uso-custo-dia")][0].days == "2") and ([.[] | select(.bucket and has("real-usd"))] | length == 2)' <<<"$G"
check "/uso: soma do custo por dia = total da API (real e estimado)" bash -c 'jq -n -e --argjson g "$1" --argjson t "$2" "
  ([\$g[] | select(.bucket and has(\"real-usd\")) | (.[\"real-usd\"] | select(. != \"\") | tonumber)] | add) as \$r |
  ([\$g[] | select(.bucket and has(\"real-usd\")) | (.[\"estimated-usd\"] | select(. != \"\") | tonumber)] | add) as \$e |
  ((\$r - \$t.real_usd | fabs) < 1e-9) and ((\$e - \$t.estimated_usd | fabs) < 1e-9)" >/dev/null' _ "$G" "$(jq -c '.totals.cost' <<<"$R")"
for K in uso-custo-dia uso-custo-role uso-custo-phase; do
  check "/uso: $K traz o total real e estimado da janela (= API)" bash -c 'jq -n -e --argjson g "$1" --argjson t "$2" --arg k "$3" "
    [\$g[] | select(.grafico == \$k)][0] | ((.[\"real-usd\"] | tonumber) - \$t.real_usd | fabs) < 1e-9 and ((.[\"estimated-usd\"] | tonumber) - \$t.estimated_usd | fabs) < 1e-9" >/dev/null' _ "$G" "$(jq -c '.totals.cost' <<<"$R")" "$K"
done
check "/uso: barras de papel e de fase: 1 linha cada, com o custo do total (a API só tem avulsa e desconhecida)" bash -c 'jq -n -e --argjson g "$1" --argjson t "$2" "
  ([\$g[] | select(.nome)] | length == 2) and ([\$g[] | select(.nome) | ((.[\"real-usd\"] | tonumber) - \$t.real_usd | fabs) < 1e-9 and ((.[\"estimated-usd\"] | tonumber) - \$t.estimated_usd | fabs) < 1e-9] | all)" >/dev/null' _ "$G" "$(jq -c '.totals.cost' <<<"$R")"
check "/uso: tokens por dia = tokens da API (entrada, saída, cache)" bash -c 'jq -n -e --argjson g "$1" --argjson t "$2" "
  [\$g[] | select(.grafico == \"uso-tokens-dia\")][0] as \$c |
  (\$c.input | tonumber) == \$t.input and (\$c.output | tonumber) == \$t.output and (\$c[\"cache-read\"] | tonumber) == \$t.cache_read and (\$c[\"cache-creation\"] | tonumber) == \$t.cache_creation" >/dev/null' _ "$G" "$(jq -c '.totals.tokens' <<<"$R")"
check "/uso: tokens: a soma das colunas = a do gráfico" bash -c 'jq -n -e --argjson g "$1" "
  [\$g[] | select(.grafico == \"uso-tokens-dia\")][0] as \$c |
  ([\$g[] | select(.bucket and has(\"input\")) | (.input | tonumber) + (.output | tonumber) + (.[\"cache-read\"] | tonumber) + (.[\"cache-creation\"] | tonumber)] | add) ==
  ((\$c.input | tonumber) + (\$c.output | tonumber) + (\$c[\"cache-read\"] | tonumber) + (\$c[\"cache-creation\"] | tonumber))" >/dev/null' _ "$G"
check "/uso: informado pela fonte × estimado distinguidos por texto e traço"  bash -c 'grep -q "Informado pela fonte" <<<"$1" && grep -q "Estimado ≈" <<<"$1" && grep -q "class=\"estimado\"" <<<"$1" && grep -q "class=\"real\"" <<<"$1"' _ "$UH"
check "/uso: entrada, saída e cache distinguidos por texto e traço" bash -c 'for w in "Entrada (" "Saída (" "Cache, leitura" "t-ent" "t-sai" "t-cache"; do grep -q "$w" <<<"$1" || exit 1; done' _ "$UH"
check "/uso: sem style= nas tags dos gráficos (CSP)"    bash -c '! grep -q "style=" <<<"$1"' _ "$UH"
check "/uso: as tabelas por papel e por fase seguem na tela" jqe '([.[] | select(.uso == "role")] | length) == 1 and ([.[] | select(.uso == "phase")] | length) == 1' <<<"$G"
GE="$(data <<<"$(studio_page "${A[@]}" "$STUDIO_URL/uso?from=2030-01-01&to=2030-01-02")")"
check "/uso: janela vazia, gráficos sem coluna e sem barra" jqe '([.[] | select(.bucket or .nome)] | length) == 0 and ([.[] | select(.grafico)] | length) == 4' <<<"$GE"

studio_stop

# ---------------------------------------------------------------- 6. lógica reusável (#204-#206), direto no módulo
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/s/db.duckdb" "$TMP/prices.toml" "$ROOT/config/agent-studio/config.toml" "$ROOT/config/select/models.toml" > "$TMP/py.out" 2>&1 <<'PY'
import sys, duckdb
from agent_studio import config, cost, otlp, usage
from agent_studio.store import Store
from otlp_json import rs, span
from pycheck import check as out
db, test_cfg, repo_cfg = sys.argv[1:4]
P = cost.ModelPrice
out("estimativa sem preço = None", cost.estimate_cost_usd(10, 10, 0, 0, None) is None)
out("estimativa pelos 4 eixos", round(cost.estimate_cost_usd(1e6, 1e6, 1e6, 1e6, P(1, 2, 0.5, 4)), 9) == 7.5)
out("cache ausente = preço de input", P.parse({"input": 2, "output": 8}) == P(2.0, 8.0, 2.0, 2.0))
for bad in ({"input": -1, "output": 1}, {"input": 1}, {"input": 1, "output": True}, {"input": 1, "output": 1, "ouput": 2}, "x"):
    try:
        P.parse(bad); out(f"preço inválido recusado: {bad}", False)
    except ValueError:
        out(f"preço inválido recusado: {bad}", True)
t = cost.PriceTable({"GPT-5": P(1, 1, 1, 1)})
out("busca sem caixa e sem prefixo", t.lookup("openai/gpt-5") is not None and t.lookup("gpt-5") is not None)
out("busca de modelo vazio/desconhecido = None", t.lookup(None) is None and t.lookup("x/y") is None)
c = config.load(repo_cfg)
out("config do repo carrega sem erro e tem o Codex", not c.errors and c.prices.lookup("gpt-5-codex") is not None)
out("config do repo: preço de reserva dos modelos Claude da tabela do ADR-02 (#157)",
    all(c.prices.lookup(m) is not None for m in ("claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5-20251001")))
# unpriced_models vazio para toda a tabela do ADR-02 (Claude e reserva gpt-6-*), com o preço do config do repo (#157)
import tomllib
sel = tomllib.load(open(sys.argv[4], "rb"))
table = sorted({m for blk in (sel["default"], *sel["line"], *sel["exception"]) for k, m in blk.items() if k in ("claude", "codex")})
out("tabela do ADR-02 lida: Claude e reserva", {"gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "claude-opus-5-5"} <= set(table))
stp = Store(":memory:")
rp = {"host.name": "h", "oute.agent": "codex"}
sp = [span("session_task.turn", 1759000000 + i, 1, {"model": m, "codex.turn.token_usage.non_cached_input_tokens": 1000,
      "codex.turn.token_usage.output_tokens": 100}) for i, m in enumerate(table)]
stp.write({"spans": otlp.span_rows({"resourceSpans": [rs(rp, sp)]}, 1), "logs": []})
gp = usage.aggregate(stp.con, 1759000000 * 10**9, (1759000000 + 100) * 10**9, c.prices, ("model",))
out("tabela do ADR-02 sem preço: nenhum modelo", not any(v["unpriced_models"] or v["unpriced_calls"] for v in gp.values()) and len(gp) == len(table))
out("reserva gpt-6-*: 4 eixos do models.dev", [c.prices.lookup(m) for m in ("gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna")]
    == [P(10, 50, 1, 12.5), P(2, 10, 0.1, 2.5), P(0.1, 0.5, 0.01, 0.125)])
out("reserva gpt-6-*: custo estimado de 1000 de entrada + 100 de saída", [round(gp[(m,)]["estimated_usd"], 9) for m in ("gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna")] == [0.015, 0.003, 0.00015])
stp.close()
out("config ausente: vazia, com o motivo", (lambda c: len(c.prices) == 0 and "não encontrada" in c.errors[0])(config.load("/nao/existe.toml")))
import tempfile, os
with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
    f.write("prices = [1, 2]\n")
out("[prices] que não é tabela: vazia, com o motivo", "não é tabela" in config.load(f.name).errors[0])
with open(f.name, "w") as g:
    g.write("[prices\n")
out("TOML inválido: vazia, com o motivo", "inválida" in config.load(f.name).errors[0])
os.unlink(f.name)
con = duckdb.connect(db, read_only=True)
lo, hi = 1758931200 * 10**9, 1759104000 * 10**9
g = usage.aggregate(con, lo, hi, config.load(test_cfg).prices, ("agent",))
cx = g[("codex",)]
out("agrupamento só por agente: estimado somado entre modelos", round(cx["estimated_usd"], 9) == 2.51 and cx["unpriced_calls"] == 1)
out("agrupamento só por agente: erros de span e log", cx["span_errors"] == 1 and cx["log_errors"] == 2)
try:
    usage.aggregate(con, lo, hi, config.load(test_cfg).prices, ("rodada",)); out("chave inválida recusada", False)
except ValueError:
    out("chave inválida recusada", True)
# `usage()` lê o DuckDB uma vez e reagrupa (#504): o resultado é o mesmo de uma consulta por corte, p95 incluído
pr = config.load(test_cfg).prices
U = usage.usage(con, lo, hi, pr)
def rnd(x):
    # a soma de DOUBLE em paralelo muda de ordem entre execuções (diferença na última casa): compara arredondado
    if isinstance(x, float):
        return round(x, 6)
    if isinstance(x, dict):
        return {k: rnd(v) for k, v in x.items()}
    return [rnd(v) for v in x] if isinstance(x, list) else x
def cut(keys):
    return rnd([usage.render(k, a, keys) for k, a in usage._sorted(usage.aggregate(con, lo, hi, pr, keys))])
out("usage(): totals e cortes iguais a um aggregate por corte",
    rnd(U["totals"]) == rnd(usage.render((), usage.aggregate(con, lo, hi, pr, ())[()], ())) and rnd(U["rows"]) == cut(("host", "agent", "model"))
    and rnd(U["series"]) == cut(("day", "host", "agent", "model")) and rnd(U["by_role"]) == cut(("role",)) and rnd(U["by_phase"]) == cut(("phase",)))
out("usage(): a janela de teste tem dados e p95 nas linhas", len(U["rows"]) > 1 and any(r["latency_p95_ms"] for r in U["rows"]))

# custo do Claude pelo log (#157): casos de borda da regra, num banco em memória montado pela ingestão
from otlp_json import api_request, claude_call, rl, rs, span
st = Store(":memory:")
res = {"host.name": "h", "oute.agent": "claude"}
T0 = 1759000000
a = claude_call(T0, 1, {"model": "claude-sonnet-5", "cost_usd": 0.5}, 9.0)        # custo no span e no log
b = claude_call(T0 + 10, 1, {"model": "claude-sonnet-5"})                       # log com o custo em texto
c = claude_call(T0 + 20, 1, {"model": "claude-sonnet-5"})                       # evento com o prefixo
d = span("session_task.turn", T0 + 30, 1, {"model": "gpt-9-sem-preco", "request_id": "req_codex"})
e = claude_call(T0 + 40, 1, {"model": "claude-sonnet-5"}, 0.125)                # log 30 min depois do fim da janela
f = claude_call(T0 + 50, 1, {"model": "claude-sonnet-5", "input_tokens": 1_000_000}, 0.0)  # custo que não é número
rid = lambda s: next(x["value"]["stringValue"] for x in s["attributes"] if x["key"] == "request_id")
lb = api_request(T0 + 11, rid(b[0]), 0.0, {})
lb["attributes"][-1]["value"] = {"stringValue": "0.25"}
lc = api_request(T0 + 21, rid(c[0]), 0.75, {})
lc["attributes"] = [x for x in lc["attributes"] if x["key"] != "event.name"]
lc["eventName"] = "claude_code.api_request"
le = e[1]
le["timeUnixNano"] = str((T0 + 41 + 1800) * 10**9)
lf = f[1]
lf["attributes"] = [x if x["key"] != "cost_usd" else {"key": "cost_usd", "value": {"stringValue": "n/d"}} for x in lf["attributes"]]
traces = {"resourceSpans": [rs(res, [a[0], b[0], c[0], d, e[0], f[0]])]}
logs = {"resourceLogs": [rl(res, [a[1], lb, lc, api_request(T0 + 31, "req_codex", 5.0, {}), le, lf])]}
st.write({"spans": otlp.span_rows(traces, 1), "logs": otlp.log_rows(logs, 1)})
g = usage.aggregate(st.con, T0 * 10**9, (T0 + 60) * 10**9, cost.PriceTable({"claude-sonnet-5": P(3, 15, 3, 3)}), ("model",))
cl, cx = g[("claude-sonnet-5",)], g[("gpt-9-sem-preco",)]
out("custo no span vale antes do log; texto e prefixo do evento aceitos; borda com folga",
    cl["real_calls"] == 4 and round(cl["real_usd"], 9) == 0.5 + 0.25 + 0.75 + 0.125)
out("custo do log que não é número: a chamada cai no estimado (nunca zero)",
    cl["estimated_calls"] == 1 and round(cl["estimated_usd"], 9) == 3.0)
out("api_request só dá custo ao span do Claude (o do Codex segue sem preço)", cx["real_calls"] == 0 and cx["unpriced_calls"] == 1)
sql, params = cost.window_spans_with_cost(0, 10)
out("janela que começa no zero: a folga não fica negativa", params[-2] == 0)
# junção só por igualdade (#504): o plano não pode ter laço aninhado (era quadrático: ~30 s em /uso de 7 d)
plan = " ".join(r[1] for r in st.con.execute("EXPLAIN SELECT count(*) FROM " + sql, params).fetchall())
out("junção com os logs de custo: hash join, sem laço aninhado", "HASH_JOIN" in plan and not any(
    n in plan for n in ("NESTED_LOOP_JOIN", "BLOCKWISE_NL_JOIN", "CROSS_PRODUCT", "PIECEWISE_MERGE_JOIN")))
st.close()
# span do Claude sem request_id e log repetido do mesmo request_id: sem custo inventado, um custo só por chamada
st2 = Store(":memory:")
g1 = claude_call(T0, 1, {"model": "claude-sonnet-5"}, 1.5)
g2 = claude_call(T0 + 5, 1, {"model": "claude-sonnet-5"})
g2[0]["attributes"] = [x for x in g2[0]["attributes"] if x["key"] != "request_id"]
dup = api_request(T0 + 2, rid(g1[0]), 9.0, {})
dup["timeUnixNano"] = str((T0 + 3) * 10**9)
st2.write({"spans": otlp.span_rows({"resourceSpans": [rs(res, [g1[0], g2[0]])]}, 1),
           "logs": otlp.log_rows({"resourceLogs": [rl(res, [g1[1], dup])]}, 1)})
g = usage.aggregate(st2.con, T0 * 10**9, (T0 + 60) * 10**9, cost.PriceTable({}), ("model",))[("claude-sonnet-5",)]
out("duas linhas do mesmo request_id: uma chamada, custo máximo; span sem request_id não junta",
    g["calls"] == 2 and g["real_calls"] == 1 and g["real_usd"] == 9.0 and g["unpriced_calls"] == 1)
st2.close()
# dados dos gráficos da tela (#533): dia sem chamada entra zerado, custo só estimado ou sem custo não quebra, 10+ dias afinam o eixo
from agent_studio import usage_charts
mk = lambda day, real, est, i=0: {"day": day, "calls": 1, "cost": {"real_usd": real, "estimated_usd": est},
                                  "tokens": {"input": i, "output": 2, "cache_read": 3, "cache_creation": 4}}
dc = usage_charts.days([mk("2025-09-27", 1.0, None, 10), mk("2025-09-27", None, 1.0, 5), mk("2025-09-29", None, 2.0)])
out("gráficos: o dia sem chamada (28) entra zerado entre o primeiro e o último",
    [p["key"] for p in dc["points"]] == ["2025-09-27", "2025-09-28", "2025-09-29"] and dc["points"][1]["tokens"] == 0 and dc["points"][1]["calls"] == 0)
out("gráficos: custo do dia soma real e estimado; fração pelo maior dia",
    dc["points"][0]["real_usd"] == 1.0 and dc["points"][0]["estimated_usd"] == 1.0 and dc["max_cost"] == 2.0
    and dc["points"][0]["real_frac"] == 0.5 and dc["points"][2]["est_frac"] == 1.0)
out("gráficos: tokens do dia somam entrada, saída e cache (leitura + escrita)",
    dc["points"][0]["input"] == 15 and dc["points"][0]["cache"] == 14 and dc["points"][0]["tokens"] == 15 + 4 + 14)
out("gráficos: sem série, nada a desenhar", usage_charts.days([]) == {"points": [], "max_cost": 0, "mid_cost": 0, "max_tokens": 0, "mid_tokens": 0})
long = usage_charts.days([mk("2025-09-01", 1.0, None), mk("2025-09-30", 1.0, None)])["points"]
out("gráficos: 30 dias, rótulo de um a cada 4 no eixo", len(long) == 30 and sum(1 for p in long if p["tick"]) == 8)
sem = usage_charts.bars([{"role": "x", "calls": 1, "cost": {"real_usd": None, "estimated_usd": None}}], "role")
out("gráficos: barra sem custo nenhum fica sem preço e sem largura", sem[0]["priced"] is False and sem[0]["real_frac"] == 0 and sem[0]["est_frac"] == 0)
PY
check_py_lines "$TMP/py.out"

# ---------------------------------------------------------------- 7. sem config e leitura que falha
studio_start "$TMP/n" AGENT_STUDIO_CONFIG="$TMP/nao-existe.toml" || { echo "FAIL agent-studio não subiu sem config"; exit 1; }
post traces "$TMP/traces.json" >/dev/null
post logs "$TMP/logs.json" >/dev/null
R="$(usage "$WIN")"
check "sem config: sobe e responde 200 com o motivo"   jqe '.prices.models == 0 and (.prices.errors[0] | test("não encontrada"))' <<<"$R"
check "sem config: sem estimado, custo real intacto"   jqe ".totals.cost.estimated_usd == null and .totals.cost.unpriced_calls == 4 and $(usd .totals.cost.real_usd) == 61000" <<<"$R"
studio_stop
check "sem config: motivo no stderr"                   grep -q "config não encontrada" "$TMP/n/stderr"
studio_start "$TMP/f" STUDIO_FAIL_USAGE=1 AGENT_STUDIO_CONFIG="$TMP/prices.toml" || { echo "FAIL agent-studio não subiu"; exit 1; }
check "leitura que falha: 500"                         test "$(code "${A[@]}" "$STUDIO_URL/v1/usage$WIN")" = 500
studio_stop

# ---------------------------------------------------------------- 8. compose: config montada só leitura
SVC="$(compose_service agent-studio)"
check "compose: config/agent-studio montada só leitura" grep -qx '      - ./config/agent-studio:/etc/oute/agent-studio:ro' <<<"$SVC"
check "compose: AGENT_STUDIO_CONFIG aponta o arquivo"  grep -qx '      AGENT_STUDIO_CONFIG: /etc/oute/agent-studio/config.toml' <<<"$SVC"

check_end
