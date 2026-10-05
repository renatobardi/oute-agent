#!/usr/bin/env bash
# Testes da página da rodada do agent-studio (#507, ADR-08 "Página da rodada e do ciclo"): o evento
# `oute.swarm.step.published` pela ingestão de verdade (POST /v1/logs), a `etapa` derivada no SurrealDB (a revisão mais
# alta vence em qualquer ordem), `GET /rodadas`, `GET /rodada?id=` (barra de etapas, Markdown restrito, aviso fixo das
# etapas reprovada e sem revisor, texto sempre escapado), `GET /v1/rodada?id=`, o SurrealDB fora e o `rebuild-state`
# (`etapas=`). Mais a lógica direto em Python (gramática do Markdown, estado inválido, barra). Sem Docker; o SurrealDB é o
# binário fixado de tests/lib/surreal.sh.
# Uso: tests/agent-studio-rodada.test.sh   (sai != 0 se algum caso falhar)
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
PKG="$ROOT/docker/agent-studio/agent_studio"

# ---------------------------------------------------------------- exemplo
# R1 (swarm-1004-1306): fechamento r1 sem-revisor e r2 aprovado (o r2 chega ANTES do r1: a revisão mais alta vence), merge
#    do PR 12 aprovado, kaizen reprovado com HTML no texto.
# R2 (swarm-1004-1400): fechamento reprovado. R3 (swarm-1004-1500): fechamento aprovado, sem o corpo do evento.
# R4 (swarm-1004-1600): só evento fora do formato (tipo desconhecido, sha256 curto): não vira etapa.
# R5 (swarm-1004-1700, #508): as quatro etapas, com dois pedidos de merge (PR 21 e 22): triagem, merge 21, merge 22, kaizen e
#    fechamento, todas aprovadas.
NOW="$(date +%s)"
R1=swarm-1004-1306; R2=swarm-1004-1400; R3=swarm-1004-1500; R4=swarm-1004-1600; R5=swarm-1004-1700
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" <<'PY'
import hashlib, json, sys
from otlp_json import event, rl
tmp, NOW = sys.argv[1], int(sys.argv[2])
res = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "claude"}
def step(t, rnd, eid, kind, rev, review, text, key=None, writer="claude-sonnet-5-5", reviewer="claude-opus-5-5", sha=None, **extra):
    sha = sha or (hashlib.sha256(text.encode()).hexdigest() if text is not None else "0" * 64)
    attrs = {"oute.swarm.round": rnd, "oute.swarm.step.kind": kind, "oute.swarm.step.rev": rev, "oute.swarm.step.sha256": sha,
             "oute.swarm.step.review": review, "oute.swarm.step.writer": writer, "oute.swarm.step.reviewer": reviewer,
             "oute.swarm.step.refcheck": "ausente", **extra}
    if key: attrs["oute.swarm.step.key"] = key
    return event(t, "oute.swarm.step.published", eid, attrs, text)
T1 = ("## Decisão\n1. aprovar o fechamento da rodada **swarm-1004-1306** <b>negrito falso</b>\n2. pedir ajuste\n\n"
      "## Ações\n- rodar `oute update` no host\n- ler o PR [#600](https://github.com/renatobardi/oute-agent/pull/600), [mau](javascript:alert(1)) e [http](http://x.invalid/a)\n\n"
      "## Detalhe\nParágrafo com <script>alert('detalhe')</script> e &amp; literal e uma marca\u202e de direção.\nVeja [https://github.com/renatobardi/oute-agent](https://evil.example/phishing) e [malformado](https://[abc).\n\n### Subtítulo\n```\nbloco <b>cru</b> & mais\n```\n")
T1R1 = "## Decisão\n1. versão antiga r1, sem revisor\n"
TMERGE = "## Decisão\n1. fazer merge do #12?\n\n## Detalhe\nCI verde.\n"
TKAIZEN = "## Decisão\n1. aplicar a lição <script>alert('kaizen')</script>\n\n## Ações\n- nada\n\n## Detalhe\nSem fonte para o número 42.\n"
TR2 = "## Decisão\n1. fechar a rodada\n\n## Ações\n- nenhuma\n\n## Detalhe\nTexto que o revisor reprovou.\n"
r1_late = [step(NOW - 600, "swarm-1004-1306", "ev-f1", "fechamento", 1, "sem-revisor", T1R1)]
r1 = [step(NOW - 500, "swarm-1004-1306", "ev-f2", "fechamento", 2, "aprovado", T1),
      step(NOW - 900, "swarm-1004-1306", "ev-m12", "merge", 1, "aprovado", TMERGE, key="12"),
      step(NOW - 700, "swarm-1004-1306", "ev-k1", "kaizen", 1, "reprovado", TKAIZEN, **{"oute.swarm.cycle": "renatobardi/oute-agent#489"})]
others = [step(NOW - 3000, "swarm-1004-1400", "ev-r2f", "fechamento", 2, "reprovado", TR2),
          step(NOW - 200, "swarm-1004-1500", "ev-r3f", "fechamento", 1, "aprovado", None),
          step(NOW - 100, "swarm-1004-1600", "ev-r4-tipo", "diagrama", 1, "aprovado", "x"),
          step(NOW - 90, "swarm-1004-1600", "ev-r4-sha", "fechamento", 1, "aprovado", "x", sha="abc")]
r5 = [step(NOW - 1500, "swarm-1004-1700", "ev-r5t", "triagem", 1, "aprovado", "## Decisão\n1. abrir a #508\n\n## Ações\n- escolher a opção\n\n## Detalhe\nTriagem.\n"),
      step(NOW - 1400, "swarm-1004-1700", "ev-r5m21", "merge", 1, "aprovado", "## Decisão\n1. fazer merge do #21?\n", key="21"),
      step(NOW - 1300, "swarm-1004-1700", "ev-r5m22", "merge", 1, "aprovado", "## Decisão\n1. fazer merge do #22?\n", key="22"),
      step(NOW - 1200, "swarm-1004-1700", "ev-r5k", "kaizen", 1, "aprovado", "## Decisão\n1. sem lições\n"),
      step(NOW - 1100, "swarm-1004-1700", "ev-r5f", "fechamento", 1, "aprovado", "## Decisão\n1. fechar a rodada\n")]
json.dump({"resourceLogs": [rl(res, r1 + others + r5)]}, open(f"{tmp}/b1.json", "w"))
json.dump({"resourceLogs": [rl(res, r1_late)]}, open(f"{tmp}/b2.json", "w"))
open(f"{tmp}/t1.md", "w").write(T1)
open(f"{tmp}/tr2.md", "w").write(TR2)
PY

SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml")
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
C=(-H "Authorization: Bearer $STUDIO_TOKEN")
page() { local path="$1"; curl -s "${C[@]}" "$STUDIO_URL$path"; return $?; }
sr() { local q="$1"; surreal_q "$q"; return $?; }
steps_of() { data | jq -c '[.[] | select(has("etapa"))]'; return $?; }

