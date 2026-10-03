#!/usr/bin/env bash
# Testes da tela de sessões do agent-studio (#207, ADR-08 §9): as conversas agrupadas pela sessão do `oute-task`
# (`oute.task.id`) e, sem ela, por `session.id`, com agente, modelo, rodada, tokens, custo e p95 pela lógica do #203.
# O DuckDB e o SurrealDB de exemplo nascem pela ingestão de verdade (POST /v1/traces e /v1/logs, com os eventos
# `oute.task.*` e `oute.swarm.*` virando os registros `sessao` e `rodada`); as páginas são conferidas pelo HTML que
# o servidor devolve (atributos `data-*`). Mais a lógica direto em Python (limites, sem SurrealDB, leitura que
# falha). Sem Docker; o SurrealDB é o binário fixado de tests/lib/surreal.sh.
# Uso: tests/agent-studio-sessions.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init
. "$ROOT/tests/lib/surreal.sh"
trap 'studio_stop; surreal_stop; rm -rf "$TMP"' EXIT
surreal_bin
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não subiu"; }


# ---------------------------------------------------------------- DuckDB e SurrealDB de exemplo
# D1 = 2025-09-27T19:06:40Z. Tudo chega agora: só a hora do fato põe as sessões na janela de 2025.
#   S1 (sessão de rodada, claude, oute-server): 3 conversas. s1-0 começou 2 dias antes (os números são da sessão
#      inteira); s1-a com custo real e estimado; s1-b com outro modelo, um span e um log com erro. Evento
#      `oute.task.opened` com a escolha do seletor (#219: fase, origem, modelo) e um evento de exemplo, de nome
#      qualquer, com o `oute.task.id`.
#   S2 (avulsa, codex, oute-mac): aberta e removida; uma conversa só com custo estimado.
#   S3 (id com HTML, sem evento `oute.task.*`: sem registro `sessao`): uma conversa com modelo sem preço.
#   S4: só o evento `oute.task.opened` (sessão aberta, sem conversa ainda).
#   S0 (janeiro de 2025): fora da janela.
#   Sem sessão: solta-1 (claude), "solta 2/&é" (codex, oute-mac) e solta-jan (fora da janela).
S1=oute-agent-207-tela-20250927190000; S2=lab-ajuste-20250927191000; S3='repo <b>x</b>&y=é'; S4=oute-agent-vazia-20250927192000
RND=swarm-0927-1900
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import api_request, kv, rs
tmp = sys.argv[1]
D1 = 1759000000
S1, S2, S3, S4, S0 = ("oute-agent-207-tela-20250927190000", "lab-ajuste-20250927191000", "repo <b>x</b>&y=é",
                      "oute-agent-vazia-20250927192000", "oute-agent-antiga-20250101000000")
RND = "swarm-0927-1900"
n = [0]
def call(conv, start, dur, attrs, name="claude_code.llm_request", err=False):
    n[0] += 1
    s = {"traceId": f"{n[0]:032x}", "spanId": f"{n[0]:016x}", "name": name,
         "startTimeUnixNano": str(int(start * 1e9)), "endTimeUnixNano": str(int((start + dur) * 1e9)),
         "attributes": kv({"session.id": conv, **attrs})}
    if err: s["status"] = {"code": 2, "message": "comando falhou"}
    return s
# chamada do Claude com custo real, como em produção (#157): o span leva o request_id, e o custo vem no log
# api_request de mesmo request_id, no fim da chamada (guardado em `paid` por resource)
paid = {}
def paid_call(res, conv, start, dur, attrs, cost):
    s = call(conv, start, dur, {**attrs, "request_id": f"req-{n[0] + 1}"})
    paid.setdefault(res, []).append(api_request(start + dur, f"req-{n[0]}", cost, {"session.id": conv, **attrs}))
    return s
server = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "claude-code", "oute.agent": "claude"}
mac = {"host.name": "oute-mac", "oute.instance": "oute-agent", "service.name": "codex_exec", "oute.agent": "codex"}
sonnet, opus = {"model": "claude-sonnet-5"}, {"model": "claude-opus-5"}
codex_turn = {"model": "gpt-5-codex", "codex.turn.token_usage.non_cached_input_tokens": 1_000_000,
              "codex.turn.token_usage.output_tokens": 100_000, "codex.turn.token_usage.cached_input_tokens": 2_000_000}
