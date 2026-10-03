#!/usr/bin/env bash
# Testes do tests/lib/check.sh (#240): a contagem que todo tests/*.test.sh usa, pelo lado em que um caso falha.
# Cada cenário roda num bash à parte (run), com a lib carregada, e confere a saída e o código de saída: caso que
# falha conta e deixa o teste vermelho, CHECK_OUT mostra a saída, die sai com 1, e os casos de um trecho em Python
# entram na soma (linha que não é caso = falha). Mais o pycheck.py, que imprime no formato que a lib soma,
# e o check-lint.py (#285), que reprova `check` com condição fora dele (`check "…" [ … ] && …`) em tests/*.test.sh.
# Mais o has/hasnt/has_line/hasnt_str sobre o $OUT (#246).
# Uso: tests/check-lib.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1   # o bad mostra a saída inteira

# run <trecho>: o trecho num bash novo, com a lib carregada e sem CHECK_OUT; define OUT e RC
run() { OUT="$(env -u CHECK_OUT bash -c "set -uo pipefail; . '$ROOT/tests/lib/check.sh'; $1" 2>&1)"; RC=$?; }

# ---------------------------------------------------------------- 1. check, ok, bad e check_end
run 'check "passa" true; check "também passa" test 1 = 1; check_end'
check "tudo ok: sai 0"                                 test "$RC" = 0
check "tudo ok: uma linha por caso"                    has_line "ok   passa"
check "tudo ok: resumo"                                has_line "2 ok, 0 falha(s)"
run 'check "passa" true; check "quebra" false; check "passa depois" true; check_end'
check "um caso falha: sai != 0"                        test "$RC" -ne 0
check "um caso falha: FAIL com a descrição"            has_line "FAIL quebra"
check "um caso falha: os outros casos rodam"           has_line "ok   passa depois"
check "um caso falha: resumo conta os dois lados"      has_line "2 ok, 1 falha(s)"
run 'ok "a"; bad "b"; bad "c"; check_end'
check "ok e bad diretos: contam"                       has_line "1 ok, 2 falha(s)"
run 'check "comando que não existe" comando-que-nao-existe-240; check_end'
check "comando que não existe: falha, não aborta"      has_line "0 ok, 1 falha(s)"

# ---------------------------------------------------------------- 2. CHECK_OUT
run 'OUT=$(printf "um\ndois\ntres"); check "quebra" false'
check "sem CHECK_OUT: o bad não mostra a saída"        hasnt_str "| "
run 'CHECK_OUT=+1; OUT=$(printf "um\ndois\ntres"); check "quebra" false'
check "CHECK_OUT=+1: a saída inteira"                  test "$(grep -c '^     | ' <<<"$OUT")" = 3
run 'CHECK_OUT=2; OUT=$(printf "um\ndois\ntres"); check "quebra" false'
check "CHECK_OUT=2: só as 2 últimas linhas"            test "$(grep '^     | ' <<<"$OUT" | tr -d '\n')" = "     | dois     | tres"
run 'CHECK_OUT=2; OUT=$(printf "um\ndois"); check "passa" true'
check "CHECK_OUT: caso que passa não mostra a saída"   hasnt_str "| "
run 'CHECK_OUT=+1; check "quebra" false; check_end'
check "CHECK_OUT sem OUT definido: não aborta (set -u)" has_line "0 ok, 1 falha(s)"

# ---------------------------------------------------------------- 3. jqe e die
run 'jqe ".a == 1" <<<"{\"a\": 1}"'
check "jqe: filtro verdadeiro = 0, sem saída"          test "$RC$OUT" = 0
run 'jqe ".a == 2" <<<"{\"a\": 1}"'
check "jqe: filtro falso != 0, sem saída"              test "$RC$OUT" = 1
run 'die "precisa de jq"; echo "não chega aqui"'
check "die: sai com 1"                                 test "$RC" = 1
check "die: FAIL com o motivo e nada depois"           test "$OUT" = "FAIL precisa de jq"

# ---------------------------------------------------------------- 3b. has, hasnt, has_line e hasnt_str sobre $OUT (#246)
run 'OUT=$(printf "um\ndois 2\na.b"); check "regex" has "^do.s"; check "falta" has "^tres"; check_end'
check "has: regex sobre o \$OUT, e o que falta falha"   bash -c 'grep -qxF "ok   regex" <<<"$1" && grep -qxF "FAIL falta" <<<"$1"' _ "$OUT"
run 'OUT=$(printf "um\ndois"); check "não tem" hasnt "^tres"; check "tem" hasnt "^um"; check_end'
check "hasnt: o contrário do has"                      bash -c 'grep -qxF "ok   não tem" <<<"$1" && grep -qxF "FAIL tem" <<<"$1"' _ "$OUT"
run 'OUT=$(printf "um\ndois 2\na.b"); check "linha" has_line "dois 2"; check "pedaço" has_line "dois"; check "literal" has_line "a.b"; check "sem regex" has_line "a.."; check_end'
check "has_line: linha inteira, sem regex"             test "$(grep -c "^ok   " <<<"$OUT") $(grep -c "^FAIL " <<<"$OUT")" = "2 2"
run 'OUT=$(printf "um\na.b"); check "sem regex" hasnt_str "a.."; check "tem" hasnt_str "a."; check_end'
check "hasnt_str: texto, sem regex"                    bash -c 'grep -qxF "ok   sem regex" <<<"$1" && grep -qxF "FAIL tem" <<<"$1"' _ "$OUT"
run 'check "has" has x; check "hasnt" hasnt x; check "has_line" has_line x; check "hasnt_str" hasnt_str x; check_end'
check "sem OUT definido: não aborta (set -u)"          has_line "2 ok, 2 falha(s)"

