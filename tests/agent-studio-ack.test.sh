#!/usr/bin/env bash
# Testes do ack ("visto") de alerta e de decisão pendente pela tela (#537, ADR-08 §10, adendo do ack): `POST /ack` com a
# credencial de marcação (cookie, Origin, csrf), a tabela `ack_marks` só de acréscimo e separada da `action_marks`, o `ack`
# derivado no SurrealDB, o `rebuild-state` (linha `vistos:`), a validade de 24 h por ocorrência e o item que sai da faixa
# e volta quando a ocorrência muda. Sem a credencial a rota não existe; a de leitura (a do agente) nunca marca. Sem Docker;
# o SurrealDB é o binário fixado de tests/lib/surreal.sh. Todas as credenciais são sorteadas na hora.
# Uso: tests/agent-studio-ack.test.sh   (sai != 0 se algum caso falhar)
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
#   fila do exporter studio_logs alta desde há 10 min (alerta `queue`, não recolhe por tempo)
#   r-parada: rodada aberta há 60 min, sem evento (alerta `round_stalled`)
#   r-pergunta: aberta há 20 min, perguntada há 10 min (decisão pendente; ainda não é rodada parada)
NOW="$(date +%s)"
READ_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
MARK_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
ECO="eco-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
# lote <arquivo> <segundo> <tipo> [args]: grava um lote de exemplo em $TMP
lote() {
  local file="$1"; shift
  PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP/$file" "$@" <<'PY'
import json, sys
from otlp_json import event, queue_metrics, rl
out, t, kind, args = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
RES = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "human"}
if kind == "fila":
    doc = queue_metrics("oute-server", t, int(args[0]))
elif kind == "pergunta":
    doc = {"resourceLogs": [rl(RES, [event(t, "oute.swarm.round.asked", args[1], {"oute.swarm.round": args[0]}, args[2])])]}
else:
    sw = lambda mins, name, rnd, n, body=None: event(t - mins * 60, name, f"ack-{n}", {"oute.swarm.round": rnd}, body)
    doc = {"resourceLogs": [rl(RES, [sw(60, "oute.swarm.round.opened", "r-parada", 1), sw(20, "oute.swarm.round.opened", "r-pergunta", 2),
                                     sw(10, "oute.swarm.round.asked", "r-pergunta", 3, "pergunta um")])]}
json.dump(doc, open(out, "w"))
PY
  return $?
}
lote rodadas.json "$NOW" rodadas
lote fila-velha.json "$((NOW - 600))" fila 800
lote fila-agora.json "$((NOW - 5))" fila 800
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
JS_=(-H 'Accept: application/json')
# ack <cabeçalho Cookie ou vazio> <Origin ou vazio> <corpo> [curl…]: POST /ack; imprime o código HTTP e deixa o corpo em $TMP/resp
ack() {
  local cookie="$1" origin="$2" body="$3"; shift 3
  curl -s -o "$TMP/resp" -w '%{http_code}' -X POST ${cookie:+-H "$cookie"} ${origin:+-H "Origin: $origin"} \
    -H 'Content-Type: application/x-www-form-urlencoded' --data "$body" "$@" "$STUDIO_URL/ack"
  return $?
}
# tela <arquivo> [cabeçalho Cookie]: a página /conversas inteira (com as faixas) em $TMP/<arquivo>
tela() {
  local file="$1" cookie="${2-$MC_}"
  curl -s -H "$cookie" "$STUDIO_URL/conversas?full=1" > "$TMP/$file"
  return $?
}
# faixa <arquivo>: JSON do que a página mostra: itens na faixa, nos vistos e com formulário
faixa() {
  local file="$1"
  python3 "$ROOT/tests/lib/html-data.py" < "$TMP/$file" | jq -c '{
    alertas: [.[] | select(has("alerta")) | .alerta] | sort, decisoes: [.[] | select(has("decisao")) | .decisao] | sort,
    contagem: ([.[] | select(.tag == "section" and has("alertas")) | .alertas] | first),
    vistos: [.[] | select(has("visto"))] | length, formularios: [.[] | select(has("ack-form"))] | length,
    entrar: ([.[] | select(has("ack-entrar"))] | length), indisponivel: ([.[] | select(has("ack-indisponivel"))] | length)}'
  return $?
}
# corpo <arquivo> <atributo do <li>> <valor>: o corpo do formulário do ack daquele item, como o navegador o envia
corpo() {
  local file="$1" attr="$2" value="$3"
  python3 - "$TMP/$file" "$attr" "$value" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode
path, attr, value = sys.argv[1:4]
class P(HTMLParser):
    inside, form, found = False, None, None
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "li":
            self.inside = a.get(attr) == value
        elif tag == "form" and self.inside and a.get("action") == "/ack" and self.found is None:
            self.form = []
        elif tag == "input" and self.form is not None:
            self.form.append((a.get("name"), a.get("value") or ""))
    def handle_endtag(self, tag):
        if tag == "form" and self.form is not None:
            self.found, self.form = self.form, None
p = P(); p.feed(open(path, encoding="utf-8").read())
print(urlencode(p.found or []))
PY
  return $?
}
# troca <corpo> <campo> <valor>: o mesmo corpo com um campo trocado
troca() {
  local body="$1" field="$2" value="$3"
  python3 -c 'import sys; from urllib.parse import parse_qsl, urlencode; print(urlencode([(k, sys.argv[3] if k == sys.argv[2] else v) for k, v in parse_qsl(sys.argv[1], keep_blank_values=True)]))' "$body" "$field" "$value"
  return $?
}

