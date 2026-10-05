#!/usr/bin/env bash
# Testes do histórico de rodadas do agent-studio (#601, ADR-08 "Página da rodada e do ciclo"): `GET /rodadas` lista toda
# rodada com `oute.swarm.round.opened`, pela ingestão de verdade (POST /v1/logs e /v1/traces): rodada com etapa, sem etapa
# publicada, sem evento de fechamento, antiga (fora da janela padrão), só com etapa (sem o evento de abertura) e a que não
# entra (só `session.spawned`). Mais o filtro de período (enviado como o navegador envia, tests/lib/studio_form.py), a
# paginação, o link para as sessões da rodada sem etapa e a lógica do `etapas.with_state` direto em Python. Sem Docker e sem
# SurrealDB: a lista sai dos eventos do DuckDB (o SurrealDB fora, com o aviso, está em tests/agent-studio-rodada.test.sh).
# Uso: tests/agent-studio-historico.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "${TMP:?}"' EXIT
studio_init

# ---------------------------------------------------------------- exemplo
# As horas ficam longe dos limites das janelas (24 h, 7 dias, 30 dias, 366 dias): nenhum caso depende do minuto em que roda.
# A (com etapa): abertura há 5 h, 2 sessões (uma com o `spawned` repetido), triagem e dois pedidos de merge (PR 31 e 32),
#    fechamento há 2 h.
# B (sem etapa): abertura há 8 h, 3 sessões, fechamento há 7 h. Uma conversa da sessão `tb` há 7 h 30.
# C (sem fechamento): abertura há 1 h, 1 sessão, nenhum `round.closed`.
# D (antiga): abertura há 40 dias, fechamento 1 h depois: fora de 24 h, de 7 dias e de 30 dias; dentro de 366 dias.
# E (só etapa): fechamento publicado há 6 h, sem o evento de abertura.
# F (não entra): só um `session.spawned`, há 3 h.
# G (em andamento na janela): abertura há 60 h, fechamento há 10 h, nenhum evento entre as 50 h e as 40 h.
# H (abertura além do máximo da tela): abertura há 400 dias, uma sessão há 12 h, sem fechamento.
# P01 a P21: só a abertura, há 20 dias e mais 1 a 21 horas (para a segunda página).
NOW="$(date +%s)"
A=swarm-0101-0001; B=swarm-0101-0002; C_=swarm-0101-0003; D=swarm-0901-0004; E=swarm-0101-0005; F=swarm-0101-0006
G=swarm-0101-0007; H=swarm-0801-0008
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" <<'PY'
import hashlib, json, sys
from otlp_json import event, rl, rs, span
tmp, NOW = sys.argv[1], int(sys.argv[2])
HOUR, DAY = 3600, 86400
res = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "claude"}
n = 0
def ev(t, name, rnd, **attrs):
    global n
    n += 1
    return event(t, name, f"ev-{n}", {"oute.swarm.round": rnd, **{k.replace("_", "."): v for k, v in attrs.items()}})
def opened(t, rnd, label=None):
    extra = {"oute.swarm.label": label} if label else {}
    return event(t, "oute.swarm.round.opened", f"op-{rnd}", {"oute.swarm.round": rnd, "oute.swarm.repo": "oute-agent", "oute.swarm.max": 4, **extra})
def spawned(t, rnd, slug):
    global n
    n += 1
    return event(t, "oute.swarm.session.spawned", f"sp-{n}", {"oute.swarm.round": rnd, "oute.swarm.session": slug, "oute.swarm.issue": int(slug.split("-")[0])})
def closed(t, rnd):
    return event(t, "oute.swarm.round.closed", f"cl-{rnd}", {"oute.swarm.round": rnd})
def step(t, rnd, kind, key=None):
    text = f"## Decisão\n1. etapa {kind} da rodada\n"
    attrs = {"oute.swarm.round": rnd, "oute.swarm.step.kind": kind, "oute.swarm.step.rev": 1,
             "oute.swarm.step.sha256": hashlib.sha256(text.encode()).hexdigest(), "oute.swarm.step.review": "aprovado",
             "oute.swarm.step.writer": "claude-sonnet-5-5", "oute.swarm.step.reviewer": "claude-opus-5-5", "oute.swarm.step.refcheck": "ausente"}
    if key: attrs["oute.swarm.step.key"] = key
    return event(t, "oute.swarm.step.published", f"st-{rnd}-{kind}-{key or ''}", attrs, text)
