#!/usr/bin/env bash
# Testes da tela do agent-studio (#206, ADR-08 §9): login por token que vira cookie, lista de conversas por
# host/agente e detalhe com a árvore de spans e os logs. O DuckDB de exemplo nasce pela ingestão de verdade
# (POST /v1/traces e /v1/logs); as páginas são conferidas pelo HTML que o servidor devolve (atributos `data-*`).
# Mais a lógica direto em Python (árvore com ciclo, limite da lista, leitura que falha = 500). Sem Docker.
# Uso: tests/agent-studio-web.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init
PKG="$ROOT/docker/agent-studio/agent_studio"


# ---------------------------------------------------------------- DuckDB de exemplo
# D1 = 2025-09-27T19:06:40Z. Tudo chega agora: só a hora do fato põe as conversas na janela de 2025.
#   conv-a (claude, oute-server): duas interações; chamada com custo real, chamada estimada, chamada sem preço
#           (órfã: o pai não chegou), tool com erro e um span que não é chamada; 3 logs fora de ordem.
#   conv-b (codex, oute-mac): uma chamada estimada e 205 logs (duas páginas).
#   "conv d/1&x=é" (claude, oute-mac): começou 2 dias antes e segue na janela (os números são da conversa inteira).
#   conv-c (janeiro de 2025): fora da janela. Um span sem session.id: fora de toda conversa.
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import api_request, kv, rl, rs
tmp = sys.argv[1]
D1 = 1759000000
def span(trace, sid, parent, name, start, dur, attrs, err=False):
    s = {"traceId": f"{trace:032x}", "spanId": f"{sid:016x}", "name": name,
         "startTimeUnixNano": str(int(start * 1e9)), "endTimeUnixNano": str(int((start + dur) * 1e9)),
         "attributes": kv(attrs)}
    if parent: s["parentSpanId"] = f"{parent:016x}"
    if err: s["status"] = {"code": 2, "message": "comando falhou"}
    return s
claude = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "claude-code", "oute.agent": "claude",
          "oute.task.id": "oute-agent-206"}
codex = {"host.name": "oute-mac", "service.name": "codex_exec", "oute.agent": "codex"}
mac_claude = {"host.name": "oute-mac", "service.name": "claude-code", "oute.agent": "claude"}
A, B, C, D = ({"session.id": s} for s in ("conv-a", "conv-b", "conv-c", "conv d/1&x=é"))
sonnet = {"model": "claude-sonnet-5"}
traces = {"resourceSpans": [
  rs(claude, [
    # fora de ordem de propósito: a árvore sai pela hora do fato, não pela chegada
    span(1, 0xa5, 0xa1, "claude_code.llm_request", D1 + 7, 3, {**A, **sonnet, "input_tokens": 1_000_000}),
    span(1, 0xa4, 0xa3, "claude_code.tool.execution", D1 + 4.5, 1, A, err=True),
    span(1, 0xa1, None, "claude_code.interaction", D1, 20, {**A, "user_prompt": "<script>alert('span')</script>"}),
    span(1, 0xa2, 0xa1, "claude_code.llm_request", D1 + 1, 2,
         {**A, **sonnet, "input_tokens": 100, "output_tokens": 50, "cache_read_tokens": 1000, "cache_creation_tokens": 10, "request_id": "req-a2"}),
    # não é chamada ao modelo: o cost_usd dele não entra em soma nem aparece na coluna
    span(1, 0xa3, 0xa1, "claude_code.tool", D1 + 4, 2, {**A, "tool_name": "Bash", "cost_usd": 50.0, "input_tokens": 999}),
    # órfão: o pai (0xff) nunca chegou; modelo sem preço na tabela
    span(1, 0xa6, 0xff, "claude_code.llm_request", D1 + 12, 1, {**A, "model": "modelo-sem-preco", "input_tokens": 500}),
    span(2, 0xa7, None, "claude_code.interaction", D1 + 30, 1, A),
    span(3, 0xc1, None, "claude_code.llm_request", 1735689600, 1, {**C, **sonnet, "input_tokens": 5}),
    # sem session.id: não é de conversa nenhuma
    span(4, 0xe1, None, "claude_code.llm_request", D1, 1, {**sonnet, "input_tokens": 7, "request_id": "req-e1"}),
  ]),
  rs(codex, [
    span(5, 0xb1, None, "session_task.turn", D1 + 100, 10,
         {**B, "model": "gpt-5-codex", "codex.turn.token_usage.non_cached_input_tokens": 1_000_000,
          "codex.turn.token_usage.output_tokens": 100_000, "codex.turn.token_usage.cached_input_tokens": 2_000_000}),
  ]),
  rs(mac_claude, [
    span(6, 0xd1, None, "claude_code.llm_request", D1 - 2 * 86400, 1, {**D, **sonnet, "input_tokens": 10, "request_id": "req-d1"}),
    span(7, 0xd2, None, "claude_code.llm_request", D1 + 50, 1, {**D, **sonnet, "input_tokens": 20, "request_id": "req-d2"}),
  ]),
]}
json.dump(traces, open(f"{tmp}/traces.json", "w"))
def log(t, sev, body, attrs, name=None):
    r = {"timeUnixNano": str(int(t * 1e9)), "severityNumber": sev, "body": {"stringValue": body}, "attributes": kv(attrs)}
    if name: r["eventName"] = name
    return r