# ---------------------------------------------------------------- 1. sem a credencial de marcação a rota não existe
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
check "ingestão das rodadas" test "$(post logs "$TMP/rodadas.json")" = 200
check "ingestão da fila (há 10 min)" test "$(post metrics "$TMP/fila-velha.json")" = 200
check "ingestão da fila (agora)" test "$(post metrics "$TMP/fila-agora.json")" = 200
O="$STUDIO_URL"
FAKE="alvo=$(printf 'a%.0s' {1..32})&desde=2026-10-06T00:00:00Z&visto=1&voltar=/&csrf=x"
check "sem credencial de marcação: POST /ack = 404 (não existe), mesmo com cookie e Origin" test "$(ack "$RC_" "$O" "$FAKE")" = 404
tela sem.html "$RC_"
check "sem credencial de marcação: a faixa mostra os dois alertas e a decisão, sem formulário e sem convite" jqe '.alertas == ["queue", "round_stalled"] and .decisoes == ["r-pergunta"] and .formularios == 0 and .entrar == 0 and .vistos == 0' <<<"$(faixa sem.html)"
studio_stop

# ---------------------------------------------------------------- 2. quem pode: só o cookie de marcação
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_MARK_TOKEN="$MARK_T" || { cat "$TMP/s/stderr"; die "agent-studio (com marcação) não subiu"; }
O="$STUDIO_URL"
tela leitura.html "$RC_"
check "só com a leitura: os itens aparecem, sem formulário e sem csrf, com o convite para entrar" bash -c 'jq -e ".formularios == 0 and .entrar == 2 and (.alertas | length) == 2" <<<"$1" >/dev/null && ! grep -qF "$3" "$2"' _ "$(faixa leitura.html)" "$TMP/leitura.html" "$CSRF"
tela m1.html
check "com o cookie de marcação: um formulário por item (2 alertas e 1 decisão), sem convite" jqe '.formularios == 3 and .entrar == 0 and .indisponivel == 0 and .contagem == "2"' <<<"$(faixa m1.html)"
check "o trecho da faixa pedido à parte (/bloco/conversas/alertas) também traz o formulário" bash -c 'curl -s -H "$1" "$2/bloco/conversas/alertas" | grep -q "data-ack-form="' _ "$MC_" "$O"
FILA="$(corpo m1.html data-alerta queue)"; PARADA="$(corpo m1.html data-alerta round_stalled)"; DEC="$(corpo m1.html data-decisao r-pergunta)"
check "o formulário leva só alvo, desde, visto, voltar e csrf" test "$(python3 -c 'import sys; from urllib.parse import parse_qsl; print(",".join(k for k, _ in parse_qsl(sys.argv[1], keep_blank_values=True)))' "$FILA")" = "alvo,desde,visto,voltar,csrf"
check "o voltar do formulário é a tela de agora" bash -c 'grep -q "voltar=%2Fconversas\(&\|$\)" <<<"$1"' _ "$FILA"
check "sem credencial nenhuma: 401"                                 test "$(ack "" "$O" "$FILA")" = 401
check "com o cookie de leitura (o que o agente monta): 403"         test "$(ack "$RC_" "$O" "$FILA")" = 403
check "com o Bearer de leitura (o que o agente tem): 403"           test "$(ack "" "$O" "$FILA" "${RB_[@]}")" = 403
check "com o Bearer de ingestão: 401"                               test "$(ack "" "$O" "$FILA" -H "Authorization: Bearer $STUDIO_TOKEN")" = 401
check "o cookie de leitura no lugar do de marcação: 403"            test "$(ack "Cookie: agent_studio=$COOKIE_R; agent_studio_mark=$COOKIE_R" "$O" "$FILA")" = 403
check "cookie de marcação sem Origin: 403"                          test "$(ack "$MC_" "" "$FILA")" = 403
check "cookie de marcação com Origin de outro site: 403"            test "$(ack "$MC_" "https://outro-site.example" "$FILA")" = 403
check "csrf errado: 403"                                            test "$(ack "$MC_" "$O" "$(troca "$FILA" csrf "$COOKIE_M")")" = 403
check "campo a mais: 400, e nada do cliente na resposta"            bash -c '[ "$1" = 400 ] && [ "$(cat "$2")" = "{\"message\":\"campos inválidos\"}" ]' _ "$(ack "$MC_" "$O" "$FILA&nota=$ECO")" "$TMP/resp"
check "campo a menos: 400"                                          test "$(ack "$MC_" "$O" "${FILA%&csrf=*}")" = 400
check "alvo fora do formato: 400"                                   test "$(ack "$MC_" "$O" "$(troca "$FILA" alvo "$ECO")")" = 400
check "desde fora do formato: 400"                                  test "$(ack "$MC_" "$O" "$(troca "$FILA" desde ontem)")" = 400
check "visto que não é número: 400"                                 test "$(ack "$MC_" "$O" "$(troca "$FILA" visto 1e9)")" = 400
check "corpo acima de 4 KB: 413"                                    test "$(ack "$MC_" "$O" "$(troca "$FILA" voltar "/$(printf 'x%.0s' {1..5000})")")" = 413
check "JSON no lugar do formulário: 400"                            test "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$MC_" -H "Origin: $O" -H 'Content-Type: application/json' --data '{"alvo":"x"}' "$O/ack")" = 400
check "alvo que não está vigente: 400 (item inexistente)"           bash -c '[ "$1" = 400 ] && [ "$(cat "$2")" = "{\"message\":\"item inexistente\"}" ]' _ "$(ack "$MC_" "$O" "$(troca "$FILA" alvo "$(printf 'b%.0s' {1..32})")")" "$TMP/resp"
# formulário antigo: a página mostrou outra ocorrência (outro `desde`) e foi montada antes do começo da de agora
VELHO="$(troca "$(troca "$FILA" desde 2026-01-01T00:00:00Z)" visto "$(( (NOW - 3600) * 1000000000 ))")"
check "formulário antigo, de outra ocorrência: 409"                 bash -c '[ "$1" = 409 ] && [ "$(cat "$2")" = "{\"message\":\"a ocorrência mudou; recarregue a página\"}" ]' _ "$(ack "$MC_" "$O" "$VELHO")" "$TMP/resp"
check "visto no futuro: 409"                                        test "$(ack "$MC_" "$O" "$(troca "$FILA" visto "$(( (NOW + 86400) * 1000000000 ))")")" = 409
check "decisão com o desde de outra pergunta: 409, mesmo com a página montada agora" test "$(ack "$MC_" "$O" "$(troca "$DEC" desde 2026-01-01T00:00:00Z)")" = 409
check "depois das recusas: nenhum visto na tela e nenhum ack no SurrealDB (o DuckDB é conferido na seção 6)" bash -c '[ "$1" = 0 ] && [ "$2" = 0 ]' _ \
  "$(curl -s -H "$MC_" "$O/conversas?full=1" | grep -c 'data-visto=')" "$(sr 'SELECT count() FROM ack GROUP ALL' 2>/dev/null | jq -r 'try .[0].count // 0')"

