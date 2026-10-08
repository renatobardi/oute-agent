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
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init
PKG="$ROOT/docker/agent-studio/agent_studio"

# Regra (#588): <svg só na macro (_macros.html) e nos _graficos*.html; nenhuma tela leva <svg colado, com ou sem Jinja ao redor.
# Falha também se a pasta não existe ou não tem nenhum .html (teste vazio não passa).
svg_templates_valid() {
  local templates="$1" template lidos=0
  [[ -d "$templates" ]] || return 1
  for template in "$templates"/*.html; do
    [[ -f "$template" ]] || continue
    lidos=$((lidos + 1))
    case "${template##*/}" in
      _macros.html | _graficos*.html) continue ;;
      *) grep -q '<svg' "$template" && return 1 ;;
    esac
  done
  [[ "$lidos" -gt 0 ]] || return 1
  return 0
}

svg_templates_rejects_screen() {
  local templates="$1"
  if svg_templates_valid "$templates"; then
    return 1
  fi
  return 0
}


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
check "/ sem login: 303 para o /login, com a volta"    test "$(code "$STUDIO_URL/")$(hdr location "$STUDIO_URL/")" = "303/login?next=%2F"
check "htmx sem login em /: 401 com HX-Redirect"       test "$(code "${HX[@]}" "$STUDIO_URL/")$(hdr hx-redirect "${HX[@]}" "$STUDIO_URL/")" = "401/login?next=%2F"
LOGIN="$(studio_page "$STUDIO_URL/login")"
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
check "com o cookie: / é o Dashboard (200, sem redirecionar)" bash -c 'test "$(curl -s -o "$2" -w "%{http_code}" "${@:3}" "$1/")" = 200 && grep -q "<h1>Dashboard</h1>" "$2"' _ "$STUDIO_URL" "$TMP/dash.html" "${C[@]}"
check "já entrou: /login leva ao Dashboard (#523)"     test "$(hdr location "${C[@]}" "$STUDIO_URL/login")" = "/"
check "sem next, o login leva a / (#523)"              bash -c 'curl -s -o /dev/null -D "$2" -X POST --data-urlencode "token=$3" "$1/login" && tr -d "\r" < "$2" | grep -qi "^location: /$"' _ "$STUDIO_URL" "$TMP/h2" "$STUDIO_TOKEN"
for n in 'https://evil.example/' '//evil.example/x' '/\evil.example' 'conversas'; do
  login --data-urlencode "token=$STUDIO_TOKEN" --data-urlencode "next=$n" >/dev/null
  check "next de fora ($n): volta ao Dashboard (#523)" grep -qi '^location: /$' <(tr -d '\r' < "$TMP/h")
done
check "next de fora no GET /login: descartado"         grep -q 'name="next" value="/"' <(studio_page "$STUDIO_URL/login?next=https://evil.example/")
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
studio_page "${C[@]}" "$STUDIO_URL/conversas?$WIN" > "$TMP/list.html"
studio_page "${C[@]}" "$STUDIO_URL/conversa?id=conv-a" > "$TMP/a.html"
check "páginas: nenhum script, estilo ou link de fora" bash -c '! grep -hoiE "(src|href|action|hx-get)=\"[^\"]*\"" "$@" | grep -qE "=\"([a-z]+:)?//"' _ "$TMP/list.html" "$TMP/a.html" <(echo "$LOGIN")
check "páginas: sem script nem estilo inline"          bash -c '! grep -hiE "<script(>| [^>]*>)[^<]|<style|[ \"]style=|[ \"]on[a-z]+=\"" "$@"' _ "$TMP/list.html" "$TMP/a.html" <(echo "$LOGIN")
check "páginas: script só do /static"                  test "$(grep -ho '<script[^>]*>' "$TMP/list.html" "$TMP/a.html" | sort -u)" = $'<script src="/static/htmx.min.js" defer>\n<script src="/static/loading.js" defer>'
CSP="$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/conversa?id=conv-a")"
check "CSP: script e estilo só deste servidor"         bash -c 'grep -q "default-src .none." <<<"$1" && grep -q "script-src .self.;" <<<"$1" && grep -q "style-src .self.;" <<<"$1"' _ "$CSP"
check "CSP: font-src só deste servidor, e o resto da política igual" bash -c 'grep -q "img-src .self.; font-src .self.; connect-src .self.; form-action .self.; base-uri .none.; frame-ancestors .none." <<<"$1"' _ "$CSP"
FONT_SHA=$(sha256sum "$PKG/static/fonts/InterVariable.woff2" | cut -d' ' -f1)
check "fonte Inter Variable servida sem login (woff2)"  test "$(code "$STUDIO_URL/static/fonts/InterVariable.woff2")" = 200
check "fonte: o servidor entrega o arquivo do repo"     test "$(curl -s "$STUDIO_URL/static/fonts/InterVariable.woff2" | sha256sum | cut -d' ' -f1)" = "$FONT_SHA"
check "fonte: é woff2 de verdade (magic wOF2)"          test "$(head -c4 "$PKG/static/fonts/InterVariable.woff2")" = wOF2
curl -s "$STUDIO_URL/static/studio.css" > "$TMP/studio.css"
check "CSS: @font-face Inter Variable 100-900 com local('Inter') e a url de /static" bash -c 'grep -q "font-family: .Inter Variable.;" "$1" && grep -q "font-weight: 100 900;" "$1" && grep -q "src: local(.Inter.), url(./static/fonts/InterVariable.woff2.) format(.woff2.);" "$1"' _ "$TMP/studio.css"
check "CSS: nenhum hex de cor nem variável antiga"      bash -c '! perl -0pe "s{/\*.*?\*/}{}gs" "$1" | grep -qE "#[0-9a-fA-F]{3,8}\b|--(fundo|painel|texto|fraco|linha|link|erro|est|real)\b"' _ "$TMP/studio.css"
check "CSS: tokens Kubo no claro e no escuro (OKLCH)"   bash -c 'for v in background foreground card muted muted-foreground border primary destructive gate gate-tint; do [ "$(grep -c -- "^ *--$v: oklch(" "$1")" = 2 ] || exit 1; done' _ "$TMP/studio.css"
check "CSS: dark por prefers-color-scheme"              grep -q "@media (prefers-color-scheme: dark)" "$TMP/studio.css"
check "CSS: âmbar (--gate) só em .decisoes, no Badge gate, no ponto de Gate da linha do tempo (#468) e no ícone do insight de Gate (#469)"             bash -c '[ "$(grep -c "var(--gate" "$1")" -ge 2 ] && ! perl -0pe "s{/\*.*?\*/}{}gs" "$1" | perl -0ne "while (/([^{}]+)\{([^{}]*)\}/g) { my (\$s, \$b) = (\$1, \$2); \$s =~ s/^\\s+|\\s+\$//g; print qq{\$s\n} if \$b =~ /var\(--gate/ }" | grep -vqE "^\s*(\.decisoes|\.badge\.gate|\.tempo \.ponto\.gate|\.insight-icone\.gate)\s*\$"' _ "$TMP/studio.css"
check "CSS: body Inter 14px, h1 20px/600/-0.025em, h2 16px/500, mono 12px" bash -c 'grep -q "font: 14px/1.5 var(--font-sans)" "$1" && grep -q "^h1 { font-size: 20px; font-weight: 600; letter-spacing: -0.025em;" "$1" && grep -q "^h2 { font-size: 16px; font-weight: 500;" "$1" && grep -q "font-family: var(--font-mono); font-size: 12px;" "$1"' _ "$TMP/studio.css"
check "CSS: .real sem cor; .est muted itálico"          bash -c '! grep -E "^\.real \{.*color" "$1" && grep -q "^\.est { color: var(--muted-foreground); font-style: italic; }" "$1"' _ "$TMP/studio.css"
check "CSS: .aviso.erro e Badge destrutivo com --destructive tingido; a linha não leva mais a borda do erro (#468)" bash -c 'grep -E "^\.aviso\.erro" "$1" | grep -q "color-mix(in oklch, var(--destructive)" && grep -E "^\.badge\.destrutivo" "$1" | grep -q "color-mix(in oklab, var(--destructive)" && ! grep -q "tr\.erro" "$1"' _ "$TMP/studio.css"
check "páginas não vão para cache"                     test "$(hdr cache-control "${C[@]}" "$STUDIO_URL/conversas")" = no-store
check "sem build de front-end no repo"                 bash -c '! ls "$1"/package.json "$1"/../package.json "$1"/node_modules 2>/dev/null | grep -q .' _ "$PKG"