logs = {"resourceLogs": [
  rl(claude, [
    log(D1 + 8, 17, "falhou <b>feio</b>", A, "claude_code.api_error"),
    log(D1 + 0.5, 9, "claude_code.user_prompt", {**A, "prompt": "<script>alert('log')</script> & cia"}, "claude_code.user_prompt"),
    # o custo real do Claude chega no log api_request de mesmo request_id (#157), não no span
    api_request(D1 + 3, "req-a2", 0.01, {**A, **sonnet}),
  ]),
  rl(claude, [api_request(D1 + 1, "req-e1", 9.0, sonnet)]),
  rl(mac_claude, [api_request(D1 - 2 * 86400 + 1, "req-d1", 0.5, {**D, **sonnet}),
                  api_request(D1 + 51, "req-d2", 0.25, {**D, **sonnet})]),
  rl(codex, [log(D1 + 100 + i / 1000, 9, f"linha {i:03d}", B) for i in range(205)]),
]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
PY
studio_prices "$TMP/prices.toml"
WIN='from=2025-09-27T00:00:00Z&to=2025-09-29'

studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$TMP/prices.toml" || { echo "FAIL agent-studio não subiu"; cat "$TMP/s/stderr"; exit 1; }
check "ingestão: traces = 200"                         test "$(post traces "$TMP/traces.json")" = 200
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200
B=(-H "Authorization: Bearer $STUDIO_TOKEN")
HX=(-H "HX-Request: true")

# ---------------------------------------------------------------- 1. login: token -> cookie
check "página sem cookie nem Bearer: 303"              test "$(code "$STUDIO_URL/conversas")" = 303
check "  … para o /login, com a volta"                 test "$(hdr location "$STUDIO_URL/conversas")" = "/login?next=%2Fconversas"
check "  … a volta guarda a query"                     test "$(hdr location "$STUDIO_URL/conversa?id=conv-a")" = "/login?next=%2Fconversa%3Fid%3Dconv-a"
check "detalhe, logs e span sem login: 303"            test "$(code "$STUDIO_URL/conversa?id=conv-a")$(code "$STUDIO_URL/conversa/logs?id=conv-a")$(code "$STUDIO_URL/conversa/span?trace=1&span=2")" = 303303303
check "htmx sem login: 401 com HX-Redirect"            test "$(code "${HX[@]}" "$STUDIO_URL/conversas")$(hdr hx-redirect "${HX[@]}" "$STUDIO_URL/conversas")" = "401/login?next=%2Fconversas"
check "API sem cookie nem Bearer: 401"                 test "$(code "$STUDIO_URL/v1/usage")$(code "$STUDIO_URL/v1/alerts")" = 401401
check "/ leva às conversas"                            test "$(code "$STUDIO_URL/")$(hdr location "$STUDIO_URL/")" = "303/conversas"
LOGIN="$(curl -s "$STUDIO_URL/login")"
check "GET /login: formulário do token"                grep -q 'name="token" type="password"' <<<"$LOGIN"
check "GET /login: sem o menu de quem entrou"          bash -c '! grep -q "/logout" <<<"$1"' _ "$LOGIN"

login() { curl -s -D "$TMP/h" -o "$TMP/body" -w '%{http_code}' -X POST "$@" "$STUDIO_URL/login"; }
check "token errado: 401"                              test "$(login --data-urlencode "token=${STUDIO_TOKEN}x")" = 401
check "  … sem cookie"                                 bash -c '! grep -qi "^set-cookie:" "$1"' _ "$TMP/h"
check "  … e a página avisa"                           grep -q 'Token errado' "$TMP/body"
check "token vazio: 401"                               test "$(login --data-urlencode "token=")" = 401
check "sem o campo token: 401"                         test "$(login --data-urlencode "next=/conversas")" = 401
check "corpo acima de 4 KB: 413"                       test "$(login --data-urlencode "token=$(head -c 5000 /dev/zero | tr '\0' x)")" = 413
check "token certo: 303"                               test "$(login --data-urlencode "token=$STUDIO_TOKEN" --data-urlencode "next=/conversa?id=conv-a")" = 303
SETC="$(tr -d '\r' < "$TMP/h" | grep -i '^set-cookie:')"
check "  … volta para onde ia"                         grep -qi '^location: /conversa?id=conv-a$' <(tr -d '\r' < "$TMP/h")
check "  … cookie HttpOnly"                            grep -qi '; *HttpOnly' <<<"$SETC"
check "  … cookie Secure"                              grep -qi '; *Secure' <<<"$SETC"
check "  … cookie SameSite=Lax"                        grep -qi '; *SameSite=lax' <<<"$SETC"
check "  … cookie Path=/ e com prazo"                  bash -c 'grep -qi "; *Path=/\(;\|$\)" <<<"$1" && grep -qi "; *Max-Age=[1-9]" <<<"$1"' _ "$SETC"
check "  … o cookie não leva o token"                  bash -c '! grep -qF "$2" <<<"$1"' _ "$SETC" "$STUDIO_TOKEN"
COOKIE="$(sed -E 's/^[^:]*: *([^;]*).*/\1/' <<<"$SETC")"
C=(-H "Cookie: $COOKIE")
check "com o cookie: página 200"                       test "$(code "${C[@]}" "$STUDIO_URL/conversas")" = 200
check "com o cookie: API de leitura 200"               test "$(code "${C[@]}" "$STUDIO_URL/v1/usage")$(code "${C[@]}" "$STUDIO_URL/v1/alerts")" = 200200
check "com Bearer: página 200"                         test "$(code "${B[@]}" "$STUDIO_URL/conversas")" = 200
check "com Bearer: a API continua 200"                 test "$(code "${B[@]}" "$STUDIO_URL/v1/usage")$(code "${B[@]}" "$STUDIO_URL/v1/alerts")" = 200200
check "cookie forjado: 303"                            test "$(code -H "Cookie: ${COOKIE}0" "$STUDIO_URL/conversas")" = 303
check "o token cru como cookie: 303"                   test "$(code -H "Cookie: ${COOKIE%%=*}=$STUDIO_TOKEN" "$STUDIO_URL/conversas")" = 303
check "cookie forjado na API: 401"                     test "$(code -H "Cookie: ${COOKIE}0" "$STUDIO_URL/v1/usage")" = 401
check "ingestão só com o cookie: 401 (só Bearer)"      test "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${C[@]}" -H 'Content-Type: application/json' --data-binary "@$TMP/logs.json" "$STUDIO_URL/v1/logs")" = 401
check "já entrou: /login leva às conversas"            test "$(hdr location "${C[@]}" "$STUDIO_URL/login")" = "/conversas"
for n in 'https://evil.example/' '//evil.example/x' '/\evil.example' 'conversas'; do
  login --data-urlencode "token=$STUDIO_TOKEN" --data-urlencode "next=$n" >/dev/null
  check "next de fora ($n): volta às conversas"        grep -qi '^location: /conversas$' <(tr -d '\r' < "$TMP/h")
