#!/usr/bin/env bash
# Testes da página do ciclo do agent-studio (#509, ADR-08 "Página da rodada e do ciclo"): `oute.swarm.cycle` do evento da
# triagem no registro `rodada` (a revisão vigente da triagem vale, em qualquer ordem de chegada), `GET /ciclo?id=` (as
# rodadas do ciclo, o resumo do ciclo como etapa com revisor, o id sempre validado e nunca devolvido), o link da rodada
# para o ciclo, o resumo no bloco `steps` do tray, o SurrealDB fora e o `rebuild-state`. Sem Docker; o SurrealDB é o
# binário fixado de tests/lib/surreal.sh.
# Uso: tests/agent-studio-ciclo.test.sh   (sai != 0 se algum caso falhar)
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
# ciclo C (#509): rodadas A e B (triagem com o ciclo); A também tem fechamento e o evento de abertura (repo). Rodada X: ciclo D.
# Rodada Y: triagem r2 sem ciclo chega ANTES da r1 (com C): a revisão vigente não tem ciclo. Rodada Z: ciclo fora do formato.
# Resumo do ciclo C: pasta P, `ciclo` r2 aprovado chega ANTES do r1 sem-revisor. Ciclo E (#700): só o resumo. Ciclo F (#800): só rodada.
NOW="$(date +%s)"
C='renatobardi/oute-agent#509'; D='renatobardi/oute-agent#600'; E='renatobardi/oute-agent#700'; F='renatobardi/oute-agent#800'
CQ='renatobardi%2Foute-agent%23509'; EQ='renatobardi%2Foute-agent%23700'; FQ='renatobardi%2Foute-agent%23800'
A=swarm-1004-2000; B=swarm-1004-2100; X=swarm-1004-2200; Y=swarm-1004-2300; Z=swarm-1004-2400
P=ciclo-renatobardi_oute-agent-509; PE=ciclo-renatobardi_oute-agent-700
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" <<'PY'
import hashlib, json, sys
from otlp_json import event, rl
tmp, NOW = sys.argv[1], int(sys.argv[2])
res = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "claude"}
def step(t, rnd, eid, kind, rev, review, text, cycle=None, **extra):
    sha = hashlib.sha256(text.encode()).hexdigest()
    attrs = {"oute.swarm.round": rnd, "oute.swarm.step.kind": kind, "oute.swarm.step.rev": rev, "oute.swarm.step.sha256": sha,
             "oute.swarm.step.review": review, "oute.swarm.step.writer": "claude-sonnet-5-5", "oute.swarm.step.reviewer": "claude-opus-5-5",
             "oute.swarm.step.refcheck": "ausente", **extra}
    if cycle: attrs["oute.swarm.cycle"] = cycle
    return event(t, "oute.swarm.step.published", eid, attrs, text)
C, D, E, F = 'renatobardi/oute-agent#509', 'renatobardi/oute-agent#600', 'renatobardi/oute-agent#700', 'renatobardi/oute-agent#800'
TRI = "## Decisão\n1. abrir as issues\n\n## Ações\n- escolher\n\n## Detalhe\nTriagem.\n"
SUM1 = "## Decisão\n1. versão antiga do resumo, sem revisor\n"
SUM2 = ("## Decisão\n1. fechar o ciclo **509** <b>falso</b>\n\n## Ações\n- abrir a `iter`\n\n"
        "## Detalhe\nQuatro rodadas <script>alert('ciclo')</script> e [PR](https://github.com/renatobardi/oute-agent/pull/600).\n")
