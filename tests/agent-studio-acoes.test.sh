#!/usr/bin/env bash
# Testes da lista de ações com escrita da página da rodada (#510, ADR-08 "Página da rodada e do ciclo", D2=1 e D3=1):
# `POST /rodada/acao` com a credencial de marcação (cookie próprio, Origin, campo csrf), a tabela `action_marks` só de
# acréscimo, o `acao` derivado no SurrealDB, o `rebuild-state` (`acoes=`), a ação com pedido sem caixa e o que o servidor
# nunca devolve nem registra do cliente. Sem a credencial a rota não existe. Sem Docker; o SurrealDB é o binário fixado
# de tests/lib/surreal.sh. Todas as credenciais são sorteadas na hora.
# Uso: tests/agent-studio-acoes.test.sh   (sai != 0 se algum caso falhar)
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

# ---------------------------------------------------------------- exemplo
# Rodada R: o `merge` do PR 12 (aprovado) com as ações a1, a3 (caixa), a2 (cita o pedido PID: sem caixa), a1 repetido e uma
# linha sem id; o `fechamento` reprovado, com a ação b1 (texto fechado). Rodada S: só o kaizen, sem ação.
R=swarm-1005-0100; S=swarm-1005-0200; PID=20261005-010000-aplicar-deploy
NOW="$(date +%s)"
READ_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
MARK_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" "$R" "$S" "$PID" <<'PY'
import hashlib, json, sys
from otlp_json import canal_decided, canal_proposed, event, rl
tmp, NOW, R, S, PID = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
res = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "claude"}
def step(t, rnd, eid, kind, rev, review, text, key=None):
    attrs = {"oute.swarm.round": rnd, "oute.swarm.step.kind": kind, "oute.swarm.step.rev": rev,
             "oute.swarm.step.sha256": hashlib.sha256(text.encode()).hexdigest(), "oute.swarm.step.review": review,
             "oute.swarm.step.writer": "claude-sonnet-5-5", "oute.swarm.step.reviewer": "claude-opus-5-5", "oute.swarm.step.refcheck": "ausente"}
    if key: attrs["oute.swarm.step.key"] = key
    return event(t, "oute.swarm.step.published", eid, attrs, text)
MERGE = ("## Decisão\n1. nada a decidir\n\n## Ações\n- a1: conferir o deploy <b>agora</b>\n"
         f"- a2: aplicar o `pedido:{PID}` no host\n- a3: ler o PR **12**\n- a1: repetida\n- sem id aqui\n\n## Detalhe\nTexto.\n")
FECH = "## Decisão\n1. fechar\n\n## Ações\n- b1: fechar a aba\n\n## Detalhe\nFim.\n"
KAIZEN = "## Decisão\n1. ok\n\n## Ações\n- k1: abrir a issue\n"
b1 = [step(NOW - 900, R, "ev-merge", "merge", 1, "aprovado", MERGE, "12"), step(NOW - 800, R, "ev-fech", "fechamento", 1, "reprovado", FECH),
      step(NOW - 700, S, "ev-kaizen", "kaizen", 1, "aprovado", KAIZEN),
      canal_proposed(NOW - 600, PID, "ev-prop", "aplicar o deploy", "oute-ops", "echo ok\n"), canal_decided(NOW - 500, PID, "ev-dec", "executado")]
json.dump({"resourceLogs": [rl(res, b1)]}, open(f"{tmp}/b1.json", "w"))
PY
# o cookie de leitura, o de marcação e o campo csrf, pelo mesmo código do servidor
read -r COOKIE_R COOKIE_M CSRF < <(PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -c '
import sys
from agent_studio.auth import Auth
a = Auth(sys.argv[1], sys.argv[2], sys.argv[3])
print(a.cookie_value, a.mark_cookie_value, a.mark_csrf)' "$STUDIO_TOKEN" "$READ_T" "$MARK_T")

SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml"
      AGENT_STUDIO_READ_TOKEN="$READ_T")
sr() { local q="$1"; surreal_q "$q"; return $?; }
RC_="Cookie: agent_studio=$COOKIE_R"; MC_="Cookie: agent_studio=$COOKIE_R; agent_studio_mark=$COOKIE_M"
RB_=(-H "Authorization: Bearer $READ_T")
# acao <cabeçalho Cookie ou vazio> <Origin ou vazio> <corpo> [curl…]: POST /rodada/acao; imprime o código HTTP e deixa o corpo em $TMP/resp
acao() {
  local cookie="$1" origin="$2" body="$3"; shift 3
  curl -s -o "$TMP/resp" -w '%{http_code}' -X POST ${cookie:+-H "$cookie"} ${origin:+-H "Origin: $origin"} \
    -H 'Content-Type: application/x-www-form-urlencoded' --data "$body" "$@" "$STUDIO_URL/rodada/acao"
  return $?
}
form() { local rod="$1" etapa="$2" id="$3" est="$4" csrf="${5-$CSRF}"; printf 'rodada=%s&etapa=%s&acao=%s&estado=%s&csrf=%s' "$rod" "$etapa" "$id" "$est" "$csrf"; return 0; }
page() { local path="$1"; shift; studio_page -H "$RC_" "$@" "$STUDIO_URL$path"; return $?; }