# ---------------------------------------------------------------- 1. antes de qualquer etapa; quem lê
EMPTY="$(page /rodadas)"
check "sem etapa nenhuma: /rodadas 200 com a mensagem"  bash -c 'grep -q "data-sem-rodadas" <<<"$1"' _ "$EMPTY"
check "sem etapa nenhuma: /rodada = 404"               test "$(code "${C[@]}" "$STUDIO_URL/rodada?id=$R1")" = 404
check "sem id: /rodada = 400"                          test "$(code "${C[@]}" "$STUDIO_URL/rodada")" = 400
check "sem etapa nenhuma: /v1/rodada = 404"            test "$(code "${C[@]}" "$STUDIO_URL/v1/rodada?id=$R1")" = 404
check "sem id: /v1/rodada = 400"                       test "$(code "${C[@]}" "$STUDIO_URL/v1/rodada")" = 400
check "sem credencial: /v1/rodada = 401"               test "$(code "$STUDIO_URL/v1/rodada?id=$R1")" = 401
check "sem login: /rodada = 303 para o /login, com a volta" test "$(code "$STUDIO_URL/rodada?id=$R1")$(hdr location "$STUDIO_URL/rodada?id=$R1")" = "303/login?next=%2Frodada%3Fid%3D$R1"
check "sem login: /rodadas = 303"                      test "$(code "$STUDIO_URL/rodadas")" = 303
check "menu: Rodadas em Governança"                    grep -qE '<a class="nav-item" href="/rodadas"[^>]*>.*<span>Rodadas</span></a>' <<<"$EMPTY"

