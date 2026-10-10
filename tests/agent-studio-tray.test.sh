#!/usr/bin/env bash
# Testes do `GET /v1/tray` do agent-studio (#205, ADR-08 §10): o contrato da resposta que o tray no Mac (#158) lê a
# cada 15 s. Máquinas (pela hora de chegada), pedidos pendentes do SurrealDB com o link do "ver script", custo de hoje
# (total e por agente, estimado marcado), erros na última hora por host × agente, alertas (com title e text prontos, #344)
# e os contadores da barra, e a fixture do app (tray/Tests/Fixtures) com as mesmas chaves e tipos da resposta real.
# O DuckDB e o SurrealDB de exemplo nascem pela ingestão de verdade (POST /v1/traces, /v1/logs e /v1/metrics), com as
# horas em volta de agora; o custo e os alertas são conferidos contra o `/v1/usage` e o `/v1/alerts` (mesma regra).
# Mais a lógica direto em Python (host parado, outro dia, limite de pedidos), o SurrealDB fora e o tempo de resposta
# com um banco de volume parecido com o de produção. Sem Docker; o SurrealDB é o binário fixado de tests/lib/surreal.sh.
# Uso: tests/agent-studio-tray.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init
. "$ROOT/tests/lib/surreal.sh"
trap 'studio_stop; surreal_stop; rm -rf "${TMP:?}"' EXIT
surreal_bin
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não subiu"; }

# "hoje" é o dia UTC: perto da virada, os fatos de agora cairiam em dias diferentes no meio do teste. Espera passar.
while s=$(( $(date +%s) % 86400 )); (( s < 120 || s > 86400 - 300 )); do sleep 20; done

# ---------------------------------------------------------------- DuckDB e SurrealDB de exemplo
# Tudo chega agora; a hora do fato é relativa a NOW.
#   custo de hoje: claude (oute-server) 0,03 real + 3,00 estimado (uma chamada sem custo); codex (oute-mac) só
#   estimado (2,50 + 0,01) e uma chamada de modelo sem preço; pi (jev.decision) 0,0004 real. Um span de ontem com
#   US$ 100 fica fora.
#   erros na última hora: codex no oute-mac (1 span + 1 log) e claude no oute-server (1 span); um erro de 2 h atrás
#   fica fora.
#   pedidos: P1 (pendente, root, claude, oute-server, há 5 min), P5 (pendente, user, codex, oute-mac, há 1 min, id
#   com HTML) e P2 (decidido: não entra).
#   alerta: fila do collector do oute-server a 80%.
#   etapas (#508): TA (swarm-1004-1000, aberta): triagem há 48 min, merge do PR 12 (aprovado) e do PR 13 (sem-revisor);
#   TB (swarm-1004-0900, fechada): fechamento, fora do tray; TC (swarm-1004-1100, sem evento de abertura): fechamento
#   aprovado há 1 min, o mais novo. O texto de cada etapa leva um segredo de teste, que nunca pode sair no tray.
#   oute-velho: um log com a hora do fato de 3 dias atrás, que chegou agora (máquina ativa pela hora de chegada).
NOW="$(date +%s)"
P1=20260930-120000-reiniciar-nginx; P2=20260930-110000-listar-backups; P5='p <b>5</b>&x=é'
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" <<'PY'
import json, sys
import hashlib
from otlp_json import canal_decided, canal_proposed, claude_call, event, kv, queue_metrics, rl, rs, span
tmp, NOW = sys.argv[1], int(sys.argv[2])
DAY = NOW // 86400 * 86400
P1, P2, P5 = "20260930-120000-reiniciar-nginx", "20260930-110000-listar-backups", "p <b>5</b>&x=é"
claude = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "claude-code", "oute.agent": "claude"}
codex = {"host.name": "oute-mac", "oute.instance": "oute-agent", "service.name": "codex_exec", "oute.agent": "codex"}
# histórico até 2026-09-30 (#218): registro do jev-router, que saiu do stack; o custo gravado continua contando
router = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "jev-router", "oute.agent": "router"}
cl = lambda **a: {"model": "claude-sonnet-5", **a}
def step(t, rnd, eid, kind, rev, review, key=None):
    text = "## Decisão\n1. segredo-da-etapa-" + eid + "\n"
    attrs = {"oute.swarm.round": rnd, "oute.swarm.step.kind": kind, "oute.swarm.step.rev": rev, "oute.swarm.step.review": review,
             "oute.swarm.step.sha256": hashlib.sha256(text.encode()).hexdigest(), "oute.swarm.step.writer": "claude-sonnet-5-5",
             "oute.swarm.step.reviewer": "claude-opus-5-5", "oute.swarm.step.refcheck": "ausente"}
    if key: attrs["oute.swarm.step.key"] = key
    return event(t, "oute.swarm.step.published", eid, attrs, text)
watch = lambda t, eid, kind, rnd, body: event(t, f"oute.swarm.watch.{kind}", eid, {"oute.swarm.round": rnd, "oute.swarm.source": "watch"}, body)
cx = lambda m, i=0, o=0, c=0: {"model": m, "codex.turn.token_usage.non_cached_input_tokens": i,
                               "codex.turn.token_usage.output_tokens": o, "codex.turn.token_usage.cached_input_tokens": c}