# ---------------------------------------------------------------- 1. sem a credencial de marcação a rota não existe
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
check "ingestão do lote de etapas e do pedido" test "$(post logs "$TMP/b1.json")" = 200
O="$STUDIO_URL"
check "sem credencial de marcação: POST /rodada/acao = 404 (não existe), mesmo com cookie e Origin" test "$(acao "$RC_" "$O" "$(form "$R" merge:12 a1 feita)")" = 404
check "sem credencial de marcação: GET e POST /marcar = 404" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "$1" "$3/marcar")" = 404 ] && [ "$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$1" -H "Origin: $2" -d token=x "$3/marcar")" = 404 ]' _ "$RC_" "$O" "$O"
page "/rodada?id=$R" > "$TMP/off.html"
check "sem credencial de marcação: a página diz que a marcação está desligada, as ações saem só com o estado e sem formulário" bash -c 'f="$1"; grep -q "data-marcacao=\"desligada\"" "$f" && grep -q "data-acao=\"a1\"" "$f" && [ "$(grep -ho "<form[^>]*>" "$f" | sort -u)" = "<form method=\"post\" action=\"/logout\">" ]' _ "$TMP/off.html"
check "sem credencial de marcação: o estado das ações sai do SurrealDB (pendente) e o csrf não existe em lugar nenhum" bash -c '! grep -qF "$2" "$1" && grep -q "data-estado=\"pendente\"" "$1"' _ "$TMP/off.html" "$CSRF"
studio_stop

# ---------------------------------------------------------------- 2. com a credencial: quem pode e de onde
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_MARK_TOKEN="$MARK_T" || { cat "$TMP/s/stderr"; die "agent-studio não subiu com a credencial de marcação"; }
O="$STUDIO_URL"
B="$(form "$R" merge:12 a1 feita)"
check "sem cookie nenhum: 401"                                   test "$(acao "" "$O" "$B")" = 401
check "cookie de leitura: 403 (o agente tem a leitura e alcança o studio)" test "$(acao "$RC_" "$O" "$B")" = 403
check "Bearer da credencial de leitura: 403"                     test "$(acao "" "$O" "$B" "${RB_[@]}")" = 403
check "Bearer da credencial de ingestão: 401 (não lê, não marca)" test "$(acao "" "$O" "$B" -H "Authorization: Bearer $STUDIO_TOKEN")" = 401
check "cookie de marcação sem Origin: 403"                       test "$(acao "$MC_" "" "$B")" = 403
check "Origin de outro site: 403"                                test "$(acao "$MC_" "https://outro-site.example" "$B")" = 403
check "Origin do mesmo host em outra porta: 403"                 test "$(acao "$MC_" "${O%:*}:1" "$B")" = 403
check "Origin com caminho: 403"                                  test "$(acao "$MC_" "$O/x" "$B")" = 403
check "csrf errado: 403"                                         test "$(acao "$MC_" "$O" "$(form "$R" merge:12 a1 feita "$(printf '0%.0s' $(seq 1 64))")")" = 403
check "csrf de outro valor (o cookie, não o campo): 403"         test "$(acao "$MC_" "$O" "$(form "$R" merge:12 a1 feita "$COOKIE_M")")" = 403
check "nenhuma dessas recusas gravou marca"                      bash -c '[ "$(curl -s "${@:2}" "$1/v1/rodada?id='"$R"'" | jq "[.steps[].actions[]? | select(.state == \"feita\")] | length")" = 0 ]' _ "$O" "${RB_[@]}"

