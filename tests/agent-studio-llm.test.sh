#!/usr/bin/env bash
# Testes do consumo do LLM do ai-memory no agent-studio (#459, ADR-08 adendo): o span `ai_memory.llm_request` do
# oute-llm-proxy entra pela ingestão de verdade, vira chamada ao modelo (agente `ai-memory`, custo real do
# `oute.cost_usd`) no `/v1/usage` e na tela `/uso`, com o modelo com preço da config do repo; e o alerta `llm_proxy_down`
# (heartbeat `oute.llm_proxy.up` parado) liga e desliga. Sem Docker.
# Uso: tests/agent-studio-llm.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init

# D1 = 2025-09-27T19:06:40Z. O modelo do ai-memory é o que o proxy grava (openai/gpt-oss-120b, preço na config do repo).
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import claude_call, kv, rs, span
tmp = sys.argv[1]
D1 = 1759000000
proxy = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute-llm-proxy", "oute.agent": "ai-memory"}
mac = {"host.name": "oute-mac", "oute.instance": "oute-agent", "service.name": "oute-llm-proxy", "oute.agent": "ai-memory"}
M = "openai/gpt-oss-120b"
def call(t, dur, attrs, err=False):
    return span("ai_memory.llm_request", t, dur,
                {"oute.agent": "ai-memory", "gen_ai.request.model": M, "gen_ai.response.model": M, **attrs}, err)
claude = {"host.name": "oute-server", "service.name": "claude-code", "oute.agent": "claude"}
c_span, c_log = claude_call(D1, 2, {"model": "claude-sonnet-5", "input_tokens": 10, "output_tokens": 5}, 0.5)
traces = {"resourceSpans": [
  rs(proxy, [
    call(D1, 1.5, {"gen_ai.usage.input_tokens": 100, "gen_ai.usage.output_tokens": 30, "gen_ai.usage.cache_read_input_tokens": 20,
                   "oute.cost_usd": 0.000321, "http.response.status_code": 200}),
    call(D1 + 10, 1.0, {"gen_ai.usage.input_tokens": 1000000, "gen_ai.usage.output_tokens": 1000000, "http.response.status_code": 200}),  # sem custo: estimado
    call(D1 + 20, 0.5, {"oute.llm.usage_missing": True, "http.response.status_code": 200}),
    call(D1 + 30, 0.2, {"http.response.status_code": 500, "oute.llm.usage_missing": True}, err=True),
  ]),
  rs(mac, [call(D1 + 40, 2.0, {"gen_ai.usage.input_tokens": 200, "gen_ai.usage.output_tokens": 50, "oute.cost_usd": 0.0004})]),
  rs(claude, [c_span]),
]}
json.dump(traces, open(f"{tmp}/traces.json", "w"))
json.dump({"resourceLogs": [{"resource": {"attributes": kv(claude)}, "scopeLogs": [{"logRecords": [c_log]}]}]}, open(f"{tmp}/logs.json", "w"))
# heartbeat do proxy: oute-server parado há 20 min no AT; oute-mac em dia; oute-nunca sem heartbeat
def hb(host, t):
    pt = {"timeUnixNano": str(t * 10**9), "asInt": "1", "attributes": kv({"oute.llm_proxy.key_present": True})}
    return {"resource": {"attributes": kv({"host.name": host, "oute.instance": "oute-agent", "service.name": "oute-llm-proxy", "oute.agent": "ai-memory"})},
            "scopeMetrics": [{"metrics": [{"name": "oute.llm_proxy.up", "unit": "1", "gauge": {"dataPoints": [pt]}}]}]}
AT = D1 + 3600
metrics = {"resourceMetrics": [hb("oute-server", AT - 20 * 60), hb("oute-server", AT - 25 * 60), hb("oute-mac", AT - 30)]}
json.dump(metrics, open(f"{tmp}/metrics.json", "w"))
open(f"{tmp}/at", "w").write(str(AT))
PY
AT="$(cat "$TMP/at")"
WIN='?from=2025-09-27T00:00:00Z&to=2025-09-29'

studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
check "ingestão: traces = 200"                         test "$(post traces "$TMP/traces.json")" = 200
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200
check "ingestão: métricas = 200"                       test "$(post metrics "$TMP/metrics.json")" = 200
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
R="$(curl -s "${A[@]}" "$STUDIO_URL/v1/usage$WIN")"
row() { jq -c --arg h "$1" --arg a "$2" '.rows[] | select(.host == $h and .agent == $a)' <<<"$R"; }