# ---------------------------------------------------------------- 2. ingestão e o estado derivado (a revisão mais alta vence)
check "ingestão: o lote com o r2 do fechamento, o merge, o kaizen e as outras rodadas = 200" test "$(post logs "$TMP/b1.json")" = 200
check "ingestão: o r1 do fechamento chega DEPOIS do r2 = 200" test "$(post logs "$TMP/b2.json")" = 200
SK="etapa:['$R1','fechamento','']"
check "SurrealDB: a revisão vigente é o r2 aprovado, não o r1 que chegou depois" jqe --arg ev ev-f2 '.[0] | .rev == 2 and .review == "aprovado" and .event == $ev and .kind == "fechamento" and .key == ""' <<<"$(sr "SELECT rev, review, event, kind, key FROM $SK")"
check "SurrealDB: sha256, autor, revisor, refcheck, host, link para a rodada" jqe --arg r "$R1" --arg sha "$(sha256sum "$TMP/t1.md" | cut -d' ' -f1)" '.[0] | .sha256 == $sha and .writer == "claude-sonnet-5-5" and .reviewer == "claude-opus-5-5" and .refcheck == "ausente" and .host == "oute-server" and (.rodada | contains($r))' <<<"$(sr "SELECT sha256, writer, reviewer, refcheck, host, <string>rodada AS rodada FROM $SK")"
check "SurrealDB: o texto não é copiado para a etapa"  jqe '.[0] | has("text") | not and (tostring | contains("Decisão") | not)' <<<"$(sr "SELECT * FROM $SK")"
check "SurrealDB: merge com a chave do PR"             jqe '.[0] | .kind == "merge" and .key == "12" and .rev == 1' <<<"$(sr "SELECT kind, key, rev FROM etapa:['$R1','merge','12']")"
check "SurrealDB: o ciclo do kaizen"                   jqe '.[0].cycle == "renatobardi/oute-agent#489" and .[0].review == "reprovado"' <<<"$(sr "SELECT cycle, review FROM etapa:['$R1','kaizen','']")"
check "SurrealDB: 10 etapas (3 da R1, 1 da R2, 1 da R3, 5 da R5); o evento fora do formato não vira estado" test "$(sr 'SELECT count() FROM etapa GROUP ALL' | jq -r '.[0].count')" = 10
check "SurrealDB: a rodada ganha registro com a origem" jqe '.[0].host == "oute-server"' <<<"$(sr "SELECT host FROM rodada:\`$R1\`")"
post logs "$TMP/b2.json" >/dev/null; post logs "$TMP/b1.json" >/dev/null
check "reenvio dos dois lotes: o estado não muda (r2 aprovado)" jqe '.[0].rev == 2 and .[0].review == "aprovado"' <<<"$(sr "SELECT rev, review FROM $SK")"

# ---------------------------------------------------------------- 3. /rodadas
page /rodadas > "$TMP/list.html"
L="$(data < "$TMP/list.html" | jq -c '[.[] | select(has("rodada"))]')"
check "lista: as rodadas com etapa, da mais recente para a mais antiga (a R4, sem etapa válida, não conta como etapa mas aparece pelo evento)" jqe --arg a "$R4" --arg b "$R3" --arg c "$R1" --arg e "$R5" --arg d "$R2" 'map(.rodada) == [$a, $b, $c, $e, $d]' <<<"$L"
check "lista: etapas, revisões e o veredito da última" jqe --arg r "$R1" '.[] | select(.rodada == $r) | .etapas == "3" and .revisoes == "4" and .review == "aprovado" and .state == ""' <<<"$L"
check "lista: a R5 tem cinco etapas e o veredito da última (#508)" jqe --arg r "$R5" '.[] | select(.rodada == $r) | .etapas == "5" and .revisoes == "5" and .review == "aprovado"' <<<"$L"
check "lista: link da página da rodada"                grep -qF "<a href=\"/rodada?id=$R1\">$R1</a>" "$TMP/list.html"
check "lista: veredito em Badge (aprovado, reprovado)"  bash -c 'grep -q "badge secundario\"><svg[^>]*><use href=\"/static/lucide.svg#check\"/></svg>aprovado</span>" "$1" && grep -q "badge destrutivo\"><svg[^>]*><use href=\"/static/lucide.svg#triangle-alert\"/></svg>reprovado</span>" "$1"' _ "$TMP/list.html"
# tabela com ordem, filtro por coluna e página (#529)
rounds_of() { data | jq -c '[.[] | select(has("rodada")) | .rodada]'; }
check "lista: o rodapé conta as rodadas ('1 a 5 de 5') e o tamanho 20 é o padrão" bash -c 'grep -q "data-faixa>1 a 5 de 5<" "$1" && grep -q "aria-current=\"true\">20</a>" "$1"' _ "$TMP/list.html"
check "lista: ordenar pela rodada de A a Z e invertido" test "$(page '/rodadas?ord=rodada&dir=asc' | rounds_of)$(page '/rodadas?ord=rodada&dir=desc' | rounds_of)" = "$(jq -cn --arg a "$R1" --arg b "$R2" --arg c "$R3" --arg d "$R4" --arg e "$R5" '[$a, $b, $c, $d, $e]')$(jq -cn --arg a "$R1" --arg b "$R2" --arg c "$R3" --arg d "$R4" --arg e "$R5" '[$e, $d, $c, $b, $a]')"
check "lista: ordenar pelo número de etapas começa pela rodada com mais etapas (a R5, cinco)" test "$(page '/rodadas?ord=steps&dir=desc' | rounds_of | jq -r '.[0]')" = "$R5"
check "lista: o cabeçalho da coluna ordenada propõe a direção oposta no segundo clique" bash -c 'tr "\n" " " <<<"$1" | grep -q "data-col=\"steps\">[[:space:]]*<a class=\"ordem\" href=\"/rodadas?ord=steps&amp;dir=asc\""' _ "$(page '/rodadas?ord=steps&dir=desc')"
check "lista: filtro por veredito deixa só as reprovadas (a R2) e o rodapé conta o filtrado" bash -c 'h="$(curl -s "${@:2}" "$1/rodadas?f_review=reprovado")"; grep -q "data-faixa>1 a 1 de 1 (filtrado, 5 no total)<" <<<"$h" && [ "$(grep -c "data-rodada=\"$2\"" <<<"$h")" = 1 ] && [ "$(grep -c "<tr data-rodada=" <<<"$h")" = 1 ]' _ "$STUDIO_URL" "$R2" "${C[@]}"
check "lista: o filtro do cabeçalho de veredito oferece os valores da lista inteira" bash -c 'h="$(curl -s "${@:2}" "$1/rodadas?f_review=reprovado")"; sed -n "/data-filtro=\"review\"/,/<\/details>/p" <<<"$h" | grep -q ">aprovado</a>"' _ "$STUDIO_URL" "${C[@]}"
check "lista: filtro sem rodada mostra o aviso com o link para limpar, não a mensagem de 'nenhuma rodada ainda'" bash -c 'h="$(curl -s "${@:2}" "$1/rodadas?f_review=sem-revisor-nenhum")"; grep -q "Limpar o filtro" <<<"$h" && ! grep -q "data-sem-rodadas" <<<"$h"' _ "$STUDIO_URL" "${C[@]}"
check "lista: ordem, direção, tamanho, página ou filtro fora da lista fixa = 400" bash -c 'for q in ord=nope dir=up tam=7 tam=abc pag=0 pag=x f_nada=1 f_review_d=x ord_p=state; do [ "$(curl -s -o /dev/null -w "%{http_code}" "${@:2}" "$1/rodadas?$q")" = 400 ] || { echo "$q" >&2; exit 1; }; done' _ "$STUDIO_URL" "${C[@]}"

# ---------------------------------------------------------------- 4. /rodada: a R1
page "/rodada?id=$R1" > "$TMP/r1.html"
check "R1: 200 (o texto da etapa tem link de host inválido, https://[abc)"  test "$(code "${C[@]}" "$STUDIO_URL/rodada?id=$R1")" = 200
S="$(steps_of < "$TMP/r1.html")"
check "R1: três etapas, na ordem da rodada (merge, kaizen, fechamento)" jqe 'map(.etapa) == ["merge", "kaizen", "fechamento"]' <<<"$S"
check "R1: fechamento = r2 aprovado (a revisão mais alta, não a mais recente a chegar)" jqe '.[2] | .rev == "2" and .review == "aprovado" and (.sha256 | length == 64)' <<<"$S"
check "R1: o r1 antigo (sem revisor) não aparece"       bash -c '! grep -q "versão antiga r1" "$1" && ! grep -q "data-aviso=\"sem-revisor\"" "$1"' _ "$TMP/r1.html"
check "R1: merge com a chave do PR no título"          bash -c 'grep -q "<h2>Pedido de merge #12</h2>" "$1" && grep -q "id=\"etapa-merge-12\"" "$1"' _ "$TMP/r1.html"
BAR="$(data < "$TMP/r1.html" | jq -c '[.[] | select(has("passo")) | {passo, feito, review, total}]')"
check "barra de etapas: triagem não publicada, merge, kaizen e fechamento feitos, com o pior veredito" test "$BAR" = '[{"passo":"triagem","feito":"nao","review":"","total":"0"},{"passo":"merge","feito":"sim","review":"aprovado","total":"1"},{"passo":"kaizen","feito":"sim","review":"reprovado","total":"1"},{"passo":"fechamento","feito":"sim","review":"aprovado","total":"1"}]'
check "barra de etapas: a posição atual é a última com etapa (aria-current)" bash -c 'grep -q "data-passo=\"fechamento\"[^>]*aria-current=\"step\"" "$1" && [ "$(grep -c "aria-current=\"step\"" "$1")" = 1 ]' _ "$TMP/r1.html"
check "barra de etapas: a que não foi publicada diz isso, sem link" bash -c 'grep -q "data-passo=\"triagem\"" "$1" && grep -q "<span class=\"so-leitor\"> (não publicada)</span>" "$1" && ! grep -q "href=\"#etapa-triagem\"" "$1" && grep -q "href=\"#etapa-fechamento\"" "$1"' _ "$TMP/r1.html"
sed -n '/id="etapa-fechamento"/,/<\/section>\n*<\/section>/p' "$TMP/r1.html" > "$TMP/r1-fech.html"
check "aprovado: seções Decisão, Ações e Detalhe, na ordem" bash -c 'f="$1"; a="$(grep -n "data-secao=\"Decisão\"" "$f" | head -1 | cut -d: -f1)"; b="$(grep -n "data-secao=\"Ações\"" "$f" | head -1 | cut -d: -f1)"; c="$(grep -n "data-secao=\"Detalhe\"" "$f" | head -1 | cut -d: -f1)"; [ -n "$a" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]' _ "$TMP/r1-fech.html"
check "aprovado: lista numerada, lista de itens, negrito e código" bash -c 'grep -q "<ol><li>aprovar o fechamento da rodada <strong>swarm-1004-1306</strong>" "$1" && grep -q "<li>rodar <code>oute update</code> no host</li>" "$1"' _ "$TMP/r1.html"
check "aprovado: texto aberto, sem aviso nem <details> no fechamento" bash -c 'f="$1"; s="$(sed -n "/id=\"etapa-fechamento\"/,/<\/section>/p" "$f")"; grep -q "data-texto>" <<<"$s" && ! grep -q "data-aviso\|<details" <<<"$s"' _ "$TMP/r1.html"
check "aprovado: HTML do texto sai escapado (nada de tag viva)" bash -c 'f="$1"; ! grep -q "<b>negrito falso</b>\|<script>alert\|<b>cru</b>" "$f" && grep -q "&lt;b&gt;negrito falso&lt;/b&gt;" "$f" && grep -q "&lt;script&gt;alert(&#39;detalhe&#39;)&lt;/script&gt; e &amp;amp; literal" "$f" && grep -q "bloco &lt;b&gt;cru&lt;/b&gt; &amp; mais" "$f"' _ "$TMP/r1.html"
check "aprovado: link https vira link com rel e título; javascript: e http: ficam texto" bash -c 'f="$1"; grep -q "<a href=\"https://github.com/renatobardi/oute-agent/pull/600\" rel=\"noopener noreferrer nofollow\" referrerpolicy=\"no-referrer\" title=\"https://github.com/renatobardi/oute-agent/pull/600\">#600</a>" "$f" && ! grep -q "href=\"javascript\|href=\"http://" "$f" && grep -q "\[mau\](javascript:alert(1))" "$f"' _ "$TMP/r1.html"
check "aprovado: o link mostra o host do destino ao lado do texto (github.com e o enganoso evil.example)" bash -c 'grep -q "title=\"https://github.com/renatobardi/oute-agent/pull/600\">#600</a> <span class=\"link-host\">(github.com)</span>" "$1" && grep -q ">https://github.com/renatobardi/oute-agent</a> <span class=\"link-host\">(evil.example)</span>" "$1"' _ "$TMP/r1.html"
check "aprovado: a marca de direção U+202E não chega à página" bash -c '! grep -q $'"'"'\xe2\x80\xae'"'"' "$1" && grep -q "uma marca de direção" "$1"' _ "$TMP/r1.html"
check "aprovado: bloco de código em <pre>"             bash -c 'grep -q "<pre class=\"script\">bloco &lt;b&gt;cru&lt;/b&gt; &amp; mais</pre>" "$1" && grep -q "<h4>Subtítulo</h4>" "$1"' _ "$TMP/r1.html"
check "etapa: revisão, autor, revisor e sha256 curto no topo" bash -c 'grep -qE "revisão 2 · publicada em 20[0-9-]+ [0-9:]+ GMT-3 · autor claude-sonnet-5-5 · revisor claude-opus-5-5 · sha256 <code>[0-9a-f]{12}</code>" "$1"' _ "$TMP/r1.html"
check "etapa: o ciclo aparece quando o evento traz"    grep -q "ciclo renatobardi/oute-agent#489" "$TMP/r1.html"
KZ="$(sed -n '/id="etapa-kaizen"/,/<\/section>/p' "$TMP/r1.html")"
check "D6, reprovado: aviso fixo do studio, em alerta"  bash -c 'grep -q "data-aviso=\"reprovado\"" <<<"$1" && grep -q "Etapa reprovada pelo revisor. O texto abaixo não foi aprovado" <<<"$1" && grep -q "role=\"alert\"" <<<"$1"' _ "$KZ"
check "D6, reprovado: o texto fica fechado (details sem open) e escapado" bash -c 'grep -q "<details class=\"etapa-fechada\" data-texto-fechado>" <<<"$1" && ! grep -q "<details[^>]* open" <<<"$1" && ! grep -q "<script>alert" <<<"$1" && grep -q "&lt;script&gt;alert(&#39;kaizen&#39;)&lt;/script&gt;" <<<"$1" && grep -q "Abrir o texto sem revisão aprovada" <<<"$1"' _ "$KZ"
check "D6, reprovado: Badge destrutivo"                 grep -q 'badge destrutivo"><svg[^>]*><use href="/static/lucide.svg#triangle-alert"/></svg>reprovado pelo revisor</span>' <<<"$KZ"
page "/rodada?id=$R2" > "$TMP/r2.html"
check "R2: fechamento reprovado: aviso fixo e texto fechado" bash -c 'grep -q "data-aviso=\"reprovado\"" "$1" && grep -q "data-texto-fechado" "$1" && grep -q "Texto que o revisor reprovou" "$1"' _ "$TMP/r2.html"
page "/rodada?id=$R3" > "$TMP/r3.html"
check "R3: sem o corpo do evento: avisa que o texto não chegou, sem texto" bash -c 'grep -q "data-sem-texto" "$1" && ! grep -q "data-texto" "$1"' _ "$TMP/r3.html"
check "R4: só evento fora do formato: 404"              test "$(code "${C[@]}" "$STUDIO_URL/rodada?id=$R4")" = 404
check "rodada que não existe: 404"                      test "$(code "${C[@]}" "$STUDIO_URL/rodada?id=nao-existe")" = 404
check "rodada com HTML no id: 404, id nunca na página"  bash -c 'b="$(curl -s -H "Authorization: Bearer $2" "$1/rodada?id=%3Cb%3Ex%3C%2Fb%3E")"; ! grep -q "<b>x</b>" <<<"$b"' _ "$STUDIO_URL" "$STUDIO_TOKEN"

# ---------------------------------------------------------------- 4b. a R5 (#508): as quatro etapas, a posição e a navegação
page "/rodada?id=$R5" > "$TMP/r5.html"
card() { local id="$1" f="$2"; awk -v id="id=\"$id\"" 'index($0, id) { on = 1; print; next } on && /<section class="cartao etapa"/ { exit } on { print }' "$f"; return 0; }
S5="$(steps_of < "$TMP/r5.html")"
check "R5: as cinco etapas, na ordem da rodada (triagem, merge 21, merge 22, kaizen, fechamento)" jqe 'map(.etapa + ":" + .key) == ["triagem:", "merge:21", "merge:22", "kaizen:", "fechamento:"]' <<<"$S5"
check "R5: cada etapa traz a posição na rodada (1 a 5 de 5)" jqe 'map(.pos + "/" + .total) == ["1/5", "2/5", "3/5", "4/5", "5/5"]' <<<"$S5"
check "R5: o texto da posição, por extenso, em cada etapa" bash -c 'grep -c "data-posicao>Etapa [1-5] de 5 da rodada</p>" "$1" | grep -qx 5 && grep -q "Etapa 3 de 5 da rodada" "$1"' _ "$TMP/r5.html"
check "R5: a primeira etapa só tem o seguinte, para o merge #21" bash -c 'c="$1"; ! grep -q "data-nav=\"anterior\"" <<<"$c" && grep -q "rel=\"next\" href=\"#etapa-merge-21\" data-nav=\"seguinte\"" <<<"$c" && grep -q "Seguinte: Pedido de merge #21" <<<"$c"' _ "$(card etapa-triagem "$TMP/r5.html")"
check "R5: a do meio tem o anterior e o seguinte (merge #22: #21 e kaizen)" bash -c 'c="$1"; grep -q "rel=\"prev\" href=\"#etapa-merge-21\" data-nav=\"anterior\"" <<<"$c" && grep -q "Anterior: Pedido de merge #21" <<<"$c" && grep -q "rel=\"next\" href=\"#etapa-kaizen\" data-nav=\"seguinte\"" <<<"$c" && grep -q "Seguinte: Retrospectiva (kaizen)" <<<"$c"' _ "$(card etapa-merge-22 "$TMP/r5.html")"
check "R5: a última só tem o anterior (kaizen)" bash -c 'c="$1"; grep -q "rel=\"prev\" href=\"#etapa-kaizen\" data-nav=\"anterior\"" <<<"$c" && ! grep -q "data-nav=\"seguinte\"" <<<"$c"' _ "$(card etapa-fechamento "$TMP/r5.html")"
check "R5: todo link de navegação aponta para uma etapa que existe na página" bash -c 'f="$1"; for h in $(grep -o "rel=\"\(prev\|next\)\" href=\"#[a-z0-9-]*\"" "$f" | sed "s/.*href=\"#//; s/\"//"); do grep -q "id=\"$h\"" "$f" || exit 1; done' _ "$TMP/r5.html"
BAR5="$(data < "$TMP/r5.html" | jq -c '[.[] | select(has("passo")) | {passo, feito, review, total}]')"
check "R5, barra: as quatro posições feitas, merge com 2" test "$BAR5" = '[{"passo":"triagem","feito":"sim","review":"aprovado","total":"1"},{"passo":"merge","feito":"sim","review":"aprovado","total":"2"},{"passo":"kaizen","feito":"sim","review":"aprovado","total":"1"},{"passo":"fechamento","feito":"sim","review":"aprovado","total":"1"}]'
check "R5, barra: um link por pedido de merge (#21 e #22)" bash -c 'f="$1"; [ "$(grep -o "data-barra-item" "$f" | wc -l)" = 2 ] && grep -q "<a href=\"#etapa-merge-21\" data-barra-item>#21</a><a href=\"#etapa-merge-22\" data-barra-item>#22</a>" "$f"' _ "$TMP/r5.html"
check "R5, barra: a posição atual é o fechamento, uma só" bash -c 'grep -q "data-passo=\"fechamento\"[^>]*aria-current=\"step\"" "$1" && [ "$(grep -c "aria-current=\"step\"" "$1")" = 1 ]' _ "$TMP/r5.html"
check "R5: cada etapa traz o texto, aprovada, aberta, sem aviso" bash -c 'f="$1"; [ "$(grep -c "<div class=\"etapa-texto\" data-texto>" "$f")" = 5 ] && ! grep -q "data-aviso\|data-texto-fechado" "$f"' _ "$TMP/r5.html"
check "R1: um só pedido de merge: a barra não repete o link dele" bash -c '! grep -q "data-barra-item" "$1"' _ "$TMP/r1.html"
check "R1: três etapas, a navegação do kaizen leva ao merge e ao fechamento" bash -c 'c="$1"; grep -q "href=\"#etapa-merge-12\" data-nav=\"anterior\"" <<<"$c" && grep -q "href=\"#etapa-fechamento\" data-nav=\"seguinte\"" <<<"$c"' _ "$(card etapa-kaizen "$TMP/r1.html")"
check "R3: uma etapa só: posição 1 de 1 e nenhuma navegação" bash -c 'grep -q "Etapa 1 de 1 da rodada" "$1" && ! grep -q "data-etapa-nav\|data-nav=" "$1"' _ "$TMP/r3.html"
check "navegação: só leitura, links com âncora e nenhum campo (o teste do formulário vale para a R5)" bash -c 'f="$1"; ! grep -hiE "<(input|select|textarea)" "$f" | grep -qv "menu-interruptor" && [ "$(grep -ho "<form[^>]*>" "$f" | sort -u)" = "<form method=\"post\" action=\"/logout\">" ]' _ "$TMP/r5.html"

# ---------------------------------------------------------------- 5. /v1/rodada
J="$(page "/v1/rodada?id=$R1")"
check "API: rodada, repo e as três etapas na ordem"    jqe --arg r "$R1" '.round == $r and (.steps | map(.kind)) == ["merge", "kaizen", "fechamento"] and .state_read == true' <<<"$J"
check "API: fechamento = r2 aprovado, com o texto inteiro" jqe --rawfile t "$TMP/t1.md" '.steps[2] | .rev == 2 and .review == "aprovado" and .text == $t and .text_withheld == false and .refcheck == "ausente" and .writer == "claude-sonnet-5-5"' <<<"$J"
check "API: etapa reprovada não leva o texto"          jqe '.steps[1] | .review == "reprovado" and .text == null and .text_withheld == true and .cycle == "renatobardi/oute-agent#489"' <<<"$J"
check "API: merge com a chave do PR; sem chave nas outras" jqe '.steps[0].key == "12" and .steps[1].key == null and .steps[2].key == null' <<<"$J"
check "API: url da página, com a âncora da etapa"      jqe --arg r "$R1" '.steps[0].url == "/rodada?id=" + $r + "#etapa-merge-12" and .steps[2].url == "/rodada?id=" + $r + "#etapa-fechamento"' <<<"$J"
check "API: etapa sem revisor também fica sem texto"   jqe '.steps[0].text_withheld == false' <<<"$J"
check "API: rodada que só o DuckDB tem o texto (sem corpo) sai com text nulo, não 500" jqe '.steps[0] | .text == null and .review == "aprovado"' <<<"$(page "/v1/rodada?id=$R3")"
check "API: o corpo do reprovado (R2) não vaza"        bash -c '! grep -q "Texto que o revisor reprovou" <<<"$1"' _ "$(page "/v1/rodada?id=$R2")"

# ---------------------------------------------------------------- 6. só leitura, sem script, mesma CSP
check "POST /rodada e /rodadas: 405 (só leitura)"       test "$(code -X POST "${C[@]}" "$STUDIO_URL/rodada?id=$R1")$(code -X POST "${C[@]}" "$STUDIO_URL/rodadas")" = 405405
check "POST /v1/rodada: 405"                            test "$(code -X POST "${C[@]}" "$STUDIO_URL/v1/rodada?id=$R1")" = 405
check "rodada: o único formulário é o de sair, nenhum campo, nenhum botão a mais" bash -c 'for f in "$@"; do [ "$(grep -ho "<form[^>]*>" "$f" | sort -u)" = "<form method=\"post\" action=\"/logout\">" ] && ! grep -hiE "<(input|select|textarea)" "$f" | grep -qv "menu-interruptor" || exit 1; done' _ "$TMP/r1.html" "$TMP/r2.html" "$TMP/list.html"
check "rodada: sem script nem estilo inline, só o htmx do /static" bash -c '! grep -hiE "<script(>| [^>]*>)[^<]|<style|[ \"]style=|[ \"]on[a-z]+=\"" "$@" && [ "$(grep -ho "<script[^>]*>" "$@" | sort -u)" = "<script src=\"/static/htmx.min.js\" defer>" ]' _ "$TMP/r1.html" "$TMP/r2.html" "$TMP/list.html"
CSP="$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/rodada?id=$R1")"
check "CSP: a mesma das outras telas"                   test "$CSP" = "$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/pedidos")" -a "$CSP" = "$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/rodadas")"
check "rodada: não vai para cache"                      test "$(hdr cache-control "${C[@]}" "$STUDIO_URL/rodada?id=$R1")" = no-store
check "rodada: a página de detalhe não leva as faixas de alerta" bash -c '! grep -q "id=\"alertas\"" "$1"' _ "$TMP/r1.html"

# ---------------------------------------------------------------- 7. SurrealDB fora: a página sai com o texto e um aviso
surreal_stop
page "/rodada?id=$R1" > "$TMP/r1-down.html"
check "SurrealDB fora: /rodada 200"                     test "$(code "${C[@]}" "$STUDIO_URL/rodada?id=$R1")" = 200
check "SurrealDB fora: aviso, e o texto vem do DuckDB (a revisão mais alta)" bash -c 'grep -q "data-estado-indisponivel" "$1" && grep -q "data-etapa=\"fechamento\"" "$1" && grep -q "data-rev=\"2\"" "$1" && ! grep -q "versão antiga r1" "$1" && grep -q "<strong>swarm-1004-1306</strong>" "$1"' _ "$TMP/r1-down.html"
check "SurrealDB fora: as três etapas e o veredito de cada uma" jqe 'map({etapa, review}) == [{"etapa":"merge","review":"aprovado"},{"etapa":"kaizen","review":"reprovado"},{"etapa":"fechamento","review":"aprovado"}]' <<<"$(steps_of < "$TMP/r1-down.html")"
check "SurrealDB fora: a causa não vai à página"        bash -c '! grep -qiE "surreal ?db: |connection|Errno|Traceback" <<<"$(sed "s/SurrealDB/X/g" "$1")"' _ "$TMP/r1-down.html"
check "SurrealDB fora: /v1/rodada 200 com state_read false, texto do DuckDB" jqe '.state_read == false and .steps[2].rev == 2 and (.steps[2].text | startswith("## Decisão"))' <<<"$(page "/v1/rodada?id=$R1")"
check "SurrealDB fora: /rodadas lista, com o aviso"     bash -c 'grep -q "data-estado-indisponivel" <<<"$1" && grep -q "data-rodada=\"$2\"" <<<"$1"' _ "$(page /rodadas)" "$R1"
check "SurrealDB fora: a causa só no stderr do servidor" bash -c 'grep -q "estado das etapas (SurrealDB) falhou" "$1"' _ "$TMP/s/stderr"
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não voltou"; }
check "SurrealDB de volta: o aviso some"                bash -c '! grep -q "data-estado-indisponivel" <<<"$1"' _ "$(page "/rodada?id=$R1")"
# o SurrealDB volta vazio de etapa: a página usa o DuckDB e avisa
sr "DELETE etapa" >/dev/null
check "SurrealDB sem etapa nenhuma: a página sai do DuckDB e avisa que o estado precisa ser remontado" bash -c 'grep -q "data-estado-indisponivel" <<<"$1" && grep -q "data-etapa=\"fechamento\"" <<<"$1"' _ "$(page "/rodada?id=$R1")"

# ---------------------------------------------------------------- 8. rebuild-state remonta a etapa e imprime `etapas=`
studio_stop
DB="$TMP/s/db.duckdb"
check "DuckDB: os 12 eventos de etapa com corpo, o texto inteiro" test "$(studio_sql "$DB" "SELECT count(*) AS n FROM logs WHERE event_name = 'oute.swarm.step.published' AND body IS NOT NULL" | jq -r .n)" = 12
REB=(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio.rebuild_state)
OUT="$("${REB[@]}" 2>"$TMP/err")"; RC=$?
check "rebuild-state: rc 0 e o stderr vazio"            bash -c '[ "$1" = 0 ] && [ ! -s "$2" ]' _ "$RC" "$TMP/err"
check "rebuild-state: depois, 10 etapas"                has " etapas=10 acoes=0$"
check "rebuild-state: antes, o SurrealDB sem etapa (etapas=0)" has "^antes: .* etapas=0 acoes=0$"
check "rebuild-state: a etapa remontada é a vigente (r2 aprovado)" jqe '.[0].rev == 2 and .[0].review == "aprovado" and .[0].event == "ev-f2"' <<<"$(sr "SELECT rev, review, event FROM $SK")"
check "rebuild-state: o merge e o kaizen remontados"    jqe '.[0].key == "12"' <<<"$(sr "SELECT key FROM etapa:['$R1','merge','12']")"
sr "SELECT * FROM etapa ORDER BY id" > "$TMP/etapas-1.json"
OUT="$(AGENT_STUDIO_REBUILD_CHUNK=1 "${REB[@]}" 2>&1)"
sr "SELECT * FROM etapa ORDER BY id" > "$TMP/etapas-2.json"
check "rebuild-state de novo, em blocos de 1 linha: o mesmo estado (idempotente)" cmp -s "$TMP/etapas-1.json" "$TMP/etapas-2.json"

# ---------------------------------------------------------------- 9. lógica direto em Python
SURREAL_URL="$SURREAL_URL" SURREAL_TEST_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" \
  "$STUDIO_PY" - "$DB" > "$TMP/py.out" 2>&1 <<'PY'
import os, sys
from agent_studio import etapas, state, web
from agent_studio.app import create_app
from agent_studio.surreal import Surreal
from pycheck import check
from studio_asgi import TOKEN, Broken, Odd, get

def flat(doc):
    return [(s["title"], b["t"]) for s in doc["sections"] for b in s["blocks"]]

d = etapas.parse("## Decisão\n1. um\n2. dois\n\n## Ações\n- a\n- b\n  continua\n\n## Detalhe\nTexto.\n\n### Sub\nMais.\n")
check("gramática: as três seções, nesta ordem, sem seção faltando",
      [s["title"] for s in d["sections"]] == ["Decisão", "Ações", "Detalhe"] and d["missing"] == [])
check("gramática: lista numerada, lista de itens, parágrafo e subtítulo",
      flat(d) == [("Decisão", "ol"), ("Ações", "ul"), ("Detalhe", "p"), ("Detalhe", "h"), ("Detalhe", "p")])
check("gramática: a linha seguinte indentada continua o item", d["sections"][1]["blocks"][0]["items"][1][0]["s"] == "b continua")
check("gramática: seção que falta é dita", etapas.parse("## Decisão\nx\n")["missing"] == ["Ações", "Detalhe"])
check("gramática: texto antes da primeira seção fica numa seção sem título", etapas.parse("solto\n\n## Decisão\nx\n")["sections"][0]["title"] is None)
check("gramática: outro `## título` é texto, não seção", [s["title"] for s in etapas.parse("## Decisão\nx\n\n## Outra coisa\ny\n")["sections"]] == ["Decisão"])
check("gramática: lista que troca de tipo vira duas listas", flat(etapas.parse("- a\n1. b\n")) == [(None, "ul"), (None, "ol")])
inl = etapas.inline("a `c` **b** [t](https://x.example/p?q=1) fim")
check("inline: texto, código, negrito e link", [t["t"] for t in inl] == ["text", "code", "text", "b", "text", "a", "text"] and inl[5]["href"] == "https://x.example/p?q=1")
for bad in ("[x](javascript:alert(1))", "[x](http://a.example)", "[x](data:text/html;base64,AAAA)", "[x](//a.example)", "[x](https://a.example/ b)", "[x](https://a.example/\")"):
    check(f"inline: link recusado fica texto ({bad})", all(t["t"] == "text" for t in etapas.inline(bad)))