R1, R0 = "r1", "r0"
res = {R1: {**server, "oute.task.id": S1, "oute.swarm.round": RND}, R0: {**server, "oute.task.id": S0}, "solta": server}
traces = {"resourceSpans": [
  rs(res[R1], [
    paid_call(R1, "s1-0", D1 - 2 * 86400, 1, {**sonnet, "input_tokens": 10}, 0.25),
    paid_call(R1, "s1-a", D1 + 1, 2, {**sonnet, "input_tokens": 100, "output_tokens": 50, "cache_read_tokens": 1000,
                                      "cache_creation_tokens": 10}, 0.01),
    call("s1-a", D1 + 5, 4, {**sonnet, "input_tokens": 1_000_000}),
    paid_call(R1, "s1-b", D1 + 100, 10, {**opus, "input_tokens": 7}, 0.5),
    # não é chamada ao modelo: o cost_usd dele não entra em soma; o erro conta
    call("s1-b", D1 + 111, 1, {"tool_name": "Bash", "cost_usd": 50.0}, name="claude_code.tool", err=True),
  ]),
  rs({**mac, "oute.task.id": S2}, [call("s2-a", D1 + 700, 10, codex_turn, name="session_task.turn")]),
  rs({**server, "oute.task.id": S3}, [call("s3-a", D1 + 300, 1, {"model": "modelo-sem-preco", "input_tokens": 500})]),
  rs(res[R0], [paid_call(R0, "s0-a", 1735689600, 1, {**sonnet, "input_tokens": 5}, 100.0)]),
  rs(server, [
    paid_call("solta", "solta-1", D1 + 400, 3, {**sonnet, "input_tokens": 20}, 0.02),
    paid_call("solta", "solta-jan", 1735689700, 1, {**sonnet, "input_tokens": 5}, 200.0),
  ]),
  rs(mac, [call("solta 2/&é", D1 + 500, 6, codex_turn, name="session_task.turn")]),
]}
json.dump(traces, open(f"{tmp}/traces.json", "w"))
def log(t, body, attrs, name=None, sev=9):
    r = {"timeUnixNano": str(int(t * 1e9)), "severityNumber": sev, "body": {"stringValue": body}, "attributes": kv(attrs)}
    if name: r["eventName"] = name
    return r
def rl(res, recs, scope=None): return {"resource": {"attributes": kv(res)}, "scopeLogs": [{"scope": {"name": scope or ""}, "logRecords": recs}]}
def ev(t, name, eid, attrs): return log(t, name, {"event.name": name, "oute.event.id": eid, **attrs}, name)
oute = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "human"}
oute_mac = {**oute, "host.name": "oute-mac"}
task1 = {"oute.task.id": S1, "oute.task.repo": "oute-agent", "oute.task.slug": "207-tela", "oute.task.agent": "claude",
         "oute.swarm.round": RND, "oute.swarm.session": "207-tela",
         # escolha do seletor no opened (ADR-02, #219; catálogo do ADR-04)
         "oute.task.phase": "build", "oute.task.origin": "label", "oute.task.model": "claude-sonnet-5-5"}
task2 = {"oute.task.id": S2, "oute.task.repo": "lab", "oute.task.slug": "ajuste", "oute.task.agent": "codex",
         # sessão avulsa sem label: a fase veio do Jev, com a confiança (ADR-02, #257)
         "oute.task.phase": "ops", "oute.task.origin": "jev", "oute.task.confidence": 0.87}