done
check "next de fora no GET /login: descartado"         grep -q 'name="next" value="/conversas"' <(curl -s "$STUDIO_URL/login?next=https://evil.example/")
SAIR="$(curl -s -o /dev/null -D - -X POST "${C[@]}" "$STUDIO_URL/logout" | tr -d '\r')"
check "sair: 303 para o /login"                        bash -c 'grep -q "^HTTP/[0-9.]* 303" <<<"$1" && grep -qi "^location: /login$" <<<"$1"' _ "$SAIR"
check "sair: apaga o cookie (vazio, Max-Age=0)"        grep -qiE "^set-cookie: ${COOKIE%%=*}=(\"\")?;.*Max-Age=0" <<<"$SAIR"
check "sair: o cookie apagado mantém as flags"         bash -c 'c="$(grep -i "^set-cookie:" <<<"$1")"; grep -qi "HttpOnly" <<<"$c" && grep -qi "Secure" <<<"$c" && grep -qi "SameSite=lax" <<<"$c"' _ "$SAIR"
check "GET /logout: 405"                               test "$(code "${C[@]}" "$STUDIO_URL/logout")" = 405

# ---------------------------------------------------------------- 2. sem CDN e sem build: tudo servido daqui
check "htmx servido pelo agent-studio (sem login)"     test "$(code "$STUDIO_URL/static/htmx.min.js")" = 200
# htmx 2.0.11 (npm htmx.org, 0BSD): o arquivo do repo é o que o servidor entrega
HTMX_SHA=d6fdc75f204e6bdefa99b69bf1e6d4ac69b8a364f77929f45c13476b4000f717
check "htmx: é o arquivo fixado (sha256)"              test "$(curl -s "$STUDIO_URL/static/htmx.min.js" | sha256sum | cut -d' ' -f1)" = "$HTMX_SHA"
check "CSS servido pelo agent-studio"                  test "$(code "$STUDIO_URL/static/studio.css")" = 200
check "fora do /static: nada de arquivo do pacote"     test "$(code "$STUDIO_URL/static/../web.py")$(code "$STUDIO_URL/static/%2e%2e/web.py")" = 404404
curl -s "${C[@]}" "$STUDIO_URL/conversas?$WIN" > "$TMP/list.html"
curl -s "${C[@]}" "$STUDIO_URL/conversa?id=conv-a" > "$TMP/a.html"
check "páginas: nenhum script, estilo ou link de fora" bash -c '! grep -hoiE "(src|href|action|hx-get)=\"[^\"]*\"" "$@" | grep -qE "=\"([a-z]+:)?//"' _ "$TMP/list.html" "$TMP/a.html" <(echo "$LOGIN")
check "páginas: sem script nem estilo inline"          bash -c '! grep -hiE "<script(>| [^>]*>)[^<]|<style|[ \"]style=|[ \"]on[a-z]+=\"" "$@"' _ "$TMP/list.html" "$TMP/a.html" <(echo "$LOGIN")
check "páginas: script só do /static"                  test "$(grep -ho '<script[^>]*>' "$TMP/list.html" "$TMP/a.html" | sort -u)" = '<script src="/static/htmx.min.js" defer>'
CSP="$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/conversa?id=conv-a")"
check "CSP: script e estilo só deste servidor"         bash -c 'grep -q "default-src .none." <<<"$1" && grep -q "script-src .self.;" <<<"$1" && grep -q "style-src .self.;" <<<"$1"' _ "$CSP"
check "páginas não vão para cache"                     test "$(hdr cache-control "${C[@]}" "$STUDIO_URL/conversas")" = no-store
check "sem build de front-end no repo"                 bash -c '! ls "$1"/package.json "$1"/../package.json "$1"/node_modules 2>/dev/null | grep -q .' _ "$PKG"