# ---------------------------------------------------------------- 3. o ack: o item sai da faixa, por 24 h, sem mexer no resto
check "ack do alerta da fila: 200" test "$(ack "$MC_" "$O" "$FILA" "${JS_[@]}")" = 200
cp "$TMP/resp" "$TMP/ack1.json"
check "a resposta traz só o alvo, a hora do servidor, o prazo e novo = true" jqe --arg alvo "$(python3 -c 'import sys; from urllib.parse import parse_qs; print(parse_qs(sys.argv[1])["alvo"][0])' "$FILA")" \
  '(keys == ["alvo", "novo", "vale_ate", "visto_em"]) and .alvo == $alvo and .novo == true' < "$TMP/ack1.json"
check "o prazo é de 24 h contadas no servidor (vale_ate - visto_em)" test "$(python3 -c 'import json, sys
from datetime import datetime
d = json.load(open(sys.argv[1])); p = lambda s: datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
print(int((p(d["vale_ate"]) - p(d["visto_em"])).total_seconds()))' "$TMP/ack1.json")" = 86400
check "a hora do ack é a do servidor, não o visto do formulário"    bash -c 'v="$(jq -r .visto_em "$1")"; s="$(date -u -d "${v:0:19}Z" +%s)"; [ "$s" -ge "$2" ] && [ "$s" -le "$(( $(date +%s) + 1 ))" ]' _ "$TMP/ack1.json" "$NOW"
tela m2.html
check "a fila saiu da faixa: sobra a rodada parada (1 alerta) e a decisão; a fila está nos vistos" jqe '.alertas == ["round_stalled"] and .contagem == "1" and .decisoes == ["r-pergunta"] and .vistos == 1 and .formularios == 2' <<<"$(faixa m2.html)"
check "o visto continua consultável, com a hora e a validade, fora da seção da faixa" bash -c 'sed -n "/id=\"alertas-vistos\"/,/<\/details>/p" "$1" | grep -q "visto em .*, vale até " && ! sed -n "/<section class=\"alertas\"/,/<\/section>/p" "$1" | grep -q "data-visto="' _ "$TMP/m2.html"
tela m2-leitura.html "$RC_"
check "o ack vale para outro aparelho (só com a leitura): a fila também está fora da faixa" jqe '.alertas == ["round_stalled"] and .vistos == 1' <<<"$(faixa m2-leitura.html)"
check "o GET /v1/alerts não muda: a fila segue lá, sem campo novo"  jqe '([.alerts[].type] | sort) == ["queue", "round_stalled"] and (.alerts[0] | keys) == ["evidence", "host", "instance", "limit", "since", "type", "unit", "value"]' <<<"$(curl -s "${RB_[@]}" "$O/v1/alerts")"
check "o GET /v1/tray não muda: a fila e a decisão seguem lá"      jqe '([.alerts[].type] | index("queue")) != null and ([.decisions.pending[].round] == ["r-pergunta"])' <<<"$(curl -s "${RB_[@]}" "$O/v1/tray")"
check "repetir o mesmo envio: 200, novo = false e o mesmo prazo (não renova)" bash -c '[ "$1" = 200 ] && jq -e --slurpfile a "$3" ".novo == false and .vale_ate == \$a[0].vale_ate and .visto_em == \$a[0].visto_em" "$2" >/dev/null' _ "$(ack "$MC_" "$O" "$FILA" "${JS_[@]}")" "$TMP/resp" "$TMP/ack1.json"
check "ack da decisão pelo formulário (sem JSON): 303 de volta para a tela" bash -c 'st="$(curl -s -o /dev/null -D "$5" -w "%{http_code}" -X POST -H "$2" -H "Origin: $1" -H "Content-Type: application/x-www-form-urlencoded" --data "$3" "$1/ack")"; [ "$st" = 303 ] && tr -d "\r" < "$5" | grep -qix "location: $4"' _ "$O" "$MC_" "$DEC" "/conversas" "$TMP/h.txt"
check "voltar para fora do servidor não vale (vai para a raiz)"     bash -c 'curl -s -o /dev/null -D - -X POST -H "$2" -H "Origin: $1" -H "Content-Type: application/x-www-form-urlencoded" --data "$3" "$1/ack" | tr -d "\r" | grep -qix "location: /"' _ "$O" "$MC_" "$(troca "$DEC" voltar "https://outro-site.example/")"
tela m3.html
check "a decisão saiu da faixa e está nos vistos; a rodada parada segue" jqe '.decisoes == [] and .alertas == ["round_stalled"] and .vistos == 2 and .formularios == 1' <<<"$(faixa m3.html)"