check("inline: o host do link sai do destino, não do texto (e userinfo não engana)", [t["host"] for t in etapas.inline("[a.com](https://b.example/x) [c](https://github.com@evil.example/y) [d](https://Sub.Exemplo.COM:8443/z?q=1)") if t["t"] == "a"] == ["b.example", "evil.example", "sub.exemplo.com"])
check("inline: link com host que o urlsplit recusa (https://[abc) não derruba: host vazio", [t["host"] for t in etapas.inline("[x](https://[abc) e [y](https://[::1)") if t["t"] == "a"] == ["", ""])
check("parse: texto com link de host inválido monta os blocos", etapas.parse("## Decisão\n[x](https://[abc)\n")["sections"][0]["blocks"][0]["inl"][0]["t"] == "a")
check("inline: HTML cru e entidade ficam texto, para o template escapar", etapas.inline("<b>x</b> &amp;") == [{"t": "text", "s": "<b>x</b> &amp;"}])
check("inline: negrito sem fechar e crase sem fechar ficam texto", [t["t"] for t in etapas.inline("**a e `b")] == ["text"])
check("fence: bloco não fechado vai até o fim, sem perder texto", flat(etapas.parse("```\nlinha\nlinha 2")) == [(None, "pre")] and etapas.parse("```\nlinha\nlinha 2")["sections"][0]["blocks"][0]["s"] == "linha\nlinha 2")
check("fence: dentro do bloco `## Decisão` é código, não seção", [s["title"] for s in etapas.parse("```\n## Decisão\n```\n")["sections"]] == [None])
check("controle: CRLF, TAB e controles não quebram nem entram", etapas.parse("## Decisão\r\nlinha\x00\x1b com \tTAB\r\n")["sections"][0]["blocks"][0]["inl"][0]["s"] == "linha com     TAB")
for cp in (0x200b, 0x200f, 0x2028, 0x2029, 0x202a, 0x202e, 0x2060, 0x2066, 0x2069, 0xfeff):
    check(f"direção: U+{cp:04X} sai do texto antes de montar os blocos", etapas.parse("## Decisão\na" + chr(cp) + "b\n")["sections"][0]["blocks"][0]["inl"][0]["s"] == "ab")