# ---------------------------------------------------------------- 4. casos de um trecho em Python
PYTHONPATH="$ROOT/tests/lib" python3 - > "$TMP/py.out" <<'PY'
from pycheck import check
check("certo", 1 + 1 == 2)
check("errado", 1 + 1 == 3)
check("certo de novo", True)
PY
check "pycheck.py: o formato dos casos"                test "$(cat "$TMP/py.out")" = $'ok   certo\nFAIL errado\nok   certo de novo'
run "check 'do bash' true; check_py '$TMP/py.out'; echo \"n=\$n_ok/\$n_fail\"; check_end"
check "check_py: soma os casos do Python"              has_line "3 ok, 1 falha(s)"
check "check_py: define n_ok e n_fail"                 has_line "n=2/1"
check "check_py: não repete as linhas"                 hasnt_str "certo"
check "check_py: caso do Python que falha = sai != 0"  test "$RC" -ne 0
printf 'ok   certo\nTraceback (most recent call last):\nRuntimeError: quebrou\n' > "$TMP/tb.out"
run "check_py '$TMP/tb.out'; echo \"n=\$n_ok/\$n_fail\"; check_end"
check "check_py: traceback não conta (o teste confere o total)" has_line "n=1/0"
run "check_py_lines '$TMP/py.out'; check_end"
check "check_py_lines: repete cada caso"               has_line "FAIL errado"
check "check_py_lines: soma"                           has_line "2 ok, 1 falha(s)"
run "check_py_lines '$TMP/tb.out'; check_end"
check "check_py_lines: linha que não é caso = falha"   has_line "FAIL python: RuntimeError: quebrou"
check "check_py_lines: traceback deixa o teste vermelho" bash -c '[[ "$1" -ne 0 ]] && grep -qxF "1 ok, 2 falha(s)" <<<"$2"' _ "$RC" "$OUT"
: > "$TMP/vazio.out"
run "check_py '$TMP/vazio.out'; check_py_lines '$TMP/vazio.out'; echo \"n=\$n_ok/\$n_fail\"; check_end"
check "saída vazia do Python: nada somado, sem erro"   bash -c '[[ "$1" -eq 0 ]] && grep -qxF "n=0/0" <<<"$2" && grep -qxF "0 ok, 0 falha(s)" <<<"$2"' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 5. check com condição fora dele (#285)
# check-lint.py: em `check "…" [ … ] && grep …` o grep fica fora do check e a falha dele é ignorada
cat > "$TMP/ruim.sh" <<'SH'
check "colchete e grep" [ 1 = 1 ] && grep -q x f
check "ou" true || false
check "pipe" true | cat
check "continuação" [ x ] \
  && true
for a in 1; do
  check "no laço" true && true
done
x=1; check "depois de ;" grep -q a f && ! grep -q b f
SH
cat > "$TMP/bom.sh" <<'SH'
check "bash -c" bash -c '[ 1 = 1 ] && grep -q x "$1"' _ f
check "dentro de \$()" test "$(a && b)" = x
check "a && b na descrição" true
check "dentro de aspas duplas" test "x && y" = z
check "awk" awk 'BEGIN { exit !(1 && 1) }'
check "redirecionamento" grep -q x <<<"$OUT" 2>&1
check "um só" true; x && y
run 'check "dentro de um trecho" true && true'
# check "num comentário" true && true
checkx "outra função" true && true
cat <<'EOF'
check "num heredoc" true && true
EOF
check "depois do heredoc" true
SH
lint() { OUT="$(python3 "$ROOT/tests/lib/check-lint.py" "$@")"; RC=$?; }
lint "$TMP/ruim.sh"
check "check-lint: código != 0 com o padrão"           test "$RC" -ne 0
check "check-lint: aponta cada ocorrência, com a linha" test "$OUT" = "$(printf '%s\n' "$TMP/ruim.sh:1: check com && fora dele" \
  "$TMP/ruim.sh:2: check com || fora dele" "$TMP/ruim.sh:3: check com | fora dele" "$TMP/ruim.sh:4: check com && fora dele" \
  "$TMP/ruim.sh:7: check com && fora dele" "$TMP/ruim.sh:9: check com && fora dele")"
lint "$TMP/bom.sh"
check "check-lint: condição dentro do check passa"     test "$RC$OUT" = 0
lint "$ROOT"/tests/*.test.sh
check "tests/*.test.sh: nenhum check com condição fora dele" test "$RC$OUT" = 0

check_end