SUME = "## Decisão\n1. ciclo só com resumo\n"
b1 = [event(NOW - 5000, "oute.swarm.round.opened", "ev-a-open", {"oute.swarm.round": "swarm-1004-2000", "oute.swarm.repo": "oute-agent", "oute.swarm.max": 3}),
      step(NOW - 4000, "swarm-1004-2000", "ev-a-tri", "triagem", 1, "aprovado", TRI, C),
      step(NOW - 3900, "swarm-1004-2000", "ev-a-fec", "fechamento", 1, "aprovado", "## Decisão\n1. fechar\n"),
      step(NOW - 3000, "swarm-1004-2100", "ev-b-tri", "triagem", 1, "aprovado", TRI, C),
      step(NOW - 2500, "swarm-1004-2200", "ev-x-tri", "triagem", 1, "aprovado", TRI, D),
      step(NOW - 2000, "swarm-1004-2300", "ev-y-tri2", "triagem", 2, "aprovado", TRI + "Corrigida.\n"),
      step(NOW - 1500, "swarm-1004-2400", "ev-z-tri", "triagem", 1, "aprovado", TRI, "javascript:alert(1)"),
      step(NOW - 1000, "ciclo-renatobardi_oute-agent-509", "ev-p-2", "ciclo", 2, "aprovado", SUM2, C),
      step(NOW - 900, "ciclo-renatobardi_oute-agent-700", "ev-pe-1", "ciclo", 1, "aprovado", SUME, E),
      step(NOW - 800, "ciclo-renatobardi_oute-agent-800", "ev-pf-sem", "ciclo", 1, "aprovado", SUME),
      step(NOW - 700, "swarm-1004-2500", "ev-f-tri", "triagem", 1, "aprovado", TRI, F)]
b2 = [step(NOW - 2100, "swarm-1004-2300", "ev-y-tri1", "triagem", 1, "aprovado", TRI, C),
      step(NOW - 1100, "ciclo-renatobardi_oute-agent-509", "ev-p-1", "ciclo", 1, "sem-revisor", SUM1, C)]
json.dump({"resourceLogs": [rl(res, b1)]}, open(f"{tmp}/b1.json", "w"))
json.dump({"resourceLogs": [rl(res, b2)]}, open(f"{tmp}/b2.json", "w"))
PY

SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml")
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
C_=(-H "Authorization: Bearer $STUDIO_TOKEN")
page() { local path="$1"; studio_page "${C_[@]}" "$STUDIO_URL$path"; return $?; }
sr() { local q="$1"; surreal_q "$q"; return $?; }
rounds_of() { data | jq -c '[.[] | select(has("rodada")) | .rodada]'; return $?; }

# ---------------------------------------------------------------- 1. antes de qualquer evento; quem lê; o id
check "sem evento nenhum: /ciclo = 404"                 test "$(code "${C_[@]}" "$STUDIO_URL/bloco/ciclo/resumo?id=$CQ")" = 404
check "sem id: /ciclo = 400"                            test "$(code "${C_[@]}" "$STUDIO_URL/ciclo")" = 400
check "sem login: /ciclo = 303 para o /login, com a volta" test "$(code "$STUDIO_URL/ciclo?id=$CQ")$(hdr location "$STUDIO_URL/ciclo?id=$CQ")" = "303/login?next=%2Fciclo%3Fid%3Drenatobardi%252Foute-agent%2523509"
for bad in 'ZZlixo' '%3Cb%3EZZx%3C%2Fb%3E%2Fy%231' 'ZZa%2Fb' 'ZZa%2Fb%231%3Cscript%3E' 'ZZa%2Fb%23' 'ZZa%2Fb%231%0A' '..%2F..%2FZZx%2Fy%2312' "$(printf 'a%.0s' $(seq 1 200))%2Fb%231"; do
  body="$(studio_page "${C_[@]}" "$STUDIO_URL/ciclo?id=$bad")"; rc="$(code "${C_[@]}" "$STUDIO_URL/ciclo?id=$bad")"
  check "id inválido ($bad): 400 e o id nunca volta na página" bash -c '[ "$1" = 400 ] && ! grep -qF "ZZ" <<<"$2" && ! grep -qF "<b>" <<<"$2" && ! grep -qF "<script>" <<<"$2" && grep -qF "O id do ciclo tem de ser" <<<"$2"' _ "$rc" "$body"
done