A, B, C, D, E, F, G, H = (f"swarm-{x}" for x in ("0101-0001", "0101-0002", "0101-0003", "0901-0004", "0101-0005", "0101-0006", "0101-0007", "0801-0008"))
logs = [opened(NOW - 5 * HOUR, A, "ready"), spawned(NOW - 5 * HOUR + 60, A, "31-um"), spawned(NOW - 5 * HOUR + 120, A, "32-dois"),
        spawned(NOW - 5 * HOUR + 130, A, "32-dois"), step(NOW - 4 * HOUR, A, "triagem"), step(NOW - 3 * HOUR, A, "merge", "31"),
        step(NOW - 3 * HOUR + 60, A, "merge", "32"), closed(NOW - 2 * HOUR, A),
        opened(NOW - 8 * HOUR, B), *[spawned(NOW - 8 * HOUR + 60 * i, B, f"4{i}-b{i}") for i in (1, 2, 3)], closed(NOW - 7 * HOUR, B),
        opened(NOW - 1 * HOUR, C), spawned(NOW - 1 * HOUR + 60, C, "51-c"),
        opened(NOW - 40 * DAY, D), spawned(NOW - 40 * DAY + 60, D, "61-d"), closed(NOW - 40 * DAY + HOUR, D),
        step(NOW - 6 * HOUR, E, "fechamento"),
        spawned(NOW - 3 * HOUR, F, "71-f"),
        opened(NOW - 60 * HOUR, G), closed(NOW - 10 * HOUR, G),
        opened(NOW - 400 * DAY, H), spawned(NOW - 12 * HOUR, H, "81-h"),
        *[opened(NOW - 20 * DAY - i * HOUR, f"swarm-0911-p{i:02d}") for i in range(1, 22)]]
json.dump({"resourceLogs": [rl(res, logs)]}, open(f"{tmp}/logs.json", "w"))
# conversas: a sessão `tb` é da rodada B, a `ta` da rodada A e a `solta` não tem rodada
call = lambda t: span("claude_code.llm_request", t, 2, {"model": "claude-sonnet-5", "input_tokens": 10, "output_tokens": 5, "session.id": f"c-{t}"})  # noqa: E731
json.dump({"resourceSpans": [rs({**res, "oute.task.id": "tb", "oute.swarm.round": B}, [call(NOW - 7 * HOUR - 1800)]),
                             rs({**res, "oute.task.id": "ta", "oute.swarm.round": A}, [call(NOW - 7 * HOUR - 1700)]),
                             rs({**res, "oute.task.id": "solta"}, [call(NOW - 7 * HOUR - 1600)])]}, open(f"{tmp}/traces.json", "w"))
PY

studio_start "$TMP/s" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
AUTH=(-H "Authorization: Bearer $STUDIO_TOKEN")
page() { local path="$1"; studio_page "${AUTH[@]}" "$STUDIO_URL$path"; return $?; }
rounds_of() { data | jq -c '[.[] | select(has("rodada")) | .rodada]'; return $?; }
row() { local rnd="$1" file="$2"; data < "$file" | jq -c --arg r "$rnd" '.[] | select(.rodada == $r)'; return $?; }
# a linha <tr> de uma rodada, com as células, numa linha só
tr_of() { local rnd="$1" file="$2"; tr '\n' ' ' < "$file" | grep -o "<tr data-rodada=\"$rnd\".*" | sed 's#</tr>.*##'; return $?; }
href_of() { local rnd="$1" file="$2"; tr_of "$rnd" "$file" | grep -o '<td class="prim"><a href="[^"]*"' | sed 's/.*href="//; s/"$//; s/&amp;/\&/g'; return $?; }
iso() { local secs="$1"; date -u -d "@$secs" +%Y-%m-%dT%H:%M:%SZ; return $?; }

# ---------------------------------------------------------------- 1. antes de qualquer evento
EMPTY="$(page /rodadas)"
check "sem evento: /rodadas 200 com a mensagem da janela" bash -c 'grep -q "data-sem-rodadas" <<<"$1" && grep -q "Nenhuma rodada nessa janela" <<<"$1"' _ "$EMPTY"
check "ingestão: logs = 200"                            test "$(post logs "$TMP/logs.json")" = 200
check "ingestão: traces = 200"                          test "$(post traces "$TMP/traces.json")" = 200