fam = "\U0001F468\u200d\U0001F469\u200d\U0001F467"
def inl0(t): return etapas.parse("## Decisão\n" + t + "\n")["sections"][0]["blocks"][0]["inl"][0]["s"]
check("ZWJ: emoji composto (família, coração em chamas) fica inteiro", inl0("a" + fam + "b") == "a" + fam + "b" and inl0("\u2764\ufe0f\u200d\U0001F525") == "\u2764\ufe0f\u200d\U0001F525")
check("ZWJ: solto, entre letras, no começo e no fim do pictograma sai", inl0("a\u200db") == "ab" and inl0("\u200d\U0001F468") == "\U0001F468" and inl0("\U0001F468\u200d") == "\U0001F468")
check("direção: acento e emoji ficam", etapas.parse("ação ✓\n")["sections"][0]["blocks"][0]["inl"][0]["s"] == "ação ✓")
check("grande: 32 KiB de uma linha só passam sem erro", flat(etapas.parse("a" * 32768)) == [(None, "p")])
check("grande: 4000 itens de lista passam", len(etapas.parse("\n".join("- i" for _ in range(4000)))["sections"][0]["blocks"][0]["items"]) == 4000)
steps = [{"kind": "fechamento", "key": "", "review": "sem-revisor"}, {"kind": "merge", "key": "7", "review": "aprovado"}, {"kind": "merge", "key": "9", "review": "reprovado"}]
b = etapas.bar(steps)
check("barra: quatro posições fixas, na ordem da rodada", [x["kind"] for x in b] == ["triagem", "merge", "kaizen", "fechamento"])
check("barra: pior veredito do tipo, contagem e posição atual", b[1]["review"] == "reprovado" and b[1]["count"] == 2 and b[3]["review"] == "sem-revisor" and b[3]["current"] and not b[1]["current"] and not b[0]["done"] and not b[2]["done"])
check("barra (#508): um item por etapa; o merge leva um por PR, com o número", [i["label"] for i in b[1]["items"]] == ["#7", "#9"] and [i["anchor"] for i in b[1]["items"]] == ["etapa-merge-7", "etapa-merge-9"] and [i["label"] for i in b[3]["items"]] == ["Fechamento"] and b[0]["items"] == [] and b[2]["items"] == [])
nv = etapas.navigate([{"anchor": "a", "title": "A"}, {"anchor": "b", "title": "B"}, {"anchor": "c", "title": "C"}])
check("navegação: posição de cada etapa e o total", [(x["pos"], x["total"]) for x in nv] == [(1, 3), (2, 3), (3, 3)])
check("navegação: anterior e seguinte são só âncora e título; as pontas não têm vizinho", nv[0]["prev"] is None and nv[0]["next"] == {"anchor": "b", "title": "B"} and nv[1]["prev"] == {"anchor": "a", "title": "A"} and nv[1]["next"] == {"anchor": "c", "title": "C"} and nv[2]["next"] is None)
one = etapas.navigate([{"anchor": "a", "title": "A"}])
check("navegação: uma etapa só (1 de 1, sem vizinho) e nenhuma etapa", (one[0]["pos"], one[0]["total"], one[0]["prev"], one[0]["next"]) == (1, 1, None, None) and etapas.navigate([]) == [])
rd = etapas.render([{"kind": "merge", "key": "5", "rev": 1, "sha256": "a" * 64, "text": "## Decisão\nx\n", "review": "aprovado"}, {"kind": "fechamento", "key": "", "rev": 1, "sha256": "b" * 64, "text": None, "review": "aprovado"}])
check("render: a navegação sai com o título fixo do tipo, nunca do texto", rd[0]["next"] == {"anchor": "etapa-fechamento", "title": "Fechamento da rodada"} and rd[1]["prev"] == {"anchor": "etapa-merge-5", "title": "Pedido de merge #5"})
check("barra: sem etapa nenhuma, nenhuma posição atual", not any(x["current"] or x["done"] for x in etapas.bar([])))
rows = [{"kind": "fechamento", "key": "", "rev": 1, "review": "aprovado", "time_unix_nano": 9}, {"kind": "fechamento", "key": "", "rev": 3, "review": "reprovado", "time_unix_nano": 1},
        {"kind": "fechamento", "key": "", "rev": 2, "review": "aprovado", "time_unix_nano": 99}, {"kind": "diagrama", "key": "", "rev": 9, "review": "aprovado", "time_unix_nano": 5},
        {"kind": "kaizen", "key": "", "rev": 1, "review": "talvez", "time_unix_nano": 5}, {"kind": "merge", "key": None, "rev": None, "review": "aprovado", "time_unix_nano": 5}]