# ---------------------------------------------------------------- 1. /v1/usage
S="$(row oute-server ai-memory)"
check "ai-memory: linha própria com o modelo e 4 chamadas"  jqe '.model == "openai/gpt-oss-120b" and .calls == 4' <<<"$S"
check "ai-memory: tokens de entrada, saída e cache"         jqe '.tokens == {input: 1000100, output: 1000030, cache_read: 20, cache_creation: 0}' <<<"$S"
check "ai-memory: custo real = usage.cost (1 chamada)"      jqe "$(usd .cost.real_usd) == 321 and .cost.real_calls == 1" <<<"$S"
check "ai-memory: sem custo, estimado pelo preço do modelo" jqe "$(usd .cost.estimated_usd) == 207000 and .cost.estimated_calls == 3 and .cost.unpriced_calls == 0" <<<"$S"
check "ai-memory: erro 5xx conta como erro de span"         jqe '.errors.spans == 1' <<<"$S"
check "ai-memory: p95 das chamadas"                         jqe '.latency_p95_ms > 0' <<<"$S"
check "modelo com preço: não aparece como sem preço"        jqe '.unpriced_models == []' <<<"$R"
check "ai-memory no Mac: outro host, mesmo agente"          jqe "$(usd .cost.real_usd) == 400 and .calls == 1" <<<"$(row oute-mac ai-memory)"
check "o Claude não mudou (custo real do log)"              jqe "$(usd .cost.real_usd) == 500000 and .calls == 1" <<<"$(row oute-server claude)"
check "soma por agente bate com o total (chamadas)"         jqe '([.rows[].calls] | add) == .totals.calls and .totals.calls == 6' <<<"$R"
check "soma por agente bate com o total (real, micro-US\$)" jqe "([.rows[].cost.real_usd // 0] | add | $(usd .)) == (.totals.cost.real_usd | $(usd .))" <<<"$R"
check "soma por agente bate com o total (estimado)"         jqe "([.rows[].cost.estimated_usd // 0] | add | $(usd .)) == (.totals.cost.estimated_usd | $(usd .))" <<<"$R"

# ---------------------------------------------------------------- 2. tela /uso: o consumo do ai-memory está nos totais
P="$(studio_page "${A[@]}" "$STUDIO_URL/uso$WIN" | data)"
check "/uso: total da janela inclui as 5 chamadas do ai-memory" jqe '.[] | select(.tag == "p" and .calls == "6")' <<<"$P"
check "/uso: custo real do total = o da API"                  jqe ".[] | select(.tag == \"p\" and .calls == \"6\") | (.[\"real-usd\"] | $(usd .)) == $(jq "(.totals.cost.real_usd | $(usd .))" <<<"$R")" <<<"$P"
check "/uso: chamada do ai-memory (sem sessão) cai em standalone" jqe '.[] | select(.role == "standalone") | (.calls | tonumber) >= 5' <<<"$P"

# ---------------------------------------------------------------- 3. alerta do proxy fora
iso() { python3 -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
alerts() { curl -s "${A[@]}" "$STUDIO_URL/v1/alerts?at=$(iso "$1")"; }
L='[.alerts[] | select(.type == "llm_proxy_down")]'
AL="$(alerts "$AT")"
check "proxy parado há 20 min no oute-server: alerta ligado" jqe "$L | length == 1 and .[0].host == \"oute-server\" and .[0].unit == \"seconds\" and .[0].value == 1200 and .[0].limit == 300" <<<"$AL"
check "alerta: evidência com o último heartbeat"            jqe "$L[0].evidence.last_heartbeat == \"$(iso $((AT - 20 * 60)))\"" <<<"$AL"
check "proxy em dia (Mac, heartbeat há 30 s): sem alerta"   jqe "$L | all(.host != \"oute-mac\")" <<<"$AL"
check "host sem nenhum heartbeat: sem alerta"               jqe "$L | all(.host != \"oute-nunca\")" <<<"$AL"
check "heartbeat de volta (5 min antes): alerta desligado"  jqe "$L | length == 0" <<<"$(alerts $((AT - 20 * 60 + 4 * 60)))"
check "checks: o tipo novo está ligado"                     jqe '.checks.llm_proxy_down == true' <<<"$AL"
check "texto do alerta no módulo de texto"                  bash -c 'PYTHONPATH="$1/docker/agent-studio" python3 -c "
from agent_studio import alert_text
a = {\"type\": \"llm_proxy_down\", \"value\": 1200, \"unit\": \"seconds\", \"limit\": 300, \"evidence\": {}}
assert alert_text.title(a).startswith(\"Proxy do LLM\"), alert_text.title(a)
assert \"20 min\" in alert_text.text(a), alert_text.text(a)"' _ "$ROOT"

check_end
