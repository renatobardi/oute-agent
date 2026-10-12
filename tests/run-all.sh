#!/usr/bin/env bash
# Roda os testes do repo em paralelo e mede quanto dura cada um (#829). Uso: tests/run-all.sh [arquivo…]
# Sem argumento: todo tests/*.test.sh. Cada teste roda com `bash <arquivo>`, com o log guardado; quantos rodam ao
# mesmo tempo: OUTE_TEST_JOBS (padrão: nproc). No CI, o tests/lib/slot.sh não limita (CI está definido): o limite é
# este. Saída: uma linha por teste (`ok`/`FALHOU`, segundos, arquivo) em ordem de nome, o log inteiro de cada falha
# e os 5 mais lentos. Código: 0 se todos passaram; 1 se algum falhou; 2 se não há teste para rodar.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNALL_OUT="$(mktemp -d)"; trap 'rm -rf "${RUNALL_OUT:?}"' EXIT
JOBS="${OUTE_TEST_JOBS:-$(nproc 2>/dev/null || echo 1)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || JOBS=1
export RUNALL_OUT

# agora: segundos com fração (python3, que os testes já exigem; `date +%N` não existe no Mac)
agora() { python3 -c 'import time; print(time.time())'; return $?; }
# uma <arquivo>: roda o teste e grava em $RUNALL_OUT/r.<n> o código, a duração e o arquivo; o log vai para r.<n>.log
uma() {
  local t="$1" res t0 t1 rc
  res="$(mktemp "$RUNALL_OUT/r.XXXXXX")"
  t0="$(agora)"
  bash "$t" > "$res.log" 2>&1; rc=$?
  t1="$(agora)"
  printf '%s %s %s\n' "$rc" "$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.1f", b - a}')" "$t" > "$res"
  return 0
}
export -f uma agora

cd "$ROOT" || exit 2
if [[ $# -eq 0 ]]; then set -- tests/*.test.sh; fi
[[ -e "$1" ]] || { echo "run-all: nenhum teste para rodar" >&2; exit 2; }
start="$(agora)"
printf '%s\0' "$@" | xargs -0 -P "$JOBS" -n1 bash -c 'uma "$1"' _
total="$(awk -v a="$start" -v b="$(agora)" 'BEGIN {printf "%.1f", b - a}')"

fail=0
for res in "$RUNALL_OUT"/r.*; do
  [[ "$res" != *.log ]] || continue
  read -r rc secs t < "$res"
  st=ok
  [[ "$rc" == 0 ]] || { st=FALHOU; fail=$((fail + 1)); }
  printf '%-7s %7ss  %s\n' "$st" "$secs" "$t" >> "$RUNALL_OUT/lista.txt"
done
[[ -e "$RUNALL_OUT/lista.txt" ]] || : > "$RUNALL_OUT/lista.txt"
sort -k3 "$RUNALL_OUT/lista.txt"
for res in "$RUNALL_OUT"/r.*; do
  [[ "$res" != *.log ]] || continue
  read -r rc secs t < "$res"
  [[ "$rc" == 0 ]] && continue
  echo "::group::$t (falhou, código $rc)"
  tail -n 60 "$res.log"
  echo "::endgroup::"
done
echo "--- 5 mais lentos:"
sort -k2 -rn "$RUNALL_OUT/lista.txt" | head -n 5
echo "--- $(wc -l < "$RUNALL_OUT/lista.txt" | tr -d ' ') testes, $fail falharam, $total s no total (JOBS=$JOBS)"
[[ "$fail" -eq 0 ]]