# ---------------------------------------------------------------- 2b. casco: sidebar, header, sprite e Entrar (#467)
echo "$LOGIN" > "$TMP/login.html"
check "casco: o logo leva a / (#523)"                  grep -q '<a class="marca" href="/">' "$TMP/list.html"
check "casco: nome Agent Studio e a frase nova (#523)" bash -c 'grep -q "<strong>Agent Studio</strong><span>O painel de controle dos seus agentes de código.</span>" "$1" && ! grep -q "telemetria dos agentes" "$1"' _ "$TMP/list.html"
check "casco: <title> e login dizem Agent Studio (#523)" bash -c 'grep -q "<title>Conversas · Agent Studio</title>" "$1" && grep -q "<title>Entrar · Agent Studio</title>" "$2" && grep -q "<span>Agent Studio</span></div>" "$2"' _ "$TMP/list.html" "$TMP/login.html"
check "lista: sem o parágrafo, a janela e o fuso ficam junto do filtro (#523)" bash -c '! grep -q "Chamadas ao modelo entre\|Conversas com atividade entre" "$1" && grep -q "data-janela>[^<]* · [A-Z]" "$1"' _ "$TMP/list.html"
GLIFOS="layout-dashboard message-square layers chart-column receipt shield-check siren hand panel-left log-out moon sun chevron-right chevron-left chevron-down chevron-up info triangle-alert copy check x server terminal sparkles wrench workflow corner-down-right circle-dot repeat archive loader user shield-alert lock eye eye-off arrow-left arrow-right menu network database sakura activity timer tag circle-alert arrow-left-right trending-up trending-down minus chart-pie database-zap"
check "sprite /static/lucide.svg: 200 sem login, como svg" test "$(code "$STUDIO_URL/static/lucide.svg")$(hdr content-type "$STUDIO_URL/static/lucide.svg" | cut -d';' -f1)" = "200image/svg+xml"
curl -s "$STUDIO_URL/static/lucide.svg" > "$TMP/lucide.svg"
check "sprite: é o arquivo do repo"                    cmp -s "$TMP/lucide.svg" "$PKG/static/lucide.svg"
check "sprite: XML válido, um <symbol> por glifo, sem id repetido" python3 -c '
import sys, xml.etree.ElementTree as ET
ids = [e.get("id") for e in ET.parse(sys.argv[1]).iter() if e.tag.endswith("symbol")]
sys.exit(0 if sorted(ids) == sorted(set(ids)) and set(ids) == set(sys.argv[2].split()) else 1)' "$TMP/lucide.svg" "$GLIFOS"
check "sprite: sem script, estilo nem recurso de fora" bash -c '! sed "s/xmlns=\"[^\"]*\"//" "$1" | grep -qiE "<script|<style|style=|href=|xlink|https?:|[ \"]on[a-z]+="' _ "$TMP/lucide.svg"
studio_page "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b" > "$TMP/logs.html"
studio_page "${C[@]}" "$STUDIO_URL/conversa?id=nao-existe" > "$TMP/erro.html"
curl -s -X POST --data-urlencode "token=${STUDIO_TOKEN}x" "$STUDIO_URL/login" > "$TMP/login-erro.html"
check "páginas: todo ícone aponta para um símbolo do sprite" bash -c 'u="$(grep -ho "href=\"/static/lucide.svg#[^\"]*\"" "${@:2}" | sed "s/.*#//; s/\"//" | sort -u)"; [ -n "$u" ] && for g in $u; do grep -q "<symbol id=\"$g\" " "$1" || { echo "falta $g" >&2; exit 1; }; done' _ "$TMP/lucide.svg" "$TMP/list.html" "$TMP/a.html" "$TMP/logs.html" "$TMP/erro.html" "$TMP/login-erro.html" "$TMP/login.html"
check "templates: <svg só na macro ou em _graficos*.html" svg_templates_valid "$PKG/templates"
check "macro _macros.html: exatamente 2 SVGs (icon e logo)" bash -c '[ "$(grep -c "<svg" "$1")" = 2 ]' _ "$PKG/templates/_macros.html"
mkdir -p "$TMP/svg-regra" "$TMP/svg-vazia"
printf '%s\n' '<svg></svg>' > "$TMP/svg-regra/tela.html"
check "templates: a regra reprova <svg> colado numa tela" svg_templates_rejects_screen "$TMP/svg-regra"
check "templates: a regra reprova pasta sem .html"        svg_templates_rejects_screen "$TMP/svg-vazia"
check "templates: a regra reprova pasta que não existe"   svg_templates_rejects_screen "$TMP/svg-nao-existe"
# teste do teste (#588): um <svg estático na primeira linha de cada tela, mesmo com Jinja no resto do arquivo, reprova
for tela in "$PKG/templates"/*.html; do
  nome="${tela##*/}"
  case "$nome" in _macros.html | _graficos*.html) continue ;; *) : ;; esac
  rm -rf "${TMP:?}/svg-mut" && cp -r "$PKG/templates" "$TMP/svg-mut"
  { printf '%s\n' '<svg width="9"><circle r="1"/></svg>'; cat "$tela"; } > "$TMP/svg-mut/$nome"
  check "templates: a regra reprova <svg estático colado em $nome" svg_templates_rejects_screen "$TMP/svg-mut"
