#!/usr/bin/env bash
# Testes do cadastro de planos de assinatura (#746, ADR-08 adendo "Planos de assinatura"): a tabela `plan_history` só de acréscimo,
# a consulta "valor do plano no dia D", a semente do `[[plans]]`, `POST /planos` com a credencial de marcação (sem ela a rota não
# existe), `GET /v1/plans`, a tela `/planos` ("sem plano", nunca US$ 0), o `plano` derivado no SurrealDB e o `rebuild-state`
# (linha `planos:`). Sem Docker; o SurrealDB é o binário fixado de tests/lib/surreal.sh. Credenciais sorteadas na hora.
# Uso: tests/agent-studio-planos.test.sh   (sai != 0 se algum caso falhar)
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

READ_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
MARK_T="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
read -r COOKIE_R COOKIE_M CSRF < <(PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -c '
import sys
from agent_studio.auth import Auth
a = Auth(sys.argv[1], sys.argv[2], sys.argv[3])
print(a.cookie_value, a.mark_cookie_value, a.mark_csrf)' "$STUDIO_TOKEN" "$READ_T" "$MARK_T")
RC_="Cookie: agent_studio=$COOKIE_R"; MC_="Cookie: agent_studio=$COOKIE_R; agent_studio_mark=$COOKIE_M"
RB_=(-H "Authorization: Bearer $READ_T")
# config sem semente (planos vazios) e com a semente verdadeira do repo
printf 'timezone = "UTC"\n' > "$TMP/sem-semente.toml"
SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_READ_TOKEN="$READ_T")
sr() { local q="$1"; surreal_q "$q"; return $?; }
# plano <cookie ou vazio> <Origin ou vazio> <corpo>: POST /planos; imprime o código HTTP e deixa o corpo em $TMP/resp
plano() {
  local cookie="$1" origin="$2" body="$3"
  curl -s -o "$TMP/resp" -w '%{http_code}' -X POST ${cookie:+-H "$cookie"} ${origin:+-H "Origin: $origin"} \
    -H 'Content-Type: application/x-www-form-urlencoded' --data "$body" "$STUDIO_URL/planos/novo"
  return $?
}
# corpo <assinatura> <plano> <valor> <início> [csrf]
corpo() {
  local sub="$1" name="$2" value="$3" start="$4" csrf="${5-$CSRF}"
  python3 -c 'import sys; from urllib.parse import urlencode; print(urlencode(list(zip(["assinatura","plano","valor","inicio","csrf"], sys.argv[1:]))))' "$sub" "$name" "$value" "$start" "$csrf"
  return $?
}
# linhas <arquivo.duckdb>: as linhas da plan_history, em JSON, uma por linha
linhas() { local db="$1"; studio_sql "$db" "SELECT subscription, plan, monthly_usd, start_date, origin FROM plan_history ORDER BY registered_unix_nano"; return $?; }
# tela <arquivo> [cookie]: a página /planos inteira; dados: os atributos data-* dela em JSON
tela() { local file="$1" cookie="${2-$MC_}"; curl -s -H "$cookie" "$STUDIO_URL/planos?full=1" > "$TMP/$file"; return $?; }
dados() { local file="$1"; python3 "$ROOT/tests/lib/html-data.py" < "$TMP/$file"; return $?; }

# ---------------------------------------------------------------- 1. sem a credencial de marcação a rota não existe; sem semente, sem plano
studio_start "$TMP/s0" "${SENV[@]}" AGENT_STUDIO_CONFIG="$TMP/sem-semente.toml" || { cat "$TMP/s0/stderr"; die "agent-studio não subiu"; }
O="$STUDIO_URL"
BODY="$(corpo claude 'Max 5x' 100 2026-10-08)"
check "sem credencial de marcação configurada: POST /planos/novo = 404 (não existe), com cookie e Origin" test "$(plano "$MC_" "$O" "$BODY")" = 404
check "GET /v1/plans sem credencial: 401" test "$(code "$O/v1/plans")" = 401
check "sem semente: /v1/plans mostra as três assinaturas sem plano (current nulo, label 'sem plano')" jqe '[.subscriptions[] | select(.current == null and .label == "sem plano" and .history == [])] | length == 3' <<<"$(curl -s "${RB_[@]}" "$O/v1/plans")"
check "sem semente: a tela diz 'sem plano' nas três e não mostra valor" bash -c 'jq -e "[.[] | select(has(\"assinatura\") and .plano == \"sem plano\")] | length == 3 and ([.[] | select(has(\"valor\")) | .valor] | all(. == \"\"))" <<<"$1" >/dev/null' _ "$(tela t0.html "$RC_"; dados t0.html)"
studio_stop

