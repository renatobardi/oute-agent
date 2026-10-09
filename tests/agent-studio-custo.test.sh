#!/usr/bin/env bash
# Testes do custo por papel e por fase do agent-studio (#433, ADR-08 §9): `GET /v1/usage` devolve `by_role`
# (dispatcher, worker, avulsa) e `by_phase` (só fases do ADR-07, #749) ao lado dos agrupamentos de
# sempre, e a tela `/uso` mostra as duas tabelas. Papel e fase saem dos eventos `oute.task.opened`/`reopened` da sessão
# (e, sem eles, do resource da chamada); nenhum atributo novo. O DuckDB de exemplo nasce pela ingestão de verdade
# (POST /v1/traces e /v1/logs). Sem Docker.
# Uso: tests/agent-studio-custo.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init

# ---------------------------------------------------------------- DuckDB de exemplo
# D1 = 2025-09-27T19:06:40Z. Sessões (todas no oute-server, claude, exceto TA):
#   TD dispatcher (rodada R, fase plan): 2 chamadas Opus com custo real, 0,50 + 0,30.
#   TW worker (rodada R, sessão do swarm, fase build): 1 chamada real 0,10 e 1 estimada (1M de entrada = 3,00), uma
#      chamada com erro; reaberta depois sem fase (vale a primeira conhecida).
#   TA avulsa (sem rodada, aberta sem fase: escolha manual): 1 chamada do Codex estimada (1,25).
#   TB avulsa com fase hostil no evento ("<b>x</b>"): a fase não vale e cai em build (a mais provável, #749); chamada real 0,04.
#   TX sem nenhum evento de abertura, mas com rodada e sessão do swarm no resource: worker/build, real 0,02.
#   TY com evento de outro nome levando oute.task.phase=ops: o evento não vale, fica em build; real 0,03.
#   chamada sem oute.task.id e sem conversa: avulsa/ops (fato sem sessão nem conversa, #749), real 0,07; chamada sem preço de TW: fora das somas (unpriced).
#   Chamada de TW em janeiro de 2025: fora da janela.
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import claude_call, event, kv, rl, rs, span
tmp = sys.argv[1]
D1 = 1759000000
origin = {"host.name": "oute-server", "oute.instance": "oute-agent"}
claude = {**origin, "service.name": "claude-code", "oute.agent": "claude"}
codex = {"host.name": "oute-mac", "oute.instance": "oute-agent", "service.name": "codex_exec", "oute.agent": "codex"}
R = "swarm-0927-1900"
sess = lambda tid, **extra: {**claude, "oute.task.id": tid, **extra}
sonnet, opus = {"model": "claude-sonnet-5"}, {"model": "claude-opus-5"}
TD, TW, TA, TB, TX, TY = ("repo-plan-1", "repo-build-1", "repo-avulsa-1", "repo-hostil-1", "repo-sem-evento-1", "repo-outro-1")
calls = {
  TD: [claude_call(D1, 2, {**opus, "input_tokens": 100}, 0.50), claude_call(D1 + 10, 2, {**opus, "input_tokens": 200}, 0.30)],
  TW: [claude_call(D1 + 20, 2, {**sonnet, "input_tokens": 10}, 0.10),
       claude_call(D1 + 30, 2, {**sonnet, "input_tokens": 1_000_000}),
       claude_call(D1 + 40, 2, {**sonnet, "input_tokens": 5}, 0.05, err=True),
       claude_call(D1 + 50, 2, {"model": "modelo-sem-preco", "input_tokens": 7}),
       claude_call(1735689600, 1, {**sonnet, "input_tokens": 9}, 9.0)],
  TB: [claude_call(D1 + 60, 2, {**sonnet, "input_tokens": 1}, 0.04)],
  TX: [claude_call(D1 + 70, 2, {**sonnet, "input_tokens": 1}, 0.02)],
  TY: [claude_call(D1 + 80, 2, {**sonnet, "input_tokens": 1}, 0.03)],
  "": [claude_call(D1 + 90, 2, {**sonnet, "input_tokens": 1}, 0.07)],
}
res = {TD: sess(TD, **{"oute.swarm.round": R}), TW: sess(TW, **{"oute.swarm.round": R, "oute.swarm.session": "build-1"}),
       TB: sess(TB), TX: sess(TX, **{"oute.swarm.round": R, "oute.swarm.session": "sem-evento"}), TY: sess(TY), "": claude}