done
check "templates: nenhum style= nem <style"            bash -c '! grep -rnE "style=|<style" "$1/templates"' _ "$PKG"
check "macro icon(name, size=16): <use> do sprite, traço currentColor, escondido do leitor de tela" bash -c 'grep -q "macro icon(name, size=16" "$1" && grep -q "stroke=\"currentColor\"" "$1" && grep -q "aria-hidden=\"true\"><use href=\"/static/lucide.svg#{{ name }}\"/>" "$1"' _ "$PKG/templates/_macros.html"
check "páginas: o ícone sai do sprite com o tamanho pedido" bash -c 'grep -q "<svg class=\"icone\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" [^>]*><use href=\"/static/lucide.svg#layers\"/></svg>" "$1" && grep -q "<svg class=\"icone\" width=\"14\" height=\"14\" [^>]*><use href=\"/static/lucide.svg#chevron-right\"/>" "$1"' _ "$TMP/list.html"
# barra lateral
check "sidebar: <aside> com a marca, no 256 px do CSS" bash -c 'grep -q "<aside class=\"barra\" id=\"barra\"" "$1" && grep -q "^\.barra { flex: 0 0 256px; width: 256px;" "$2"' _ "$TMP/list.html" "$TMP/studio.css"
check "sidebar: Dashboard acima dos grupos, apontando para / (#469)" bash -c 'a="$(grep -n "<span>Dashboard</span>" "$1" | cut -d: -f1)"; g="$(grep -n "nav-rotulo\">Telemetria" "$1" | cut -d: -f1)"; grep -q "<a class=\"nav-item\" href=\"/\">.*<span>Dashboard</span>" "$1" && [ "$a" -lt "$g" ]' _ "$TMP/list.html"
check "sidebar: grupos Telemetria, Análise e Governança, nessa ordem" test "$(grep -o 'nav-rotulo">[^<]*' "$TMP/list.html" | cut -d'>' -f2 | paste -sd,)" = "Telemetria,Análise,Governança"
check "sidebar: itens Conversas, Sessões, Uso, Ferramentas, Preços, Planos, Pedidos, Rodadas, nessa ordem" test "$(grep -o 'class="nav-item" href="[^"]*"[^>]*><svg[^>]*><use href="[^"]*"/></svg><span>[^<]*' "$TMP/list.html" | sed -E 's/.*#([^"]*)"\/><\/svg><span>/\1=/' | paste -sd,)" = "layout-dashboard=Dashboard,message-square=Conversas,layers=Sessões,chart-column=Uso,wrench=Ferramentas,receipt=Preços,tag=Planos,shield-check=Pedidos,repeat=Rodadas"
check "sidebar: só o item da tela está ativo (aria-current)" test "$(grep -o 'class="nav-item" href="[^"]*" aria-current="page"' "$TMP/list.html")" = 'class="nav-item" href="/conversas" aria-current="page"'
check "sidebar: no detalhe da conversa o item Conversas segue ativo" grep -q 'class="nav-item" href="/conversas" aria-current="page"' "$TMP/a.html"
check "sidebar: rodapé com Renato Bardi e o Sair"      bash -c 'grep -q "<strong>Renato Bardi</strong>" "$1" && [ "$(grep -c "<form method=\"post\" action=\"/logout\">" "$1")" = 2 ]' _ "$TMP/list.html"
# cabeçalho e trilha
check "header: 72 px, botão de recolher (panel-left), divisor e trilha" bash -c 'grep -q "^\.cabecalho { height: 72px;" "$2" && grep -q "<header class=\"cabecalho\">" "$1" && grep -q "for=\"menu\" title=\"Mostrar ou esconder o menu\"" "$1" && grep -q "lucide.svg#panel-left" "$1" && grep -q "class=\"divisor so-desktop\"" "$1" && grep -q "<nav class=\"trilha\" aria-label=\"Trilha\">" "$1"' _ "$TMP/list.html" "$TMP/studio.css"
check "header: na lista a trilha é Telemetria › Conversas" bash -c 'grep -q "<span class=\"trilha-pai\">Telemetria</span>" "$1" && grep -q "<span class=\"trilha-atual\" aria-current=\"page\">Conversas</span>" "$1"' _ "$TMP/list.html"
check "header: no detalhe a trilha é Conversas › <id>, com link na primeira" bash -c 'grep -q "<a class=\"trilha-pai\" href=\"/conversas\">Conversas</a>" "$1" && grep -q "<span class=\"trilha-atual\" aria-current=\"page\">$2</span>" "$1"' _ "$TMP/a.html" "$(nome conv-a)"
check "header: à direita o selo do host e o Sair"      bash -c 'grep -q "class=\"selo\">.*oute-server</span>" "$1" && grep -q "class=\"botao\">.*Sair</button>" "$1"' _ "$TMP/list.html"
check "header: o menu (celular) abre pela barra, sem script" bash -c 'grep -q "<input type=\"checkbox\" id=\"menu\" class=\"menu-interruptor\"" "$1" && grep -q "for=\"menu\" title=\"Abrir o menu\"" "$1" && grep -q "menu-interruptor:checked ~ .app .barra" "$2"' _ "$TMP/list.html" "$TMP/studio.css"
check "celular: na lista há o menu e nenhum voltar"    bash -c 'grep -q "title=\"Abrir o menu\"" "$1" && ! grep -q "title=\"Voltar\"" "$1"' _ "$TMP/list.html"
check "celular: no detalhe o voltar (para a lista) toma o lugar do menu" bash -c 'grep -q "<a class=\"botao icone-botao so-celular\" href=\"/conversas\" title=\"Voltar\">" "$1" && ! grep -q "title=\"Abrir o menu\"" "$1"' _ "$TMP/a.html"
check "celular: CSS até 640 px, header 56 px e barra em folha" bash -c 'grep -q "@media (max-width: 640px)" "$1" && grep -q "^  \.cabecalho { height: 56px;" "$1" && grep -q "z-index: 20; inset: 0 auto 0 0; width: 300px" "$1"' _ "$TMP/studio.css"
check "casco só para quem entrou: o trecho do htmx não leva barra nem cabeçalho" bash -c '! grep -qE "class=\"(barra|cabecalho)\"" <<<"$1"' _ "$(studio_page "${C[@]}" -H 'HX-Request: true' "$STUDIO_URL/conversa/logs?id=conv-b")"
check "erro de quem entrou (404) leva o casco, com o #conteudo" bash -c 'grep -q "class=\"barra\"" "$1" && grep -q "<main id=\"conteudo\">" "$1"' _ "$TMP/erro.html"
check "logs do detalhe: casco com o voltar para a conversa" bash -c 'grep -q "href=\"/conversa?id=conv-b\" title=\"Voltar\"" "$1"' _ "$TMP/logs.html"
# tela Entrar
check "Entrar: duas colunas (painel e formulário), sem o casco" bash -c 'grep -q "<section class=\"entrar-painel\">" "$1" && grep -q "<main id=\"conteudo\" class=\"entrar-form\">" "$1" && ! grep -qE "class=\"(barra|cabecalho)\"|<aside|/logout" "$1"' _ "$TMP/login.html"
check "Entrar: painel com logo, frase e 3 pontos"      bash -c 'grep -q "lucide.svg#sakura" "$1" && grep -q "Telemetria e estado dos agentes do oute." "$1" && [ "$(grep -c "<li><svg" "$1")" = 6 ] && grep -q "Só leitura" "$1" && grep -q "Só na tailnet" "$1"' _ "$TMP/login.html"
check "Entrar: label, dica do vault, campo e botão grande" bash -c 'grep -q "<label for=\"token\">Token</label>" "$1" && grep -q "Vaultwarden · pasta oute-services" "$1" && grep -q "<input id=\"token\" name=\"token\" type=\"password\" autocomplete=\"current-password\"" "$1" && grep -q "class=\"botao primario grande\">Entrar" "$1"' _ "$TMP/login.html"
check "Entrar: mostrar/esconder só com o script (botão nasce escondido)" bash -c 'grep -q "id=\"token-ver\" hidden aria-controls=\"token\" aria-label=\"Mostrar token\"" "$1" && grep -q "<script src=\"/static/login.js\" defer>" "$1"' _ "$TMP/login.html"
check "Entrar: scripts só do /static (htmx e login.js)" test "$(grep -ho '<script[^>]*>' "$TMP/login.html" | sort -u | paste -sd,)" = '<script src="/static/htmx.min.js" defer>,<script src="/static/login.js" defer>'
check "Entrar: /static/login.js servido, sem eval nem recurso de fora" bash -c '[ "$(curl -s -o "$2" -w "%{http_code}" "$1/static/login.js")" = 200 ] && ! grep -qE "eval|innerHTML|document\.write|https?:|fetch\(|XMLHttpRequest" "$2" && grep -q "addEventListener(\"click\"" "$2"' _ "$STUDIO_URL" "$TMP/login.js"
check "Entrar: sem erro, sem o aviso de token"         bash -c '! grep -qE "Token errado|aria-invalid|role=\"alert\"" "$1"' _ "$TMP/login.html"
check "Entrar com token errado: callout com triangle-alert e o campo inválido" bash -c 'grep -q "<div class=\"aviso erro login-erro\" role=\"alert\">" "$1" && grep -q "lucide.svg#triangle-alert" "$1" && grep -q "<strong>Token errado.</strong>" "$1" && grep -q "aria-invalid=\"true\"" "$1"' _ "$TMP/login-erro.html"
check "Entrar: o erro não devolve o token digitado"    bash -c '! grep -qF "$2" "$1"' _ "$TMP/login-erro.html" "${STUDIO_TOKEN}x"
check "Entrar: o 413 de quem não entrou sai sem o casco" bash -c '! curl -s -X POST --data-urlencode "token=$(head -c 5000 /dev/zero | tr "\0" x)" "$1/login" | grep -qE "class=\"(barra|cabecalho)\""' _ "$STUDIO_URL"
check "CSS: Entrar em duas colunas, uma só até 640 px"  bash -c 'grep -q "^\.entrar-painel { flex: 1 1 520px;" "$1" && grep -q "^\.entrar-form { flex: 1 1 520px;" "$1" && grep -q "^  \.entrar-painel { flex: 0 0 auto;" "$1"' _ "$TMP/studio.css"
check "CSS: faixas .alertas (destructive tingido) e .decisoes (--gate-tint)" bash -c 'grep -q "^\.alertas { background: color-mix(in oklab, var(--destructive) 10%, transparent);" "$1" && grep -q "background: var(--gate-tint);" "$1"' _ "$TMP/studio.css"

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
ids() { local query="$1"; studio_page "${C[@]}" "$STUDIO_URL/conversas?$WIN&$query" | data | jq -c '[.[] | select(.conversa) | .conversa]'; return $?; }
check "filtro por host"                                test "$(ids host=oute-mac)" = '["conv-b","conv d/1&x=é"]'
check "filtro por agente"                              test "$(ids agent=codex)" = '["conv-b"]'
check "filtro por host e agente"                       test "$(ids 'host=oute-mac&agent=claude')" = '["conv d/1&x=é"]'
check "filtro sem resultado: lista vazia, com aviso"   grep -q 'Nenhuma conversa nessa janela' <(studio_page "${C[@]}" "$STUDIO_URL/conversas?$WIN&host=oute-server&agent=codex")
check "filtros do cabeçalho oferecem os hosts e agentes da janela (links, #529)" bash -c 'grep -q "<a href=\"[^\"]*host=oute-mac[^\"]*\">oute-mac</a>" "$1" && grep -q "<a href=\"[^\"]*host=oute-server[^\"]*\">oute-server</a>" "$1" && grep -q "<a href=\"[^\"]*agent=codex[^\"]*\">codex</a>" "$1"' _ "$TMP/list.html"
check "janela padrão (24 h): nada (hora do fato, não a de chegada)" grep -q 'Nenhuma conversa nessa janela' <(studio_page "${C[@]}" "$STUDIO_URL/conversas")
check "janela só com o começo da conversa longa"       test "$(studio_page "${C[@]}" "$STUDIO_URL/conversas?from=2025-09-25&to=2025-09-26" | data | jq -c '[.[] | select(.conversa) | .conversa]')" = '["conv d/1&x=é"]'
check "janela inválida: 400"                           test "$(code "${C[@]}" "$STUDIO_URL/conversas?from=ontem&to=2025-09-29")" = 400
check "from sem to: 400"                               test "$(code "${C[@]}" "$STUDIO_URL/conversas?from=2025-09-27")" = 400
check "hours inválido: 400, com a página de erro"      grep -q 'hours inválido' <(studio_page "${C[@]}" "$STUDIO_URL/conversas?hours=x")
check "lista com htmx (filtro troca só o conteúdo)"    grep -q 'hx-get="/conversas"' "$TMP/list.html"

# ---------------------------------------------------------------- 4. detalhe: árvore de spans e logs
check "detalhe: 200"                                   test "$(code "${C[@]}" "$STUDIO_URL/conversa?id=conv-a")" = 200
check "conversa que não existe: 404"                   test "$(code "${C[@]}" "$STUDIO_URL/bloco/conversa/resumo?id=nao-existe")" = 404
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
check "span: nome, duração e modelo"                   jqe '.text | test("claude_code.llm_request \\+1,0 s 2,0 s claude-sonnet-5 100 / 50 cache 1\\.000 / 10 US\\$ 0,0100")' <<<"$(sp a2)"
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
F="$(studio_page "${C[@]}" "${HX[@]}" "${SPAN_URL}3")"
check "conteúdo do span (htmx): trecho, não página"    bash -c '! grep -qi "<html" <<<"$1" && grep -q "data-span-detalhe=\"00000000000000a3\"" <<<"$1"' _ "$F"
check "conteúdo do span: atributos, resource e status" bash -c 'grep -q "tool_name" <<<"$1" && grep -q "host.name" <<<"$1" && grep -q "00000000000000a1" <<<"$1"' _ "$F"
check "conteúdo do span: mensagem do status de erro"   grep -q 'comando falhou' <(studio_page "${C[@]}" "${HX[@]}" "${SPAN_URL}4")
F1="$(studio_page "${C[@]}" "${HX[@]}" "${SPAN_URL}1")"
check "conteúdo do span: escapado"                     bash -c '! grep -q "<script>alert" <<<"$1" && grep -q "&lt;script&gt;alert" <<<"$1"' _ "$F1"
check "conteúdo do span sem htmx: página inteira, com a volta" bash -c 'grep -qi "<html" <<<"$1" && grep -q "href=\"/conversa?id=conv-a\"" <<<"$1"' _ "$(studio_page "${C[@]}" "${SPAN_URL}3")"
check "span que não existe: 404"                       test "$(code "${C[@]}" "${SPAN_URL}f&full=1")" = 404
check "span sem trace ou sem span: 400"                test "$(code "${C[@]}" "$STUDIO_URL/conversa/span?trace=1")$(code "${C[@]}" "$STUDIO_URL/conversa/span?span=1")" = 400400
check "linha da árvore abre o conteúdo pelo htmx"      grep -q 'hx-get="/conversa/span?trace=00000000000000000000000000000001&amp;span=00000000000000a3" hx-target="next .conteudo"' "$TMP/a.html"

# conv-b: 205 logs = página de 200 + "mais logs"
studio_page "${C[@]}" "$STUDIO_URL/conversa?id=conv-b" > "$TMP/b.html"
GB="$(data < "$TMP/b.html" | jq -c '[.[] | select(.log)]')"
check "logs: primeira página com 200, em ordem"        jqe 'length == 200 and (.[0].text | test("linha 000")) and (.[199].text | test("linha 199"))' <<<"$GB"
check "logs: link para o resto"                        grep -q 'hx-get="/conversa/logs?id=conv-b&amp;offset=200"' "$TMP/b.html"
check "conv-b: total de logs no título"                grep -q 'Logs (205)' "$TMP/b.html"
M="$(studio_page "${C[@]}" "${HX[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=200")"
check "mais logs (htmx): só as 5 linhas que faltavam"  bash -c '! grep -qi "<html\|<table" <<<"$1" && test "$(grep -c "<tr data-log" <<<"$1")" = 5 && grep -q "linha 204" <<<"$1"' _ "$M"
check "mais logs: última página sem link"              bash -c '! grep -q "mais logs" <<<"$1"' _ "$M"
check "mais logs sem htmx: página inteira"             bash -c 'grep -qi "<html" <<<"$1" && test "$(grep -c "<tr data-log" <<<"$1")" = 5' _ "$(studio_page "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=200")"
check "mais logs além do fim: aviso, sem erro"         grep -q 'Sem mais logs' <(studio_page "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=900")
check "mais logs: offset inválido ou sem id = 400"     test "$(code "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=x")$(code "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-b&offset=-1")$(code "${C[@]}" "$STUDIO_URL/conversa/logs?offset=0")" = 400400400
check "id com espaço, /, & e acento abre o detalhe"    grep -q 'data-calls="2"' <(studio_page "${C[@]}" "$STUDIO_URL/conversa?id=conv%20d/1%26x%3D%C3%A9")
check "conversa só com spans: aviso no lugar dos logs" grep -q 'Esta conversa não tem logs' <(studio_page "${C[@]}" "$STUDIO_URL/conversa?id=conv-c")
check "a tela não derrubou o servidor (sem 500 no stderr)" bash -c '! grep -q "respondi 500\|Traceback" "$1"' _ "$TMP/s/stderr"
# ---------------------------------------------------------------- 4b. receitas Kubo nas macros e nas páginas (#468)
curl -s "$STUDIO_URL/static/copiar.js" > "$TMP/copiar.js"
check "copiar.js: servido sem login, é o arquivo do repo" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" "$1/static/copiar.js")" = 200 ] && cmp -s "$2" "$3"' _ "$STUDIO_URL" "$TMP/copiar.js" "$PKG/static/copiar.js"
check "copiar.js: só copia (sem rede, eval nem HTML montado)" bash -c '! grep -qE "fetch|XMLHttpRequest|eval\(|innerHTML|new Function|sendBeacon|WebSocket" "$1" && grep -q "clipboard" "$1"' _ "$TMP/copiar.js"
check "CSS: Badge padrão, contorno, secundário, destrutivo e gate" bash -c 'for v in "^\.badge \{" "^\.badge\.contorno" "^\.badge\.secundario" "^\.badge\.destrutivo" "^\.badge\.gate"; do grep -qE "$v" "$1" || exit 1; done' _ "$TMP/studio.css"
check "CSS: cartão com anel (ring de 1 px a 10%), th 12px/500 muted, linha com hover muted/50" bash -c 'grep -qE "^\.cartao \{.*box-shadow: 0 0 0 1px color-mix\(in oklab, var\(--foreground\) 10%" "$1" && grep -q "^th { padding-top: 8px; padding-bottom: 8px; font-size: 12px; font-weight: 500; color: var(--muted-foreground)" "$1" && grep -q "^tbody tr:hover > td { background: color-mix(in oklab, var(--muted) 50%" "$1"' _ "$TMP/studio.css"
check "CSS: árvore de spans com 16 px por nível" bash -c 'grep -q "\.d1 { padding-left: 36px; } \.d2 { padding-left: 52px; }" "$1" && grep -q "\.d12 { padding-left: 212px; }" "$1"' _ "$TMP/studio.css"
check "CSS celular: tabela empilha vira cartão/linha de 2 níveis, alvos de 44 px" bash -c 'm="$(perl -0ne "print \$1 if /\@media \(max-width: 640px\) \{\n  \.tiles(.*?)\n\}\n/s" "$1")"; grep -q "table.empilha .sec { display: none; }" <<<"$m" && grep -q "table.empilha tr { display: flex; flex-wrap: wrap;" <<<"$m" && grep -q "\.botao, \.copiar { min-height: 44px; }" <<<"$m"' _ "$TMP/studio.css"
check "listas: tabela no cartão, Tokens ent / saí numa célula com o cache embaixo, sem as colunas Entrada e Saída" bash -c 'grep -q "<div class=\"cartao rolagem\">" "$1" && grep -q "<table class=\"conversas empilha\" data-tabela>" "$1" && grep -q "<th class=\"n\" title=\"[^\"]*\" aria-sort=\"[^\"]*\" data-col=\"tokens\">" "$1" && grep -q ">Tokens ent / saí</a>" "$1" && grep -q "<span class=\"fino\" title=\"tokens de cache: leitura / escrita\">cache " "$1" && ! grep -qE "<th class=\"n\">(Entrada|Saída|Cache)</th>" "$1"' _ "$TMP/list.html"
check "listas: no celular a linha de baixo (início, host, agente, chamadas, duração) e as colunas secundárias marcadas" bash -c 'grep -q "<span class=\"so-celular-linha\">" "$1" && grep -q "<td class=\"hora sec\">" "$1" && grep -q "<td class=\"prim\"><span class=\"conv-nome\"><a href=\"/conversa?id=" "$1"' _ "$TMP/list.html"
check "listas: Erros em Badge destrutivo só onde há erro, linha sem class erro" bash -c 'n="$(grep -c "data-errors=\"[1-9]" "$1")"; [ "$n" -ge 1 ] && [ "$(grep -o "<td class=\"n\"><a class=\"erros-link\" href=\"[^\"]*\" title=\"[^\"]*\"><span class=\"badge destrutivo\">" "$1" | wc -l)" = "$n" ] && ! grep -q "class=\"erro\"" "$1"' _ "$TMP/list.html"
check "detalhe: 4 StatTiles (chamadas, tokens ent / saí, custo, duração) fora do dl do resumo" bash -c '[ "$(grep -o "<div class=\"tile\">" "$1" | wc -l)" = 4 ] && grep -q "Tokens ent / saí</strong>\|tile-rotulo\"><svg[^>]*><use href=\"/static/lucide.svg#arrow-left-right\"/></svg>Tokens ent / saí" "$1" && [ "$(grep -o "<dl class=\"resumo\"" "$1" | wc -l)" = 1 ]' _ "$TMP/a.html"
check "detalhe: resumo num cartão, spans num cartão com o Badge de erros" bash -c 'grep -q "<div class=\"cartao bloco\">" "$1" && grep -q "<span class=\"badge destrutivo\">1 com erro</span>" "$1"' _ "$TMP/a.html"
check "árvore: ícone por tipo (workflow, sparkles, wrench, terminal) e o mesmo ícone de chamada para a chamada sem pai" python3 -c '
import re, sys
h = open(sys.argv[1]).read()
def icon(sid):
    m = re.search(r"<tr data-span=\"0*" + sid + r"\".*?<use href=\"/static/lucide.svg#([a-z-]+)\"", h, re.S)
    return m.group(1) if m else None
want = {"a1": "workflow", "a2": "sparkles", "a3": "wrench", "a4": "terminal", "a5": "sparkles", "a6": "sparkles"}
sys.exit(0 if {k: icon(k) for k in want} == want else 1)' "$TMP/a.html"
check "árvore: pai ausente em Badge de contorno; erro em Badge destrutivo na coluna Status; a linha sem class erro" bash -c 'grep -q "<span class=\"badge contorno\">pai ausente</span>" "$1" && [ "$(grep -o "<td><span class=\"badge destrutivo\">erro</span></td>" "$1" | wc -l)" = 1 ] && ! grep -q "<tr [^>]*class=\"erro\"" "$1"' _ "$TMP/a.html"
check "árvore: Tokens ent / saí numa célula e o cache em segunda linha menor" bash -c 'grep -q "100 / 50<span class=\"fino\" title=\"tokens de cache: leitura / escrita\">cache 1.000 / 10</span>" "$1"' _ "$TMP/a.html"
check "árvore: o conteúdo do span segue pelo htmx (hx-get, hx-target, linha de conteúdo)" bash -c '[ "$(grep -c "hx-target=\"next .conteudo\"" "$1")" = 7 ] && [ "$(grep -c "<tr class=\"conteudo-linha\"><td class=\"conteudo\" colspan=\"7\" data-inline-bloco=\"faixa\">" "$1")" = 7 ]' _ "$TMP/a.html"
check "logs: tabela no cartão, nível em Badge (erro destrutivo, o resto de contorno), sem class erro na linha" bash -c 'grep -q "<table class=\"logs empilha\">" "$1" && grep -q "<span class=\"badge destrutivo\">" "$1" && grep -q "<span class=\"badge contorno\">" "$1" && ! grep -q "<tr [^>]*class=\"erro\"" "$1"' _ "$TMP/a.html"
check "detalhe e logs: botão de voltar com o ícone, no lugar do link solto" bash -c 'grep -q "<a class=\"botao\" href=\"/conversas\">.*Conversas</a>" "$1" && grep -q "<a class=\"botao\" href=\"/conversa?id=conv-b\">" "$2"' _ "$TMP/a.html" "$TMP/logs.html"
check "ícones das páginas novas todos no sprite" bash -c 'u="$(grep -ho "href=\"/static/lucide.svg#[^\"]*\"" "${@:2}" | sed "s/.*#//; s/\"//" | sort -u)"; [ -n "$u" ] && for g in $u; do grep -q "<symbol id=\"$g\" " "$1" || { echo "falta $g" >&2; exit 1; }; done' _ "$TMP/lucide.svg" "$TMP/a.html" "$TMP/list.html"

# ---------------------------------------------------------------- 4b. nome amigável e erros da conversa (#530)
NA="$(nome conv-a)"
check "nome: formato Adjetivo_Substantivo"             bash -c '[[ "$1" =~ ^[A-Z][a-z]+_[A-Z][a-z]+$ ]]' _ "$NA"
check "nome: o mesmo id dá o mesmo nome"               test "$(nome conv-a)" = "$NA"
check "lista: o nome com o link e, abaixo, o id inteiro" grep -qF "<span class=\"conv-nome\"><a href=\"/conversa?id=conv-a\">$NA</a></span><span class=\"fino conv-id\">conv-a</span>" "$TMP/list.html"
check "lista: o id inteiro segue no data-conversa e na URL" bash -c 'grep -q "data-conversa=\"conv-a\"" "$1" && grep -qF "href=\"/conversa?id=conv%20d/1%26x%3D%C3%A9\"" "$1"' _ "$TMP/list.html"
check "lista: conversa do Codex também tem nome"       grep -qF "<a href=\"/conversa?id=conv-b\">$(nome conv-b)</a>" "$TMP/list.html"
check "detalhe: o mesmo nome, com o id inteiro abaixo" grep -qF "<span class=\"conv-nome\">$NA</span><span class=\"fino conv-id\">conv-a</span>" "$TMP/a.html"
check "lista: selo de erros com link para os erros da conversa" grep -qF 'href="/conversa?id=conv-a&amp;erros=1"' "$TMP/list.html"
check "lista: linha sem erro não tem link de erros"    bash -c '[ "$(grep -c "class=\"erros-link\"" "$1")" = 1 ]' _ "$TMP/list.html"
studio_page "${C[@]}" "$STUDIO_URL/conversa?id=conv-a&erros=1" > "$TMP/ae.html"
AE="$(data < "$TMP/ae.html")"
check "filtrado: só o span com erro"                   jqe '[.[] | select(.span)] | map(.span[-2:]) == ["a4"]' <<<"$AE"
check "filtrado: só o log ERROR ou acima"              jqe '[.[] | select(.log)] | map(.log) == ["1759000008000000000"]' <<<"$AE"
check "filtrado: as somas seguem as da conversa inteira" jqe '.[] | select(has("resumo")) | .calls == "3"' <<<"$AE"
check "filtrado: link de volta à conversa inteira"     grep -qF '<a href="/conversa?id=conv-a">Ver a conversa inteira</a>' "$TMP/ae.html"
check "sem filtro: sem o link de volta"                bash -c '! grep -q "data-filtro-erros" "$1"' _ "$TMP/a.html"
check "filtro que não é 1 (erros=0): conversa inteira" bash -c '[ "$(studio_page "${@:2}" "$1/conversa?id=conv-a&erros=0" | grep -c "<tr data-span=")" = 7 ]' _ "$STUDIO_URL" "${C[@]}"
CBE="$(studio_page "${C[@]}" "$STUDIO_URL/conversa?id=conv-b&erros=1")"
check "filtrado, conversa sem erro: avisos e nenhuma linha" bash -c 'grep -q "não tem spans com erro" <<<"$1" && grep -q "não tem logs com erro" <<<"$1" && ! grep -q "<tr data-log" <<<"$1"' _ "$CBE"
check "logs filtrados (htmx): só a linha com erro"     bash -c '[ "$(studio_page "${@:2}" -H "HX-Request: true" "$1/conversa/logs?id=conv-a&erros=1" | grep -c "<tr data-log")" = 1 ]' _ "$STUDIO_URL" "${C[@]}"
check "logs filtrados: página inteira volta ao filtro" grep -qF 'href="/conversa?id=conv-a&amp;erros=1" title="Voltar"' <(studio_page "${C[@]}" "$STUDIO_URL/conversa/logs?id=conv-a&erros=1")
cat > "$TMP/names.py" <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["PKG_PARENT"])
from agent_studio import names, web
ok = lambda name, cond: print(("ok   " if cond else "FAIL ") + name)
ok("palavras: 64 adjetivos, 32 animais e 32 pessoas, sem repetição", (len(names.ADJECTIVES), len(names.ANIMALS), len(names.PEOPLE)) == (64, 32, 32)
   and len(set(names.ADJECTIVES)) == 64 and len(set(names.NOUNS)) == 64)
ok("palavras: uma palavra só, capitalizada, em letras ASCII", all(re.fullmatch(r"[A-Z][a-z]+", w) for w in names.ADJECTIVES + names.NOUNS))
ofensivas = {"Idiot", "Stupid", "Dumb", "Ugly", "Fat", "Dead", "Evil", "Nazi", "Slave", "Whore", "Bitch", "Fool", "Crazy", "Mad"}
ok("palavras: nenhuma da lista de ofensivas", not ofensivas & set(names.ADJECTIVES + names.NOUNS))
ok("nome: o mesmo id, o mesmo nome, em formato Adjetivo_Substantivo", all(names.friendly(i) == names.friendly(i) and re.fullmatch(r"[A-Z][a-z]+_[A-Z][a-z]+", names.friendly(i)) for i in ("a", "conv d/1&x=é", "0" * 36)))
ok("nome: cobre as listas (ids diferentes dão nomes diferentes)", len({names.friendly(f"id-{i}") for i in range(2000)}) > 1000)
ok("nome: o filtro `nome` dos templates é o mesmo", web._env().filters["nome"] is names.friendly)
m = web._env().get_template("_macros.html").module
ok("logs: o link de mais logs leva o filtro de erros", 'offset=200&amp;erros=1' in str(m.log_rows([], "x", 200, True)) and 'erros=1' not in str(m.log_rows([], "x", 200, False)))
PY
PKG_PARENT="$ROOT/docker/agent-studio" "$STUDIO_PY" "$TMP/names.py" > "$TMP/names.out" 2>&1
check_py "$TMP/names.out"
check "nomes e erros: os 7 casos em Python rodaram"    test "$((n_ok + n_fail))" = 7

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
      == ["/conversa?id=a"] + ["/"] * 7)

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
check "compose: agent-studio só em 127.0.0.1"          bash -c 'awk "/^  agent-studio:/{f=1;print;next} f&&/^  [a-z]/{exit} f" "$1" | grep -q "\"127.0.0.1:\${OUTE_AGENT_STUDIO_PORT:-8430}:8430\""' _ "$ROOT/docker/compose.yaml"

check_end