# ---------------------------------------------------------------- 3. lista de conversas
L="$(data < "$TMP/list.html" | jq -c '[.[] | select(.conversa)]')"
row() { jq -c --arg id "$1" '.[] | select(.conversa == $id)' <<<"$L"; }
check "lista: as 3 conversas da janela, da mais recente para a mais antiga (pelo início)" \
  jqe 'map(.conversa) == ["conv-b", "conv-a", "conv d/1&x=é"]' <<<"$L"
check "lista: hora do fato (janeiro fora) e span sem conversa fora" jqe 'all(.conversa != "conv-c") and length == 3' <<<"$L"
RA="$(row conv-a)"
check "conv-a: host e agente"                          jqe '.host == "oute-server" and .agent == "claude"' <<<"$RA"
check "conv-a: início e duração (31 s)"                jqe '.["start-ns"] == "1759000000000000000" and .["duration-ns"] == "31000000000"' <<<"$RA"
check "conv-a: 3 chamadas (tool e interação não contam)" jqe '.calls == "3"' <<<"$RA"
check "conv-a: tokens só das chamadas"                 jqe '.input == "1000600" and .output == "50" and .["cache-read"] == "1000" and .["cache-creation"] == "10"' <<<"$RA"
check "conv-a: custo real 0,01 (o da tool não soma)"   jqe "$(usd '.["real-usd"]') == 10000" <<<"$RA"
check "conv-a: estimado 3,00, separado do real"        jqe "$(usd '.["estimated-usd"]') == 3000000" <<<"$RA"
check "conv-a: estimado marcado na tela"               jqe '.text | test("US\\$ 0,0100 ≈ US\\$ 3,0000 est\\. 1 sem preço")' <<<"$RA"
check "conv-a: chamada sem preço fora das somas"       jqe '.["unpriced-calls"] == "1"' <<<"$RA"
check "conv-a: erros (1 span + 1 log)"                 jqe '.errors == "2"' <<<"$RA"
RB="$(row conv-b)"
check "conv-b (Codex): só estimado (2,50), sem real"   jqe ".[\"real-usd\"] == \"\" and $(usd '.["estimated-usd"]') == 2500000 and .host == \"oute-mac\" and .agent == \"codex\"" <<<"$RB"
check "conv-b: tela não mostra custo real"             jqe '.text | test("≈ US\\$ 2,5000 est\\.") and (test("US\\$ 0,") | not)' <<<"$RB"
RD="$(row 'conv d/1&x=é')"
check "conversa que começou antes da janela: números da conversa inteira" jqe ".calls == \"2\" and $(usd '.["real-usd"]') == 750000" <<<"$RD"
check "lista: link do detalhe com o id codificado"     grep -qF 'href="/conversa?id=conv%20d/1%26x%3D%C3%A9"' "$TMP/list.html"
ids() { curl -s "${C[@]}" "$STUDIO_URL/conversas?$WIN&$1" | data | jq -c '[.[] | select(.conversa) | .conversa]'; }
check "filtro por host"                                test "$(ids host=oute-mac)" = '["conv-b","conv d/1&x=é"]'
check "filtro por agente"                              test "$(ids agent=codex)" = '["conv-b"]'
check "filtro por host e agente"                       test "$(ids 'host=oute-mac&agent=claude')" = '["conv d/1&x=é"]'
check "filtro sem resultado: lista vazia, com aviso"   grep -q 'Nenhuma conversa nessa janela' <(curl -s "${C[@]}" "$STUDIO_URL/conversas?$WIN&host=oute-server&agent=codex")
check "filtros oferecem os hosts e agentes da janela"  bash -c 'grep -q "<option value=\"oute-mac\"" "$1" && grep -q "<option value=\"oute-server\"" "$1" && grep -q "<option value=\"codex\"" "$1"' _ "$TMP/list.html"
check "janela padrão (24 h): nada (hora do fato, não a de chegada)" grep -q 'Nenhuma conversa nessa janela' <(curl -s "${C[@]}" "$STUDIO_URL/conversas")
check "janela só com o começo da conversa longa"       test "$(curl -s "${C[@]}" "$STUDIO_URL/conversas?from=2025-09-25&to=2025-09-26" | data | jq -c '[.[] | select(.conversa) | .conversa]')" = '["conv d/1&x=é"]'
check "janela inválida: 400"                           test "$(code "${C[@]}" "$STUDIO_URL/conversas?from=ontem&to=2025-09-29")" = 400
check "from sem to: 400"                               test "$(code "${C[@]}" "$STUDIO_URL/conversas?from=2025-09-27")" = 400
check "hours inválido: 400, com a página de erro"      grep -q 'hours inválido' <(curl -s "${C[@]}" "$STUDIO_URL/conversas?hours=x")
check "lista com htmx (filtro troca só o conteúdo)"    grep -q 'hx-get="/conversas"' "$TMP/list.html"