# ---------------------------------------------------------------- 2. a rota de escrita, com a credencial de marcação
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_CONFIG="$TMP/sem-semente.toml" AGENT_STUDIO_MARK_TOKEN="$MARK_T" || { cat "$TMP/s/stderr"; die "agent-studio não voltou"; }
O="$STUDIO_URL"; DB="$TMP/s/db.duckdb"
check "sem nenhuma credencial: 401"                              test "$(plano "" "$O" "$BODY")" = 401
check "com a credencial de leitura (cookie): 403"                test "$(plano "$RC_" "$O" "$BODY")" = 403
check "com a credencial de leitura (Bearer): 403"                test "$(curl -s -o /dev/null -w '%{http_code}' -X POST "${RB_[@]}" -H "Origin: $O" -H 'Content-Type: application/x-www-form-urlencoded' --data "$BODY" "$O/planos/novo")" = 403
check "cookie de marcação sem Origin: 403"                       test "$(plano "$MC_" "" "$BODY")" = 403
check "cookie de marcação com Origin de outro site: 403"         test "$(plano "$MC_" "https://outro.example" "$BODY")" = 403
check "csrf errado: 403"                                         test "$(plano "$MC_" "$O" "$(corpo claude 'Max 5x' 100 2026-10-08 errado)")" = 403
check "assinatura desconhecida: 400"                             test "$(plano "$MC_" "$O" "$(corpo gemini X 10 2026-10-08)")" = 400
check "valor negativo: 400"                                      test "$(plano "$MC_" "$O" "$(corpo claude X -1 2026-10-08)")" = 400
check "valor com 3 casas: 400"                                   test "$(plano "$MC_" "$O" "$(corpo claude X 1.234 2026-10-08)")" = 400
check "valor acima do teto: 400"                                 test "$(plano "$MC_" "$O" "$(corpo claude X 1000000 2026-10-08)")" = 400
check "data que não existe: 400"                                 test "$(plano "$MC_" "$O" "$(corpo claude X 10 2026-02-30)")" = 400
check "nome do plano vazio: 400"                                 test "$(plano "$MC_" "$O" "$(corpo claude '  ' 10 2026-10-08)")" = 400
check "nome do plano com marcação HTML: 400"                     test "$(plano "$MC_" "$O" "$(corpo claude '<b>x</b>' 10 2026-10-08)")" = 400
check "campo a mais: 400"                                        test "$(plano "$MC_" "$O" "$BODY&x=1")" = 400
check "campo a menos: 400"                                       test "$(plano "$MC_" "$O" "assinatura=claude&plano=X&valor=1&csrf=$CSRF")" = 400
check "campo repetido: 400"                                      test "$(plano "$MC_" "$O" "$BODY&valor=2")" = 400
check "corpo acima de 4 KB: 413"                                 test "$(plano "$MC_" "$O" "$BODY&x=$(head -c 5000 /dev/zero | tr '\0' a)")" = 413
check "a recusa não devolve nada do cliente na resposta"         bash -c '! grep -q "outro.example" "$1"' _ "$TMP/resp"
check "linha certa: 303 para /planos"                            test "$(plano "$MC_" "$O" "$(corpo claude 'Max 5x' 100 2026-10-01)")" = 303
check "valor com vírgula (18,50) é aceito"                       test "$(plano "$MC_" "$O" "$(corpo zai Lite 18,50 2026-10-01)")" = 303
check "resposta JSON só com valores já conferidos"               jqe '.assinatura == "claude" and .valor_usd == 120 and .inicio == "2026-10-20" and .plano == "Max 5x"' <<<"$(curl -s -X POST -H "$MC_" -H "Origin: $O" -H 'Accept: application/json' -H 'Content-Type: application/x-www-form-urlencoded' --data "$(corpo claude 'Max 5x' 120 2026-10-20)" "$O/planos/novo")"
# o aumento do claude acima (120 desde 20/10) deixa o valor de antes valendo para os dias anteriores
plano "$MC_" "$O" "$(corpo zai Lite 20 2026-10-15)" >/dev/null
plano "$MC_" "$O" "$(corpo zai Lite 22 2026-10-15)" >/dev/null   # correção: mesmo dia, registrada depois
plano "$MC_" "$O" "$(corpo codex Gratuito 0 2026-10-01)" >/dev/null
q() { local sub="$1" day="$2"; curl -s "${RB_[@]}" "$O/v1/plans?subscription=$sub&day=$day"; return $?; }
check "valor no dia: antes da primeira linha = sem plano (plan nulo), nunca 0" jqe '.plan == null and .label == "sem plano"' <<<"$(q claude 2026-09-30)"
check "valor no dia: no dia de início vale a linha nova"       jqe '.plan.monthly_usd == 100 and .plan.plan == "Max 5x"' <<<"$(q claude 2026-10-01)"
check "valor no dia: um dia antes do aumento vale o valor antigo (100)" jqe '.plan.monthly_usd == 100' <<<"$(q claude 2026-10-19)"
check "valor no dia: no dia do aumento e depois vale o novo (120)"  jqe '.plan.monthly_usd == 120' <<<"$(q claude 2026-10-20) $(q claude 2026-12-31)"
check "valor no dia: zai antes de 15/10 vale 18,5"             jqe '.plan.monthly_usd == 18.5' <<<"$(q zai 2026-10-14)"
check "valor no dia: mesmo dia, a linha registrada por último vence (22)" jqe '.plan.monthly_usd == 22' <<<"$(q zai 2026-10-15)"
check "valor no dia: US\$ 0 do codex é 0 de verdade, não 'sem plano'" jqe '.plan.monthly_usd == 0 and .label == "Gratuito"' <<<"$(q codex 2026-10-02)"
check "consulta sem 'subscription' devolve as três com histórico" jqe '[.subscriptions[] | .history | length] == [2, 3, 1]' <<<"$(curl -s "${RB_[@]}" "$O/v1/plans?day=2026-12-31")"
check "day inválido: 400"                                      test "$(code "${RB_[@]}" "$O/v1/plans?day=2026-13-01")" = 400
check "subscription inválida: 400"                             test "$(code "${RB_[@]}" "$O/v1/plans?subscription=x")" = 400
check "parâmetro desconhecido: 400"                            test "$(code "${RB_[@]}" "$O/v1/plans?foo=1")" = 400
check "SurrealDB: um plano por linha, com o valor e o dia" test "$(sr 'SELECT count() FROM plano GROUP ALL' | jq -r '.[0].count')" = 6
tela t1.html "$RC_"
check "tela sem cookie de marcação: sem formulário, com o convite para /marcar" bash -c 'jq -e "[.[] | select(has(\"cadastro\"))] | length == 1" <<<"$1" >/dev/null && ! grep -q "novo-plano" "$2"' _ "$(dados t1.html)" "$TMP/t1.html"
tela t2.html
check "tela com cookie de marcação: formulário com o csrf e as três assinaturas" bash -c 'grep -q "id=\"novo-plano\"" "$1" && grep -q "name=\"csrf\" value=\"$2\"" "$1" && [ "$(grep -o "<option value=" "$1" | wc -l)" = 3 ]' _ "$TMP/t2.html" "$CSRF"
check "tela: o codex gratuito aparece com valor 0,00, não como 'sem plano'" jqe '. as $d | ([$d[] | select(.assinatura == "codex" and .plano == "Gratuito")] | length == 1) and ([$d[] | select(.valor == "0.00")] | length == 1)' <<<"$(dados t2.html)"
studio_stop
linhas "$DB" > "$TMP/linhas.jsonl"
check "DuckDB: as 6 linhas, na ordem em que entraram, nenhuma editada" bash -c '[ "$(wc -l < "$1")" = 6 ] && jq -sce "[.[] | [.subscription, .monthly_usd]] == [[\"claude\",100],[\"zai\",18.5],[\"claude\",120],[\"zai\",20],[\"zai\",22],[\"codex\",0]]" "$1" >/dev/null' _ "$TMP/linhas.jsonl"
check "a rota e a tabela não têm UPDATE nem DELETE" bash -c 'cd "$1/docker/agent-studio/agent_studio" && ! grep -niE "(update|delete)[[:space:]]+(from[[:space:]]+)?plan_history" planos.py marcar.py rebuild_state.py store.py' _ "$ROOT"
check "a ingestão e o replay não mencionam plan_history" bash -c 'cd "$1/docker/agent-studio/agent_studio" && ! grep -n "plan_history" otlp.py replay.py' _ "$ROOT"