# ---------------------------------------------------------------- 2. a lista na janela padrão (24 h)
page /rodadas > "$TMP/list.html"
check "lista: toda rodada com evento de abertura na janela, da aberta mais recente para a mais antiga (a E, só com etapa, pela hora do primeiro evento)" \
  jqe --arg a "$A" --arg b "$B" --arg c "$C_" --arg e "$E" --arg g "$G" --arg h "$H" '. == [$c, $a, $e, $b, $g, $h]' <<<"$(rounds_of < "$TMP/list.html")"
check "lista: a rodada só com session.spawned (F) não entra" bash -c '! grep -qF "data-rodada=\"$2\"" "$1"' _ "$TMP/list.html" "$F"
check "lista: a rodada antiga (D) fica fora das 24 h"   bash -c '! grep -qF "data-rodada=\"$2\"" "$1"' _ "$TMP/list.html" "$D"
check "lista: a janela aparece no topo e 24 horas é a ativa" bash -c 'grep -q "data-janela" "$1" && grep -q "<a href=\"/rodadas?hours=24\" aria-current=\"true\">24 horas</a>" "$1"' _ "$TMP/list.html"

# rodada com etapa
check "com etapa (A): 3 etapas, 2 sessões (o spawned repetido conta uma vez), 2 PRs, fechada, abertura e fechamento na hora do fato" \
  jqe --arg o "$(( (NOW - 5 * 3600) * 1000000000 ))" --arg c "$(( (NOW - 2 * 3600) * 1000000000 ))" \
  '.etapas == "3" and .sessoes == "2" and .prs == "2" and .state == "fechada" and .["aberta-ns"] == $o and .["fechada-ns"] == $c and .review == "aprovado"' <<<"$(row "$A" "$TMP/list.html")"
check "com etapa (A): a linha leva à página da rodada"  test "$(href_of "$A" "$TMP/list.html")" = "/rodada?id=$A"
check "com etapa (A): a página da rodada abre (200)"     test "$(code "${AUTH[@]}" "$STUDIO_URL/rodada/bloco/resumo?id=$A")" = 200
check "com etapa (A): repositório e label da abertura, e 'fechada em'" bash -c 'grep -q "<td class=\"sec\">oute-agent · ready</td>" <<<"$1" && grep -q "fechada em " <<<"$1" && ! grep -q "data-sem-etapas" <<<"$1"' _ "$(tr_of "$A" "$TMP/list.html")"

# rodada sem etapa publicada
check "sem etapa (B): 0 etapas, 3 sessões, PRs sem número, fechada" jqe '.etapas == "0" and .sessoes == "3" and .prs == "" and .state == "fechada" and .review == ""' <<<"$(row "$B" "$TMP/list.html")"
check "sem etapa (B): mostra 'sem etapas publicadas' e o traço nos PRs" bash -c 'grep -q "data-sem-etapas>sem etapas publicadas<" <<<"$1" && grep -q "<td class=\"n sec\">—</td>" <<<"$1"' _ "$(tr_of "$B" "$TMP/list.html")"
LB="$(href_of "$B" "$TMP/list.html")"
check "sem etapa (B): a linha leva às sessões dela, do primeiro evento ao fechamento" \
  test "$LB" = "/sessoes?from=$(enc "$(iso $((NOW - 8 * 3600)))")&to=$(enc "$(iso $((NOW - 7 * 3600 + 1)))")&f_round=$B"
page "$LB" > "$TMP/sess-b.html"
check "sem etapa (B): o link abre só a sessão da rodada (a da rodada A e a avulsa ficam fora)" \
  jqe '. == ["tb"]' <<<"$(data < "$TMP/sess-b.html" | jq -c '[.[] | select(has("sessao")) | .sessao]')"
check "Sessões: sem o filtro, as três sessões da janela" \
  jqe '. == ["solta", "ta", "tb"]' <<<"$(page "${LB%&f_round=*}" | data | jq -c '[.[] | select(has("sessao")) | .sessao] | sort')"