# ---------------------------------------------------------------- 4. detalhe: árvore de spans e logs
check "detalhe: 200"                                   test "$(code "${C[@]}" "$STUDIO_URL/conversa?id=conv-a")" = 200
check "conversa que não existe: 404"                   test "$(code "${C[@]}" "$STUDIO_URL/conversa?id=nao-existe")" = 404
check "detalhe sem id: 400"                            test "$(code "${C[@]}" "$STUDIO_URL/conversa")" = 400
DA="$(data < "$TMP/a.html")"
S="$(jq -c '[.[] | select(.span)]' <<<"$DA")"
sp() { jq -c --arg id "00000000000000$1" '.[] | select(.span == $id)' <<<"$S"; }
check "árvore: pai antes dos filhos, irmãos pela hora do fato" \
  jqe 'map(.span[-2:]) == ["a1", "a2", "a3", "a4", "a5", "a6", "a7"]' <<<"$S"
check "árvore: níveis (raiz 0, filho 1, neto 2)"       jqe 'map(.depth) == ["0", "1", "1", "2", "1", "0", "0"]' <<<"$S"
check "árvore: cada filho aponta o pai"                jqe '.parent == "00000000000000a3" and .name == "claude_code.tool.execution"' <<<"$(sp a4)"
check "árvore: span com pai ausente vira raiz, marcado" jqe '.orphan == "1" and .depth == "0" and (.text | test("pai ausente"))' <<<"$(sp a6)"
check "árvore: só o órfão é marcado"                   jqe '[.[] | select(.orphan == "1")] | length == 1' <<<"$S"
check "span: nome, duração e modelo"                   jqe '.text | test("claude_code.llm_request \\+1,0 s 2,0 s claude-sonnet-5 100 50 1\\.000 / 10 US\\$ 0,0100")' <<<"$(sp a2)"
check "span: custo real"                               jqe ".[\"cost-kind\"] == \"real\" and $(usd .cost) == 10000" <<<"$(sp a2)"
check "span: custo estimado, marcado"                  jqe ".[\"cost-kind\"] == \"estimated\" and $(usd .cost) == 3000000 and (.text | test(\"≈ US\\\\$ 3,0000 est\\\\.\"))" <<<"$(sp a5)"
check "span: modelo sem preço nunca vira zero"         jqe '.["cost-kind"] == "unpriced" and .cost == "" and (.text | test("sem preço"))' <<<"$(sp a6)"
check "span que não é chamada: sem tokens nem custo"   jqe '.["cost-kind"] == "" and .cost == "" and (.text | test("999|50,0") | not)' <<<"$(sp a3)"
check "span: status de erro"                           jqe '.status == "erro" and (.text | test("erro$"))' <<<"$(sp a4)"
check "span: os outros sem erro"                       jqe '[.[] | select(.status == "erro")] | length == 1' <<<"$S"
R="$(jq -c '.[] | select(has("resumo"))' <<<"$DA")"
check "resumo: as somas do #203"                       jqe ".calls == \"3\" and $(usd '.["real-usd"]') == 10000 and $(usd '.["estimated-usd"]') == 3000000 and .[\"unpriced-calls\"] == \"1\"" <<<"$R"
check "resumo: host, instância, agente e sessão"       jqe '.text | test("oute-server \\(oute-agent\\).*claude · claude-code.*oute-agent-206")' <<<"$R"
check "resumo = soma das linhas da árvore (mesma regra)" jqe --argjson r "$R" \
  '([.[] | select(.["cost-kind"] == "real") | .cost | tonumber] | add) == ($r["real-usd"] | tonumber)
   and ([.[] | select(.["cost-kind"] == "estimated") | .cost | tonumber] | add) == ($r["estimated-usd"] | tonumber)
   and ([.[] | select(.["cost-kind"] == "unpriced")] | length) == ($r["unpriced-calls"] | tonumber)' <<<"$S"