logs = {"resourceLogs": [
  rl(oute, [
    ev(D1 - 3 * 86400, "oute.swarm.round.opened", "ev-r1", {"oute.swarm.round": RND, "oute.swarm.repo": "oute-agent",
                                                              "oute.swarm.max": 3, "oute.swarm.label": "studio-tela"}),
    ev(D1 - 3 * 86400 + 5, "oute.swarm.session.spawned", "ev-w1", {"oute.swarm.round": RND, "oute.swarm.session": "207-tela",
                                                                   "oute.swarm.issue": 207, "oute.swarm.session.agent": "claude"}),
    ev(D1 - 3 * 86400 + 10, "oute.task.opened", "ev-t1", task1),
    # evento de nome qualquer com o oute.task.id: entra na página da sessão pela identidade, sem mudança na tela
    ev(D1 - 3 * 86400 + 11, "oute.exemplo.seletor", "ev-sel1", {"oute.task.id": S1, "fase": "build", "origem": "label",
                                                                 "modelo": "claude-sonnet-5", "nota": "<script>alert('ev')</script>"}),
    ev(D1 + 600, "oute.task.opened", "ev-t4", {"oute.task.id": S4, "oute.task.repo": "oute-agent", "oute.task.slug": "vazia",
                                                "oute.task.agent": "shell"}),
  ], "oute-emit"),
  rl(oute_mac, [
    ev(D1 + 650, "oute.task.opened", "ev-t2", task2),
    ev(D1 + 800, "oute.task.removed", "ev-t3", {"oute.task.id": S2, "oute.task.reason": "pr-mergeado"}),
  ], "oute-emit"),
  rl({**server, "oute.task.id": S1, "oute.swarm.round": RND}, [
    log(D1 + 101, "falhou <b>feio</b>", {"session.id": "s1-b"}, "claude_code.api_error", sev=17),
    log(D1 + 2, "claude_code.user_prompt", {"session.id": "s1-a"}, "claude_code.user_prompt"),
  ]),
  *(rl(res[k], recs) for k, recs in paid.items()),
]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
PY
studio_prices "$TMP/prices.toml"
WIN='from=2025-09-27T00:00:00Z&to=2025-09-29'

SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$TMP/prices.toml")
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
C=(-H "Authorization: Bearer $STUDIO_TOKEN")
HX=(-H "HX-Request: true")
# antes de qualquer evento `oute.task.*`: a tabela `sessao` ainda não existe no SurrealDB
check "sem evento nenhum: /sessoes 200, sem aviso"     bash -c 'grep -q "Nenhuma sessão nessa janela" <<<"$1" && ! grep -q data-estado-indisponivel <<<"$1"' _ "$(curl -s "${C[@]}" "$STUDIO_URL/sessoes?$WIN")"
check "ingestão: traces = 200"                         test "$(post traces "$TMP/traces.json")" = 200
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200
check "SurrealDB de exemplo: 3 registros sessao"       test "$(surreal_q 'SELECT count() FROM sessao GROUP ALL' | jq -r '.[0].count')" = 3

# ---------------------------------------------------------------- 1. quem lê
check "sessões sem login: 303 para o /login"           test "$(code "$STUDIO_URL/sessoes")$(hdr location "$STUDIO_URL/sessoes")" = "303/login?next=%2Fsessoes"
check "sessão sem login: 303, com a volta"             test "$(hdr location "$STUDIO_URL/sessao?id=$S1")" = "/login?next=%2Fsessao%3Fid%3D$S1"
check "htmx sem login: 401 com HX-Redirect"            test "$(code "${HX[@]}" "$STUDIO_URL/sessoes")$(hdr hx-redirect "${HX[@]}" "$STUDIO_URL/sessoes")" = "401/login?next=%2Fsessoes"
check "POST /sessoes: 405 (só leitura)"                test "$(code -X POST "${C[@]}" "$STUDIO_URL/sessoes")" = 405

# ---------------------------------------------------------------- 2. lista: sessões com as conversas agrupadas
curl -s "${C[@]}" "$STUDIO_URL/sessoes?$WIN" > "$TMP/list.html"
ALL="$(data < "$TMP/list.html")"
L="$(jq -c '[.[] | select(.sessao)]' <<<"$ALL")"
srow() { jq -c --arg id "$1" '.[] | select(.sessao == $id)' <<<"$L"; }
check "lista: as 4 sessões da janela, da mais recente para a mais antiga (pelo início)" \
  jqe --arg s1 "$S1" --arg s2 "$S2" --arg s3 "$S3" --arg s4 "$S4" 'map(.sessao) == [$s2, $s4, $s3, $s1]' <<<"$L"
check "lista: hora do fato (sessão de janeiro fora)"   jqe 'all(.sessao | test("antiga") | not)' <<<"$L"
check "lista: menu com conversas e sessões"            bash -c 'grep -q "<a href=\"/conversas\">Conversas</a>" "$1" && grep -q "<a href=\"/sessoes\">Sessões</a>" "$1"' _ "$TMP/list.html"
R1="$(srow "$S1")"
check "S1: host e agente"                              jqe '.host == "oute-server" and .agents == "claude"' <<<"$R1"
check "S1: modelos das chamadas, do mais chamado para o menos" jqe '.models == "claude-sonnet-5,claude-opus-5" and (.text | test("claude-sonnet-5 ×3 claude-opus-5 ×1"))' <<<"$R1"
check "S1: 3 conversas"                                jqe '.conversations == "3"' <<<"$R1"
check "S1: começa no evento de abertura (3 dias antes): números da sessão inteira" \
  jqe '.["start-ns"] == "1758740810000000000" and .calls == "4"' <<<"$R1"
check "S1: tokens só das chamadas"                     jqe '.input == "1000117" and .output == "50" and .["cache-read"] == "1000" and .["cache-creation"] == "10"' <<<"$R1"
check "S1: custo real 0,76 (o da tool não soma)"       jqe "$(usd '.["real-usd"]') == 760000" <<<"$R1"
check "S1: estimado 3,00, separado do real e marcado"  jqe "$(usd '.["estimated-usd"]') == 3000000 and (.text | test(\"US\\\\$ 0,7600 ≈ US\\\\$ 3,0000 est\\\\.\"))" <<<"$R1"
check "S1: p95 das chamadas (1, 2, 4 e 10 s = 9,1 s)"  jqe '(.["p95-ms"] | tonumber) == 9100 and (.text | test("9,1 s"))' <<<"$R1"
check "S1: erros (1 span + 1 log)"                     jqe '.errors == "2"' <<<"$R1"
check "S1: estado, repo e slug do SurrealDB"           jqe '.state == "aberta" and (.text | test("oute-agent · 207-tela aberta"))' <<<"$R1"
check "S1: rodada do swarm, com o label e a issue"     jqe --arg r "$RND" '.round == $r and (.text | test("rodada " + $r + " \\(studio-tela\\) issue #207"))' <<<"$R1"
R2="$(srow "$S2")"
check "S2 (Codex): só estimado (2,50), sem real"       jqe ".[\"real-usd\"] == \"\" and $(usd '.["estimated-usd"]') == 2500000 and .host == \"oute-mac\" and .agents == \"codex\" and .models == \"gpt-5-codex\"" <<<"$R2"
check "S2: removida e avulsa (sem rodada)"             jqe '.state == "removida" and .round == "" and (.text | test("lab · ajuste removida avulsa"))' <<<"$R2"
check "S2: um modelo só não leva contagem"             jqe '.text | test("×") | not' <<<"$R2"
R3="$(srow "$S3")"
check "S3: sem registro no SurrealDB, segue pelo DuckDB" jqe '.state == "" and .conversations == "1" and .agents == "claude"' <<<"$R3"
check "S3: modelo sem preço nunca vira zero"           jqe '.["unpriced-calls"] == "1" and .["real-usd"] == "" and .["estimated-usd"] == "" and (.text | test("1 sem preço"))' <<<"$R3"
R4="$(srow "$S4")"
check "S4: sessão só com o evento de abertura (0 conversas)" jqe '.conversations == "0" and .calls == "0" and .state == "aberta" and .["p95-ms"] == "" and .agents == ""' <<<"$R4"
check "S4: sem conversa, o agente é o da abertura"     jqe '.text | test(" shell ")' <<<"$R4"
V="$(jq -c '[.[] | select(.conversa)]' <<<"$ALL")"
of() { jq -c --arg id "$1" '[.[] | select(.["da-sessao"] == $id)]' <<<"$V"; }
check "S1: as conversas dela, em ordem"                jqe 'map(.conversa) == ["s1-0", "s1-a", "s1-b"]' <<<"$(of "$S1")"
check "agrupadas: cada conversa logo abaixo da sua sessão" jqe --arg s1 "$S1" --arg s2 "$S2" --arg s3 "$S3" --arg s4 "$S4" \
  '[.[] | select(.sessao or .conversa) | (.sessao // .conversa)] == [$s2, "s2-a", $s4, $s3, "s3-a", $s1, "s1-0", "s1-a", "s1-b", "solta 2/&é", "solta-1"]' <<<"$ALL"
check "conversa: link para o detalhe (#206)"           grep -qF '<a href="/conversa?id=s1-a">s1-a</a>' "$TMP/list.html"
check "conversa: agente, modelo e números dela"        jqe ".agent == \"claude\" and .models == \"claude-sonnet-5\" and .calls == \"2\" and $(usd '.["real-usd"]') == 10000 and $(usd '.["estimated-usd"]') == 3000000" <<<"$(jq -c '.[] | select(.conversa == "s1-a")' <<<"$V")"
check "conversa: p95 dela (2 e 4 s = 3,9 s)"           jqe '(.["p95-ms"] | tonumber) == 3900' <<<"$(jq -c '.[] | select(.conversa == "s1-a")' <<<"$V")"
check "sessão = soma das conversas dela (mesma regra)" jqe --argjson r "$R1" \
  '(map(.calls | tonumber) | add) == ($r.calls | tonumber)
   and (map(.["real-usd"] | select(. != "") | tonumber) | add * 1e6 | round) == ($r["real-usd"] | tonumber * 1e6 | round)
   and (map(.["estimated-usd"] | select(. != "") | tonumber) | add * 1e6 | round) == ($r["estimated-usd"] | tonumber * 1e6 | round)
   and (map(.errors | tonumber) | add) == ($r.errors | tonumber)' <<<"$(of "$S1")"
LOOSE="$(of "")"
check "sem sessão: uma linha por session.id, da mais recente para a mais antiga" jqe 'map(.conversa) == ["solta 2/&é", "solta-1"]' <<<"$LOOSE"
check "sem sessão: agente, modelo e custo de cada"     jqe ".[0].agent == \"codex\" and .[0].models == \"gpt-5-codex\" and $(usd '.[0]["estimated-usd"]') == 2500000 and $(usd '.[1]["real-usd"]') == 20000" <<<"$LOOSE"
check "sem sessão: link do detalhe com o id codificado" grep -qF 'href="/conversa?id=solta%202/%26%C3%A9"' "$TMP/list.html"
# os mesmos números do /v1/usage (#203): tudo o que a tela soma é o total da API na janela que cobre o ano
curl -s "${C[@]}" "$STUDIO_URL/sessoes?from=2025-01-01&to=2026-01-01" | data > "$TMP/year.json"
U="$(curl -s "${C[@]}" "$STUDIO_URL/v1/usage?from=2025-01-01&to=2026-01-01" | jq -c .totals)"
check "sessões + sem sessão = totais do /v1/usage"     jqe --argjson u "$U" \
  '[.[] | select(.sessao or (.conversa and .["da-sessao"] == ""))] as $g
   | ($g | map(.calls | tonumber) | add) == $u.calls
   and ($g | map(.["real-usd"] | select(. != "") | tonumber) | add * 1e6 | round) == ($u.cost.real_usd * 1e6 | round)
   and ($g | map(.["estimated-usd"] | select(. != "") | tonumber) | add * 1e6 | round) == ($u.cost.estimated_usd * 1e6 | round)
   and ($g | map(.input | tonumber) | add) == $u.tokens.input
   and ($g | map(.errors | tonumber) | add) == $u.errors.total' "$TMP/year.json"
check "janela do ano: a sessão e a conversa de janeiro entram" jqe '([.[] | select(.sessao)] | length) == 5 and any(.[]; .conversa == "solta-jan")' "$TMP/year.json"
ids() { curl -s "${C[@]}" "$STUDIO_URL/sessoes?$WIN&$1" | data | jq -c '[.[] | select(.sessao or (.conversa and .["da-sessao"] == "")) | (.sessao // .conversa)]'; }
check "filtro por host"                                test "$(ids host=oute-mac)" = "[\"$S2\",\"solta 2/&é\"]"
check "filtro por agente"                              test "$(ids agent=codex)" = "[\"$S2\",\"solta 2/&é\"]"
check "filtro por host e agente"                       test "$(ids 'host=oute-server&agent=claude' | jq -c 'map(select(test("<b>") | not))')" = "[\"$S1\",\"solta-1\"]"
check "filtro sem resultado: avisos, sem erro"         bash -c 'grep -q "Nenhuma sessão nessa janela" <<<"$1" && grep -q "Nenhuma conversa sem sessão" <<<"$1"' _ "$(curl -s "${C[@]}" "$STUDIO_URL/sessoes?$WIN&host=oute-mac&agent=claude")"
check "filtros oferecem os hosts e agentes da janela"  bash -c 'grep -q "<option value=\"oute-mac\"" "$1" && grep -q "<option value=\"oute-server\"" "$1" && grep -q "<option value=\"codex\"" "$1" && ! grep -q "<option value=\"human\"" "$1"' _ "$TMP/list.html"
check "janela padrão (24 h): nada (hora do fato, não a de chegada)" grep -q 'Nenhuma sessão nessa janela' <(curl -s "${C[@]}" "$STUDIO_URL/sessoes")
check "janela só com o começo da sessão longa"         test "$(curl -s "${C[@]}" "$STUDIO_URL/sessoes?from=2025-09-25&to=2025-09-26" | data | jq -c '[.[] | select(.sessao) | .calls]')" = '["4"]'
check "janela inválida: 400"                           test "$(code "${C[@]}" "$STUDIO_URL/sessoes?from=ontem&to=2025-09-29")" = 400
check "hours inválido: 400, com a página de erro"      grep -q 'hours inválido' <(curl -s "${C[@]}" "$STUDIO_URL/sessoes?hours=x")
check "lista com htmx (filtro troca só o conteúdo)"    grep -q 'hx-get="/sessoes"' "$TMP/list.html"
check "SurrealDB lido: sem aviso de estado"            bash -c '! grep -q data-estado-indisponivel "$1"' _ "$TMP/list.html"

# ---------------------------------------------------------------- 3. página da sessão
curl -s "${C[@]}" "$STUDIO_URL/sessao?id=$S1" > "$TMP/s1.html"
D="$(data < "$TMP/s1.html")"
RS="$(jq -c '.[] | select(has("resumo-sessao"))' <<<"$D")"
check "sessão: 200"                                    test "$(code "${C[@]}" "$STUDIO_URL/sessao?id=$S1")" = 200
check "sessão: as somas da lista"                      jqe --argjson r "$R1" '.calls == $r.calls and .["real-usd"] == $r["real-usd"] and .["estimated-usd"] == $r["estimated-usd"] and .["p95-ms"] == $r["p95-ms"] and .errors == $r.errors and .models == $r.models' <<<"$RS"
check "sessão: repo, estado, abertura e agente da abertura" jqe '.text | test("Repositório oute-agent · 207-tela Estado aberta Aberta em \\(UTC\\) 2025-09-24 19:06:50 Aberta com claude")' <<<"$RS"
check "sessão: rodada, label, estado, worker e issue"  jqe --arg r "$RND" '.text | test("Rodada " + $r + " · studio-tela · aberta · worker 207-tela · issue #207")' <<<"$RS"
check "sessão: host, agente, modelos e p95"            jqe '.text | test("Host oute-server \\(oute-agent\\) Agente claude Modelo claude-sonnet-5 ×3 claude-opus-5 ×1") and test("p95 das chamadas 9,1 s")' <<<"$RS"
check "sessão: as 3 conversas, com link"               bash -c 'test "$(jq -c "[.[] | select(.conversa) | .conversa]" <<<"$1")" = "[\"s1-0\",\"s1-a\",\"s1-b\"]" && grep -qF "<a href=\"/conversa?id=s1-b\">s1-b</a>" "$2"' _ "$D" "$TMP/s1.html"
G="$(jq -c '[.[] | select(.log)]' <<<"$D")"
check "sessão: eventos dela, pela hora do fato (os logs das conversas não entram)" jqe 'map(.text | capture("(?<e>oute\\.[a-z.]+)").e) == ["oute.task.opened", "oute.exemplo.seletor"]' <<<"$G"
check "sessão: a escolha do seletor aparece no oute.task.opened (#219)" jqe '.[0].text | test("\"oute.task.phase\": \"build\"") and test("\"oute.task.origin\": \"label\"") and test("\"oute.task.model\": \"claude-sonnet-5-5\"")' <<<"$G"
check "sessão: evento com o oute.task.id aparece com os atributos" jqe '.[1].text | test("\"fase\": \"build\"") and test("\"origem\": \"label\"") and test("\"modelo\": \"claude-sonnet-5\"")' <<<"$G"
check "sessão: conteúdo do evento escapado"            bash -c '! grep -q "<script>alert" "$1" && grep -q "&lt;script&gt;alert" "$1"' _ "$TMP/s1.html"
S2H="$(curl -s "${C[@]}" "$STUDIO_URL/sessao?id=$S2" | data | jq -c '.[] | select(has("resumo-sessao"))')"
check "sessão avulsa: a origem jev e a confiança aparecem no oute.task.opened (#257)" jqe '[.[] | select(.log) | .text | select(test("oute\\.task\\.opened"))][0] | test("\"oute.task.origin\": \"jev\"") and test("\"oute.task.confidence\": 0.87") and test("\"oute.task.phase\": \"ops\"")' <<<"$(curl -s "${C[@]}" "$STUDIO_URL/sessao?id=$S2" | data)"
check "sessão removida: estado com o motivo e a hora"  jqe '.text | test("Estado removida \\(pr-mergeado\\)") and test("Removida em \\(UTC\\) 2025-09-27 19:20:00") and test("Rodada sessão avulsa")' <<<"$S2H"
S4H="$(curl -s "${C[@]}" "$STUDIO_URL/sessao?id=$S4")"
check "sessão sem conversa: aviso, com o evento de abertura" bash -c 'grep -q "Esta sessão não tem conversas" <<<"$1" && grep -q "oute.task.opened" <<<"$1"' _ "$S4H"
S3U="$STUDIO_URL/sessao?id=$(enc "$S3")"
check "sessão sem evento: aviso no lugar dos eventos"  grep -q 'Esta sessão não tem eventos' <(curl -s "${C[@]}" "$S3U")
check "id da sessão escapado na página e codificado no link" bash -c '! grep -q "<b>x</b>" "$1" && grep -q "repo &lt;b&gt;x&lt;/b&gt;&amp;y=é" "$1" && grep -qF "href=\"/sessao?id=repo%20%3Cb%3Ex%3C/b%3E%26y%3D%C3%A9\"" "$1"' _ "$TMP/list.html"
check "sessão com id estranho abre"                    grep -q 'data-conversations="1"' <(curl -s "${C[@]}" "$S3U")
check "sessão que não existe: 404"                     test "$(code "${C[@]}" "$STUDIO_URL/sessao?id=nao-existe")" = 404
check "sessão sem id: 400"                             test "$(code "${C[@]}" "$STUDIO_URL/sessao")" = 400
# sessão que só o SurrealDB conhece (registro sem fato no DuckDB)
surreal_q 'UPSERT type::record("sessao", "so-no-surreal") MERGE {repo: "lab", slug: "so", state: "aberta", agent: "claude"}' >/dev/null
SO="$(curl -s "${C[@]}" "$STUDIO_URL/sessao?id=so-no-surreal")"
check "sessão só no SurrealDB: 200, com o registro"    bash -c 'grep -q "lab · so" <<<"$1" && grep -q "Esta sessão não tem conversas" <<<"$1" && grep -q "data-calls=\"0\"" <<<"$1"' _ "$SO"
check "conversa: a sessão vira link para a página dela" grep -qF "<a href=\"/sessao?id=$S1\">$S1</a>" <(curl -s "${C[@]}" "$STUDIO_URL/conversa?id=s1-a")

# ---------------------------------------------------------------- 4. sem CDN, sem script inline, mesma CSP
check "páginas: nenhum script, estilo ou link de fora" bash -c '! grep -hoiE "(src|href|action|hx-get)=\"[^\"]*\"" "$@" | grep -qE "=\"([a-z]+:)?//"' _ "$TMP/list.html" "$TMP/s1.html"
check "páginas: sem script nem estilo inline"          bash -c '! grep -hiE "<script(>| [^>]*>)[^<]|<style|[ \"]style=|[ \"]on[a-z]+=\"" "$@"' _ "$TMP/list.html" "$TMP/s1.html"
check "páginas: script só do /static"                  test "$(grep -ho '<script[^>]*>' "$TMP/list.html" "$TMP/s1.html" | sort -u)" = '<script src="/static/htmx.min.js" defer>'
CSP="$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/sessoes")"
check "CSP: a mesma das conversas"                     test "$CSP" = "$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/conversas")"
check "CSP: script e estilo só deste servidor"         bash -c 'grep -q "default-src .none." <<<"$1" && grep -q "script-src .self.;" <<<"$1" && grep -q "style-src .self.;" <<<"$1"' _ "$CSP"
check "páginas não vão para cache"                     test "$(hdr cache-control "${C[@]}" "$STUDIO_URL/sessao?id=$S1")" = no-store
check "até aqui, nenhuma falha no stderr"              bash -c '! grep -q "respondi 500\|segui sem ele\|Traceback" "$1"' _ "$TMP/s/stderr"