check("current: a revisão mais alta vence, mesmo a mais antiga a chegar; tipo, veredito ou revisão inválidos saem",
      [(r["kind"], r["rev"]) for r in etapas.current(rows)] == [("fechamento", 3)])
a = lambda d: (lambda k: d.get(k))
sha = "a" * 64
ok = {"oute.swarm.step.kind": "fechamento", "oute.swarm.step.rev": 2, "oute.swarm.step.review": "aprovado", "oute.swarm.step.sha256": sha}
st = state.step_statements("r1", a(ok), 10**18, "ev", {"host": "h", "instance": None})
check("estado: evento válido gera o UPSERT da rodada e o da etapa, com texto em base64",
      len(st) >= 2 and st[-1][0] == state.STEP_UPSERT and st[-1][1]["id"] == ["r1", "fechamento", ""] and st[-1][1]["rev"] == 2 and "Decisão" not in str(st))
for name, patch in (("tipo desconhecido", {"oute.swarm.step.kind": "diagrama"}), ("veredito desconhecido", {"oute.swarm.step.review": "talvez"}),
                    ("sha256 curto", {"oute.swarm.step.sha256": "abc"}), ("revisão zero", {"oute.swarm.step.rev": 0}), ("revisão que não é número", {"oute.swarm.step.rev": "x"}),
                    ("revisão enorme", {"oute.swarm.step.rev": 10**6}), ("chave fora do merge", {"oute.swarm.step.key": "12"}),
                    ("merge sem chave", {"oute.swarm.step.kind": "merge"}), ("chave que não é número", {"oute.swarm.step.kind": "merge", "oute.swarm.step.key": "1; DROP"})):
    check(f"estado: evento inválido não vira estado ({name})", state.step_statements("r1", a({**ok, **patch}), 1, "ev", {}) == [])
