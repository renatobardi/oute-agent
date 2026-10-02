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
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init
usage() { curl -s -H "Authorization: Bearer $STUDIO_TOKEN" "$STUDIO_URL/v1/usage${1:-}"; }

# ---------------------------------------------------------------- DuckDB de exemplo
# D1 = 2025-09-27T19:06:40Z, D2 = D1 + 1 dia. Tudo chega agora: a janela de 2025 só acha os fatos pela hora do fato.
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import kv, rs, span
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
traces = {"resourceSpans": [
  rs(claude, [
    span("claude_code.llm_request", D1, 2, cl(input_tokens=100, output_tokens=50, cache_read_tokens=1000, cache_creation_tokens=10, cost_usd=0.01)),
    span("claude_code.llm_request", D1 + 60, 4, cl(input_tokens=200, output_tokens=20, cost_usd=0.02)),
    span("claude_code.llm_request", D2, 1, cl(input_tokens=10, output_tokens=5, cost_usd=0.03)),
    # sem cost_usd: estimado pela tabela (claude-sonnet-5 = 3/M de entrada)
    span("claude_code.llm_request", D2 + 60, 3, cl(input_tokens=1_000_000)),
    # fora da janela (hora do fato em janeiro)
    span("claude_code.llm_request", 1735689600, 1, cl(input_tokens=5, cost_usd=100.0)),
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
  log(D1, 17, "erro"), log(D2, 21, "fatal"), log(D1, 9, "info"), log(1735689600, 17, "erro fora da janela")]}]}]}
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
check "logs de erro: host × agente, modelo null"       jqe '.calls == 0 and .errors == {spans: 0, logs: 2, total: 2}' <<<"$(row oute-mac codex "")"

# ---------------------------------------------------------------- 4. série diária (UTC, hora do fato)
ser() { jq -c --arg d "$1" --arg h "$2" --arg a "$3" --arg m "$4" '.series[] | select(.day == $d and .host == $h and .agent == $a and (.model // "") == $m)' <<<"$R"; }
check "série: só os dois dias da janela"               jqe '[.series[].day] | unique == ["2025-09-27", "2025-09-28"]' <<<"$R"
check "série Claude D1: 2 chamadas, real 0,03, p95 3900" jqe ".calls == 2 and $(usd .cost.real_usd) == 30000 and .cost.estimated_usd == null and (.latency_p95_ms | round) == 3900" <<<"$(ser 2025-09-27 oute-server claude claude-sonnet-5)"
check "série Claude D2: real 0,03 + estimado 3,00"     jqe ".calls == 2 and $(usd .cost.real_usd) == 30000 and $(usd .cost.estimated_usd) == 3000000" <<<"$(ser 2025-09-28 oute-server claude claude-sonnet-5)"
check "série: log de erro no dia do fato"              jqe '.errors.logs == 1' <<<"$(ser 2025-09-28 oute-mac codex "")"
check "série soma o mesmo que os totais"               jqe "([.series[].calls] | add) == 9 and ([.series[].cost.real_usd // 0] | add | $(usd .)) == 61000" <<<"$R"

# ---------------------------------------------------------------- 5. hora do fato × chegada
check "últimas 24 h: nada (tudo chegou agora, fato em 2025)" jqe '.totals.calls == 0 and .rows == [] and .series == [] and .totals.cost.real_usd == null and .totals.latency_p95_ms == null' <<<"$(usage)"
studio_stop

# ---------------------------------------------------------------- 6. lógica reusável (#204-#206), direto no módulo
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/s/db.duckdb" "$TMP/prices.toml" "$ROOT/config/agent-studio/config.toml" > "$TMP/py.out" 2>&1 <<'PY'
import sys, duckdb
from agent_studio import config, cost, usage
from pycheck import check as out
db, test_cfg, repo_cfg = sys.argv[1:]
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
PY
check_py_lines "$TMP/py.out"

# ---------------------------------------------------------------- 7. sem config e leitura que falha
studio_start "$TMP/n" AGENT_STUDIO_CONFIG="$TMP/nao-existe.toml" || { echo "FAIL agent-studio não subiu sem config"; exit 1; }
post traces "$TMP/traces.json" >/dev/null
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