# ---------------------------------------------------------------- 5. SurrealDB fora: a tela segue com o DuckDB
surreal_stop
curl -s "${C[@]}" "$STUDIO_URL/sessoes?$WIN" > "$TMP/down.html"
DOWN="$(data < "$TMP/down.html" | jq -c '[.[] | select(.sessao)]')"
check "SurrealDB fora: /sessoes 200"                   test "$(code "${C[@]}" "$STUDIO_URL/sessoes?$WIN")" = 200
check "SurrealDB fora: aviso na página"                grep -q 'data-estado-indisponivel' "$TMP/down.html"
check "SurrealDB fora: sessões, conversas e somas do DuckDB" jqe --argjson r "$R1" --arg s1 "$S1" \
  'length == 4 and (.[] | select(.sessao == $s1) | .calls == $r.calls and .["real-usd"] == $r["real-usd"] and .conversations == "3" and .state == "")' <<<"$DOWN"
check "SurrealDB fora: a rodada segue (está no fato)"  jqe --arg s1 "$S1" --arg r "$RND" '.[] | select(.sessao == $s1) | .round == $r' <<<"$DOWN"
check "SurrealDB fora: página da sessão 200, com aviso" bash -c 'grep -q data-estado-indisponivel <<<"$1" && grep -q "data-calls=\"4\"" <<<"$1"' _ "$(curl -s "${C[@]}" "$STUDIO_URL/sessao?id=$S1")"
check "SurrealDB fora: sessão só do SurrealDB = 404"   test "$(code "${C[@]}" "$STUDIO_URL/sessao?id=so-no-surreal")" = 404
check "SurrealDB fora: a causa não vai para a página"  bash -c '! grep -qi "urlopen\|refused\|127\.0\.0\.1" "$1"' _ "$TMP/down.html"
check "SurrealDB fora: aviso no stderr, sem 500"       bash -c 'grep -q "estado das sessões (SurrealDB) falhou, segui sem ele" "$1" && ! grep -q "respondi 500" "$1"' _ "$TMP/s/stderr"
studio_stop