import base64
check("estado: o refcheck inválido é gravado como ausente", base64.b64decode(state.step_statements("r1", a({**ok, "oute.swarm.step.refcheck": "talvez"}), 1, "ev", {})[-1][1]["b"]["refcheck"]).decode() == "ausente")
check("estado: o evento sem rodada não gera nada", state.event_statements({"event_name": state.STEP_EVENT, "_attrs": {}, "_res": {}, "time_unix_nano": 1}) == [])
sdb = Surreal(os.environ["SURREAL_URL"], "root", os.environ["SURREAL_TEST_PASS"])
class Store:
    def read(self, fn):
        import duckdb
        con = duckdb.connect(sys.argv[1], read_only=True)
        con.execute("SET TimeZone='UTC'")
        try:
            return fn(con)
        finally:
            con.close()
d = etapas.load(Store(), sdb, "swarm-1004-1306")
check("load: etapas do SurrealDB, com o texto do DuckDB pelo event id", d["state_read"] is True and [s["kind"] for s in d["steps"]] == ["merge", "kaizen", "fechamento"] and d["steps"][2]["text"].startswith("## Decisão"))
check("load: rodada que nenhum banco conhece = None", etapas.load(Store(), sdb, "nao-existe") is None)
d = etapas.load(Store(), None, "swarm-1004-1306")
check("load: sem SurrealDB (None) o estado é nulo e as etapas saem do DuckDB", d["state_read"] is None and len(d["steps"]) == 3 and d["state_error"] is None)
d = etapas.load(Store(), Odd(), "swarm-1004-1306")
check("load: SurrealDB com resposta fora do formato: DuckDB, state_read falso e só o tipo do erro", d["state_read"] is False and len(d["steps"]) == 3 and d["state_error"] == "TypeError")
import time
sdb.query('UPDATE type::record("rodada", $id) SET state = "fechada";', {"id": "swarm-1004-1400"})
tr = etapas.tray_steps(sdb, time.time_ns())
check("tray: disponível, com o total das etapas das rodadas abertas (a R2 fechada fica fora; rodada sem estado conta como aberta)", tr["available"] is True and tr["total"] == 9 and len(tr["rows"]) == 9 and all(r["round"] != "swarm-1004-1400" for r in tr["rows"]))
check("tray: as mais novas primeiro", [r["published_at"] for r in tr["rows"]] == sorted((r["published_at"] for r in tr["rows"]), reverse=True) and tr["rows"][0]["round"] == "swarm-1004-1500")
check("tray: campos de cada etapa, sem texto", all(set(r) == {"round", "kind", "key", "rev", "review", "title", "published_at", "age_seconds", "url"} for r in tr["rows"]))
fech = tr["rows"][0]
check("tray: etapa sem chave: título fixo do tipo, chave nula, link com âncora, idade", fech["kind"] == "fechamento" and fech["key"] is None and fech["title"] == "Fechamento da rodada" and fech["url"] == "/rodada?id=swarm-1004-1500#etapa-fechamento" and fech["age_seconds"] >= 0 and fech["published_at"].endswith("Z"))
m22 = next(r for r in tr["rows"] if r["round"] == "swarm-1004-1700" and r["key"] == "22")
check("tray: pedido de merge leva o número do PR no título e na âncora", m22["title"] == "Pedido de merge #22" and m22["url"].endswith("#etapa-merge-22") and m22["review"] == "aprovado" and m22["rev"] == 1)
check("tray: o veredito vai como está (reprovado da R1)", next(r for r in tr["rows"] if r["kind"] == "kaizen" and r["round"] == "swarm-1004-1306")["review"] == "reprovado")
t2 = etapas.tray_steps(sdb, time.time_ns(), limit=2)
check("tray: o limite corta as linhas e o total continua o de todas", len(t2["rows"]) == 2 and t2["total"] == 9)
class FakeSteps:
    def __init__(self, rows, n): self.rows, self.n, self.vars = rows, n, None
    def query(self, sql, variables):
        self.vars = variables
        return [{"status": "OK", "result": self.rows}, {"status": "OK", "result": [{"n": self.n}] if self.n else []}]
