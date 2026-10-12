#!/usr/bin/env bash
# Testes dos alertas de captura do ai-memory no agent-studio (#725): as métricas `oute.memory.capture.*` do `oute-doctor`
# entram pela ingestão de verdade e ligam `memory_capture` (sessões locais sem captura acima do limite, por host,
# instância e agente) e `memory_hooks_untrusted` (hook do ai-memory do Codex sem `trusted_hash`); o limite e a validade
# do ponto vêm do `[alerts]` da config. Sem Docker.
# Uso: tests/agent-studio-captura.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init

# AT = D1 + 10 dias. Pontos (minutos antes do AT):
#   oute-server/claude: 50% há 20 min e 80% há 10 min (10 locais, 2 capturadas)  -> alerta, desde o de 20 min
#   oute-server/codex:  10% há 10 min (abaixo do limite) e 2 hooks sem trusted_hash -> só o alerta dos hooks
#   oute-mac/claude:    80% há 3 dias e 0% há 5 min                               -> recuperou, sem alerta
#   oute-mac/codex:     20% há 5 min (igual ao limite) e 0 hooks                  -> sem alerta
#   oute-velho/claude:  90% há 9 dias (fora da validade de 7 dias)                -> sem alerta
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import kv
tmp = sys.argv[1]
AT = 1759000000 + 10 * 86400
def rm(host, agent, t, pct=None, local=None, captured=None, hooks=None):
    ns = str(t * 10**9)
    def g(name, unit, point):
        return {"name": name, "unit": unit, "gauge": {"dataPoints": [{"timeUnixNano": ns, **point}]}}
    basis = {"attributes": kv({"oute.memory.capture.basis": "delta"})}
    ms = []
    if pct is not None:
        ms += [g("oute.memory.capture.missing_pct", "%", {"asDouble": float(pct), **basis}),
               g("oute.memory.capture.local", "{session}", {"asInt": str(local), **basis}),
               g("oute.memory.capture.captured", "{session}", {"asInt": str(captured), **basis})]
    if hooks is not None:
        ms.append(g("oute.memory.capture.hooks_untrusted", "{hook}", {"asInt": str(hooks)}))
    return {"resource": {"attributes": kv({"host.name": host, "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": agent})},
            "scopeMetrics": [{"scope": {"name": "oute-emit"}, "metrics": ms}]}