# ---------------------------------------------------------------- 2. ingestão e o estado derivado
check "ingestão: o lote com as triagens, o resumo r2 e os outros ciclos = 200" test "$(post logs "$TMP/b1.json")" = 200
check "ingestão: o r1 do resumo e a r1 da rodada Y chegam DEPOIS = 200" test "$(post logs "$TMP/b2.json")" = 200
check "SurrealDB: o ciclo da triagem entra no registro da rodada A" jqe --arg c "$C" '.[0].cycle == $c' <<<"$(sr "SELECT cycle FROM rodada:\`$A\`")"
check "SurrealDB: e no da rodada B" jqe --arg c "$C" '.[0].cycle == $c' <<<"$(sr "SELECT cycle FROM rodada:\`$B\`")"
check "SurrealDB: a rodada de outro ciclo (X) leva o dela" jqe --arg d "$D" '.[0].cycle == $d' <<<"$(sr "SELECT cycle FROM rodada:\`$X\`")"
check "SurrealDB: Y, com a triagem r2 sem ciclo chegando antes da r1, fica sem ciclo (a revisão vigente vale)" jqe '.[0] | has("cycle") | not' <<<"$(sr "SELECT * FROM rodada:\`$Y\`")"
check "SurrealDB: o ciclo fora do formato não vira ciclo da rodada Z" jqe '.[0] | has("cycle") | not' <<<"$(sr "SELECT * FROM rodada:\`$Z\`")"
check "SurrealDB: o resumo é a revisão vigente (r2 aprovado) e leva o ciclo" jqe --arg c "$C" '.[0] | .rev == 2 and .review == "aprovado" and .kind == "ciclo" and .cycle == $c and .event == "ev-p-2"' <<<"$(sr "SELECT rev, review, kind, cycle, event FROM etapa:['$P','ciclo','']")"
check "SurrealDB: a pasta do ciclo não ganha registro de rodada" jqe 'length == 0 or (.[0] | length == 0)' <<<"$(sr "SELECT * FROM rodada:\`$P\`")"
check "SurrealDB: o resumo sem ciclo (ev-pf-sem) não vira estado" jqe 'length == 0 or (.[0] | length == 0)' <<<"$(sr "SELECT * FROM etapa:['ciclo-renatobardi_oute-agent-800','ciclo','']")"
post logs "$TMP/b2.json" >/dev/null; post logs "$TMP/b1.json" >/dev/null
check "reenvio dos dois lotes: o estado não muda (Y sem ciclo, resumo r2)" bash -c 'jqe() { jq -e "$@" >/dev/null; }; jqe ".[0] | has(\"cycle\") | not" <<<"$1" && jqe ".[0].rev == 2" <<<"$2"' _ "$(sr "SELECT * FROM rodada:\`$Y\`")" "$(sr "SELECT rev FROM etapa:['$P','ciclo','']")"

# ---------------------------------------------------------------- 3. /ciclo
page "/ciclo?id=$CQ" > "$TMP/c.html"
check "ciclo C: 200"                                     test "$(code "${C_[@]}" "$STUDIO_URL/ciclo?id=$CQ")" = 200
check "ciclo C: as rodadas A e B, na ordem em que abriram; X, Y e Z de fora" jqe --arg a "$A" --arg b "$B" '. == [$a, $b]' <<<"$(rounds_of < "$TMP/c.html")"
check "ciclo C: cada rodada tem link para a página dela" bash -c 'grep -qF "<a href=\"/rodada?id=$2\">$2</a>" "$1" && grep -qF "<a href=\"/rodada?id=$3\">$3</a>" "$1"' _ "$TMP/c.html" "$A" "$B"
check "ciclo C: etapas e veredito de cada rodada" jqe --arg a "$A" --arg b "$B" '. == [{"rodada": $a, "etapas": "2", "review": "aprovado"}, {"rodada": $b, "etapas": "1", "review": "aprovado"}]' <<<"$(data < "$TMP/c.html" | jq -c '[.[] | select(has("rodada")) | {rodada, etapas, review}]')"
check "ciclo C: o resumo é a r2 aprovada (a mais alta, não a mais recente a chegar), aberto e sem aviso" bash -c 'f="$1"; grep -q "data-etapa=\"ciclo\" data-rev=\"2\" data-review=\"aprovado\"" "$f" && grep -q "<h2>Resumo do ciclo</h2>" "$f" && grep -q "data-texto>" "$f" && ! grep -q "versão antiga" "$f" && ! grep -q "data-aviso\|data-texto-fechado" "$f"' _ "$TMP/c.html"
check "ciclo C: o texto do resumo sai escapado, link https vira link" bash -c 'f="$1"; ! grep -q "<b>falso</b>\|<script>alert" "$f" && grep -q "&lt;b&gt;falso&lt;/b&gt;" "$f" && grep -q "&lt;script&gt;alert(&#39;ciclo&#39;)&lt;/script&gt;" "$f" && grep -q "<strong>509</strong>" "$f" && grep -q "href=\"https://github.com/renatobardi/oute-agent/pull/600\"" "$f"' _ "$TMP/c.html"
check "ciclo C: revisão, autor e revisor no topo do resumo" bash -c 'grep -qE "revisão 2 · publicada em 20[0-9-]+ [0-9:]+ GMT-3 · autor claude-sonnet-5-5 · revisor claude-opus-5-5 · sha256 <code>[0-9a-f]{12}</code>" "$1"' _ "$TMP/c.html"
check "ciclo C: só leitura, sem script nem estilo inline, mesma CSP" bash -c 'f="$1"; [ "$(grep -ho "<form[^>]*>" "$f" | sort -u)" = "<form method=\"post\" action=\"/logout\">" ] && ! grep -hiE "<script(>| [^>]*>)[^<]|<style|[ \"]style=|[ \"]on[a-z]+=\"" "$f" && [ "$(grep -ho "<script[^>]*>" "$f" | sort -u)" = "$(printf '<script src=\"/static/htmx.min.js\" defer>\n<script src=\"/static/loading.js\" defer>')" ]' _ "$TMP/c.html"
check "ciclo C: CSP igual à das outras telas, sem cache" test "$(hdr content-security-policy "${C_[@]}" "$STUDIO_URL/ciclo?id=$CQ")" = "$(hdr content-security-policy "${C_[@]}" "$STUDIO_URL/rodadas")" -a "$(hdr cache-control "${C_[@]}" "$STUDIO_URL/ciclo?id=$CQ")" = no-store
check "POST /ciclo: 405 (só leitura)"                    test "$(code -X POST "${C_[@]}" "$STUDIO_URL/ciclo?id=$CQ")" = 405
page "/ciclo?id=$EQ" > "$TMP/e.html"
check "ciclo E (só o resumo): 200, o resumo e a mensagem de sem rodadas" bash -c 'grep -q "data-etapa=\"ciclo\"" "$1" && grep -q "data-sem-rodadas" "$1" && ! grep -q "data-sem-resumo" "$1"' _ "$TMP/e.html"
page "/ciclo?id=$FQ" > "$TMP/f.html"
check "ciclo F (só a rodada): 200, a rodada e a mensagem de sem resumo" bash -c 'grep -q "data-sem-resumo" "$1" && grep -q "data-rodada=\"swarm-1004-2500\"" "$1" && ! grep -q "data-etapa=\"ciclo\"" "$1"' _ "$TMP/f.html"
check "ciclo que ninguém conhece (id válido): 404"       test "$(code "${C_[@]}" "$STUDIO_URL/bloco/ciclo/resumo?id=renatobardi%2Foute-agent%23999")" = 404

# ---------------------------------------------------------------- 4. as outras telas
page /rodadas > "$TMP/list.html"
check "/rodadas: a pasta do resumo do ciclo não é rodada"  bash -c '! grep -q "ciclo-renatobardi" "$1"' _ "$TMP/list.html"
check "/rodadas: a rodada A liga ao ciclo; a Y e a Z não têm ciclo" bash -c 'f="$1"; grep -q "<a href=\"/ciclo?id=$2\">$3</a>" "$f" && [ "$(grep -c "href=\"/ciclo?id=" "$f")" = 4 ]' _ "$TMP/list.html" "$CQ" "$C"
page "/rodada?id=$A" > "$TMP/ra.html"
check "/rodada: o ciclo da rodada leva à página do ciclo, no topo e na etapa" bash -c 'f="$1"; grep -q "data-ciclo" "$f" && [ "$(grep -c "href=\"/ciclo?id=$2\"" "$f")" -ge 2 ]' _ "$TMP/ra.html" "$CQ"
page "/rodada?id=$Z" > "$TMP/rz.html"
check "/rodada: ciclo fora do formato fica texto escapado, sem link" bash -c 'f="$1"; ! grep -q "href=\"/ciclo" "$f" && ! grep -q "href=\"javascript" "$f" && grep -q "ciclo javascript:alert(1)" "$f"' _ "$TMP/rz.html"
check "/v1/rodada: o ciclo da rodada, só se tem o formato" jqe --arg c "$C" '.cycle == $c' <<<"$(page "/v1/rodada?id=$A")"
check "/v1/rodada: Z sem ciclo (fora do formato)"        jqe '.cycle == null' <<<"$(page "/v1/rodada?id=$Z")"
check "/rodada da pasta do resumo: sem barra de posição do ciclo (o resumo não é etapa de rodada)" bash -c 'b="$(studio_page -H "Authorization: Bearer $2" "$1/rodada?id=ciclo-renatobardi_oute-agent-509")"; ! grep -q "data-passo=\"ciclo\"" <<<"$b" && grep -q "<h2>Resumo do ciclo</h2>" <<<"$b"' _ "$STUDIO_URL" "$STUDIO_TOKEN"

# ---------------------------------------------------------------- 5. tray: o resumo abre a página do ciclo
T="$(curl -s "${C_[@]}" "$STUDIO_URL/v1/tray")"
check "tray: o resumo do ciclo C entra no bloco steps, com título fixo e a url da página do ciclo" jqe --arg u "/ciclo?id=$CQ" '.steps.rows | map(select(.kind == "ciclo" and .url == $u)) | length == 1 and (.[0].title == "Resumo do ciclo") and (.[0] | has("text") | not)' <<<"$T"
check "tray: o resumo sem ciclo (ev-pf-sem) não vira linha, e as etapas de rodada seguem para a página da rodada" jqe --arg a "/rodada?id=$A#etapa-triagem" '(.steps.rows | map(select(.kind == "ciclo")) | length) == 2 and (.steps.rows | map(.url) | index($a) != null)' <<<"$T"

# ---------------------------------------------------------------- 6. SurrealDB fora: a página sai do DuckDB e avisa
surreal_stop
page "/ciclo?id=$CQ" > "$TMP/c-down.html"
check "SurrealDB fora: /ciclo 200, com o aviso"          bash -c 'grep -q "data-estado-indisponivel" "$1"' _ "$TMP/c-down.html"
check "SurrealDB fora: as rodadas do ciclo vêm do DuckDB (revisão vigente da triagem)" jqe --arg a "$A" --arg b "$B" '. == [$a, $b]' <<<"$(rounds_of < "$TMP/c-down.html")"
check "SurrealDB fora: o resumo é a r2 do DuckDB" bash -c 'grep -q "data-etapa=\"ciclo\" data-rev=\"2\"" "$1" && ! grep -q "versão antiga" "$1"' _ "$TMP/c-down.html"
check "SurrealDB fora: a causa só no stderr"             bash -c 'grep -q "estado do ciclo (SurrealDB) falhou" "$1" && ! grep -qiE "Errno|Traceback|connection" <<<"$(sed "s/SurrealDB/X/g" "$2")"' _ "$TMP/s/stderr" "$TMP/c-down.html"
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não voltou"; }
check "SurrealDB de volta: o aviso some"                 bash -c '! grep -q "data-estado-indisponivel" <<<"$1"' _ "$(page "/ciclo?id=$CQ")"
sr "DELETE etapa; DELETE rodada" >/dev/null
check "SurrealDB sem estado nenhum: a página sai do DuckDB e avisa" bash -c 'grep -q "data-estado-indisponivel" <<<"$1" && grep -q "data-rodada=\"$2\"" <<<"$1"' _ "$(page "/ciclo?id=$CQ")" "$A"

# ---------------------------------------------------------------- 7. rebuild-state remonta o ciclo da rodada
studio_stop
DB="$TMP/s/db.duckdb"
REB=(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio.rebuild_state)
OUT="$("${REB[@]}" 2>"$TMP/err")"; RC=$?
check "rebuild-state: rc 0 e o stderr vazio"             bash -c '[ "$1" = 0 ] && [ ! -s "$2" ]' _ "$RC" "$TMP/err"
check "rebuild-state: o ciclo da rodada A volta"         jqe --arg c "$C" '.[0].cycle == $c' <<<"$(sr "SELECT cycle FROM rodada:\`$A\`")"
check "rebuild-state: Y segue sem ciclo, e o resumo r2 volta" bash -c 'jqe() { jq -e "$@" >/dev/null; }; jqe ".[0] | has(\"cycle\") | not" <<<"$1" && jqe ".[0].rev == 2 and .[0].review == \"aprovado\"" <<<"$2"' _ "$(sr "SELECT * FROM rodada:\`$Y\`")" "$(sr "SELECT rev, review FROM etapa:['$P','ciclo','']")"
sr "SELECT * FROM rodada ORDER BY id" > "$TMP/r-1.json"
OUT="$(AGENT_STUDIO_REBUILD_CHUNK=1 "${REB[@]}" 2>&1)"
sr "SELECT * FROM rodada ORDER BY id" > "$TMP/r-2.json"
check "rebuild-state de novo, em blocos de 1 linha: o mesmo estado (idempotente)" cmp -s "$TMP/r-1.json" "$TMP/r-2.json"

# ---------------------------------------------------------------- 8. lógica direto em Python
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - > "$TMP/py.out" 2>&1 <<'PY'
from agent_studio import etapas, state
from pycheck import check
a = lambda d: (lambda k: d.get(k))
sha = "a" * 64
base = {"oute.swarm.step.rev": 1, "oute.swarm.step.review": "aprovado", "oute.swarm.step.sha256": sha}
C = "renatobardi/oute-agent#509"
tri = state.step_statements("r1", a({**base, "oute.swarm.step.kind": "triagem", "oute.swarm.cycle": C}), 10**18, "ev", {"host": "h"})
check("estado: a triagem gera o registro da rodada, a etapa e a atualização do ciclo, nesta ordem", tri[-2][0] == state.STEP_UPSERT and tri[-1][0] == state.STEP_CYCLE)
check("estado: o ciclo vai em base64 (texto nunca no MERGE)", "renatobardi" not in str(tri[-1][1]["c"]) and tri[-1][1]["rev"] == 1)
sem = state.step_statements("r1", a({**base, "oute.swarm.step.kind": "triagem"}), 1, "ev", {})
check("estado: triagem sem ciclo limpa o campo (c vazio)", sem[-1][0] == state.STEP_CYCLE and sem[-1][1]["c"] == "")
inv = state.step_statements("r1", a({**base, "oute.swarm.step.kind": "triagem", "oute.swarm.cycle": "javascript:alert(1)"}), 1, "ev", {})
check("estado: ciclo fora do formato limpa o campo", inv[-1][1]["c"] == "")
for kind in ("merge", "kaizen", "fechamento"):
    extra = {"oute.swarm.step.key": "7"} if kind == "merge" else {}
    st = state.step_statements("r1", a({**base, **extra, "oute.swarm.step.kind": kind, "oute.swarm.cycle": C}), 1, "ev", {})
    check(f"estado: só a triagem mexe no ciclo da rodada ({kind})", all(s[0] != state.STEP_CYCLE for s in st))
cic = state.step_statements("ciclo-o_r-1", a({**base, "oute.swarm.step.kind": "ciclo", "oute.swarm.cycle": C}), 1, "ev", {"host": "h"})
check("estado: o resumo do ciclo gera só a etapa, sem registro de rodada", [s[0] for s in cic] == [state.STEP_UPSERT])
check("estado: o resumo sem ciclo, ou com ciclo fora do formato, não vira estado",
      state.step_statements("p", a({**base, "oute.swarm.step.kind": "ciclo"}), 1, "ev", {}) == []
      and state.step_statements("p", a({**base, "oute.swarm.step.kind": "ciclo", "oute.swarm.cycle": "x"}), 1, "ev", {}) == [])
check("estado: o resumo do ciclo com chave não é válido", not state.step_valid("ciclo", "3", 1, "aprovado", sha))
check("estado: o resumo do ciclo sem chave é válido", state.step_valid("ciclo", "", 1, "aprovado", sha))
check("cycle_url: só o formato <dono>/<repo>#<n> vira link, com o # codificado", etapas.cycle_url(C) == "/ciclo?id=renatobardi%2Foute-agent%23509")
for bad in (None, "", "lixo", "a/b", "a/b#", "a/b#1x", "javascript:alert(1)", "a/b#1\n", "a/" + "b" * 101 + "#1", "<b>/x#1"):
    check(f"cycle_url: sem link para {bad!r}", etapas.cycle_url(bad) is None)
check("barra: o resumo do ciclo não é posição da rodada", [b["kind"] for b in etapas.bar([])] == ["triagem", "merge", "kaizen", "fechamento"])
check("título fixo do resumo do ciclo", etapas.title({"kind": "ciclo", "key": ""}) == "Resumo do ciclo")
check("current: o resumo do ciclo tem a revisão vigente como as outras",
      [(r["kind"], r["rev"]) for r in etapas.current([{"kind": "ciclo", "key": "", "rev": 1, "review": "aprovado", "sha256": sha, "time_unix_nano": 1},
                                                        {"kind": "ciclo", "key": "", "rev": 2, "review": "reprovado", "sha256": sha, "time_unix_nano": 0}])] == [("ciclo", 2)])
PY
check_py "$TMP/py.out"
check_end