# ---------------------------------------------------------------- 4. a ocorrência muda: o item volta, e o formulário antigo não vale
T1="$(date +%s)"
lote pergunta2.json "$T1" pergunta r-pergunta ack-4 "pergunta dois"
check "ingestão da pergunta nova na mesma rodada" test "$(post logs "$TMP/pergunta2.json")" = 200
tela m4.html
check "pergunta nova: a decisão volta à faixa, sem herdar o ack da anterior" jqe '.decisoes == ["r-pergunta"] and .vistos == 1' <<<"$(faixa m4.html)"
check "o formulário antigo da decisão não reconhece a pergunta nova: 409" test "$(ack "$MC_" "$O" "$DEC")" = 409
# a fila se recupera e falha de novo, depois do ack: outra ocorrência do mesmo alvo
sleep 1; BAIXA="$(date +%s)"; sleep 1; ALTA="$(date +%s)"
lote fila-baixa.json "$BAIXA" fila 10; lote fila-alta.json "$ALTA" fila 900
check "ingestão da recuperação e da nova falha da fila" test "$(post metrics "$TMP/fila-baixa.json")$(post metrics "$TMP/fila-alta.json")" = 200200
tela m5.html
check "recuperação e nova falha: a fila volta à faixa, sem o ack antigo" jqe '.alertas == ["queue", "round_stalled"] and .contagem == "2" and .vistos == 0' <<<"$(faixa m5.html)"
check "o formulário antigo da fila não reconhece a ocorrência nova: 409" test "$(ack "$MC_" "$O" "$FILA")" = 409
check "o formulário novo reconhece a ocorrência nova: 200 e novo = true" bash -c '[ "$1" = 200 ] && jq -e ".novo == true" "$2" >/dev/null' _ "$(ack "$MC_" "$O" "$(corpo m5.html data-alerta queue)" "${JS_[@]}")" "$TMP/resp"
# o valor oscila dentro da mesma condição (segue acima do limite): a mesma ocorrência, o ack continua
sleep 1
lote fila-oscila.json "$(date +%s)" fila 700
check "ingestão da fila oscilando acima do limite" test "$(post metrics "$TMP/fila-oscila.json")" = 200
tela m6.html
check "valor que oscila na mesma condição não cria ocorrência nova: a fila segue fora da faixa" jqe '.alertas == ["round_stalled"] and .vistos == 1' <<<"$(faixa m6.html)"