M = 60
metrics = {"resourceMetrics": [
    rm("oute-server", "claude", AT - 20 * M, 50, 10, 5), rm("oute-server", "claude", AT - 10 * M, 80, 10, 2),
    rm("oute-server", "codex", AT - 10 * M, 10, 10, 9, hooks=2),
    rm("oute-mac", "claude", AT - 3 * 86400, 80, 5, 1), rm("oute-mac", "claude", AT - 5 * M, 0, 6, 6),
    rm("oute-mac", "codex", AT - 5 * M, 20, 5, 4, hooks=0),
    rm("oute-velho", "claude", AT - 9 * 86400, 90, 10, 1),
]}
json.dump(metrics, open(f"{tmp}/metrics.json", "w"))
open(f"{tmp}/at", "w").write(str(AT))
PY
AT="$(cat "$TMP/at")"
iso() { local ts="$1"; python3 -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$ts"; return $?; }
alerts() { local ts="$1"; curl -s "${A[@]}" "$STUDIO_URL/v1/alerts?at=$(iso "$ts")"; return $?; }
C='[.alerts[] | select(.type == "memory_capture")]'
K='[.alerts[] | select(.type == "memory_hooks_untrusted")]'

# ---------------------------------------------------------------- 1. com a config do repo (limite 20%, validade 7 dias)
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
check "ingestão: métricas = 200"                            test "$(post metrics "$TMP/metrics.json")" = 200
AL="$(alerts "$AT")"
check "config do repo: sem erro nas chaves novas"           jqe '(.config.errors // []) | map(select(test("memory_capture"))) == []' <<<"$(curl -s "${A[@]}" "$STUDIO_URL/v1/alerts?at=$(iso "$AT")")"
check "captura: só o claude do oute-server alerta"          jqe "$C | length == 1 and .[0].host == \"oute-server\" and .[0].instance == \"oute-agent\" and .[0].evidence.agent == \"claude\"" <<<"$AL"
check "captura: valor 80%, limite 20, em pct"               jqe "$C[0] | .value == 80 and .limit == 20 and .unit == \"pct\"" <<<"$AL"
check "captura: evidência com as duas contagens e a hora"   jqe "$C[0].evidence | .local == 10 and .captured == 2 and .at == \"$(iso $((AT - 600)))\" and .attribute == \"oute.memory.capture.missing_pct\"" <<<"$AL"
check "captura: desde o primeiro ponto acima do limite"     jqe "$C[0].since == \"$(iso $((AT - 1200)))\"" <<<"$AL"
check "captura: 10% (abaixo) e 20% (igual ao limite) não alertam" jqe "$C | all(.evidence.agent != \"codex\")" <<<"$AL"
check "captura: host que voltou a 0% não alerta"            jqe "$C | all(.host != \"oute-mac\")" <<<"$AL"
check "captura: ponto de 9 dias (fora da validade) não alerta" jqe "$C | all(.host != \"oute-velho\")" <<<"$AL"
check "hooks: o codex do oute-server, 2 hooks, limite 0"    jqe "$K | length == 1 and .[0].host == \"oute-server\" and .[0].evidence.agent == \"codex\" and .[0].value == 2 and .[0].limit == 0 and .[0].unit == \"hooks\"" <<<"$AL"
check "hooks: 0 hook sem trusted_hash não alerta"           jqe "$K | all(.host != \"oute-mac\")" <<<"$AL"
check "checks: os dois tipos novos estão ligados"           jqe '.checks.memory_capture == true and .checks.memory_hooks_untrusted == true' <<<"$AL"
OLD="$(alerts $((AT - 86400)))"
check "um dia antes: o Mac ainda estava em 80% (ponto de 2 dias), alerta" jqe "$C | length == 1 and .[0].host == \"oute-mac\" and .[0].value == 80 and .[0].evidence.local == 5 and .[0].evidence.captured == 1" <<<"$OLD"
check "um dia antes: nenhum alerta de hook"                 jqe "$K | length == 0" <<<"$OLD"
# o `GET /v1/tray` e a tela põem título e texto com o `alert_text.with_text` (o tray lê a hora de agora, não a do teste)
T="$(PYTHONPATH="$ROOT/docker/agent-studio" python3 -c 'import json, sys
from agent_studio import alert_text
print(json.dumps(alert_text.with_text(json.load(sys.stdin)["alerts"])))' <<<"$AL")"
check "título e texto do alerta de captura, do que a API devolveu" jqe '[.[] | select(.type == "memory_capture")] | length == 1 and .[0].title == "Captura parcial do ai-memory" and .[0].text == "claude: 10 sessões locais, 2 capturadas; 80% sem captura (limite 20%)"' <<<"$T"
check "título e texto do alerta dos hooks, do que a API devolveu" jqe '[.[] | select(.type == "memory_hooks_untrusted")] | length == 1 and (.[0].title | startswith("Hook do Codex sem trusted_hash")) and .[0].text == "codex: 2 hooks do ai-memory sem trusted_hash no config.toml"' <<<"$T"
studio_stop

# ---------------------------------------------------------------- 2. limite e validade configuráveis
cfg() { local pct="$1" days="$2"; printf '[alerts]\nmemory_capture_max_missing_pct = %s\nmemory_capture_days = %s\n' "$pct" "$days" > "$TMP/cfg.toml"; return 0; }
cfg 5 7
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/cfg.toml" || { echo "FAIL agent-studio não subiu (limite 5)"; cat "$TMP/s/stderr"; exit 1; }
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
AL="$(alerts "$AT")"
check "limite 5%: o codex de 10% e o de 20% também alertam" jqe "$C | map(.host + \"/\" + .evidence.agent) | sort == [\"oute-mac/codex\", \"oute-server/claude\", \"oute-server/codex\"]" <<<"$AL"
check "limite 5%: o limite vai no alerta"                   jqe "$C | all(.limit == 5)" <<<"$AL"
studio_stop
cfg 85 7
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/cfg.toml" || { echo "FAIL agent-studio não subiu (limite 85)"; cat "$TMP/s/stderr"; exit 1; }
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
AL="$(alerts "$AT")"
check "limite 85%: 80% não alerta mais"                     jqe "$C | length == 0" <<<"$AL"
check "limite 85%: o alerta dos hooks não depende dele"     jqe "$K | length == 1" <<<"$AL"
studio_stop
cfg 20 10
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/cfg.toml" || { echo "FAIL agent-studio não subiu (validade 10)"; cat "$TMP/s/stderr"; exit 1; }
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
check "validade de 10 dias: o ponto de 9 dias passa a alertar" jqe "$C | map(.host) | sort == [\"oute-server\", \"oute-velho\"]" <<<"$(alerts "$AT")"
studio_stop

# ---------------------------------------------------------------- 3. texto e config, sem servidor
check "texto dos dois alertas no módulo de texto"           bash -c 'PYTHONPATH="$1/docker/agent-studio" python3 -c "
from agent_studio import alert_text, alerts
a = {\"type\": \"memory_capture\", \"value\": 37.5, \"unit\": \"pct\", \"limit\": 20, \"evidence\": {\"agent\": \"codex\", \"local\": 1200, \"captured\": 750}}
assert alert_text.text(a) == \"codex: 1.200 sessões locais, 750 capturadas; 37,5% sem captura (limite 20%)\", alert_text.text(a)
a[\"evidence\"] = {\"agent\": \"codex\", \"local\": None, \"captured\": None}
assert alert_text.text(a) == \"codex: 37,5% sem captura (limite 20%)\", alert_text.text(a)
h = {\"type\": \"memory_hooks_untrusted\", \"value\": 1, \"unit\": \"hooks\", \"limit\": 0, \"evidence\": {\"agent\": \"codex\"}}
assert alert_text.text(h) == \"codex: 1 hook do ai-memory sem trusted_hash no config.toml\", alert_text.text(h)
assert set(alert_text.TITLES) >= set(alerts.TYPES)
cfg, errs = alerts.AlertConfig.parse({\"memory_capture_max_missing_pct\": 0, \"memory_capture_days\": \"x\"})
assert len(errs) == 2 and cfg.memory_capture_max_missing_pct == 20 and cfg.memory_capture_days == 7, (errs, cfg)
"' _ "$ROOT"
check "o limite do oute-doctor e o da config do repo são o mesmo (20)" bash -c 'grep -qx "memory_capture_max_missing_pct = 20" "$1/config/agent-studio/config.toml" && grep -q "OUTE_DOCTOR_MAX_MISSING_PCT\") or \"20\"" "$1/docker/oute-doctor"' _ "$ROOT"

check_end