fk = FakeSteps([{"round": "a b/c", "kind": "merge", "key": "5", "rev": 1, "review": "aprovado", "published_at": "2026-10-04T10:00:00.5Z"},
                {"round": "x", "kind": "diagrama", "key": "", "rev": 1, "review": "aprovado", "published_at": "2026-10-04T10:00:00Z"},
                {"round": "y", "kind": "kaizen", "key": "", "rev": 1, "review": "talvez", "published_at": "2026-10-04T10:00:00Z"},
                {"round": "z", "kind": "kaizen", "key": "", "rev": 1, "review": "sem-revisor", "published_at": None}], 4)
tf = etapas.tray_steps(fk, 1790667610 * 10**9)  # 2026-10-04T10:00:10Z, se o SurrealDB usasse a hora do teste
check("tray: pede o limite de 50 ao SurrealDB", fk.vars == {"limit": 50})
check("tray: tipo ou veredito fora do formato não vira linha (o total é o do banco)", [r["round"] for r in tf["rows"]] == ["a b/c", "z"] and tf["total"] == 4)
check("tray: id da rodada codificado no link, hora com fração em segundos, idade", tf["rows"][0]["url"] == "/rodada?id=a%20b%2Fc#etapa-merge-5" and tf["rows"][0]["published_at"] == "2026-10-04T10:00:00Z" and tf["rows"][0]["age_seconds"] == 10)
check("tray: sem hora de publicação: idade nula, sem quebrar", tf["rows"][1]["age_seconds"] is None and tf["rows"][1]["review"] == "sem-revisor")
check("tray: nenhuma etapa: total zero e lista vazia", etapas.tray_steps(FakeSteps([], 0), 0) == {"available": True, "total": 0, "rows": []})
check("api: texto só no aprovado", [(s["kind"], s["text"] is not None) for s in etapas.api(d)["steps"]] == [("merge", True), ("kaizen", False), ("fechamento", True)])
status, body = get(create_app(Broken(), TOKEN, surreal=None), "/rodada", "id=x")
check("DuckDB que falha: página 500, sem a causa", status == 500 and "segredo-da-falha" not in body)
status, body = get(create_app(Broken(), TOKEN, surreal=None), "/v1/rodada", "id=x")
check("DuckDB que falha: API 500, sem a causa", status == 500 and "segredo-da-falha" not in body)
status, body = get(create_app(Broken(), TOKEN, surreal=None), "/rodadas")
check("DuckDB que falha: lista 500, sem a causa", status == 500 and "segredo-da-falha" not in body)
html = web._env().get_template("rodada.html").render(r={"id": "r<b>x", "record": None, "steps": [], "state_read": True}, bar=etapas.bar([]), state_read=True, alerts_shown=False, authed=False)
check("template: id da rodada com HTML sai escapado", "r<b>x" not in html and "r&lt;b&gt;x" in html)
PY
check_py "$TMP/py.out"
check_end