# ---------------------------------------------------------------- 5. 2xx só depois do commit: SurrealDB fora = 503 e nada fica
N_ANTES="$(sr 'SELECT count() FROM ack GROUP ALL' | jq -r '.[0].count')"
surreal_stop
check "SurrealDB fora: POST /ack = 503, com Retry-After e sem a causa" bash -c 'st="$(curl -s -o "$2" -w "%{http_code}" -D "$6" -X POST -H "$3" -H "Origin: $4" -H "Content-Type: application/x-www-form-urlencoded" --data "$5" "$1/ack")"; [ "$st" = 503 ] && grep -qi "^retry-after:" "$6" && [ "$(cat "$2")" = "{\"message\":\"gravação falhou; tente de novo\"}" ]' _ "$O" "$TMP/resp" "$MC_" "$O" "$PARADA" "$TMP/h.txt"
tela fora.html
check "SurrealDB fora: todos os itens ficam visíveis, com o aviso e sem formulário" jqe '.alertas == ["queue", "round_stalled"] and .decisoes == ["r-pergunta"] and .vistos == 0 and .formularios == 0 and .indisponivel == 2' <<<"$(faixa fora.html)"
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não voltou"; }
check "SurrealDB de volta: o ack recusado não entrou (a rodada parada segue na faixa)" bash -c 'jq -e ".alertas == [\"round_stalled\"]" <<<"$1" >/dev/null && [ "$2" = "$3" ]' _ "$(tela volta.html; faixa volta.html)" "$(sr 'SELECT count() FROM ack GROUP ALL' | jq -r '.[0].count')" "$N_ANTES"
check "o stderr do servidor não tem a credencial de marcação, o csrf, o cookie nem o texto do cliente" bash -c '! grep -qF -e "$2" -e "$3" -e "$4" -e "$5" "$1"' _ "$TMP/s/stderr" "$MARK_T" "$CSRF" "$COOKIE_M" "$ECO"
studio_stop

# ---------------------------------------------------------------- 6. ack_marks: só de acréscimo, separada, escrita só pela rota
DB="$TMP/s/db.duckdb"
studio_sql "$DB" "SELECT target, kind, identity, since, rule, acked_unix_nano, expires_unix_nano, acked_by FROM ack_marks ORDER BY acked_unix_nano" > "$TMP/acks.jsonl"
check "DuckDB: três acks, na ordem (fila, decisão, fila de novo); nada das recusas nem da repetição" test "$(jq -sc '[.[].kind]' "$TMP/acks.jsonl")" = '["alerta","decisao","alerta"]'
check "DuckDB: cada linha leva o alvo, a versão, a hora do servidor (crescente), o prazo de 24 h e by = human" jqe -s 'all(.[]; .acked_by == "human" and (.expires_unix_nano - .acked_unix_nano) == 86400000000000 and (.target | test("^[0-9a-f]{32}$")) and (.since | test("Z$")) and (.rule | length) > 0) and ([.[].acked_unix_nano] | . == sort and (unique | length) == length) and .[0].target == .[2].target and .[0].since != .[2].since and (.[0].identity | fromjson | .[0:4]) == ["alerta", "queue", "oute-server", "oute-agent"]' < "$TMP/acks.jsonl"
check "o ack não escreveu em action_marks" test "$(studio_sql "$DB" "SELECT count(*) AS n FROM action_marks" | jq -r .n)" = 0
check "o código nunca faz UPDATE, DELETE, DROP nem TRUNCATE em ack_marks" bash -c '! grep -rnEi --include="*.py" --include="*.html" "(UPDATE|DELETE( FROM)?|DROP TABLE|TRUNCATE( TABLE)?)[^;\"]{0,40}ack_marks" "$1/docker/agent-studio"' _ "$ROOT"
check "só o acks.py escreve em ack_marks (INSERT) e só a rota chama o acks.append" bash -c 'cd "$1/docker/agent-studio/agent_studio" && [ "$(grep -rlE --include="*.py" "INSERT[^\"]*ack_marks" . | tr -d "\n")" = "./acks.py" ] && [ "$(grep -rlE --include="*.py" "acks(_mod)?\.append" . | tr -d "\n")" = "./marcar.py" ]' _ "$ROOT"
check "a ingestão e o replay (otlp, app, replay) não mencionam ack_marks nem o módulo do ack" bash -c 'cd "$1/docker/agent-studio/agent_studio" && ! grep -nE "ack_marks|acks" otlp.py replay.py && ! grep -n "ack_marks" app.py && [ "$(grep -c "acks_mod.create" store.py)" = 1 ]' _ "$ROOT"
check "a marca não vira evento: o módulo do ack e a rota não chamam o oute-emit nem montam OTLP" bash -c 'cd "$1/docker/agent-studio/agent_studio" && ! grep -nE "oute-emit|otlp|resourceLogs" acks.py && ! grep -nE "oute-emit|resourceLogs" marcar.py' _ "$ROOT"