check "Sessões: rodada que não existe = lista vazia com o link para limpar o filtro, não erro" \
  bash -c 'h="$(studio_page "${@:3}" "$1$2")"; grep -q "Limpar o filtro" <<<"$h" && ! grep -q "data-sessao=" <<<"$h"' _ "$STUDIO_URL" "${LB%&f_round=*}&f_round=swarm-que-nao-existe" "${AUTH[@]}"

# rodada sem evento de fechamento
check "sem fechamento (C): aberta, sem hora de fechamento, 1 sessão" jqe '.state == "aberta" and .["fechada-ns"] == "" and .sessoes == "1" and .etapas == "0"' <<<"$(row "$C_" "$TMP/list.html")"
check "sem fechamento (C): o estado mostra 'aberta', sem 'fechada em'" bash -c 'grep -q "<td class=\"sec\">aberta</td>" <<<"$1" && ! grep -q "fechada em" <<<"$1"' _ "$(tr_of "$C_" "$TMP/list.html")"
LC="$(href_of "$C_" "$TMP/list.html")"
check "sem fechamento (C): o link das sessões começa na abertura e abre (200)" \
  bash -c '[[ "$1" == "/sessoes?from=$2&to="*"&f_round=$3" ]] && [ "$(curl -s -o /dev/null -w "%{http_code}" "${@:5}" "$4$1&full=1")" = 200 ]' _ "$LC" "$(enc "$(iso $((NOW - 3600)))")" "$C_" "$STUDIO_URL" "${AUTH[@]}"

# rodada só com etapa (o evento de abertura não chegou) e rodada com a abertura além do máximo da tela
check "só etapa (E): entra, sem hora de abertura e sem estado, e leva à página da rodada" \
  bash -c 'jq -e ".etapas == \"1\" and .[\"aberta-ns\"] == \"\" and .state == \"\"" <<<"$1" >/dev/null && [ "$2" = "/rodada?id=$3" ]' _ "$(row "$E" "$TMP/list.html")" "$(href_of "$E" "$TMP/list.html")" "$E"
LH="$(href_of "$H" "$TMP/list.html")"
check "abertura há 400 dias (H): o link das sessões fica no máximo da tela (8784 h) e abre (200)" \
  bash -c 'f="$(sed "s/.*from=//; s/&.*//; s/%3A/:/g" <<<"$1")"; t="$(sed "s/.*to=//; s/&.*//; s/%3A/:/g" <<<"$1")"; [ $(( $(date -u -d "$t" +%s) - $(date -u -d "$f" +%s) )) = $((8784 * 3600)) ] && [ "$(curl -s -o /dev/null -w "%{http_code}" "${@:3}" "$2$1&full=1")" = 200 ]' _ "$LH" "$STUDIO_URL" "${AUTH[@]}"

# ---------------------------------------------------------------- 3. o filtro de período e a paginação
page '/rodadas?hours=168' > "$TMP/d7.html"
page '/rodadas?hours=720' > "$TMP/d30.html"
page '/rodadas?hours=8784' > "$TMP/d366.html"
check "7 dias: as mesmas seis rodadas (a D e as P ficam fora)" test "$(rounds_of < "$TMP/d7.html")" = "$(rounds_of < "$TMP/list.html")"
check "30 dias: entram as 21 rodadas P; a D (40 dias) não" bash -c 'grep -q "data-faixa>1 a 20 de 27<" "$1" && ! grep -qF "data-rodada=\"$2\"" "$1"' _ "$TMP/d30.html" "$D"
check "366 dias: 28 rodadas, 20 na primeira página"     bash -c 'grep -q "data-faixa>1 a 20 de 28<" "$1" && [ "$(grep -c "<tr data-rodada=" "$1")" = 20 ]' _ "$TMP/d366.html"
page '/rodadas?hours=8784&pag=2' > "$TMP/d366-2.html"
check "366 dias, página 2: as 8 que faltam, e a mais antiga (H) é a última" \
  bash -c 'grep -q "data-faixa>21 a 28 de 28<" "$1" && [ "$(grep -c "<tr data-rodada=" "$1")" = 8 ] && [ "$(python3 "$3/html-data.py" < "$1" | jq -r "[.[] | select(has(\"rodada\")) | .rodada] | last")" = "$2" ]' _ "$TMP/d366-2.html" "$H" "$STUDIO_LIB"
