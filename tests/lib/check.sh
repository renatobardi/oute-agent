# Contagem e relato dos casos de um tests/*.test.sh, para `source` logo depois de definir ROOT.
# check <descrição> <comando…>: roda o comando e conta `ok` ou `FAIL`; ok/bad <descrição>: conta direto.
# CHECK_OUT=<n>: o bad mostra também as últimas <n> linhas de $OUT, a saída do comando conferido (+1 = todas).
# jqe <filtro> [arquivo…]: `jq -e` sem saída. die <motivo>: falta o que o teste precisa para rodar; sai com 1.
# has_pty: há script(1) do util-linux para rodar um comando com terminal (`script -qec "<comando>" /dev/null`).
# check_py <arquivo>: soma os casos que um trecho em Python imprimiu (`ok   …`/`FAIL …`, como o pycheck.py),
# sem repetir as linhas; define n_ok e n_fail. check_py_lines <arquivo>: repete cada caso, e linha que não é caso
# (um traceback) conta como falha. check_end: resumo e código de saída; é a última linha do teste.
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() {
  fail=$((fail + 1)); printf 'FAIL %s\n' "$1"
  [[ -z "${CHECK_OUT:-}" ]] || printf '%s\n' "${OUT:-}" | tail -n "$CHECK_OUT" | sed 's/^/     | /'
}
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
jqe() { jq -e "$@" >/dev/null; }
die() { echo "FAIL $*"; exit 1; }
has_pty() { command -v script >/dev/null && script -qec true /dev/null </dev/null >/dev/null 2>&1; }
check_py() {
  n_ok="$(grep -c '^ok   ' "$1")"; n_fail="$(grep -c '^FAIL ' "$1")"
  pass=$((pass + n_ok)); fail=$((fail + n_fail))
}
check_py_lines() {
  local line
  while IFS= read -r line; do
    case "$line" in "ok   "*) ok "${line#ok   }" ;; "FAIL "*) bad "${line#FAIL }" ;; *) bad "python: $line" ;; esac
  done < "$1"
}
check_end() { printf '\n%d ok, %d falha(s)\n' "$pass" "$fail"; [[ "$fail" -eq 0 ]]; }