# ---------------------------------------------------------------- 6. lógica direto em Python
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/s/db.duckdb" > "$TMP/py.out" 2>&1 <<'PY'
import sys
import duckdb
from agent_studio import cost, sessions, usage, web
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, Broken, Odd, get

con = duckdb.connect(sys.argv[1], read_only=True)
D1 = 1759000000 * 10**9
DAY = 86400 * 10**9
S1 = "oute-agent-207-tela-20250927190000"
none = cost.PriceTable()

r = sessions.listing(con, D1 - DAY, D1 + DAY, none, limit=1)
check("lista: limite corta sessões e conversas sem sessão, os totais contam tudo",
      r["total"] == 4 and r["loose_total"] == 2 and len(r["sessions"]) == 1 and len(r["loose"]) == 1)
check("lista: sem tabela de preços, sem estimativa (nunca zero)",
      r["sessions"][0]["usage"]["cost"] == {"real_usd": None, "estimated_usd": None, "real_calls": 0,
                                            "estimated_calls": 0, "unpriced_calls": 1})
r = sessions.listing(con, D1 - DAY, D1 + DAY, none, conv_limit=2)
s1 = next(s for s in r["sessions"] if s["id"] == S1)
check("lista: conversas por sessão cortadas nas mais recentes, com as que faltam contadas",
      [c["id"] for c in s1["conversations"]] == ["s1-a", "s1-b"] and s1["hidden"] == 1 and s1["conversation_count"] == 3)