G="$(jq -c '[.[] | select(.log)]' <<<"$DA")"
check "logs: em ordem da hora do fato"                 jqe 'map(.log) == ["1759000000500000000", "1759000003000000000", "1759000008000000000"]' <<<"$G"
check "logs: o conteúdo aparece (corpo e atributos)"   jqe '.[0].text | test("claude_code.user_prompt") and test("alert\\(.log.\\)</script> & cia")' <<<"$G"
check "logs: nível e evento"                           jqe '.[2].text | test("17 claude_code.api_error falhou <b>feio</b>")' <<<"$G"
check "conteúdo escapado: nenhum HTML do dado vira tag" bash -c '! grep -qE "<script>alert|<b>feio" "$1" && grep -q "&lt;script&gt;alert" "$1" && grep -q "&lt;b&gt;feio" "$1"' _ "$TMP/a.html"
SPAN_URL="$STUDIO_URL/conversa/span?trace=00000000000000000000000000000001&span=00000000000000a"
F="$(curl -s "${C[@]}" "${HX[@]}" "${SPAN_URL}3")"
check "conteúdo do span (htmx): trecho, não página"    bash -c '! grep -qi "<html" <<<"$1" && grep -q "data-span-detalhe=\"00000000000000a3\"" <<<"$1"' _ "$F"
check "conteúdo do span: atributos, resource e status" bash -c 'grep -q "tool_name" <<<"$1" && grep -q "host.name" <<<"$1" && grep -q "00000000000000a1" <<<"$1"' _ "$F"
check "conteúdo do span: mensagem do status de erro"   grep -q 'comando falhou' <(curl -s "${C[@]}" "${HX[@]}" "${SPAN_URL}4")
F1="$(curl -s "${C[@]}" "${HX[@]}" "${SPAN_URL}1")"
check "conteúdo do span: escapado"                     bash -c '! grep -q "<script>alert" <<<"$1" && grep -q "&lt;script&gt;alert" <<<"$1"' _ "$F1"
check "conteúdo do span sem htmx: página inteira, com a volta" bash -c 'grep -qi "<html" <<<"$1" && grep -q "href=\"/conversa?id=conv-a\"" <<<"$1"' _ "$(curl -s "${C[@]}" "${SPAN_URL}3")"
check "span que não existe: 404"                       test "$(code "${C[@]}" "${SPAN_URL}f")" = 404
check "span sem trace ou sem span: 400"                test "$(code "${C[@]}" "$STUDIO_URL/conversa/span?trace=1")$(code "${C[@]}" "$STUDIO_URL/conversa/span?span=1")" = 400400
check "linha da árvore abre o conteúdo pelo htmx"      grep -q 'hx-get="/conversa/span?trace=00000000000000000000000000000001&amp;span=00000000000000a3" hx-target="next .conteudo"' "$TMP/a.html"