check "366 dias, 100 por página: a antiga (D) aparece sem etapa, depois das P e antes da H" \
  jqe --arg d "$D" --arg h "$H" '(.[-2:] == [$d, $h]) and length == 28' <<<"$(page '/rodadas?hours=8784&tam=100' | rounds_of)"
check "antiga (D): sem etapa, fechada, com o link das sessões; nenhuma página 500" \
  bash -c 'jq -e ".etapas == \"0\" and .state == \"fechada\" and .sessoes == \"1\"" <<<"$1" >/dev/null && [[ "$2" == /sessoes\?from=* ]] && [ "$3" = 200 ]' _ \
  "$(page '/rodadas?hours=8784&tam=100' | data | jq -c --arg r "$D" '.[] | select(.rodada == $r)')" "$(page '/rodadas?hours=8784&tam=100' > "$TMP/all.html"; href_of "$D" "$TMP/all.html")" "$(code "${AUTH[@]}" "$STUDIO_URL/bloco/rodadas/tabela?hours=8784&tam=100")"
check "os links do rodapé e do cabeçalho levam a janela" bash -c 'grep -q "href=\"/rodadas?hours=8784&amp;pag=2\"" "$1" && grep -q "href=\"/rodadas?hours=8784&amp;ord=steps&amp;dir=desc\"" "$1"' _ "$TMP/d366.html"
# intervalo: das 50 h às 40 h atrás não há evento da G nem da H, mas as duas estavam em andamento (a G abriu há 60 h e fechou
# há 10 h; a H abriu há 400 dias e teve sessão há 12 h)
W="from=$(enc "$(iso $((NOW - 50 * 3600)))")&to=$(enc "$(iso $((NOW - 40 * 3600)))")"
check "intervalo sem evento da rodada, com ela em andamento: a G e a H, e mais nenhuma" jqe --arg g "$G" --arg h "$H" '. == [$g, $h]' <<<"$(page "/rodadas?$W" | rounds_of)"
W2="from=$(enc "$(iso $((NOW - 500 * 86400)))")&to=$(enc "$(iso $((NOW - 450 * 86400)))")"
check "intervalo antes da primeira abertura: a mensagem, sem tabela" bash -c 'grep -q "data-sem-rodadas" <<<"$1" && ! grep -q "<tr data-rodada=" <<<"$1"' _ "$(page "/rodadas?$W2")"
check "filtro por estado: só as abertas (C e H) e o rodapé conta o filtrado" \
  bash -c 'h="$(studio_page "${@:4}" "$1/rodadas?f_state=aberta")"; grep -q "data-faixa>1 a 2 de 2 (filtrado, 6 no total)<" <<<"$h" && [ "$(grep -c "<tr data-rodada=" <<<"$h")" = 2 ] && grep -qF "data-rodada=\"$2\"" <<<"$h" && grep -qF "data-rodada=\"$3\"" <<<"$h"' _ "$STUDIO_URL" "$C_" "$H" "${AUTH[@]}"
check "ordenar por sessões começa pela rodada com mais sessões (B, três)" test "$(page '/rodadas?ord=sessions&dir=desc' | rounds_of | jq -r '.[0]')" = "$B"
check "ordenar por PRs: a rodada com etapa (A) primeiro; as sem número ficam no fim" test "$(page '/rodadas?ord=prs&dir=desc' | rounds_of | jq -r '.[0]')" = "$A"
check "período inválido, ordem ou filtro fora da lista fixa = 400" \
  bash -c 'for q in hours=abc hours=99999 "de=2026-01-01T00:00" "from=2026-01-02&to=2026-01-01" ord=last ord=nope f_nada=1; do [ "$(curl -s -o /dev/null -w "%{http_code}" "${@:2}" "$1/rodadas?$q")" = 400 ] || { echo "$q" >&2; exit 1; }; done' _ "$STUDIO_URL" "${AUTH[@]}"
check "período inválido: 400 também no bloco da tabela"  test "$(code "${AUTH[@]}" "$STUDIO_URL/bloco/rodadas/tabela?hours=abc")" = 400
check "sem login: /rodadas com janela = 303"            test "$(code "$STUDIO_URL/rodadas?hours=168")" = 303

# o formulário do período, enviado como o navegador envia (#586): os campos escondidos levam a ordem, o tamanho e o filtro
PYTHONPATH="$ROOT/tests/lib" "$STUDIO_PY" - "$STUDIO_URL" "$STUDIO_TOKEN" "$STUDIO_LIB" "$C_" "$H" > "$TMP/form.out" 2>&1 <<'PY'
import re, subprocess, sys
from pycheck import check
from studio_form import submit
url, token, lib, C, H = sys.argv[1:6]