check("lista: o corte das conversas não muda as somas da sessão", s1["usage"]["calls"] == 4)
html = web._env().get_template("sessions.html").render(
    **r, state_read=None, from_ns=D1 - DAY, to_ns=D1 + DAY, host="", agent="", windows=web.WINDOWS, hours="24",
    range={"from": "", "to": ""}, limit=200)
check("lista: sessão cortada leva o link para as conversas que faltam",
      f'<a href="/sessao?id={S1}">mais 1 conversas antes destas</a>' in html and 'data-conversa="s1-0"' not in html)
check("lista: sem SurrealDB lido, sessão sem estado e sem rodada resolvida",
      s1["state"] is None and s1["round"] is None and s1["swarm_round"] == "swarm-0927-1900")
check("lista: janela vazia", sessions.listing(con, 1, 2, none) ==
      {"sessions": [], "total": 0, "loose": [], "loose_total": 0, "hosts": [], "agents": []})

d = sessions.detail(con, S1, none, event_limit=1)
check("sessão: limite de eventos avisa o corte", d["events_truncated"] and len(d["events"]) == 1)
html = web._env().get_template("session.html").render(**d, id=S1, state_read=None, event_limit=1)
check("sessão: o corte dos eventos aparece na página", "Mostrando os primeiros 1 eventos" in html and "oute.exemplo.seletor" not in html)
check("sessão: sem corte, sem aviso", sessions.detail(con, S1, none)["events_truncated"] is False)
check("sessão que o DuckDB não tem: None", sessions.detail(con, "nao-existe", none) is None)