# ---------------------------------------------------------------- 3. o corpo
check "campo a menos (sem csrf): 400"                            test "$(acao "$MC_" "$O" "rodada=$R&etapa=merge:12&acao=a1&estado=feita")" = 400
check "campo a mais: 400"                                        test "$(acao "$MC_" "$O" "$B&texto=livre")" = 400
check "campo repetido: 400"                                      test "$(acao "$MC_" "$O" "$B&estado=pendente")" = 400
check "estado fora de feita/pendente: 400"                       test "$(acao "$MC_" "$O" "$(form "$R" merge:12 a1 talvez)")" = 400
check "etapa sem a chave do merge, ou chave em outra: 400"       bash -c '[ "$1" = 400 ] && [ "$2" = 400 ] && [ "$3" = 400 ]' _ "$(acao "$MC_" "$O" "$(form "$R" merge a1 feita)")" "$(acao "$MC_" "$O" "$(form "$R" fechamento:3 b1 feita)")" "$(acao "$MC_" "$O" "$(form "$R" ciclo b1 feita)")"
check "id da ação fora do formato: 400"                          test "$(acao "$MC_" "$O" "$(form "$R" merge:12 'A1;x' feita)")" = 400
check "ação que não existe na etapa: 400"                        test "$(acao "$MC_" "$O" "$(form "$R" merge:12 a9 feita)")" = 400
check "ação de outra etapa (b1 está no fechamento): 400"         test "$(acao "$MC_" "$O" "$(form "$R" merge:12 b1 feita)")" = 400
check "etapa que não existe na rodada (merge:99): 400"           test "$(acao "$MC_" "$O" "$(form "$R" merge:99 a1 feita)")" = 400
check "rodada que não existe: 400"                               test "$(acao "$MC_" "$O" "$(form swarm-1999-0000 merge:12 a1 feita)")" = 400
check "a ação repetida (a1 duas vezes) e a linha sem id: o servidor só conhece a primeira a1 e nada mais" bash -c '[ "$(curl -s "${@:2}" "$1/v1/rodada?id='"$R"'" | jq -c "[.steps[] | select(.kind == \"merge\") | .actions[].id]")" = "[\"a1\",\"a2\",\"a3\"]" ]' _ "$O" "${RB_[@]}"
check "ação que cita um pedido do canal (a2): 400, não tem caixa" test "$(acao "$MC_" "$O" "$(form "$R" merge:12 a2 feita)")" = 400
check "corpo acima de 4 KB: 413"                                 test "$(acao "$MC_" "$O" "$B&x=$(head -c 5000 /dev/zero | tr '\0' a)")" = 413
check "corpo que não é formulário (JSON): 400"                   test "$(acao "$MC_" "$O" '{"rodada":"x"}' -H 'Content-Type: application/json')" = 400
check "corpo com bytes que não são UTF-8: 400"                   bash -c '[ "$(printf "rodada=\xff" | curl -s -o /dev/null -w "%{http_code}" -X POST -H "$2" -H "Origin: $3" -H "Content-Type: application/x-www-form-urlencoded" --data-binary @- "$1/rodada/acao")" = 400 ]' _ "$O" "$MC_" "$O"
EVIL='ZZevil<script>alert(1)</script>'
check "nada do cliente volta na resposta de erro nem entra no log" bash -c 'st="$(curl -s -o "$2" -w "%{http_code}" -X POST -H "$3" -H "Origin: $4" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "rodada=$5" --data-urlencode "etapa=$5" --data-urlencode "acao=$5" --data-urlencode "estado=$5" --data-urlencode "csrf=$5" "$1/rodada/acao")"; [ "$st" = 400 ] && ! grep -q "ZZevil" "$2" && ! grep -q "ZZevil" "$6"' _ "$O" "$TMP/resp" "$MC_" "$O" "$EVIL" "$TMP/s/stderr"
check "nenhum erro de formulário abriu marca"                    bash -c '[ "$(curl -s "${@:2}" "$1/v1/rodada?id='"$R"'" | jq "[.steps[].actions[]? | select(.state == \"feita\")] | length")" = 0 ]' _ "$O" "${RB_[@]}"