# ---------------------------------------------------------------- 7. o prazo vence: marca de 25 h atrás não tira o item da faixa
# uma linha direto no DuckDB (com o serviço parado), como se o ack da rodada parada tivesse sido dado há 25 h: o prazo de
# 24 h venceu há 1 h. O rebuild-state a leva ao SurrealDB com o prazo da linha, sem renovar.
read -r ALVO_P DESDE_P < <(python3 -c 'import sys; from urllib.parse import parse_qs; q = parse_qs(sys.argv[1]); print(q["alvo"][0], q["desde"][0])' "$PARADA")
"$STUDIO_PY" - "$DB" "$ALVO_P" "$DESDE_P" "$NOW" <<'PY'
import sys, duckdb
db, target, since, now = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
acked = (now - 25 * 3600) * 10**9
con = duckdb.connect(db)
con.execute("INSERT INTO ack_marks VALUES (?, 'alerta', '[\"alerta\",\"round_stalled\"]', ?, 'seconds:1800', ?, ?, 'human')", [target, since, acked, acked + 24 * 3600 * 10**9])
con.close()
PY
snap() { local out="$1"; sr "SELECT * FROM ack ORDER BY id" > "$out"; return $?; }
snap "$TMP/ack-1.json"
REB=(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio.rebuild_state)
surreal_stop; rm -rf "${TMP:?}/sdb/data"; surreal_start "$TMP/sdb" || die "SurrealDB não voltou"
check "SurrealDB esvaziado: sem ack"                                test "$(sr 'SELECT count() FROM ack GROUP ALL' 2>/dev/null | jq -r 'try .[0].count // 0')" = 0
OUT="$("${REB[@]}" 2>"$TMP/err")"; RC=$?
check "rebuild-state: rc 0 e o stderr vazio"                        bash -c '[ "$1" = 0 ] && [ ! -s "$2" ]' _ "$RC" "$TMP/err"
check "rebuild-state: lê as quatro marcas e remonta três acks (fila, decisão e rodada parada)" has_line "vistos: marcas=4 antes=0 depois=3"
check "rebuild-state: as três linhas de antes seguem como eram, mais o vistos e o fases (cinco linhas)"     bash -c 'grep -qE "^antes: rodadas=[0-9]+ workers=[0-9]+ sessoes=[0-9]+ pedidos=[0-9]+ conversas=[0-9]+ etapas=[0-9]+ acoes=0$" <<<"$1" && grep -qE "^lidas: logs=[0-9]+ spans=0 marcas=0$" <<<"$1" && grep -qE "^depois: .* acoes=0$" <<<"$1" && grep -qE "^fases: conversas=[0-9]+$" <<<"$1" && [ "$(wc -l <<<"$1")" = 5 ]' _ "$OUT"
check "o ack remontado da fila e da decisão é igual ao que a rota gravou (a marca mais nova vence; o prazo não muda)" bash -c 'jq -e --slurpfile a "$1" "[.[] | select(.target != \$t)] == \$a[0]" --arg t "$3" "$2" >/dev/null' _ "$TMP/ack-1.json" <(sr "SELECT * FROM ack ORDER BY id") "$ALVO_P"
check "o prazo remontado da marca vencida é o da linha (não renova)" test "$(sr "SELECT expires_ns FROM ack WHERE acked_ns < $(( (NOW - 24 * 3600) * 1000000000 ))" | jq -r '.[0].expires_ns')" = "$(( (NOW - 3600) * 1000000000 ))"
OUT="$(AGENT_STUDIO_REBUILD_CHUNK=1 "${REB[@]}" 2>&1)"; RC=$?
check "rebuild-state de novo, em blocos de 1 linha: rc 0 e o mesmo estado (idempotente)" bash -c '[ "$1" = 0 ] && grep -qx "vistos: marcas=4 antes=3 depois=3" <<<"$2"' _ "$RC" "$OUT"
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_MARK_TOKEN="$MARK_T" || { cat "$TMP/s/stderr"; die "agent-studio não voltou"; }
O="$STUDIO_URL"
tela m7.html
check "depois do rebuild: a fila segue vista, e a rodada parada com ack vencido está na faixa, com formulário" bash -c 'jq -e ".alertas == [\"round_stalled\"] and .vistos == 1" <<<"$1" >/dev/null && [ -n "$2" ]' _ "$(faixa m7.html)" "$(corpo m7.html data-alerta round_stalled)"
check "vencido o prazo, um novo ack explícito vale: 200 e novo = true" bash -c '[ "$1" = 200 ] && jq -e ".novo == true" "$2" >/dev/null' _ "$(ack "$MC_" "$O" "$(corpo m7.html data-alerta round_stalled)" "${JS_[@]}")" "$TMP/resp"
tela m8.html
check "a rodada parada sai da faixa: nenhum alerta aberto, dois vistos" jqe '.alertas == [] and .vistos == 2' <<<"$(faixa m8.html)"
studio_stop
# sem SurrealDB configurado a tela não lê as marcas: tudo na faixa, sem botão e sem o aviso de falha
studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" AGENT_STUDIO_READ_TOKEN="$READ_T" AGENT_STUDIO_MARK_TOKEN="$MARK_T" || { cat "$TMP/s/stderr"; die "agent-studio (sem SurrealDB) não subiu"; }
tela m9.html
check "sem SurrealDB configurado: os itens ficam todos na faixa, sem formulário, sem vistos e sem aviso" jqe '.alertas == ["queue", "round_stalled"] and .vistos == 0 and .formularios == 0 and .indisponivel == 0 and .entrar == 0' <<<"$(faixa m9.html)"
studio_stop