# a regra de custo é a do #203: a chave `session` do aggregate dá os números da tela
g = usage.aggregate(con, 0, 2**62, none, ("session",))
check("usage.aggregate com a chave session", g[(S1,)]["calls"] == 4 and abs(g[(S1,)]["real_usd"] - 0.76) < 1e-9
      and s1["usage"] == usage.rendered(g, (S1,)))
check("sessões não repetem regra de custo (nada de cost_usd nem preço no módulo)",
      "cost_usd" not in open(sessions.__file__).read() and "estimate" not in open(sessions.__file__).read())

# estado do SurrealDB: a rodada vem do fato; sem ele, do link do registro
class Fake:
    def __init__(self, recs, rounds):
        self.recs, self.rounds, self.asked = recs, rounds, None
    def query(self, sql, variables):
        self.asked = variables
        return [{"status": "OK", "result": self.recs}, {"status": "OK", "result": self.rounds}]
rec = {"id": "a", "state": "aberta", "round": "r-link", "round_label": "do link", "round_state": "fechada"}
a, b, c = sessions.blank("a"), sessions.blank("b"), sessions.blank("c")
b["swarm_round"] = "r-fato"
fake = Fake([rec], [{"id": "r-fato", "label": "do fato", "state": "aberta"}])
sessions.with_state(fake, [a, b, c])
check("estado: rodada pelo link do registro quando o fato não a traz",
      a["swarm_round"] == "r-link" and a["round"] == {"label": "do link", "state": "fechada"} and a["state"] is rec)