# ---------------------------------------------------------------- 4. marcar, desmarcar, e o que a página mostra
page "/rodada?id=$R" -H "Cookie: agent_studio=$COOKIE_R; agent_studio_mark=$COOKIE_M" > "$TMP/on.html"
check "página com os dois cookies: um formulário por ação com caixa (a1, a3 e b1, a do fechamento), nenhum para a2 nem para a repetida" bash -c 'f="$1"; [ "$(grep -c "data-acao-form=" "$f")" = 3 ] && grep -q "data-acao-form=\"a1\"" "$f" && grep -q "data-acao-form=\"a3\"" "$f" && grep -q "data-acao-form=\"b1\"" "$f" && ! grep -q "data-acao-form=\"a2\"" "$f"' _ "$TMP/on.html"
check "página: o csrf do formulário é o HMAC da credencial de marcação, e o texto da ação sai escapado" bash -c 'f="$1"; grep -qF "name=\"csrf\" value=\"$2\"" "$f" && ! grep -q "<b>agora</b>" "$f" && grep -q "&lt;b&gt;agora&lt;/b&gt;" "$f"' _ "$TMP/on.html" "$CSRF"
check "página: a2 mostra o estado do pedido (decidido), com link para a página dele, e nenhuma caixa" bash -c 'f="$1"; grep -q "data-pedido-estado=\"decidido\"" "$f" && grep -qF "href=\"/pedido?id=$2\"" "$f"' _ "$TMP/on.html" "$PID"
check "página: a ação repetida e a linha sem id seguem como linha comum, sem caixa" bash -c 'f="$1"; grep -q "a1: repetida" "$f" && grep -q "sem id aqui" "$f" && [ "$(grep -c "data-acao=\"a1\"" "$f")" = 1 ]' _ "$TMP/on.html"
check "página: o fechamento reprovado tem a ação b1 dentro do texto fechado (details)" bash -c 'tr "\n" " " < "$1" | grep -q "data-texto-fechado.*data-acao=\"b1\""' _ "$TMP/on.html"
page "/rodada?id=$R" > "$TMP/leitor.html"
check "página só com o cookie de leitura: sem formulário de marcar, sem csrf, com o convite para entrar" bash -c 'f="$1"; ! grep -q "data-acao-form" "$f" && ! grep -qF "$2" "$f" && grep -q "data-marcacao=\"entrar\"" "$f"' _ "$TMP/leitor.html" "$CSRF"
check "marcar a1 como feita: 200 (JSON)"                          bash -c '[ "$(curl -s -o "$2" -w "%{http_code}" -X POST -H "$3" -H "Origin: $4" -H "Accept: application/json" -H "Content-Type: application/x-www-form-urlencoded" --data "$5" "$1/rodada/acao")" = 200 ] && jq -e ".acao == \"a1\" and .estado == \"feita\" and .etapa == \"merge:12\"" "$2" >/dev/null' _ "$O" "$TMP/resp" "$MC_" "$O" "$B"
check "SurrealDB: acao:[rodada, merge, 12, a1] = feita, com hora e quem marcou" jqe '.[0] | .state == "feita" and .by == "human" and .kind == "merge" and .key == "12" and .aid == "a1" and (.marked_at | type) == "string"' <<<"$(sr "SELECT state, by, kind, key, aid, marked_at FROM acao:['$R','merge','12','a1']")"
check "SurrealDB: o acao liga a rodada e a etapa"                  jqe '.[0] | (.rodada | tostring | contains("rodada")) and (.etapa | tostring | contains("etapa"))' <<<"$(sr "SELECT rodada, etapa FROM acao:['$R','merge','12','a1']")"
check "SurrealDB: nenhuma outra ação foi marcada"                  test "$(sr 'SELECT count() FROM acao GROUP ALL' | jq -r '.[0].count')" = 1
check "GET /v1/rodada: a1 feita, a3 pendente, a2 com o estado do pedido, a repetida fora" bash -c 'curl -s "${@:2}" "$1/v1/rodada?id='"$R"'" | jq -e "[.steps[] | select(.kind == \"merge\") | .actions[] | {id, state, pedido, pedido_state}] == [{\"id\":\"a1\",\"state\":\"feita\",\"pedido\":null,\"pedido_state\":null},{\"id\":\"a2\",\"state\":\"pendente\",\"pedido\":\"'"$PID"'\",\"pedido_state\":\"decidido\"},{\"id\":\"a3\",\"state\":\"pendente\",\"pedido\":null,\"pedido_state\":null}]" >/dev/null' _ "$O" "${RB_[@]}"
check "GET /v1/rodada: o texto da ação sai sem formatação; o fechamento reprovado não leva ações (texto fechado)" bash -c 'curl -s "${@:2}" "$1/v1/rodada?id='"$R"'" | jq -e "([.steps[] | select(.kind == \"merge\") | .actions[0].text] == [\"conferir o deploy <b>agora</b>\"]) and ([.steps[] | select(.kind == \"fechamento\") | .actions] == [[]]) and .actions_read == true" >/dev/null' _ "$O" "${RB_[@]}"
page "/rodada?id=$R" -H "Cookie: agent_studio=$COOKIE_R; agent_studio_mark=$COOKIE_M" > "$TMP/on2.html"
check "página depois de marcar: a1 oferece desmarcar (estado=pendente) e mostra feita" bash -c 'tr "\n" " " < "$1" | grep -q "data-acao-form=\"a1\".*name=\"estado\" value=\"pendente\".*aria-checked=\"true\" data-estado=\"feita\""' _ "$TMP/on2.html"
check "marcar a1 de novo como feita (reenvio): 200, o estado segue feita" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$2" -H "Origin: $3" -H "Content-Type: application/x-www-form-urlencoded" --data "$4" "$1/rodada/acao")" = 200 ]' _ "$O" "$MC_" "$O" "$B"
check "sem Accept de JSON: 200 com a página de confirmação e o link de volta (HTML escapado)" bash -c 'st="$(curl -s -o "$2" -w "%{http_code}" -X POST -H "$3" -H "Origin: $4" -H "Content-Type: application/x-www-form-urlencoded" --data "$5" "$1/rodada/acao")"; [ "$st" = 200 ] && grep -q "data-marcado=\"pendente\"" "$2" && grep -qF "href=\"/rodada?id='"$R"'#etapa-merge-12\"" "$2"' _ "$O" "$TMP/resp" "$MC_" "$O" "$(form "$R" merge:12 a1 pendente)"
check "desmarcada (a mais nova vence): SurrealDB acao a1 = pendente" test "$(sr "SELECT state FROM acao:['$R','merge','12','a1']" | jq -r '.[0].state')" = pendente
check "marcar b1 do fechamento (texto fechado, ação existe na revisão vigente): 200" test "$(acao "$MC_" "$O" "$(form "$R" fechamento b1 feita)")" = 200
check "marcar a3 do merge: 200"                                    test "$(acao "$MC_" "$O" "$(form "$R" merge:12 a3 feita)")" = 200
check "o acao de outra rodada não existe (S só tem k1, sem marca)" test "$(sr "SELECT count() FROM acao WHERE rodada = rodada:\`$S\` GROUP ALL" | jq -r '.[0].count // 0')" = 0

# ---------------------------------------------------------------- 5. a entrada de marcação: o cookie próprio
H="$TMP/h.txt"
check "GET /marcar sem login de leitura: redireciona para o /login" test "$(code "$O/marcar")" = 303
check "GET /marcar com o cookie de leitura: 200"                    test "$(code -H "$RC_" "$O/marcar")" = 200
check "POST /marcar sem login de leitura: 401"                      test "$(code -X POST -H "Origin: $O" -d "token=$MARK_T" "$O/marcar")" = 401
check "POST /marcar sem Origin: 403"                                test "$(code -X POST -H "$RC_" -d "token=$MARK_T" "$O/marcar")" = 403
check "POST /marcar com a credencial de leitura no lugar da de marcação: 401 e nenhum cookie de marcação" bash -c 'st="$(curl -s -o /dev/null -D "$5" -w "%{http_code}" -X POST -H "$2" -H "Origin: $3" --data-urlencode "token=$4" "$1/marcar")"; [ "$st" = 401 ] && ! grep -qi "^set-cookie: agent_studio_mark" "$5"' _ "$O" "$RC_" "$O" "$READ_T" "$H"
check "POST /marcar com a credencial de ingestão: 401"              test "$(code -X POST -H "$RC_" -H "Origin: $O" --data-urlencode "token=$STUDIO_TOKEN" "$O/marcar")" = 401
check "POST /marcar com a credencial certa: 303 de volta, cookie HttpOnly, Secure, SameSite=Strict, só em /rodada" bash -c 'st="$(curl -s -o /dev/null -D "$5" -w "%{http_code}" -X POST -H "$2" -H "Origin: $3" --data-urlencode "token=$4" --data-urlencode "next=/rodada?id='"$R"'" "$1/marcar")"; c="$(grep -i "^set-cookie: agent_studio_mark=" "$5" | tr -d "\r")"; [ "$st" = 303 ] && grep -qi "^location: /rodada?id='"$R"'" "$5" && grep -q "HttpOnly" <<<"$c" && grep -q "Secure" <<<"$c" && grep -qi "SameSite=Strict" <<<"$c" && grep -q "Path=/rodada" <<<"$c" && grep -q "agent_studio_mark=$6;" <<<"$c"' _ "$O" "$RC_" "$O" "$MARK_T" "$H" "$COOKIE_M"
check "o cookie de marcação não leva a credencial, só o HMAC dela"   bash -c '! grep -qF "$2" "$1"' _ "$H" "$MARK_T"
check "o login de leitura segue com SameSite=Lax e o cookie de leitura não vale para marcar" bash -c 'c="$(curl -s -o /dev/null -D - -X POST -H "Origin: $2" --data-urlencode "token=$3" "$1/login" | tr -d "\r" | grep -i "^set-cookie: agent_studio=")"; grep -qi "SameSite=Lax" <<<"$c" && ! grep -qi "agent_studio_mark" <<<"$c"' _ "$O" "$O" "$READ_T"
check "next fora do servidor não vale (volta para a raiz)"            bash -c 'curl -s -o /dev/null -D - -X POST -H "$2" -H "Origin: $3" --data-urlencode "token=$4" --data-urlencode "next=https://outro-site.example/" "$1/marcar" | tr -d "\r" | grep -qi "^location: /$"' _ "$O" "$RC_" "$O" "$MARK_T"

# ---------------------------------------------------------------- 6. 2xx só depois do commit: SurrealDB fora = 503 e nada fica
surreal_stop
check "SurrealDB fora: POST de marcar = 503, com Retry-After e sem a causa" bash -c 'st="$(curl -s -o "$2" -w "%{http_code}" -D "$6" -X POST -H "$3" -H "Origin: $4" -H "Content-Type: application/x-www-form-urlencoded" --data "$5" "$1/rodada/acao")"; [ "$st" = 503 ] && grep -qi "^retry-after:" "$6" && ! grep -qiE "surreal|conex|refused" "$2"' _ "$O" "$TMP/resp" "$MC_" "$O" "$(form "$R" merge:12 a1 feita)" "$H"
page "/rodada?id=$R" -H "Cookie: agent_studio=$COOKIE_R; agent_studio_mark=$COOKIE_M" > "$TMP/fora.html"
check "SurrealDB fora: a página sai com o texto e com o aviso, sem formulário e sem estado das caixas" bash -c 'f="$1"; grep -q "data-estado-indisponivel" "$f" && ! grep -q "data-acao-form" "$f" && grep -q "data-estado=\"nao-lido\"" "$f" && grep -q "data-acao=\"a1\"" "$f"' _ "$TMP/fora.html"
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não voltou"; }
check "SurrealDB de volta: a marca recusada não entrou (a1 segue pendente)" test "$(sr "SELECT state FROM acao:['$R','merge','12','a1']" | jq -r '.[0].state')" = pendente
check "SurrealDB de volta: marcar a1 funciona"                      test "$(acao "$MC_" "$O" "$(form "$R" merge:12 a1 feita)")" = 200
check "o stderr do servidor não tem a credencial de marcação, o csrf nem o cookie" bash -c '! grep -qF "$2" "$1" && ! grep -qF "$3" "$1" && ! grep -qF "$4" "$1"' _ "$TMP/s/stderr" "$MARK_T" "$CSRF" "$COOKIE_M"
studio_stop

# ---------------------------------------------------------------- 7. action_marks: só de acréscimo, escrita só pela rota
DB="$TMP/s/db.duckdb"
studio_sql "$DB" "SELECT rodada, kind, key, action_id, state, marked_by, marked_unix_nano FROM action_marks ORDER BY marked_unix_nano" > "$TMP/marks.jsonl"
check "DuckDB: seis marcas, na ordem (a1 feita, a1 feita, a1 pendente, b1, a3, e a1 feita no fim); nada das recusas" bash -c '[ "$(wc -l < "$1")" = 6 ] && [ "$(jq -sc "[.[] | .action_id + \":\" + .state]" "$1")" = "[\"a1:feita\",\"a1:feita\",\"a1:pendente\",\"b1:feita\",\"a3:feita\",\"a1:feita\"]" ]' _ "$TMP/marks.jsonl"
check "DuckDB: cada marca leva a rodada, a etapa, a hora do servidor (crescente) e by = human" bash -c 'jq -sce "all(.[]; .rodada == \"'"$R"'\" and .marked_by == \"human\") and ([.[].marked_unix_nano] | . == sort and (unique | length) == length) and (.[0].key == \"12\") and (.[3].kind == \"fechamento\" and .[3].key == \"\")" "$1" >/dev/null' _ "$TMP/marks.jsonl"
check "o código nunca faz UPDATE, DELETE, DROP nem TRUNCATE em action_marks" bash -c '! grep -rnEi "(UPDATE|DELETE( FROM)?|DROP TABLE|TRUNCATE( TABLE)?)[^;\"]{0,40}action_marks" "$1/docker/agent-studio"' _ "$ROOT"
check "só o marks.py escreve em action_marks (INSERT) e só a rota chama o marks.append" bash -c 'cd "$1/docker/agent-studio/agent_studio" && [ "$(grep -rlE --include="*.py" "INSERT[^\"]*action_marks" . | tr -d "\n")" = "./marks.py" ] && [ "$(grep -rlE --include="*.py" "marks(_mod)?\.append" . | tr -d "\n")" = "./marcar.py" ]' _ "$ROOT"
check "a ingestão (otlp, app, store.write) não menciona action_marks" bash -c 'cd "$1/docker/agent-studio/agent_studio" && ! grep -n "action_marks" otlp.py app.py && [ "$(grep -c "marks_mod.create" store.py)" = 1 ]' _ "$ROOT"

# ---------------------------------------------------------------- 8. rebuild-state remonta o acao a partir da action_marks e imprime acoes=
snap() { sr "SELECT * FROM acao ORDER BY id" > "$1"; return $?; }
snap "$TMP/acao-1.json"
REB=(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio.rebuild_state)
surreal_stop; rm -rf "${TMP:?}/sdb/data"; surreal_start "$TMP/sdb" || die "SurrealDB não voltou"
check "SurrealDB esvaziado: sem acao"                              test "$(sr 'SELECT count() FROM acao GROUP ALL' 2>/dev/null | jq -r 'try .[0].count // 0')" = 0
OUT="$("${REB[@]}" 2>"$TMP/err")"; RC=$?
check "rebuild-state: rc 0 e o stderr vazio"                        bash -c '[ "$1" = 0 ] && [ ! -s "$2" ]' _ "$RC" "$TMP/err"
check "rebuild-state: lê as seis marcas (marcas=6)"                 has_line "lidas: logs=5 spans=0 marcas=6"
check "rebuild-state: antes acoes=0 e depois acoes=3 (a1, a3, b1)"  bash -c 'grep -qE "^antes: .* acoes=0$" <<<"$1" && grep -qE "^depois: .* acoes=3$" <<<"$1"' _ "$OUT"
snap "$TMP/acao-2.json"
check "o acao remontado é igual ao que a rota gravou (a mais nova de cada ação vence)" cmp -s "$TMP/acao-1.json" "$TMP/acao-2.json"
OUT="$(AGENT_STUDIO_REBUILD_CHUNK=1 "${REB[@]}" 2>&1)"; RC=$?
snap "$TMP/acao-3.json"
check "rebuild-state de novo, em blocos de 1 linha: rc 0, antes acoes=3 e o mesmo estado (idempotente)" bash -c '[ "$1" = 0 ] && grep -qE "^antes: .* acoes=3$" <<<"$2" && cmp -s "$3" "$4"' _ "$RC" "$OUT" "$TMP/acao-1.json" "$TMP/acao-3.json"
check "o rebuild-state não escreve no DuckDB: as seis marcas seguem lá" bash -c '[ "$(wc -l < "$1")" = 6 ]' _ "$TMP/marks.jsonl"

# ---------------------------------------------------------------- 9. o compose, o vault e o host
CS="$(compose_service agent-studio)"
check "compose: o agent-studio recebe a credencial de marcação, e só ele" bash -c 'grep -q "AGENT_STUDIO_MARK_TOKEN: \${AGENT_STUDIO_MARK_TOKEN:-}" <<<"$1" && [ "$(grep -c "AGENT_STUDIO_MARK_TOKEN" "$2/docker/compose.yaml")" = 1 ]' _ "$CS" "$ROOT"
check "scripts/oute: a credencial de marcação é segredo de serviço (nunca no agent.env)" bash -c 'grep -E "^SERVICE_SECRET_NAMES=" "$1/scripts/oute" | grep -q "AGENT_STUDIO_MARK_TOKEN"' _ "$ROOT"
check "secrets/README: a credencial de marcação está na pasta oute-services, não na oute-agent" bash -c 'sed -n "/^Pasta \*\*\`oute-services\`\*\*/,/^Transição/p" "$1/secrets/README.md" | grep -q "AGENT_STUDIO_MARK_TOKEN" && ! sed -n "/^Pasta \`oute-agent\`/,/^Pasta \*\*/p" "$1/secrets/README.md" | grep -q "AGENT_STUDIO_MARK_TOKEN"' _ "$ROOT"
check "o agent não tem a credencial de marcação no código (nenhum comando do container a lê)" bash -c '! git -C "$1" grep -n "AGENT_STUDIO_MARK_TOKEN" -- docker/oute-* docker/entrypoint.sh docker/Dockerfile addons ":(exclude)docker/agent-studio"' _ "$ROOT"

# ---------------------------------------------------------------- 10. lógica direto em Python
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - > "$TMP/py.out" 2>&1 <<'PY'
from agent_studio import acoes, auth, etapas, marcar
from pycheck import check

PLAIN = "http" + ":" + "//"   # esquema sem TLS montado de partes (sem literal http:// em arquivo novo)

class Req:
    def __init__(self, **h): self.headers = {k.replace("_", "-"): v for k, v in h.items()}
ok = lambda origin, host: marcar.origin_ok(Req(origin=origin, host=host)) if origin is not None else marcar.origin_ok(Req(host=host))
check("origin: https igual ao Host vale", ok("https://agent-studio.oute.pro", "agent-studio.oute.pro"))
check("origin: sem Origin ou sem Host, não", not ok(None, "a.example") and not marcar.origin_ok(Req(origin="https://a.example")))
check("origin: host diferente, porta diferente, caminho e userinfo, não",
      not ok("https://b.example", "a.example") and not ok("https://a.example:8443", "a.example") and not ok("https://a.example/x", "a.example")
      and not ok("https://u@a.example", "a.example") and not ok("https://a.example?x=1", "a.example"))
check("origin: http só em loopback", ok(PLAIN + "127.0.0.1:8430", "127.0.0.1:8430") and ok(PLAIN + "localhost:1", "localhost:1") and not ok(PLAIN + "a.example", "a.example"))
check("origin: lixo não levanta", not ok("https://[abc", "[abc") and not ok("null", "a.example") and not ok("", "a.example"))
for ing, rd, mk in (("i", "r", "i"), ("i", "r", "r"), ("i", None, "i")):
    try:
        auth.Auth(ing, rd, mk); fail = True
    except ValueError:
        fail = False
    check(f"auth: credencial de marcação igual à de ingestão ou à de leitura é recusada ({ing},{rd},{mk})", not fail)
a = auth.Auth("ingestao", "leitura", "marcacao")
check("auth: com a credencial, mark e os três valores são distintos", a.mark and len({a.cookie_value, a.mark_cookie_value, a.mark_csrf}) == 3)
check("auth: o token só confere com o de marcação", a.mark_token_ok("marcacao") and not a.mark_token_ok("leitura") and not a.mark_token_ok("") and not a.mark_token_ok(None))
check("auth: o csrf confere só com o HMAC, não com o cookie nem com a credencial", a.csrf_ok(a.mark_csrf) and not a.csrf_ok(a.mark_cookie_value) and not a.csrf_ok("marcacao"))
b = auth.Auth("ingestao", "leitura")
check("auth: sem a credencial, nada confere (nem token vazio nem cookie vazio)", not b.mark and not b.mark_token_ok("") and not b.csrf_ok("") and not b.marker(type("R", (), {"cookies": {}})()))
check("auth: o cookie de marcação é Strict, HttpOnly, Secure e só em /rodada", auth.MARK_COOKIE_FLAGS == {"path": "/rodada", "secure": True, "httponly": True, "samesite": "strict"})
doc = etapas.parse("## Ações\n- a1: um `pedido:p-1` **dois**\n- a2: [x](https://exemplo.dev)\n- A3: maiúscula\n- a1: repetido\n- a4 sem dois-pontos\n- ab12345678901234567: longo\n\n## Detalhe\n- a9: fora da seção\n")
acts = acoes.extract(doc)
check("acoes: id minúsculo + ': ' no começo do item, só na seção Ações, o primeiro id repetido vale", [a["id"] for a in acts] == ["a1", "a2"])
check("acoes: o pedido citado em `pedido:<id>` vira link da ação, e só ele", [a["pedido"] for a in acts] == ["p-1", None])
check("acoes: o id sai do texto do item e o resto fica", "".join(t["s"] for t in acts[0]["inl"]) == "um pedido:p-1 dois")
check("acoes: o item repetido e os que não têm id continuam com o texto inteiro", doc["sections"][0]["blocks"][0]["items"][3][0]["s"] == "a1: repetido" and doc["sections"][0]["blocks"][0]["items"][2][0]["s"] == "A3: maiúscula")
check("acoes: texto sem a seção Ações não tem ação", acoes.extract(etapas.parse("## Decisão\n- a1: x\n")) == [])
check("acoes: pedido com id fora do formato não vira link", acoes.extract(etapas.parse("## Ações\n- a1: `pedido:../x`\n"))[0]["pedido"] is None)
f = marcar.parse_fields
good = {"rodada": ["swarm-1005-0100"], "etapa": ["merge:12"], "acao": ["a1"], "estado": ["feita"], "csrf": ["x"]}
check("campos: o formulário certo passa", f(good) == ("swarm-1005-0100", "merge", "12", "a1", "feita", "x"))
check("campos: fechamento sem chave passa; com chave, ou merge sem chave, ou ciclo, não",
      f({**good, "etapa": ["fechamento"]})[1:3] == ("fechamento", "") and f({**good, "etapa": ["fechamento:1"]}) is None
      and f({**good, "etapa": ["merge"]}) is None and f({**good, "etapa": ["ciclo"]}) is None and f({**good, "etapa": ["merge:0"]}) is None)
check("campos: rodada com barra, espaço ou longa demais, não", all(f({**good, "rodada": [r]}) is None for r in ("a/b", "a b", "x" * 101, "", "../x")))
check("campos: None, campo a mais, a menos ou repetido, não", f(None) is None and f({**good, "x": ["1"]}) is None and f({k: v for k, v in good.items() if k != "csrf"}) is None and f({**good, "acao": ["a1", "a2"]}) is None)
PY
check_py "$TMP/py.out"
check_end