# ---------------------------------------------------------------- 3. a semente do config.toml: só para a assinatura sem linha (sem SurrealDB, para não misturar com o estado da seção 2)
studio_start "$TMP/s2" AGENT_STUDIO_READ_TOKEN="$READ_T" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { cat "$TMP/s2/stderr"; die "agent-studio não subiu"; }
O="$STUDIO_URL"
check "semente: claude Max 5x, zai Lite e codex gratuito entram, com origem config" jqe '[.subscriptions[] | .current | [.plan, .monthly_usd, .origin]] == [["Max 5x", 100, "config"], ["Lite", 18, "config"], ["Gratuito", 0, "config"]]' <<<"$(curl -s "${RB_[@]}" "$O/v1/plans?day=2026-10-08")"
check "semente: antes do dia 08/10 as três estão sem plano" jqe '[.subscriptions[] | .label] == ["sem plano", "sem plano", "sem plano"]' <<<"$(curl -s "${RB_[@]}" "$O/v1/plans?day=2026-10-07")"
studio_stop
studio_start "$TMP/s2" AGENT_STUDIO_READ_TOKEN="$READ_T" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { cat "$TMP/s2/stderr"; die "agent-studio não voltou"; }
studio_stop
check "subir de novo não repete a semente (idempotente)" test "$(linhas "$TMP/s2/db.duckdb" | wc -l)" = 3
studio_start "$TMP/s" "${SENV[@]}" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml" || { cat "$TMP/s/stderr"; die "agent-studio não voltou"; }
studio_stop
check "banco que já tem histórico não recebe a semente por cima (6 linhas seguem 6)" test "$(linhas "$TMP/s/db.duckdb" | wc -l)" = 6