check("estado: rodada pelo fato, com o registro da rodada", b["round"]["label"] == "do fato" and b["state"] is None)
check("estado: sessão sem registro e sem rodada", c["state"] is None and c["round"] is None and c["swarm_round"] is None)
check("estado: ids e rodadas vão como variáveis", fake.asked == {"ids": ["a", "b", "c"], "rounds": ["r-fato"]})
fake.asked = None
sessions.with_state(fake, [])
check("estado: sem sessão, sem consulta", fake.asked is None)

# app sem SurrealDB (só DuckDB): a página sai sem estado e sem aviso; leitura do DuckDB que falha = 500
class ReadOnly:
    def alerts(self, *a):  # o topo de toda página (#208)
        return {"alerts": []}
    def sessions(self, *a):
        return sessions.listing(con, *a)
    def session(self, *a):
        return sessions.detail(con, *a)
app = create_app(ReadOnly(), TOKEN)
status, body = get(app, "/sessoes", "from=2025-09-27&to=2025-09-29")
check("sem SurrealDB: /sessoes 200, sem aviso e sem estado",
      status == 200 and "data-estado-indisponivel" not in body and f'data-sessao="{S1}"' in body and 'data-state="aberta"' not in body)
status, body = get(app, "/sessao", f"id={S1}")
check("sem SurrealDB: página da sessão 200, sem o bloco do registro", status == 200 and "Repositório" not in body and 'data-calls="4"' in body)
check("sem SurrealDB: sessão que o DuckDB não tem = 404", get(app, "/sessao", "id=so-no-surreal")[0] == 404)
app = create_app(Broken(), TOKEN)
for path, query in (("/sessoes", ""), ("/sessao", "id=a")):
    status, body = get(app, path, query)
    check(f"leitura que falha em {path}: 500, sem a causa na página", status == 500 and "segredo-da-falha" not in body and "A consulta falhou" in body)
# SurrealDB que responde fora do formato: a página segue, com aviso
app = create_app(ReadOnly(), TOKEN, surreal=Odd())
status, body = get(app, "/sessoes", "from=2025-09-27&to=2025-09-29")
check("SurrealDB com resposta inesperada: 200 com aviso", status == 200 and "data-estado-indisponivel" in body and f'data-sessao="{S1}"' in body)
PY
grep -v '^Traceback\|^  \|^RuntimeError\|^TypeError\|^IndexError\|^$\|tela: .* falhou' "$TMP/py.out" || true
check_py "$TMP/py.out"
check "lógica em Python: os 24 casos rodaram"          test "$((n_ok + n_fail))" = 24

# ---------------------------------------------------------------- 7. imagem
PKG="$ROOT/docker/agent-studio/agent_studio"
check "templates das sessões vão na imagem (dentro do pacote copiado)" bash -c 'test -f "$1/templates/sessions.html" && test -f "$1/templates/session.html" && grep -q "COPY docker/agent-studio/agent_studio /opt/agent-studio/app/agent_studio" "$2/docker/Dockerfile"' _ "$PKG" "$ROOT"
check "compose: agent-studio só em 127.0.0.1"          bash -c 'grep -A40 "^  agent-studio:" "$1" | grep -q "\"127.0.0.1:\${OUTE_AGENT_STUDIO_PORT:-8430}:8430\""' _ "$ROOT/docker/compose.yaml"

check_end