# ---------------------------------------------------------------- 8. lógica direto em Python
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - > "$TMP/py.out" 2>&1 <<'PY'
import copy
from agent_studio import acks, marcar, state
from pycheck import check

H = 3600 * 10**9
def alert(kind="queue", host="oute-server", value=0.8, since="2026-10-06T10:00:00Z", limit=0.5, unit="ratio", **ev):
    return {"type": kind, "host": host, "instance": "oute-agent", "value": value, "unit": unit, "limit": limit, "since": since, "evidence": ev}
a = acks.alert_item(alert(exporter="e1"))
check("alvo: 32 hex e a identidade em JSON", acks.TARGET.match(a["target"]) and a["identity"].startswith('["alerta","queue","oute-server","oute-agent","e1"'))
check("alvo: o valor e o since não entram (oscilar não muda o alvo)", acks.alert_item(alert(exporter="e1", value=0.99, since="2026-10-06T11:00:00Z"))["target"] == a["target"])
check("alvo: exporter, host ou tipo diferente = outro alvo", len({a["target"], acks.alert_item(alert(exporter="e2"))["target"],
      acks.alert_item(alert(exporter="e1", host="mac"))["target"], acks.alert_item(alert("destination_refusing", exporter="e1"))["target"]}) == 4)
q = lambda agent, attrs: acks.alert_item(alert("quota", unit="pct", limit=98, agent=agent, attributes=attrs))["target"]
check("alvo: cota por agente e por janela", len({q("claude", '{"oute.quota.window":"5h"}'), q("claude", '{"oute.quota.window":"7d"}'), q("codex", '{"oute.quota.window":"5h"}')}) == 3)
check("alvo: rodada parada e rodada antiga são alvos diferentes (o agravamento pede novo ack)",
      acks.alert_item(alert("round_stalled", round="r1"))["target"] != acks.alert_item(alert("round_old", round="r1"))["target"])
check("alvo: cada troca de preço é um alvo", acks.alert_item(alert("price_changed", model="m", field="input", changed_at="2026-10-01T00:00:00Z"))["target"]
      != acks.alert_item(alert("price_changed", model="m", field="input", changed_at="2026-10-02T00:00:00Z"))["target"])
d = {"round": "r1", "host": "oute-server", "instance": "oute-agent", "question": "x", "asked_at": "2026-10-06T10:00:00Z", "age_seconds": 5}
di = acks.decision_item(d)
check("alvo: decisão por host, instância e rodada; a versão é a hora da pergunta", di["since"] == d["asked_at"] and di["kind"] == "decisao"
      and acks.decision_item({**d, "question": "y", "asked_at": "2026-10-06T11:00:00Z"})["target"] == di["target"]
      and acks.decision_item({**d, "round": "r2"})["target"] != di["target"] and di["target"] != a["target"])
T = acks.since_ns("2026-10-06T12:00:00Z")
check("since_ns: só o formato do /v1/alerts", T == 1791288000 * 10**9 and acks.since_ns("2026-10-06 12:00:00") is None and acks.since_ns(None) is None and acks.since_ns("2026-13-40T99:00:00Z") is None)
mark = lambda since="2026-10-06T10:00:00Z", rule="ratio:0.5", acked=T: {"since": since, "rule": rule, "acked_ns": acked, "expires_ns": acked + acks.TTL_NS}
check("validade: 23 h depois ainda vale; 25 h depois não (o prazo é de 24 h)", acks.valid(mark(), a, T + 23 * H) and not acks.valid(mark(), a, T + 25 * H))
check("validade: o since andou mas segue antes do ack (janela de lookback): a mesma ocorrência",
      acks.valid(mark(), acks.alert_item(alert(exporter="e1", since="2026-10-06T11:30:00Z")), T + H))
check("validade: since depois do ack (recuperou e falhou de novo): ocorrência nova, sem ack",
      not acks.valid(mark(), acks.alert_item(alert(exporter="e1", since="2026-10-06T12:30:00Z")), T + H))