# ---------------------------------------------------------------- 4. rebuild-state: o plano do SurrealDB vem do DuckDB
DB="$TMP/s/db.duckdb"
snap() { local out="$1"; sr "SELECT * FROM plano ORDER BY id" > "$out"; return $?; }
snap "$TMP/plano-1.json"
REB=(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$ROOT/docker/agent-studio" "$STUDIO_PY" -m agent_studio.rebuild_state)
surreal_stop; rm -rf "${TMP:?}/sdb/data"; surreal_start "$TMP/sdb" || die "SurrealDB não voltou"
check "SurrealDB esvaziado: sem plano" test "$(sr 'SELECT count() FROM plano GROUP ALL' 2>/dev/null | jq -r 'try .[0].count // 0')" = 0
OUT="$("${REB[@]}" 2>"$TMP/err")"; RC=$?
check "rebuild-state: rc 0 e o stderr vazio"                  bash -c '[ "$1" = 0 ] && [ ! -s "$2" ]' _ "$RC" "$TMP/err"
check "rebuild-state: lê as 6 linhas do cadastro e remonta 6 planos" has_line "planos: linhas=6 antes=0 depois=6"
check "o plano remontado é igual ao que a rota gravou"        bash -c 'jq -e --slurpfile a "$1" ". == \$a[0]" "$2" >/dev/null' _ "$TMP/plano-1.json" <(sr "SELECT * FROM plano ORDER BY id")
OUT="$(AGENT_STUDIO_REBUILD_CHUNK=1 "${REB[@]}" 2>&1)"; RC=$?
check "rebuild-state de novo, em blocos de 1 linha: rc 0 e o mesmo estado (idempotente)" bash -c '[ "$1" = 0 ] && grep -qx "planos: linhas=6 antes=6 depois=6" <<<"$2"' _ "$RC" "$OUT"
check "o rebuild-state não escreve no DuckDB: as 6 linhas seguem lá" test "$(linhas "$DB" | wc -l)" = 6

# ---------------------------------------------------------------- 5. lógica direto em Python
PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" "$STUDIO_PY" - > "$TMP/py.out" 2>&1 <<'PY'
import duckdb
from agent_studio import config, marcar, planos, state
from pycheck import check

check("dinheiro: 18, 18.5, 18,50 e 0 passam; negativo, 3 casas, texto, NaN e booleano não",
      [planos.parse_money(v) for v in ("18", "18.5", "18,50", "0")] == [18.0, 18.5, 18.5, 0.0]
      and all(planos.parse_money(v) is None for v in ("-1", "1.234", "abc", "", float("nan"), float("inf"), True, 100001)))
check("dia: só AAAA-MM-DD que existe", planos.parse_day("2026-10-08") == "2026-10-08" and all(planos.parse_day(v) is None for v in ("2026-02-30", "08/10/2026", "2026-10-08\n", None, "2026-1-1")))
check("validate: normaliza o nome (espaços) e recusa assinatura fora das três", planos.validate("zai", " Lite ", "18", "2026-10-08") == ("zai", "Lite", 18.0, "2026-10-08", None)
      and planos.validate("outra", "X", "1", "2026-10-08")[4] == "assinatura desconhecida")
check("nome: 'Max 5×' e 'Max 5x' passam; começo com espaço, <, tabulação e 61 caracteres não",
      all(planos.validate("claude", n, "1", "2026-10-08")[4] is None for n in ("Max 5×", "Max 5x"))
      and all(planos.validate("claude", n, "1", "2026-10-08")[4] for n in ("<b>", "x\ty", "a" * 61)))
con = duckdb.connect()
planos.create(con)
check("sem nenhuma linha: lookup é None (sem plano), não 0", planos.lookup(con, "claude", "2026-10-08") is None and planos.at_day(con, "claude", "2026-10-08")["label"] == "sem plano")
r1 = planos.append(con, "claude", "Max 5x", 100.0, "2026-10-01", now_ns=10)
r2 = planos.append(con, "claude", "Max 5x", 120.0, "2026-10-20", now_ns=5)
r3 = planos.append(con, "claude", "Max 5x", 110.0, "2026-10-01", now_ns=5)
check("append: a hora do registro cresce sempre (mesmo com relógio atrasado)", r1["registered_unix_nano"] < r2["registered_unix_nano"] < r3["registered_unix_nano"])
check("lookup: antes do início = None; no início e depois, a linha; o dia do aumento troca; corrigida no mesmo dia, a última vence",
      planos.lookup(con, "claude", "2026-09-30") is None and planos.lookup(con, "claude", "2026-10-19")["monthly_usd"] == 110.0
      and planos.lookup(con, "claude", "2026-10-20")["monthly_usd"] == 120.0 and planos.lookup(con, "zai", "2026-10-20") is None)
check("view: assinatura sem linha vigente tem current nulo e label 'sem plano'; histórico em ordem", 
      [s["label"] for s in planos.view(con, "2026-10-08")["subscriptions"]] == ["Max 5x", "sem plano", "sem plano"]
      and [h["since"] for h in planos.view(con, "2026-10-08")["subscriptions"][0]["history"]] == ["2026-10-01", "2026-10-01", "2026-10-20"])
check("view: linha que só começa no futuro ainda é 'sem plano' hoje", planos.view(con, "2026-09-01")["subscriptions"][0]["current"] is None)
check("rows: blocos na ordem do registro; banco sem a tabela não levanta", [len(b) for b in planos.rows(con, 2)] == [2, 1] and list(planos.rows(duckdb.connect(), 2)) == [])
errors = []
seed = planos.parse_seed([{"subscription": "zai", "plan": "Lite", "monthly_usd": 18.0, "start": "2026-10-08"},
                          {"subscription": "zai", "plan": "Lite", "monthly_usd": -5, "start": "2026-10-08"}, "x"], errors)
check("config: entrada válida entra; inválida e não-tabela ficam de fora, com o motivo em errors",
      seed == [("zai", "Lite", 18.0, "2026-10-08")] and len(errors) == 2 and "valor inválido" in errors[0] and "[[plans]]" in errors[0])
errors = []
check("config: [plans] que não é lista vai para errors", planos.parse_seed({"a": 1}, errors) == [] and errors == ["[[plans]] não é lista de tabelas"])
cfg = config.load()
cfg_real = config.load("config/agent-studio/config.toml")
check("config do repo: a carga inicial traz as três assinaturas e nenhum erro", [p[:3] for p in cfg_real.plans] == [("claude", "Max 5x", 100.0), ("zai", "Lite", 18.0), ("codex", "Gratuito", 0.0)] and cfg_real.errors == [])
f = marcar.parse_plan
good = {"assinatura": ["claude"], "plano": ["Max 5x"], "valor": ["100"], "inicio": ["2026-10-08"], "csrf": ["x"]}
check("campos: o formulário certo passa", f(good) == ("claude", "Max 5x", 100.0, "2026-10-08", "x"))
check("campos: None, a mais, a menos, repetido ou valor ruim, não", f(None) is None and f({**good, "x": ["1"]}) is None and f({k: v for k, v in good.items() if k != "csrf"}) is None
      and f({**good, "valor": ["1", "2"]}) is None and f({**good, "valor": ["-3"]}) is None)
row = {"subscription": "zai", "plan": "Lite", "monthly_usd": 18.0, "start_date": "2026-10-08", "origin": "tela", "registered_unix_nano": 7}
st = state.plan_statements(row)
check("estado: a linha vira um statement com id (assinatura, dia, hora)", len(st) == 1 and st[0][1]["id"] == ["zai", "2026-10-08", 7] and st[0][1]["usd"] == 18.0)
check("estado: assinatura ou dia fora do formato não vira estado", all(state.plan_statements({**row, k: v}) == [] for k, v in (("subscription", "x"), ("start_date", "8/10"), ("start_date", None))))
PY
check_py "$TMP/py.out"
check_end