traces = {"resourceSpans": [rs(res[t], [s for s, _ in cs]) for t, cs in calls.items()] + [
  rs({**codex, "oute.task.id": TA}, [span("session_task.turn", D1 + 100, 5, {
    "model": "gpt-5-codex", "codex.turn.token_usage.non_cached_input_tokens": 1_000_000})])]}
json.dump(traces, open(f"{tmp}/traces.json", "w"))
n = [0]
def ev(name, tid, extra=None, rnd=None, t=D1 - 100):
    n[0] += 1
    a = {"oute.task.id": tid, "oute.task.repo": "repo", "oute.task.slug": tid, **(extra or {})}
    if rnd: a["oute.swarm.round"] = rnd
    return event(t, name, f"e{n[0]}", a)
events = [
  ev("oute.task.opened", TD, {"oute.task.phase": "plan", "oute.task.origin": "manual"}, R),
  ev("oute.task.opened", TW, {"oute.task.phase": "build", "oute.task.origin": "label", "oute.swarm.session": "build-1"}, R),
  ev("oute.task.reopened", TW, {"oute.swarm.session": "build-1"}, R, D1 + 5),
  ev("oute.task.opened", TA, {"oute.task.origin": "padrao"}),
  ev("oute.task.opened", TB, {"oute.task.phase": "<b>x</b>"}),
  ev("oute.task.opened", TY),
  ev("oute.task.other", TY, {"oute.task.phase": "ops"}),
]
logs = {"resourceLogs": [rl(origin, events)] + [rl(res[t], [l for _, l in cs if l]) for t, cs in calls.items()]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
PY
studio_prices "$TMP/prices.toml"
WIN='from=2025-09-27T00:00:00Z&to=2025-09-29'
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/prices.toml" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
check "ingestão: traces = 200"                         test "$(post traces "$TMP/traces.json")" = 200
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200
A=(-H "Authorization: Bearer $STUDIO_TOKEN")
R="$(curl -s "${A[@]}" "$STUDIO_URL/v1/usage?$WIN")"
role() { jq -c --arg k "$1" '.by_role[] | select(.role == $k)' <<<"$R"; }
phase() { jq -c --arg k "$1" '.by_phase[] | select(.phase == $k)' <<<"$R"; }

# ---------------------------------------------------------------- 1. por papel
check "by_role: os três papéis, nada além"             jqe '[.by_role[].role] | sort == ["avulsa", "dispatcher", "worker"]' <<<"$R"
check "dispatcher: 2 chamadas, real 0,80"              jqe ".calls == 2 and (.cost.real_usd | $(usd .) == 800000) and .cost.estimated_usd == null and .tokens.input == 300" <<<"$(role dispatcher)"
check "worker: real 0,17, custo de lista 3,00 (TW, e TX sem evento de abertura pelo resource)"     jqe ".calls == 5 and (.cost.real_usd | $(usd .) == 170000) and (.cost.listed_usd | $(usd .) == 3000000) and .cost.estimated_usd == null" <<<"$(role worker)"
check "worker: chamada sem preço fora das somas"       jqe ".cost.unpriced_calls == 1 and .cost.real_calls == 3 and .cost.listed_calls == 1 and .cost.estimated_calls == 0 and .cost.claude_no_log_calls == 1 and (.cost.real_calls + .cost.listed_calls + .cost.estimated_calls + .cost.unpriced_calls == .calls)" <<<"$(role worker)"
check "worker: o erro do span entra no grupo"          jqe ".errors.spans == 1" <<<"$(role worker)"
check "avulsa: real 0,14 (TB, TY, sem sessão), lista 1,25 (Codex)" jqe ".calls == 4 and (.cost.real_usd | $(usd .) == 140000) and (.cost.listed_usd | $(usd .) == 1250000) and .cost.estimated_usd == null" <<<"$(role avulsa)"

# ---------------------------------------------------------------- 2. por fase
check "by_phase: só plan, build e ops (fases do ADR-07; nem desconhecida nem interativa)" jqe '[.by_phase[].phase] | sort == ["build", "ops", "plan"]' <<<"$R"
check "plan: o dispatcher"                             jqe ".calls == 2 and (.cost.real_usd | $(usd .) == 800000)" <<<"$(phase plan)"
check "build: TW (primeira fase conhecida vale) e a sessão sem fase (sem evento, hostil, outro evento, Codex): a mais provável" jqe ".calls == 8 and (.cost.real_usd | $(usd .) == 240000) and (.cost.listed_usd | $(usd .) == 4250000) and .cost.estimated_usd == null" <<<"$(phase build)"
check "ops: a chamada sem sessão nem conversa, real 0,07 (#749)" jqe ".calls == 1 and (.cost.real_usd | $(usd .) == 70000) and .cost.estimated_usd == null" <<<"$(phase ops)"
check "nenhuma fase desconhecida nem interativa na resposta" bash -c '! grep -qE "desconhecida|interativa" <<<"$1"' _ "$R"
check "fase hostil não aparece em lugar nenhum"        bash -c '! grep -qF "<b>x</b>" <<<"$1"' _ "$R"

# ---------------------------------------------------------------- 3. as somas batem com o total da janela
sums() { jq -c --arg k "$1" '{calls: ([.[$k][].calls] | add), spans: ([.[$k][].spans] | add), input: ([.[$k][].tokens.input] | add),
  output: ([.[$k][].tokens.output] | add), real: ([.[$k][].cost.real_usd // 0] | add), listed: ([.[$k][].cost.listed_usd // 0] | add), est: ([.[$k][].cost.estimated_usd // 0] | add),
  unpriced: ([.[$k][].cost.unpriced_calls] | add), errors: ([.[$k][].errors.total] | add)}' <<<"$R"; }
TOT="$(jq -c '.totals | {calls, spans, input: .tokens.input, output: .tokens.output, real: .cost.real_usd, listed: (.cost.listed_usd // 0), est: (.cost.estimated_usd // 0),
  unpriced: .cost.unpriced_calls, errors: .errors.total}' <<<"$R")"
check "total: 11 chamadas na janela, 1 sem preço"      jqe '.calls == 11 and .unpriced == 1' <<<"$TOT"
check "soma por papel = total (chamadas, spans, tokens, erros)" bash -c 'test "$(jq -S -c "del(.real, .listed, .est)" <<<"$1")" = "$(jq -S -c "del(.real, .listed, .est)" <<<"$2")"' _ "$(sums by_role)" "$TOT"
check "soma por fase = total (chamadas, spans, tokens, erros)"  bash -c 'test "$(jq -S -c "del(.real, .listed, .est)" <<<"$1")" = "$(jq -S -c "del(.real, .listed, .est)" <<<"$2")"' _ "$(sums by_phase)" "$TOT"
check "soma por papel = total (custo real, de lista e estimado)" bash -c 'jq -n -e --argjson a "$1" --argjson t "$2" "(\$a.real - \$t.real | fabs) < 1e-9 and (\$a.listed - \$t.listed | fabs) < 1e-9 and (\$a.est - \$t.est | fabs) < 1e-9" >/dev/null' _ "$(sums by_role)" "$TOT"
check "soma por fase = total (custo real, de lista e estimado)"  bash -c 'jq -n -e --argjson a "$1" --argjson t "$2" "(\$a.real - \$t.real | fabs) < 1e-9 and (\$a.listed - \$t.listed | fabs) < 1e-9 and (\$a.est - \$t.est | fabs) < 1e-9" >/dev/null' _ "$(sums by_phase)" "$TOT"
check "agrupamentos de sempre seguem na resposta"      jqe '(.rows | length) > 0 and (.series | length) > 0 and (.totals.calls == 11)' <<<"$R"
check "janela vazia: papéis e fases vazios"            jqe '.by_role == [] and .by_phase == [] and .totals.calls == 0' <<<"$(curl -s "${A[@]}" "$STUDIO_URL/v1/usage?from=2030-01-01&to=2030-01-02")"

# ---------------------------------------------------------------- 4. a tela de uso
check "/uso sem login: 303 para o /login"              test "$(code "$STUDIO_URL/uso")$(hdr location "$STUDIO_URL/uso")" = "303/login?next=%2Fuso"
check "/uso com token: 200"                            test "$(code "${A[@]}" "$STUDIO_URL/uso?$WIN")" = 200
check "/uso janela inválida: 400"                      test "$(code "${A[@]}" "$STUDIO_URL/uso?from=ontem&to=2025-09-29")" = 400
check "POST no /uso: 405"                              test "$(code -X POST "${A[@]}" "$STUDIO_URL/uso")" = 405
HTML="$(studio_page "${A[@]}" "$STUDIO_URL/uso?$WIN")"
P="$(data <<<"$HTML")"
check "tela: tabela por papel com as três linhas"      jqe '[.[] | select(.role) | .role] | sort == ["avulsa", "dispatcher", "worker"]' <<<"$P"
check "tela: tabela por fase com as três linhas (ADR-07)" jqe '[.[] | select(.phase) | .phase] | sort == ["build", "ops", "plan"]' <<<"$P"
check "tela: linha do dispatcher = a da API"           jqe ".[] | select(.role == \"dispatcher\") | .calls == \"2\" and (.[\"real-usd\"] | $(usd .) == 800000)" <<<"$P"
check "tela: mais cara primeiro (build antes de plan)" jqe '[.[] | select(.phase) | .phase] | index("build") < index("plan")' <<<"$P"
check "tela: total da janela"                          jqe '.[] | select(.tag == "p" and .calls == "11")' <<<"$P"
check "tela: gráfico por papel com as três linhas, por fase com as três e por assinatura com as linhas da tabela" jqe '([.[] | select(.subscription)] | length) as $s | ([.[] | select(.grafico == "uso-custo-role")] | length == 1) and ([.[] | select(.grafico == "uso-custo-phase")] | length == 1) and ([.[] | select(.nome)] | length == 6 + $s)' <<<"$P"
check "tela: barras de papel, fase e assinatura somam três vezes o total (real, de lista e estimado)" bash -c 'jq -n -e --argjson g "$1" "
  ([\$g[] | select(.nome)] | map(.[\"real-usd\"] | select(. != \"\") | tonumber) | add) as \$r | ([\$g[] | select(.nome)] | map(.[\"listed-usd\"] | select(. != \"\") | tonumber) | add) as \$l | ([\$g[] | select(.nome)] | map(.[\"estimated-usd\"] | select(. != \"\") | tonumber) | add) as \$e |
  [\$g[] | select(.grafico == \"uso-custo-role\")][0] as \$c | ((\$r / 3 - (\$c[\"real-usd\"] | tonumber)) | fabs) < 1e-9 and ((\$l / 3 - (\$c[\"listed-usd\"] | tonumber)) | fabs) < 1e-9 and ((\$e // 0) / 3 - (\$c[\"estimated-usd\"] | if . == \"\" then 0 else tonumber end) | fabs) < 1e-9" >/dev/null' _ "$P"
# as dicas de Papel e de Fase (#592): cada uma no cabeçalho da sua coluna, e só nela
TH_ROLE="$(sed -n '/data-uso="role"/,/<\/thead>/p' <<<"$HTML" | grep -o '<th title="[^"]*" aria-sort="[a-z]*" data-col="name">')"
TH_PHASE="$(sed -n '/data-uso="phase"/,/<\/thead>/p' <<<"$HTML" | grep -o '<th title="[^"]*" aria-sort="[a-z]*" data-col="name">')"
check "tela: a coluna Papel leva a dica de dispatcher, worker e avulsa" grep -qF 'title="dispatcher e worker são as sessões de uma rodada do swarm; avulsa, a sessão fora de rodada (e a conversa sem sessão)"' <<<"$TH_ROLE"
check "tela: a coluna Fase leva a dica da fase do ADR-07" grep -qF 'title="a fase do AI-DLC (ADR-07) da conversa: a da abertura ou a derivada depois do fato (label, skill, papel, ação, Jev); as de baixa confiança estão em Fases, onde o Bardi as troca"' <<<"$TH_PHASE"
check "tela: a dica de Papel não está na coluna Fase, nem a de Fase na coluna Papel" bash -c '! grep -qF "aidlc:" <<<"$1" && ! grep -qF "dispatcher e worker" <<<"$2"' _ "$TH_ROLE" "$TH_PHASE"
check "tela: menu com o link do uso"                  grep -q 'href="/uso"' <<<"$HTML"
check "tela: janela vazia avisa"                       grep -q 'Nenhuma chamada ao modelo' <<<"$(studio_page "${A[@]}" "$STUDIO_URL/uso?from=2030-01-01&to=2030-01-02")"

# ---------------------------------------------------------------- 5. nada novo na origem
check "origem: oute-task/oute-emit/oute-swarm sem atributo de prompt, título ou caminho no evento da sessão" \
  bash -c '! grep -nE "oute\.task\.(prompt|title|path|role)" "$1"/docker/oute-emit "$1"/docker/oute-task "$1"/docker/oute-swarm' _ "$ROOT"
check_end