check("validade: a regra mudou (outro limite): sem ack", not acks.valid(mark(), acks.alert_item(alert(exporter="e1", limit=0.7)), T + H))
check("validade: alerta sem since não prova continuidade", not acks.valid(mark(), acks.alert_item(alert(exporter="e1", since=None)), T + H)
      and not acks.valid(mark(since=""), a, T + H))
check("validade: decisão só com a mesma pergunta, mesmo que a nova seja anterior ao ack",
      acks.valid(mark(rule="pergunta"), di, T + H) and not acks.valid(mark(rule="pergunta"), acks.decision_item({**d, "asked_at": "2026-10-06T11:00:00Z"}), T + H))
check("validade: sem marca, ou marca sem os campos, não vale", not acks.valid(None, a, T) and not acks.valid({}, a, T) and not acks.valid({"since": a["since"], "rule": a["rule"], "acked_ns": "x", "expires_ns": 1}, a, T))
items = [alert(exporter="e1"), alert(exporter="e2")]
before = copy.deepcopy(items)
marks = {a["target"]: {**mark(), "acked_at": "2026-10-06T12:00:00Z", "expires_at": "2026-10-07T12:00:00Z"}}
shown, seen = acks.split(items, acks.alert_item, marks, T + H)
check("split: o item com ack válido vai para os vistos, com a hora e o prazo; o outro fica", [s["evidence"]["exporter"] for s in shown] == ["e2"]
      and [s["evidence"]["exporter"] for s in seen] == ["e1"] and seen[0]["ack"]["expires_at"] == "2026-10-07T12:00:00Z" and shown[0]["ack"]["can"])
check("split: não muda os alertas recebidos (o cache do /v1/alerts)", items == before and "ack" not in items[0])
check("split: marcas não lidas (None ou False) deixam tudo na faixa; cálculo que falhou (None) passa como está",
      acks.split(items, acks.alert_item, None, T)[1] == [] and len(acks.split(items, acks.alert_item, False, T)[0]) == 2 and acks.split(None, acks.alert_item, marks, T) == (None, []))
check("split: item sem since não tem botão", acks.split([alert(exporter="e1", since=None)], acks.alert_item, {}, T)[0][0]["ack"]["can"] is False)
f = marcar.parse_ack
good = {"alvo": ["a" * 32], "desde": ["2026-10-06T10:00:00Z"], "visto": ["123"], "voltar": ["/conversas"], "csrf": ["x"]}
check("campos: o formulário certo passa", f(good) == ("a" * 32, "2026-10-06T10:00:00Z", 123, "/conversas", "x"))
check("campos: alvo maiúsculo, curto ou longo, não", all(f({**good, "alvo": [v]}) is None for v in ("A" * 32, "a" * 31, "a" * 33, "", "a" * 31 + "\n")))
check("campos: desde sem Z, com fração ou vazio, não", all(f({**good, "desde": [v]}) is None for v in ("2026-10-06T10:00:00", "2026-10-06T10:00:00.5Z", "")))
check("campos: visto negativo, vazio ou com 21 dígitos, não", all(f({**good, "visto": [v]}) is None for v in ("-1", "", "1" * 21, "1.0")))
check("campos: voltar acima de 1024, None, campo a mais, a menos ou repetido, não", f({**good, "voltar": ["/" + "x" * 1024]}) is None and f(None) is None
      and f({**good, "x": ["1"]}) is None and f({k: v for k, v in good.items() if k != "csrf"}) is None and f({**good, "alvo": ["a" * 32, "b" * 32]}) is None)
row = {"target": "a" * 32, "kind": "alerta", "identity": "[]", "since": "2026-10-06T10:00:00Z", "rule": "ratio:0.5", "acked_unix_nano": T, "expires_unix_nano": T + acks.TTL_NS, "acked_by": "human"}
st = state.ack_statements(row)
check("estado: a linha vira um statement com o prazo da linha", len(st) == 1 and st[0][1]["id"] == ["a" * 32] and st[0][1]["ns"] == T and st[0][1]["x"] == T + acks.TTL_NS)
check("estado: linha fora do formato (alvo, tipo, since ou regra) não vira estado",
      all(state.ack_statements({**row, k: v}) == [] for k, v in (("target", "x"), ("target", None), ("kind", "outro"), ("since", ""), ("rule", ""))))
import duckdb
con = duckdb.connect()
check("rebuild: banco anterior à #537 (sem a tabela ack_marks) não tem marca para ler e não levanta", list(acks.rows(con, 10)) == [])
acks.create(con)
r1 = acks.append(con, a); r2 = acks.append(con, a)
check("append: a hora cresce sempre e a marca mais nova do alvo é a última", r2["acked_unix_nano"] > r1["acked_unix_nano"] and acks.last(con, a["target"]) == r2
      and acks.last(con, "f" * 32) is None and [len(b) for b in acks.rows(con, 1)] == [1, 1])
PY
check_py "$TMP/py.out"
check_end