# conv-b: 205 logs = página de 200 + "mais logs"
curl -s "${C[@]}" "$STUDIO_URL/conversa?id=conv-b" > "$TMP/b.html"
GB="$(data < "$TMP/b.html" | jq -c '[.[] | select(.log)]')"
check "logs: primeira página com 200, em ordem"        jqe 'length == 200 and (.[0].text | test("linha 000")) and (.[199].text | test("linha 199"))' <<<"$GB"
check "logs: link para o resto"                        grep -q 'hx-get="/conversa/logs?id=conv-b&amp;offset=200"' "$TMP/b.html"
check "conv-b: total de logs no título"                grep -q 'Logs (205)' "$TMP/b.html"
M="$(curl -s "${C[@]}" "${HX[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=200")"
check "mais logs (htmx): só as 5 linhas que faltavam"  bash -c '! grep -qi "<html\|<table" <<<"$1" && test "$(grep -c "<tr data-log" <<<"$1")" = 5 && grep -q "linha 204" <<<"$1"' _ "$M"
check "mais logs: última página sem link"              bash -c '! grep -q "mais logs" <<<"$1"' _ "$M"
check "mais logs sem htmx: página inteira"             bash -c 'grep -qi "<html" <<<"$1" && test "$(grep -c "<tr data-log" <<<"$1")" = 5' _ "$(curl -s "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=200")"
check "mais logs além do fim: aviso, sem erro"         grep -q 'Sem mais logs' <(curl -s "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=900")
check "mais logs: offset inválido ou sem id = 400"     test "$(code "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=x")$(code "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=-1")$(code "${C[@]}" "$STUDIO_URL/conversa/logs?offset=0")" = 400400400
check "id com espaço, /, & e acento abre o detalhe"    grep -q 'data-calls="2"' <(curl -s "${C[@]}" "$STUDIO_URL/conversa?id=conv%20d/1%26x%3D%C3%A9")
check "conversa só com spans: aviso no lugar dos logs" grep -q 'Esta conversa não tem logs' <(curl -s "${C[@]}" "$STUDIO_URL/conversa?id=conv-c")
check "a tela não derrubou o servidor (sem 500 no stderr)" bash -c '! grep -q "respondi 500\|Traceback" "$1"' _ "$TMP/s/stderr"
studio_stop

# ---------------------------------------------------------------- 5. lógica direto em Python
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - "$TMP/s/db.duckdb" > "$TMP/py.out" 2>&1 <<'PY'
import sys
import duckdb
from agent_studio import auth, conversations, cost, web
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, Broken, get

# árvore: ciclo de pais (dado ruim) não some nem trava
def s(sid, parent, trace="t"):
    return {"trace_id": trace, "span_id": sid, "parent_span_id": parent}
t = conversations.tree([s("x", "y"), s("y", "x"), s("r", None), s("k", "r"), s("self", "self")])
got = [(n["span_id"], n["depth"], n["orphan"]) for n in t]
check("árvore: o que não é ciclo segue normal; span pai de si mesmo vira raiz órfã",
      got[:3] == [("r", 0, False), ("k", 1, False), ("self", 0, True)])
check("árvore: ciclo de pais entra inteiro, a partir de uma raiz órfã", got[3:] == [("x", 0, True), ("y", 1, False)])
check("árvore: o mesmo span_id em outro trace não é pai",
      [(n["span_id"], n["depth"], n["orphan"]) for n in conversations.tree([s("p", None, "t1"), s("c", "p", "t2")])]
      == [("p", 0, False), ("c", 0, True)])
deep = [s("0", None)] + [s(str(i), str(i - 1)) for i in range(1, 3000)]
check("árvore: 3000 níveis sem estourar a pilha", conversations.tree(deep)[-1]["depth"] == 2999)

# lista: limite e total, sobre o DuckDB de exemplo
con = duckdb.connect(sys.argv[1], read_only=True)
D1 = 1759000000 * 10**9
r = conversations.listing(con, D1 - 86400 * 10**9, D1 + 86400 * 10**9, cost.PriceTable(), limit=1)
check("lista: limite corta, total conta tudo", r["total"] == 3 and [c["id"] for c in r["conversations"]] == ["conv-b"])
check("lista: sem tabela de preços, sem estimativa (nunca zero)",
      r["conversations"][0]["usage"]["cost"] == {"real_usd": None, "estimated_usd": None, "real_calls": 0,
                                                 "estimated_calls": 0, "unpriced_calls": 1})
d = conversations.detail(con, "conv-a", cost.PriceTable(), span_limit=2)
check("detalhe: limite de spans avisa o corte", d["spans_truncated"] and len(d["spans"]) == 2)
check("detalhe: filho cujo pai ficou fora do limite não some", conversations.detail(con, "conv-a", cost.PriceTable())["spans_truncated"] is False)

# custo de uma chamada: a mesma regra das somas
p = cost.ModelPrice(3.0, 15.0, 3.0, 3.0)
check("call_cost: real, estimado e sem preço", cost.call_cost(0.5, 10, 0, 0, 0, p) == ("real", 0.5)
      and cost.call_cost(None, 1_000_000, 0, 0, 0, p) == ("estimated", 3.0)
      and cost.call_cost(None, 1_000_000, 0, 0, 0, None) == ("unpriced", None)
      and cost.call_cost(0.0, 1_000_000, 0, 0, 0, p) == ("real", 0.0))

# auth: o cookie sai do token, sem ser o token
a, b = auth.Auth("token-um"), auth.Auth("token-dois")
check("cookie muda com o token (trocar o token invalida os cookies)", a.cookie_value != b.cookie_value and "token-um" not in a.cookie_value)
try:
    auth.Auth(""); check("token vazio recusado", False)
except ValueError:
    check("token vazio recusado", True)
check("safe_next: só caminho deste servidor", [web.safe_next(x) for x in
      ("/conversa?id=a", "", None, "http://x/", "//x", "/\\x", "/a\nb", "x")]
      == ["/conversa?id=a"] + ["/conversas"] * 7)

# leitura que falha: página 500, sem a causa
app = create_app(Broken(), TOKEN)
for path, query in (("/conversas", ""), ("/conversa", "id=a"), ("/conversa/logs", "id=a"), ("/conversa/span", "trace=a&span=b")):
    status, body = get(app, path, query)
    check(f"leitura que falha em {path}: 500, sem a causa na página", status == 500 and "segredo-da-falha" not in body and "A consulta falhou" in body)
PY
cat "$TMP/py.out" | grep -v '^Traceback\|^  \|^RuntimeError\|^$\|tela: .* falhou' || true
check_py "$TMP/py.out"
check "lógica em Python: os 16 casos rodaram"          test "$((n_ok + n_fail))" = 16

# ---------------------------------------------------------------- 6. imagem e compose
check "templates e htmx vão na imagem (dentro do pacote copiado)" bash -c 'test -f "$1/templates/base.html" && test -f "$1/static/htmx.min.js" && grep -q "COPY docker/agent-studio/agent_studio /opt/agent-studio/app/agent_studio" "$2/docker/Dockerfile"' _ "$PKG" "$ROOT"
check "htmx do repo = o fixado"                        test "$(sha256sum "$PKG/static/htmx.min.js" | cut -d' ' -f1)" = "$HTMX_SHA"
check "jinja2 fixado por hash no requirements.txt"     grep -q '^jinja2==' "$ROOT/docker/agent-studio/requirements.txt"
check "compose: agent-studio só em 127.0.0.1"          bash -c 'grep -A40 "^  agent-studio:" "$1" | grep -q "\"127.0.0.1:\${OUTE_AGENT_STUDIO_PORT:-8430}:8430\""' _ "$ROOT/docker/compose.yaml"

check_end