def get(_app, path, query=""):
    r = subprocess.run([sys.executable, f"{lib}/studio_page.py", "-H", f"Authorization: Bearer {token}", f"{url}{path}?{query}"],
                       capture_output=True, check=True)
    return 200, r.stdout.decode()


def rounds(html):
    return re.findall(r'<tr data-rodada="([^"]*)"', html)


(_, before) = get(None, "/rodadas", "hours=168&f_state=aberta&ord=rodada&dir=asc&tam=50&pag=1")
(_, after), sent = submit(get, None, "/rodadas", "hours=168&f_state=aberta&ord=rodada&dir=asc&tam=50&pag=1")
check("formulário: o envio leva a janela, a ordem, a direção, o tamanho e o filtro, e não a página",
      dict(sent) == {"hours": "168", "ord": "rodada", "dir": "asc", "tam": "50", "f_state": "aberta", "de": "", "ate": ""})
check("formulário: o envio dá a mesma lista (as abertas, de A a Z)", rounds(after) == rounds(before) == [C, H])
check("formulário: a tela das rodadas não tem o controle de custo", "custo" not in dict(sent))
PY
check_py "$TMP/form.out"

# ---------------------------------------------------------------- 4. a lógica direto em Python
PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - > "$TMP/py.out" 2>&1 <<'PY'
from agent_studio import etapas, sessions
from pycheck import check


def line(**over):
    base = {"round": "r", "opened_ns": 10, "closed_ns": None, "repo": "oute-agent", "label": None, "sessions": 0, "revisions": 0,
            "steps": 0, "prs": 0, "review": None, "kind": None, "first_ns": 10, "last_ns": 20}
    return {**base, **over}


cyc = "renatobardi/oute-agent#489"
rows = etapas.with_state([line(), line(round="f", closed_ns=30), line(round="s", opened_ns=None, repo=None, steps=2, prs=1, revisions=2, first_ns=5),
                          line(round="x", opened_ns=None, repo=None)],
                         {"r": {"state": "fechada", "repo": "outro", "cycle": cyc}, "s": {"state": "aberta", "repo": "do-estado", "label": "ready", "cycle": "javascript:alert(1)"}})
r, f, s, x = rows
check("with_state: o fato vale mais que o registro (aberta pelo evento, repositório da abertura)", r["status"] == "aberta" and r["repo"] == "oute-agent")
check("with_state: o ciclo vem do registro e vira link", r["cycle"] == cyc and r["cycle_url"] == "/ciclo?id=renatobardi%2Foute-agent%23489")
check("with_state: fechada com o evento de fechamento", f["status"] == "fechada" and f["cycle"] is None and f["cycle_url"] is None)
check("with_state: sem etapa, o número de PRs não existe (None), e não zero", r["prs"] is None and f["prs"] is None)
check("with_state: sem evento de abertura, estado, repositório e label vêm do registro; a ordem é a do primeiro evento",
      s["status"] == "aberta" and s["repo"] == "do-estado" and s["label"] == "ready" and s["start_ns"] == 5 and s["prs"] == 1)
check("with_state: ciclo fora do formato não vira link nem texto", s["cycle"] is None and s["cycle_url"] is None)
check("with_state: sem evento de abertura e sem registro: sem estado, sem quebrar", x["status"] is None and x["repo"] is None)
alone = etapas.with_state([line()], None)[0]
check("with_state: SurrealDB não lido (None): a linha sai só com o fato", alone["status"] == "aberta" and alone["cycle"] is None)
check("tabela: a ordem padrão é a abertura, da mais recente", etapas.TABLE.default == ("opened", "desc"))
check("tabela: as colunas da issue (repositório, abertura, estado, sessões, PRs, etapas)", {"rodada", "repo", "opened", "state", "sessions", "prs", "steps"} <= set(etapas.TABLE.cols))
check("Sessões: o filtro da rodada é f_round e só existe na tabela das sessões", sessions.TABLE.cols["round"].param == "f_round" and "round" not in sessions.LOOSE.cols)
PY
check_py "$TMP/py.out"
check_end