# Claude no formato de produção (#157): o custo real vem no log api_request de mesmo request_id
calls = [
  claude_call(NOW - 30, 2, cl(input_tokens=100, output_tokens=50), 0.01),
  claude_call(NOW - 20, 4, cl(input_tokens=200, output_tokens=20), 0.02),
  claude_call(NOW - 15, 3, cl(input_tokens=1_000_000)),          # sem log: 3,00 estimado
  claude_call(DAY - 3600, 1, cl(input_tokens=5), 100.0),          # ontem
]
traces = {"resourceSpans": [
  rs(claude, [
    *(s for s, _ in calls),
    span("claude_code.tool", NOW - 40, 1, {}, err=True),
    span("claude_code.tool", NOW - 7200, 1, {}, err=True),                                    # há 2 h
  ]),
  rs(codex, [
    span("session_task.turn", NOW - 25, 10, cx("gpt-5-codex", 1_000_000, 100_000, 2_000_000)),  # 1,25 + 1,00 + 0,25
    span("session_task.turn", NOW - 10, 5, cx("gpt-5-codex", o=1000), err=True),                # 0,01
    span("session_task.turn", NOW - 12, 1, cx("gpt-9-sem-preco", 500)),
  ]),
  rs(router, [span("jev.decision", NOW - 18, 0.5, {"oute.agent": "pi", "gen_ai.response.model": "openai/gpt-oss-20b",
       "gen_ai.usage.input_tokens": 50, "gen_ai.usage.output_tokens": 10, "oute.cost_usd": 0.0004})]),
]}
json.dump(traces, open(f"{tmp}/traces.json", "w"))
oute = lambda host, agent: {"host.name": host, "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": agent}
logs = {"resourceLogs": [
  rl(claude, [l for _, l in calls if l]),
  rl(oute("oute-server", "claude"), [canal_proposed(NOW - 300, P1, "ev-p1", "Reiniciar <b>nginx</b> & cia", "root", "sudo systemctl reload nginx\n")]),
  rl(oute("oute-mac", "codex"), [canal_proposed(NOW - 60, P5, "ev-p5", "Pedido de id estranho", "user", "true\n"),
                                 canal_proposed(NOW - 3600, P2, "ev-p2", "Listar backups", "user", "ls -la /backup\n")]),
  rl(oute("oute-mac", "human"), [canal_decided(NOW - 3500, P2, "ev-d2", "executado", **{"oute.canal.rc": 0})]),
  rl(codex, [{"timeUnixNano": str((NOW - 15) * 10**9), "severityNumber": 17, "body": {"stringValue": "erro"}},
             {"timeUnixNano": str((NOW - 16) * 10**9), "severityNumber": 9, "body": {"stringValue": "info"}}]),
  rl(oute("oute-server", "claude"), [
    event(NOW - 3000, "oute.swarm.round.opened", "ev-ta-open", {"oute.swarm.round": "swarm-1004-1000", "oute.swarm.repo": "oute-agent", "oute.swarm.max": 3, "oute.swarm.round.name": "Brave_Otter"}),
    step(NOW - 2900, "swarm-1004-1000", "ev-ta-t", "triagem", 1, "aprovado"),
    step(NOW - 120, "swarm-1004-1000", "ev-ta-m12", "merge", 1, "aprovado", key="12"),
    step(NOW - 90, "swarm-1004-1000", "ev-ta-m13", "merge", 1, "sem-revisor", key="13"),
    event(NOW - 2500, "oute.swarm.round.opened", "ev-tb-open", {"oute.swarm.round": "swarm-1004-0900", "oute.swarm.repo": "oute-agent", "oute.swarm.max": 3}),
    step(NOW - 2000, "swarm-1004-0900", "ev-tb-f", "fechamento", 1, "aprovado"),
    event(NOW - 1000, "oute.swarm.round.closed", "ev-tb-close", {"oute.swarm.round": "swarm-1004-0900"}),
    step(NOW - 60, "swarm-1004-1100", "ev-tc-f", "fechamento", 1, "aprovado"),
    # o que pede atenção (#776), na rodada aberta TA; o que não vale mais ou é de rodada fechada (TB) não entra
    watch(NOW - 800, "ev-w1", "pr", "swarm-1004-1000", "PR #12 mergeado (issue #7)"),
    watch(NOW - 700, "ev-w2", "ci", "swarm-1004-1000", "PR #13 · test: fail"),
    watch(NOW - 690, "ev-w3", "ci", "swarm-1004-1000", "PR #14 · test: fail"),
    watch(NOW - 600, "ev-w4", "ci", "swarm-1004-1000", "PR #14 · verde (head abc1234): test"),
    watch(NOW - 590, "ev-w5", "ci", "swarm-1004-1000", "PR #15 · test: fail"),
    watch(NOW - 580, "ev-w6", "pr", "swarm-1004-1000", "PR #15 mergeado (issue #9)"),
    watch(NOW - 570, "ev-w7", "sessao", "swarm-1004-1000", "#7 foo: blocked (sem PR)"),
    watch(NOW - 560, "ev-w8", "sessao", "swarm-1004-1000", "#8 bar: blocked (PR #16 open)"),
    watch(NOW - 550, "ev-w9", "sessao", "swarm-1004-1000", "#8 bar: working (voltou a trabalhar)"),
    watch(NOW - 540, "ev-w10", "sessao", "swarm-1004-1000", "#9 baz: blocked (sem PR)"),
    event(NOW - 530, "oute.swarm.session.closed", "ev-w11", {"oute.swarm.round": "swarm-1004-1000", "oute.swarm.session": "9-baz"}),
    watch(NOW - 520, "ev-w12", "sessao", "swarm-1004-1000", "#10 <b>x: blocked (sem PR)"),
    watch(NOW - 1500, "ev-wb", "ci", "swarm-1004-0900", "PR #20 · test: fail"),
    event(NOW - 510, "oute.swarm.round.asked", "ev-w13", {"oute.swarm.round": "swarm-1004-1000"}, "Posso fazer merge do PR #13?")]),
  rl({"host.name": "oute-velho", "service.name": "oute"},
     [{"timeUnixNano": str((NOW - 3 * 86400) * 10**9), "severityNumber": 9, "body": {"stringValue": "atrasado"}}]),
]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
json.dump(queue_metrics("oute-server", NOW - 120, 800), open(f"{tmp}/metrics.json", "w"))
PY
studio_prices "$TMP/config.toml"
printf '[alerts]\nalways_on_hosts = ["oute-server"]\nfoo = 1\n' >> "$TMP/config.toml"

SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$TMP/config.toml")
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
C=(-H "Authorization: Bearer $STUDIO_TOKEN")
tray() { curl -s "${C[@]}" "$STUDIO_URL/v1/tray"; }
iso() { python3 -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }

# ---------------------------------------------------------------- 1. quem lê; só leitura
check "sem token: 401"                                 test "$(code "$STUDIO_URL/v1/tray")" = 401
check "token errado: 401"                              test "$(code -H "Authorization: Bearer ${STUDIO_TOKEN}x" "$STUDIO_URL/v1/tray")" = 401
check "401 não leva bloco nenhum do menu"              jqe 'keys == ["message"]' <<<"$(curl -s "$STUDIO_URL/v1/tray")"
check "com token: 200"                                 test "$(code "${C[@]}" "$STUDIO_URL/v1/tray")" = 200
COOKIE="$(python3 -c 'import hashlib, hmac, sys; print(hmac.new(sys.argv[1].encode(), b"agent-studio cookie v1", hashlib.sha256).hexdigest())' "$STUDIO_TOKEN")"
check "com o cookie do login: 200"                     test "$(code -H "Cookie: agent_studio=$COOKIE" "$STUDIO_URL/v1/tray")" = 200
for m in POST PUT PATCH DELETE; do
  check "$m no /v1/tray: 405 (só leitura)"             test "$(code -X "$m" "${C[@]}" "$STUDIO_URL/v1/tray")" = 405
done

# ---------------------------------------------------------------- 2. banco vazio: o menu inteiro, zerado
E="$(tray)"
check "vazio: todos os blocos"                         jqe 'keys == ["alerts", "at", "attention", "bar", "config", "cost_today", "decisions", "errors_last_hour", "machines", "proposals", "steps", "timezone"]' <<<"$E"
check "vazio: nenhum aviso de rodada"                  jqe '.attention == {total: 0, rows: []}' <<<"$E"
check "vazio: nenhum pedido (a tabela ainda não existe no SurrealDB)" jqe '.proposals == {available: true, total: 0, pending: []} and .bar.pending == 0' <<<"$E"
check "vazio: nenhuma etapa (a tabela ainda não existe no SurrealDB)" jqe '.steps == {available: true, total: 0, rows: []}' <<<"$E"
check "vazio: custo nulo (nunca zero), sem agente"     jqe '.cost_today | .usd == null and .real_usd == null and .estimated_usd == null and .estimated == false and .unpriced_calls == 0 and .agents == []' <<<"$E"
check "vazio: nenhum erro"                             jqe '.errors_last_hour | .total == 0 and .rows == []' <<<"$E"
check "vazio: o sempre ligado aparece parado, sem dado, e alerta" jqe '.machines == [{host: "oute-server", always_on: true, last_data: null, idle_seconds: null, state: "stopped"}] and ([.alerts[].type] == ["host_no_data"]) and .bar.alerts == 1' <<<"$E"

check "ingestão: traces = 200"                         test "$(post traces "$TMP/traces.json")" = 200
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200
check "ingestão: métricas = 200"                       test "$(post metrics "$TMP/metrics.json")" = 200

# ---------------------------------------------------------------- 3. contrato da resposta (o que o #158 consome)
R="$(tray)"
echo "$R" > "$TMP/tray.json"
check "resposta: os blocos do menu"                    jqe 'keys == ["alerts", "at", "attention", "bar", "config", "cost_today", "decisions", "errors_last_hour", "machines", "proposals", "steps", "timezone"]' <<<"$R"
check "at: a hora da resposta (UTC, ISO)"              jqe --argjson now "$NOW" '(.at | fromdateiso8601) as $t | $t >= $now and $t < $now + 300' <<<"$R"
check "bar: só os dois contadores"                     jqe '.bar == {pending: 2, alerts: 3}' <<<"$R"
check "bar: iguais ao tamanho dos blocos"              jqe '.bar.pending == .proposals.total and .bar.alerts == (.alerts | length)' <<<"$R"
check "config: erros da config (chave desconhecida)"   jqe '.config | keys == ["errors"] and (.errors | length == 1 and (.[0] | test("foo")))' <<<"$R"

# máquinas
check "máquinas: campos de cada uma"                   jqe '.machines | length == 3 and all(keys == ["always_on", "host", "idle_seconds", "last_data", "state"])' <<<"$R"
check "máquinas: em ordem de host, ativas, com o sempre ligado marcado" jqe '[.machines[] | [.host, .state, .always_on]] == [["oute-mac", "active", false], ["oute-server", "active", true], ["oute-velho", "active", false]]' <<<"$R"
check "máquinas: último dado = hora de chegada (agora), há poucos segundos" jqe --argjson now "$NOW" '.machines | all((.last_data | fromdateiso8601) >= $now and .idle_seconds >= 0 and .idle_seconds < 300)' <<<"$R"
AL="$(curl -s "${C[@]}" "$STUDIO_URL/v1/alerts")"
check "máquinas: fato de 3 dias atrás que chegou agora conta (no /v1/alerts, pela hora do fato, o host nem aparece)" jqe '[.hosts[].host] == ["oute-mac", "oute-server"]' <<<"$AL"

# pedidos pendentes
check "pedidos: disponível, total e lista"             jqe '.proposals | keys == ["available", "pending", "total"] and .available == true and .total == 2 and (.pending | length == 2)' <<<"$R"
check "pedidos: campos de cada um"                     jqe '.proposals.pending | all(keys == ["age_seconds", "agent", "as", "host", "id", "instance", "proposed_at", "title", "url"])' <<<"$R"
check "pedidos: do mais novo para o mais antigo; o decidido não entra" jqe --arg p1 "$P1" --arg p5 "$P5" '[.proposals.pending[].id] == [$p5, $p1]' <<<"$R"
check "pedido: título, root, agente, host e instância" jqe --arg t "$(iso $((NOW - 300)))" '.proposals.pending[1] | .title == "Reiniciar <b>nginx</b> & cia" and .as == "root" and .agent == "claude" and .host == "oute-server" and .instance == "oute-agent" and .proposed_at == $t' <<<"$R"
check "pedido: user, codex, oute-mac"                  jqe '.proposals.pending[0] | .as == "user" and .agent == "codex" and .host == "oute-mac"' <<<"$R"
check "pedido: idade em segundos desde a proposta"     jqe '.proposals.pending | (.[1].age_seconds >= 300 and .[1].age_seconds < 600) and (.[0].age_seconds >= 60 and .[0].age_seconds < 360)' <<<"$R"
check "pedido: link do ver script (caminho estável por id)" jqe --arg p1 "$P1" '.proposals.pending[1].url == "/pedido?id=" + $p1' <<<"$R"
check "pedido: id estranho codificado no link"         jqe '.proposals.pending[0].url == "/pedido?id=p%20%3Cb%3E5%3C/b%3E%26x%3D%C3%A9"' <<<"$R"
for i in 0 1; do
  U="$(jq -r ".proposals.pending[$i].url" <<<"$R")"
  check "pedido $i: o link abre a página do pedido (200, com o script)" bash -c 'grep -q "data-script" <<<"$1"' _ "$(studio_page "${C[@]}" "$STUDIO_URL$U")"
done
check "pedidos: o mesmo link da lista da tela"         grep -qF "href=\"$(jq -r '.proposals.pending[0].url' <<<"$R")\"" <<<"$(studio_page "${C[@]}" "$STUDIO_URL/pedidos")"
check "pedidos: o script não vem na resposta (só na página)" bash -c '! grep -q "systemctl" "$1"' _ "$TMP/tray.json"

# etapas das rodadas abertas (#508)
check "atenção: total e campos de cada item"           jqe '.attention | keys == ["rows", "total"] and .total == 5 and (.rows | length == 5) and (.rows | all(keys == ["age_seconds", "at", "id", "key", "kind", "name", "round", "title", "url"]))' <<<"$R"
check "atenção: pergunta, sessão blocked, CI reprovado e merge; o resto não vale mais" jqe '[.attention.rows[] | .kind + ":" + (.key // "")] | sort == ["blocked:7", "ci:13", "merged:12", "merged:15", "question:"]' <<<"$R"
check "atenção: títulos fixos por tipo"                jqe '[.attention.rows[].title] | sort == ["CI reprovado no PR #13", "PR #12 mergeado", "PR #15 mergeado", "Pergunta pendente do dispatcher", "Sessão #7 parada (blocked)"]' <<<"$R"
check "atenção: nome amigável e link da página da rodada (só da rodada aberta)" jqe '.attention.rows | all(.round == "swarm-1004-1000" and .name == "Brave_Otter" and .url == "/rodada?id=swarm-1004-1000")' <<<"$R"
check "atenção: id por ocorrência (rodada|tipo|chave|hora)" jqe '.attention.rows | all(.id | test("^swarm-1004-1000\\|(ci|blocked|question|merged)\\|[0-9]*\\|[0-9]+$"))' <<<"$R"
check "atenção: idade em segundos do fato"             jqe '[.attention.rows[] | select(.kind == "ci") | .age_seconds][0] as $a | $a >= 700 and $a < 1000' <<<"$R"
check "atenção: o texto do evento e o rótulo estranho nunca chegam" bash -c '! grep -qF -e "<b>" -e "baz" -e "verde" -e "PR #20" <<<"$1"' _ "$(jq -c .attention <<<"$R")"
check "atenção: a pergunta vem como decisão pendente também" jqe '.decisions.total == 1 and .decisions.pending[0].round == "swarm-1004-1000"' <<<"$R"
check "etapas: disponível, total e lista"              jqe '.steps | keys == ["available", "rows", "total"] and .available == true and .total == 4 and (.rows | length == 4)' <<<"$R"
check "etapas: campos de cada uma, nenhum é o texto"   jqe '.steps.rows | all(keys == ["age_seconds", "key", "kind", "name", "published_at", "rev", "review", "round", "title", "url"])' <<<"$R"
check "etapas: da mais nova para a mais antiga; a rodada fechada (TB) fica fora; a sem estado (TC) conta" jqe '[.steps.rows[] | .round + ":" + .kind + ":" + (.key // "")] == ["swarm-1004-1100:fechamento:", "swarm-1004-1000:merge:13", "swarm-1004-1000:merge:12", "swarm-1004-1000:triagem:"]' <<<"$R"
check "etapas: nome amigável da rodada (#605): o da rodada com nome, nulo na antiga" jqe '[.steps.rows[] | .round + "=" + (.name // "-")] | sort == ["swarm-1004-1000=Brave_Otter", "swarm-1004-1000=Brave_Otter", "swarm-1004-1000=Brave_Otter", "swarm-1004-1100=-"]' <<<"$R"
check "etapas: título fixo por tipo, com o PR no merge" jqe '[.steps.rows[].title] == ["Fechamento da rodada", "Pedido de merge #13", "Pedido de merge #12", "Triagem"]' <<<"$R"
check "etapas: veredito do revisor e revisão"          jqe '[.steps.rows[] | [.review, .rev]] == [["aprovado", 1], ["sem-revisor", 1], ["aprovado", 1], ["aprovado", 1]]' <<<"$R"
check "etapas: chave só no merge, nula nas outras"     jqe '[.steps.rows[].key] == [null, "13", "12", null]' <<<"$R"
check "etapas: link da página da rodada, com a âncora da etapa" jqe '[.steps.rows[].url] == ["/rodada?id=swarm-1004-1100#etapa-fechamento", "/rodada?id=swarm-1004-1000#etapa-merge-13", "/rodada?id=swarm-1004-1000#etapa-merge-12", "/rodada?id=swarm-1004-1000#etapa-triagem"]' <<<"$R"
check "etapas: idade em segundos desde a publicação (1 min, 90 s, 2 min, 48 min)" jqe '[.steps.rows[].age_seconds] as $a | ($a[0] >= 60 and $a[0] < 360) and ($a[1] >= 90 and $a[1] < 390) and ($a[2] >= 120 and $a[2] < 420) and ($a[3] >= 2900 and $a[3] < 3200)' <<<"$R"
check "etapas: o texto da etapa não vem na resposta"   bash -c '! grep -q "segredo-da-etapa" "$1"' _ "$TMP/tray.json"
check "etapas: cada link abre a página da rodada (200, com a etapa)" bash -c 'for u in $(jq -r ".steps.rows[].url" <<<"$1"); do b="$(studio_page -H "Authorization: Bearer $3" "$2${u%%#*}")"; grep -q "id=\"${u#*#}\"" <<<"$b" || exit 1; done' _ "$R" "$STUDIO_URL" "$STUDIO_TOKEN"
check "etapas: o total do bloco = o que o /v1/rodada tem de etapa nas rodadas abertas" test "$(for r in swarm-1004-1000 swarm-1004-1100; do curl -s "${C[@]}" "$STUDIO_URL/v1/rodada?id=$r" | jq '.steps | length'; done | jq -s add)" = "$(jq '.steps.total' <<<"$R")"
check "etapas: a barra do tray não conta etapa (só pedidos e alertas)" jqe '.bar | keys == ["alerts", "pending"]' <<<"$R"

# custo de hoje
DAY=$((NOW / 86400 * 86400))
check "custo: campos do bloco"                         jqe '.cost_today | keys == ["agents", "day", "estimated", "estimated_usd", "from", "listed_usd", "real_usd", "to", "unpriced_calls", "usd"]' <<<"$R"
check "custo: hoje = o dia UTC inteiro"                jqe --arg f "$(iso "$DAY")" --arg t "$(iso $((DAY + 86400)))" '.cost_today | .day == $f[:10] and .from == $f and .to == $t' <<<"$R"
check "custo total: real + lista (#747), sem a marca de estimado; ontem fora" jqe ".cost_today | $(usd .usd) == 5540400 and $(usd .real_usd) == 30400 and $(usd .listed_usd) == 5510000 and .estimated_usd == null and .estimated == false and .unpriced_calls == 1" <<<"$R"
check "custo por agente: campos"                       jqe '.cost_today.agents | all(keys == ["agent", "calls", "estimated", "estimated_usd", "listed_usd", "real_usd", "unpriced_calls", "usd"])' <<<"$R"
check "custo por agente: em ordem de agente"           jqe '[.cost_today.agents[].agent] == ["claude", "codex", "pi"]' <<<"$R"
check "claude: real + lista (a chamada sem log), sem a marca de estimado" jqe ".cost_today.agents[0] | .calls == 3 and $(usd .usd) == 3030000 and $(usd .real_usd) == 30000 and $(usd .listed_usd) == 3000000 and .estimated_usd == null and .estimated == false and .unpriced_calls == 0" <<<"$R"
check "codex: só lista, sem estimado; modelo sem preço fora da soma" jqe ".cost_today.agents[1] | .calls == 3 and $(usd .usd) == 2510000 and .real_usd == null and $(usd .listed_usd) == 2510000 and .estimated_usd == null and .estimated == false and .unpriced_calls == 1" <<<"$R"
check "pi: só real, sem a marca de estimado"           jqe ".cost_today.agents[2] | .calls == 1 and $(usd .usd) == 400 and .estimated_usd == null and .estimated == false" <<<"$R"
US="$(curl -s "${C[@]}" "$STUDIO_URL/v1/usage?from=$(iso "$DAY")&to=$(iso $((DAY + 86400)))")"
check "custo: o mesmo do /v1/usage do dia (#203)"      jqe --argjson u "$US" '.cost_today | .real_usd == $u.totals.cost.real_usd and .listed_usd == $u.totals.cost.listed_usd and .estimated_usd == $u.totals.cost.estimated_usd and .unpriced_calls == $u.totals.cost.unpriced_calls' <<<"$R"

# erros na última hora
check "erros: campos do bloco e de cada linha"         jqe '.errors_last_hour | keys == ["from", "rows", "to", "total"] and (.rows | all(keys == ["agent", "host", "logs", "spans", "total"]))' <<<"$R"
check "erros: janela de uma hora até agora"            jqe '.at as $at | .errors_last_hour | .to == $at and ((.to | fromdateiso8601) - (.from | fromdateiso8601) == 3600)' <<<"$R"
check "erros: por host × agente, em ordem; o de 2 h atrás fora" jqe '.errors_last_hour | .total == 3 and .rows == [{host: "oute-mac", agent: "codex", spans: 1, logs: 1, total: 2}, {host: "oute-server", agent: "claude", spans: 1, logs: 0, total: 1}]' <<<"$R"
check "erros: os mesmos do /v1/usage da última hora"   jqe --argjson r "$R" '.totals.errors.total == $r.errors_last_hour.total' <<<"$(curl -s "${C[@]}" "$STUDIO_URL/v1/usage?hours=1")"

# alertas
check "alertas: os do /v1/alerts (#204), com os mesmos campos; só ganham title e text (#344)" jqe --argjson a "$AL" '(.alerts | length == 3) and ([.alerts[] | del(.title, .text)] == $a.alerts) and ($a.alerts | all(has("title") | not))' <<<"$R"
check "alerta: title e text prontos, valor e limite por extenso" jqe '.alerts[0] | .title == "Fila do collector acima do limite" and .text == "80% da fila (limite 50%)"' <<<"$R"
check "alertas do custo (#747): conferência do claude e assinatura sem preço, com title e text prontos" jqe '([.alerts[] | select(.type == "cost_claude_diff" or .type == "cost_subscription_unpriced")] | map(.type) | sort) == ["cost_claude_diff", "cost_subscription_unpriced"] and all(.alerts[]; (.title | length) > 0 and .title != .type and (.text | length) > 0)' <<<"$R"
check "alerta: fila do collector do oute-server a 80%" jqe '.alerts[0] | .type == "queue" and .host == "oute-server" and .value == 0.8 and .limit == 0.5 and .unit == "ratio" and (has("since") and has("evidence") and has("instance"))' <<<"$R"

# ---------------------------------------------------------------- 4. SurrealDB fora: o menu segue, sem os pedidos
surreal_stop
D="$(tray)"
check "SurrealDB fora: 200"                            test "$(code "${C[@]}" "$STUDIO_URL/v1/tray")" = 200
check "SurrealDB fora: pedidos indisponíveis, contador nulo (nunca zero)" jqe '.proposals == {available: false, total: null, pending: []} and .bar.pending == null' <<<"$D"
check "SurrealDB fora: etapas indisponíveis (nunca zero por palpite)" jqe '.steps == {available: false, total: null, rows: []}' <<<"$D"
check "SurrealDB fora: o resto do menu igual"          jqe --argjson r "$R" '.bar.alerts == 3 and .cost_today == $r.cost_today and .errors_last_hour.rows == $r.errors_last_hour.rows and ([.machines[].host] == [$r.machines[].host]) and .alerts == $r.alerts' <<<"$D"
# fixture do app do tray (#344): mesmas chaves e mesmos tipos da resposta real. Pedido local e de outro host, id com
# caractere inválido, custo estimado e sem preço e alerta vêm de R; o contador nulo, de D (SurrealDB fora).
echo "$D" > "$TMP/tray-down.json"
FIX="$ROOT/tray/Tests/Fixtures"
shape_cmp() { python3 - "$@" <<'PY'
import json, sys
def shape(v):
    if isinstance(v, dict):
        return {k: shape(x) for k, x in sorted(v.items())}
    if isinstance(v, list):
        return [merge([shape(x) for x in v])] if v else []
    return "null" if v is None else "bool" if isinstance(v, bool) else "number" if isinstance(v, (int, float)) else type(v).__name__
def merge(shapes):
    first = shapes[0]
    for s in shapes[1:]:
        if isinstance(first, dict) and isinstance(s, dict) and first.keys() == s.keys():
            first = {k: merge([first[k], s[k]]) for k in first}
        elif first == "null":
            first = s
    return first
def diff(a, b, path="$"):
    """Chaves iguais; tipos iguais, e `null` de um lado casa com qualquer tipo do outro (campo anulável)."""
    if path.endswith(".evidence"):  # cada tipo de alerta tem a sua prova: objeto livre, só confere que é objeto
        return [] if isinstance(a, dict) and isinstance(b, dict) else [f"{path}: {a} != {b}"]
    if isinstance(a, dict) and isinstance(b, dict):
        if a.keys() != b.keys():
            return [f"{path}: chaves {sorted(a)} != {sorted(b)}"]
        return [d for k in a for d in diff(a[k], b[k], f"{path}.{k}")]
    if isinstance(a, list) and isinstance(b, list):
        return diff(a[0], b[0], path + "[]") if a and b else []
    return [] if a == b or "null" in (a, b) else [f"{path}: {a} != {b}"]
fix, real = (shape(json.load(open(f))) for f in sys.argv[1:3])
errs = diff(fix, real)
print("\n".join(errs))
sys.exit(1 if errs else 0)
PY
}
export -f shape_cmp
check "fixture tray.json: mesmas chaves e tipos da resposta real" shape_cmp "$FIX/tray.json" "$TMP/tray.json"
check "fixture tray-sem-surrealdb.json: mesmas chaves e tipos da resposta com o SurrealDB fora" shape_cmp "$FIX/tray-sem-surrealdb.json" "$TMP/tray-down.json"
check "fixture: o mesmo bloco de alertas da API (title e text junto)" jqe '.alerts[0] | keys == ["evidence", "host", "instance", "limit", "since", "text", "title", "type", "unit", "value"]' < "$FIX/tray.json"
check "fixture: pedido local, de outro host e de id inválido" jqe '[.proposals.pending[] | .host] | unique == ["oute-mac", "oute-server"]' < "$FIX/tray.json"
check "fixture: o id inválido vai codificado no link" jqe '.proposals.pending[0] | (.id | test("[<>& ]")) and (.url | test("^/pedido\\?id=[A-Za-z0-9%/._-]+$"))' < "$FIX/tray.json"
check "fixture: custo de lista (não estimado) e chamada sem preço" jqe '.cost_today | .estimated == false and .listed_usd > 0 and .unpriced_calls > 0 and (.agents | any(.real_usd == null))' < "$FIX/tray.json"
check "fixture: etapas das rodadas, com o merge do PR e o veredito do revisor (#508)" jqe '.steps | .available == true and .total == (.rows | length) and ([.rows[].review] | unique | length) > 1 and (.rows | any(.kind == "merge" and .key != null and (.url | test("^/rodada\\?id=[A-Za-z0-9%._-]+#etapa-merge-[0-9]+$")))) and (.rows | any(.key == null))' < "$FIX/tray.json"
check "fixture: avisos das rodadas, um de cada tipo, com o caminho da página (#776)" jqe '.attention | .total == (.rows | length) and ([.rows[].kind] | sort == ["blocked", "ci", "merged", "question"]) and (.rows | all(.url | test("^/rodada\\?id=[A-Za-z0-9%._-]+$"))) and ([.rows[].id] | unique | length == 4)' < "$FIX/tray.json"
check "fixture: sem o SurrealDB os avisos seguem (vêm do DuckDB)" jqe '.attention == {total: 0, rows: []}' < "$FIX/tray-sem-surrealdb.json"
check "fixture: sem o SurrealDB, etapas indisponíveis" jqe '.steps == {available: false, total: null, rows: []}' < "$FIX/tray-sem-surrealdb.json"
check "fixture: contador nulo só com o SurrealDB fora" jqe '.bar.pending == null and .proposals.available == false' < "$FIX/tray-sem-surrealdb.json"
check "fixture: contadores da barra batem com os blocos" jqe '.bar == {pending: .proposals.total, alerts: (.alerts | length)}' < "$FIX/tray.json"
jq 'del(.alerts[0].text)' "$FIX/tray.json" > "$TMP/fix-sem-text.json"
jq '.bar.alerts = "1"' "$FIX/tray.json" > "$TMP/fix-tipo.json"
check "sanidade do teste de forma: chave a menos na fixture falha" bash -c '! shape_cmp "$1" "$2" >/dev/null' _ "$TMP/fix-sem-text.json" "$TMP/tray.json"
check "sanidade do teste de forma: tipo trocado na fixture falha" bash -c '! shape_cmp "$1" "$2" >/dev/null' _ "$TMP/fix-tipo.json" "$TMP/tray.json"
studio_stop
check "SurrealDB fora: causa só no stderr"             grep -q "tray: pedidos pendentes falhou" "$TMP/s/stderr"
check "SurrealDB fora: a falha das etapas também só no stderr" grep -q "tray: etapas das rodadas falhou" "$TMP/s/stderr"
check "SurrealDB fora: a resposta não leva a causa"    bash -c '! grep -qi "surreal\|refused\|urlopen" <<<"$1"' _ "$D"

# ---------------------------------------------------------------- 5. lógica direto (hora escolhida, limites, falhas)
cp "$TMP/s/db.duckdb" "$TMP/copy.duckdb"
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/copy.duckdb" "$TMP/config.toml" "$NOW" > "$TMP/py.out" 2>&1 <<'PY'
import dataclasses, logging, sys, duckdb
logging.disable(logging.CRITICAL)  # as falhas provocadas aqui não vão para a saída (só os casos)
from agent_studio import alerts, config, proposals, tray
from agent_studio.app import create_app
from pycheck import check as out
from studio_asgi import TOKEN, Odd, get
import json
db, cfg_path, NOW = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = config.load(cfg_path)
con = duckdb.connect(db)
at = (NOW + 60) * 10**9
H = 3600 * 10**9
# o oute-mac parou de mandar há 2 h (hora de chegada), com a hora do fato de agora
for t in ("logs", "spans", "metrics"):
    con.execute(f"UPDATE {t} SET received_unix_nano = ? WHERE host_name = 'oute-mac'", [at - 2 * H])
on = dataclasses.replace(cfg.alerts, always_on_hosts=("oute-server", "oute-nunca"))
s = tray.snapshot(con, at, cfg.prices, on)
m = {x["host"]: x for x in s["machines"]}
out("parado: sem chegada há mais de no_data_minutes (o fato recente não conta)", m["oute-mac"]["state"] == "stopped" and m["oute-mac"]["idle_seconds"] == 7200)
out("custo (#747): o de lista soma sem a marca; só o estimado (fora das três assinaturas) marca `estimated`",
    tray._cost({"cost": {"real_usd": None, "listed_usd": 2.0, "estimated_usd": None, "estimated_calls": 0, "unpriced_calls": 0}})
    == {"usd": 2.0, "real_usd": None, "listed_usd": 2.0, "estimated_usd": None, "estimated": False, "unpriced_calls": 0}
    and tray._cost({"cost": {"real_usd": 1.0, "listed_usd": 2.0, "estimated_usd": 0.5, "estimated_calls": 1, "unpriced_calls": 0}})
    == {"usd": 3.5, "real_usd": 1.0, "listed_usd": 2.0, "estimated_usd": 0.5, "estimated": True, "unpriced_calls": 0})
out("ativo: quem chegou dentro de no_data_minutes", m["oute-server"]["state"] == "active" and m["oute-velho"]["state"] == "active")
out("sempre ligado sem dado nenhum: parado, último dado nulo", m["oute-nunca"] == {"host": "oute-nunca", "always_on": True, "last_data": None, "idle_seconds": None, "state": "stopped"})
out("limite do parado = o no_data_minutes do [alerts] (#204)", {x["host"]: x["state"] for x in tray.snapshot(con, at, cfg.prices, dataclasses.replace(on, no_data_minutes=121))["machines"]}["oute-mac"] == "active")
out("máquina sai da lista depois de lookback_hours sem chegada (a sempre ligada fica)", [x["host"] for x in tray.snapshot(con, at + 30 * H, cfg.prices, cfg.alerts)["machines"]] == ["oute-server"])
tomorrow = tray.snapshot(con, at + 24 * H, cfg.prices, cfg.alerts)
out("amanhã: custo de hoje nulo e sem agente (nunca zero)", tomorrow["cost_today"]["usd"] is None and tomorrow["cost_today"]["agents"] == [] and not tomorrow["cost_today"]["estimated"])
out("amanhã: nenhum erro na última hora", tomorrow["errors_last_hour"] == {**tomorrow["errors_last_hour"], "total": 0, "rows": []})
day = NOW // 86400 * 86400
y = tray.snapshot(con, (day - 1800) * 10**9, cfg.prices, cfg.alerts)["cost_today"]
out("ontem: só o custo do dia de ontem", y["usd"] == 100.0 and [a["agent"] for a in y["agents"]] == ["claude"] and not y["estimated"])
con.execute("UPDATE logs SET oute_agent = NULL WHERE severity_number >= 17")
out("erro de log sem agente: linha própria, com o agente nulo depois dos nomeados do host",
    tray.snapshot(con, at, cfg.prices, cfg.alerts)["errors_last_hour"]["rows"][:2]
    == [{"host": "oute-mac", "agent": "codex", "spans": 1, "logs": 0, "total": 1}, {"host": "oute-mac", "agent": None, "spans": 0, "logs": 1, "total": 1}])
try:
    alerts.last_data(con, 0, at, by="body")
    refused = False
except ValueError:
    refused = True
out("last_data: só a hora do fato ou a de chegada (outra coluna é recusada)", refused)
con.close()

# pedidos: limite, total e hora que não é hora
class Fake:
    def __init__(self, rows, n): self.rows, self.n, self.vars = rows, n, None
    def query(self, sql, variables):
        self.vars = variables
        return [{"status": "OK", "result": self.rows}, {"status": "OK", "result": [{"n": self.n}] if self.n else []}]
rows = [{"id": "a/b c", "title": None, "as": "root", "agent": "claude", "host": "h", "proposed_at": "2026-09-29T07:43:00.5Z"},
        {"id": "sem-hora", "proposed_at": None}]
f = Fake(rows, 77)
p = tray.pending(f, 1790667790 * 10**9)  # 2026-09-29T07:43:10Z
out("pedidos: pede só os 50 mais novos e devolve o total", f.vars == {"pending": 50} and p["total"] == 77 and p["available"] is True)
out("pedido: hora do SurrealDB com fração -> ISO em segundos e idade", p["pending"][0]["proposed_at"] == "2026-09-29T07:43:00Z" and p["pending"][0]["age_seconds"] == 10)
out("pedido: barra do id fica no link, o espaço é codificado", p["pending"][0]["url"] == "/pedido?id=a/b%20c")
out("pedido sem hora e sem título: campos nulos, sem quebrar", p["pending"][1] == {"id": "sem-hora", "title": None, "as": None, "agent": None, "host": None, "instance": None, "proposed_at": None, "age_seconds": None, "url": "/pedido?id=sem-hora"})
out("pedido proposto no futuro (relógio do host): idade zero, nunca negativa", proposals.age_seconds("2030-01-01T00:00:00Z", 0) == 0)
out("nenhum pendente: total zero", tray.pending(Fake([], 0), 0) == {"available": True, "total": 0, "pending": []})

# avisos das rodadas (#776): a leitura que falha cai em vazio, sem derrubar o menu
from agent_studio import avisos
def _boom(con, at_ns, cfg): raise RuntimeError("segredo-da-falha-dos-avisos")
_ok = avisos.pending
avisos.pending = _boom
try:
    caiu = tray._attention(None, 0, None)
finally:
    avisos.pending = _ok
out("avisos: leitura que falha cai em vazio (o menu segue)", caiu == {"total": 0, "rows": []} == avisos.NONE)
out("avisos: o texto de uma sessão fora do formato não vira item",
    avisos._round_items([{"event_name": avisos.WATCH_SESSION, "body": "#7 Foo/../x: blocked", "t": 1, "slug": None}], "r", 2 * 10**9, None) == [])
out("avisos: falha de CI depois do PR fechado sem merge não vale",
    avisos._round_items([{"event_name": avisos.WATCH_CI, "body": "PR #3 · test: fail", "t": 1, "slug": None},
                         {"event_name": avisos.WATCH_PR, "body": "PR #3 fechado sem merge (issue #1)", "t": 2, "slug": None}], "r", 3 * 10**9, None) == [])
out("avisos: nova falha depois do verde é outra ocorrência (id novo)",
    [i["id"] for i in avisos._round_items([{"event_name": avisos.WATCH_CI, "body": "PR #3 · test: fail", "t": 1, "slug": None}], "r", 3 * 10**9, None)]
    != [i["id"] for i in avisos._round_items([{"event_name": avisos.WATCH_CI, "body": "PR #3 · test: fail", "t": 5, "slug": None}], "r", 6 * 10**9, None)])

# o app com um SurrealDB que responde fora do formato, e sem SurrealDB
class Snap:
    def tray(self, at_ns, prices, cfg, tz=None):
        return {"machines": [], "cost_today": {}, "errors_last_hour": {}, "alerts": [{"type": "queue"}, {"type": "spool"}]}
for name, surreal in (("resposta fora do formato", Odd()), ("este processo sem SurrealDB", None)):
    status, body = get(create_app(Snap(), TOKEN, surreal), "/v1/tray")
    r = json.loads(body)
    out(f"{name}: 200, pedidos indisponíveis e o resto do menu", status == 200 and r["proposals"] == tray.UNAVAILABLE and r["bar"] == {"pending": None, "alerts": 2})
    out(f"{name}: 200 e etapas indisponíveis (#508)", r["steps"] == tray.NO_STEPS)
class Half:
    """Os pedidos respondem; a consulta das etapas falha com um texto que nunca pode chegar ao cliente."""
    def query(self, sql, variables):
        if "etapa" in sql:
            raise RuntimeError("segredo-da-falha-das-etapas")
        return [{"status": "OK", "result": []}, {"status": "OK", "result": []}]
status, body = get(create_app(Snap(), TOKEN, Half()), "/v1/tray")
r = json.loads(body)
out("só as etapas falham: 200, etapas indisponíveis e os pedidos seguem", status == 200 and r["steps"] == tray.NO_STEPS and r["proposals"] == {"available": True, "total": 0, "pending": []} and r["bar"]["pending"] == 0)
out("só as etapas falham: a causa não vai na resposta", "segredo-da-falha-das-etapas" not in body)
PY
check_py_lines "$TMP/py.out"

# ---------------------------------------------------------------- 6. leitura do DuckDB que falha
studio_start "$TMP/f" STUDIO_FAIL_USAGE=1 AGENT_STUDIO_CONFIG="$TMP/config.toml" || die "agent-studio não subiu"
check "leitura que falha: 500"                         test "$(code "${C[@]}" "$STUDIO_URL/v1/tray")" = 500
check "leitura que falha: a resposta não leva a causa" jqe '. == {message: "consulta falhou"}' <<<"$(tray)"
studio_stop
check "leitura que falha: causa no stderr"             grep -q "consulta do tray falhou" "$TMP/f/stderr"

# ---------------------------------------------------------------- 7. tempo de resposta (polling de 15 s)
# Banco com volume acima do de produção de hoje (2026-10: 2 hosts, ~3 dias de dado): 3 dias, uma coleta do collector
# por minuto (2 hosts × 7 exporters × 5 métricas) + 30 séries de métrica por host, 10 spans e 15 logs por minuto.
# As linhas entram direto no DuckDB (pela ingestão levaria minutos). O limite é folgado (máquina de CI): o que se
# quer pegar é a consulta que passa a varrer o banco inteiro. O valor medido fica no ADR-08 (#205).
mkdir -p "$TMP/v"
PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP/v/db.duckdb" 3 > "$TMP/gen.out" 2>&1 <<'PY'
import sys, time
from agent_studio.store import Store
path, days = sys.argv[1], int(sys.argv[2])
now = time.time_ns()
MIN = 60 * 10**9
mins = days * 1440
st = Store(path)
c = st.con
c.execute("BEGIN")
TS = "make_timestamp_ns(t::BIGINT) AT TIME ZONE 'UTC'"
# métricas do collector: 1 coleta por minuto, 2 hosts, 7 exporters, 5 métricas (fila: tamanho e capacidade; 3 send_failed)
c.execute(f"""
INSERT INTO metrics (dedupe_key, time, time_unix_nano, start_unix_nano, host_name, oute_instance, service_name, metric_name,
                     metric_type, value, is_monotonic, aggregation_temporality, attributes, received_at, received_unix_nano)
SELECT 'h:' || m || '-' || h || '-' || e || '-' || k, {TS}, t, {now} - {mins} * {MIN}, 'oute-' || ['server', 'mac'][h], 'oute-agent',
       'otelcol-contrib', name, CASE WHEN k <= 2 THEN 'gauge' ELSE 'sum' END,
       CASE k WHEN 1 THEN 1000 + e WHEN 2 THEN 629145600 ELSE 0 END, k > 2, CASE WHEN k > 2 THEN 2 END,
       json_object('exporter', 'exp/' || e), {TS}, t
FROM (SELECT m, h, e, k, {now} - m * {MIN} - k * 1000 AS t,
             ['otelcol_exporter_queue_size', 'otelcol_exporter_queue_capacity', 'otelcol_exporter_send_failed_spans',
              'otelcol_exporter_send_failed_metric_points', 'otelcol_exporter_send_failed_log_records'][k] AS name
      FROM range({mins}) a(m), range(1, 3) b(h), range(7) d(e), range(1, 6) f(k))""")
# outras métricas (agentes, receivers): 30 séries por host por minuto
c.execute(f"""
INSERT INTO metrics (dedupe_key, time, time_unix_nano, host_name, oute_instance, oute_agent, service_name, metric_name, metric_type,
                     value, attributes, received_at, received_unix_nano)
SELECT 'o:' || m || '-' || h || '-' || k, {TS}, t, 'oute-' || ['server', 'mac'][h], 'oute-agent', ['claude', 'codex'][1 + k % 2],
       'claude-code', 'claude_code.metric.' || k, 'sum', k, json_object('type', 'x' || k), {TS}, t
FROM (SELECT m, h, k, {now} - m * {MIN} - k * 1000 AS t FROM range({mins}) a(m), range(1, 3) b(h), range(30) d(k))""")
# spans: 10 por minuto (1 em 10 é chamada ao modelo; 1 em 200 com erro); logs: 15 por minuto, com o estado do spool.
# Claude como em produção (#157): o span sem custo, com o request_id; o custo no log api_request da mesma hora
c.execute(f"""
INSERT INTO spans (dedupe_key, time, time_unix_nano, duration_ns, host_name, oute_instance, oute_agent, service_name, session_id,
                   trace_id, span_id, name, status_code, model, input_tokens, output_tokens, cost_usd, attributes,
                   received_at, received_unix_nano)
SELECT 's:' || i, {TS}, t, 1000000 * (1 + i % 5000), 'oute-' || ['server', 'mac'][1 + i % 2], 'oute-agent',
       ['claude', 'codex', 'pi'][1 + i % 3], 'x', 'conv-' || (i // 500), 't' || i, 's' || i,
       CASE WHEN i % 10 = 0 THEN ['claude_code.llm_request', 'session_task.turn', 'jev.decision'][1 + i % 3] ELSE 'claude_code.tool' END,
       CASE WHEN i % 200 = 7 THEN 2 ELSE 0 END, ['claude-sonnet-5', 'gpt-5-codex', 'openai/gpt-oss-20b'][1 + i % 3],
       1000 + i % 9000, 100 + i % 900, CASE WHEN i % 3 = 0 OR i % 3 = 1 THEN NULL ELSE 0.01 END,
       CASE WHEN i % 30 = 0 THEN json_object('request_id', 'r' || i) ELSE '{{}}' END, {TS}, t
FROM (SELECT i, {now} - i * 6 * 1000000000 AS t FROM range({mins * 10}) a(i))""")
c.execute(f"""
INSERT INTO logs (dedupe_key, time, time_unix_nano, host_name, oute_instance, oute_agent, service_name, session_id, event_name,
                  oute_event_id, severity_number, body, attributes, received_at, received_unix_nano)
SELECT 'l:' || i, {TS}, t, 'oute-' || ['server', 'mac'][1 + i % 2], 'oute-agent', ['claude', 'codex'][1 + i % 2], 'x',
       'conv-' || (i // 500), CASE WHEN i % 45 = 0 THEN 'api_request' ELSE 'claude_code.api_request' END, 'ev-' || i, CASE WHEN i % 300 = 3 THEN 17 ELSE 9 END,
       repeat('texto do log ', 20),
       CASE WHEN i % 45 = 0 THEN json_object('event.name', 'api_request', 'request_id', 'r' || (i * 2 // 3), 'cost_usd', 0.01)
            WHEN i % 50 = 0 THEN json_object('oute.emit.spool.bytes', 1000, 'oute.emit.spool.dropped', 0) ELSE '{{}}' END,
       {TS}, t
FROM (SELECT i, {now} - i * 4 * 1000000000 AS t FROM range({mins * 15}) a(i))""")
c.execute("COMMIT")
print(" ".join(f"{t}={c.execute(f'SELECT count(*) FROM {t}').fetchone()[0]}" for t in ("metrics", "spans", "logs")))
st.close()
PY
check "volume de exemplo montado ($(tail -1 "$TMP/gen.out"))" grep -q '^metrics=561600 spans=43200 logs=64800$' "$TMP/gen.out"
studio_start "$TMP/v" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { cat "$TMP/v/stderr"; die "agent-studio não subiu"; }
check "volume: 200, com máquinas, custo e erros"       jqe '(.machines | length == 2) and .cost_today.usd > 0 and (.cost_today.agents | length == 3) and .errors_last_hour.total > 0' <<<"$(tray)"
check "volume: Claude com custo real, todo pelo log api_request" jqe '.cost_today.agents[0] | .agent == "claude" and .real_usd > 0 and .estimated == false and .unpriced_calls == 0' <<<"$(tray)"
for i in 1 2 3 4 5 6 7; do curl -s -o /dev/null -w '%{time_total}\n' "${C[@]}" "$STUDIO_URL/v1/tray"; done | sort -n > "$TMP/times"
studio_stop
MED="$(sed -n 4p "$TMP/times")"; MAX="$(tail -1 "$TMP/times")"
echo "# /v1/tray com o volume de exemplo: mediana ${MED} s, máximo ${MAX} s (7 chamadas)"
check "tempo: bem abaixo dos 15 s do polling (máximo < 3 s)" awk -v m="$MAX" 'BEGIN { exit !(m > 0 && m < 3) }'

check_end
