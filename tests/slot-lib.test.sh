#!/usr/bin/env bash
# Testes do tests/lib/slot.sh (#623): a vaga de teste que limita quantos tests/*.test.sh rodam ao mesmo tempo no
# container. Confere as vagas (uma por processo, no máximo N), a espera, a liberação quando o processo morre
# (`kill -9`) e os casos em que não há vaga a pegar (processo filho, CI, sem flock, pasta que não se cria, prazo).
# Bash puro; pasta de vagas própria do teste, nunca a do container. Precisa de flock.
# Uso: tests/slot-lib.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOT="$ROOT/tests/lib/slot.sh"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
  rm -rf "${TMP:?}"
  return 0
}
trap cleanup EXIT
. "$ROOT/tests/lib/check.sh"
command -v flock >/dev/null || die "precisa de flock"

# nproc falso (3 núcleos), para o número de vagas não depender da máquina
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\necho 3\n' > "$BIN/nproc"; chmod +x "$BIN/nproc"

# sl <pasta> <vagas> <prazo> <trecho> [arg…]: roda o trecho num processo novo com o slot.sh carregado, sem a vaga nem
# o CI de quem roda este teste; stdout em $OUT, stderr em $ERR, código em $RC
sl() {
  local dir="$1" n="$2" wait_s="$3" code="$4"
  shift 4
  OUT="$(env -u OUTE_TEST_SLOT -u CI -u GITHUB_ACTIONS OUTE_TEST_SLOT_DIR="$dir" OUTE_TEST_SLOTS="$n" OUTE_TEST_SLOT_WAIT="$wait_s" \
         bash -c ". '$SLOT'; $code" _ "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
  return 0
}
TAKE='slot_take; echo "rc=$? slot=${OUTE_TEST_SLOT:-}"'
# holder <nome> <pasta> <vagas> <prazo>: processo em segundo plano que pega uma vaga, grava o resultado em
# $TMP/<nome>.got e fica parado (num `read` do fifo, sem processo filho que herde a vaga); define HPID
holder() {
  local name="$1" dir="$2" n="$3" wait_s="$4"
  mkfifo "$TMP/$name.fifo"
  env -u OUTE_TEST_SLOT -u CI -u GITHUB_ACTIONS OUTE_TEST_SLOT_DIR="$dir" OUTE_TEST_SLOTS="$n" OUTE_TEST_SLOT_WAIT="$wait_s" \
    bash -c '. "$1"; slot_take; echo "rc=$? slot=${OUTE_TEST_SLOT:-}" > "$2"; read -r _ < "$3"' _ "$SLOT" "$TMP/$name.got" "$TMP/$name.fifo" \
    2>"$TMP/$name.err" &
  HPID=$!; PIDS+=("$HPID")
  disown "$HPID"   # sem a linha "Killed" do bash quando o teste mata o processo
  return 0
}
# got <nome> [décimos]: espera o resultado do holder aparecer (padrão 30 s); devolve 1 se não apareceu
got() {
  local name="$1" tries="${2:-300}" i
  for ((i = 0; i < tries; i++)); do
    [[ ! -s "$TMP/$name.got" ]] || return 0
    sleep 0.1
  done
  return 1
}
# waiting <nome> <décimos>: o holder ainda não tem resultado depois desse tempo
waiting() {
  local name="$1" tries="$2"
  if got "$name" "$tries"; then return 1; fi
  return 0
}

# ---------------------------------------------------------------- 1. número de vagas
OUT="$(env -u OUTE_TEST_SLOTS PATH="$BIN:$PATH" bash -c ". '$SLOT'; slot_count")"
check "vagas: o padrão é o nproc"                         test "$OUT" = 3
OUT="$(env OUTE_TEST_SLOTS=2 PATH="$BIN:$PATH" bash -c ". '$SLOT'; slot_count")"
check "vagas: OUTE_TEST_SLOTS troca o número"             test "$OUT" = 2
OUT="$(env OUTE_TEST_SLOTS=zero PATH="$BIN:$PATH" bash -c ". '$SLOT'; slot_count")"
check "vagas: OUTE_TEST_SLOTS inválido cai no nproc"      test "$OUT" = 3
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/nproc"
OUT="$(env -u OUTE_TEST_SLOTS PATH="$BIN:$PATH" bash -c ". '$SLOT'; slot_count")"
check "vagas: sem nproc, 1 vaga"                          test "$OUT" = 1

# ---------------------------------------------------------------- 2. vagas: duas, uma por processo
D="$TMP/vagas"
holder a "$D" 2 30; PA="$HPID"
check "vagas: o 1º processo pega uma"                     got a
holder b "$D" 2 30; PB="$HPID"
check "vagas: o 2º processo pega outra"                   got b
check "vagas: cada processo com a sua (1 e 2)"            test "$(sort "$TMP/a.got" "$TMP/b.got" | tr '\n' ' ')" = "rc=0 slot=1 rc=0 slot=2 "
SA="$(sed 's/.*slot=//' "$TMP/a.got")"
check "vagas: o arquivo da vaga diz o PID de quem pegou"  test "$(cut -d' ' -f1 "$D/$SA.lock")" = "$PA"
# prazo 0: com as duas ocupadas, o 3º não espera e roda sem vaga
sl "$D" 2 0 "$TAKE"
check "prazo: sem vaga no prazo, devolve 1 e segue sem vaga (OUTE_TEST_SLOT=0)" test "$OUT" = "rc=1 slot=0"
check "prazo: aviso em stderr"                            grep -qxF "# slot: nenhuma das 2 vagas ($D) soltou em 0s; o teste roda sem vaga" <<<"$ERR"

# ---------------------------------------------------------------- 3. espera, e liberação quando o processo morre
holder c "$D" 2 120
check "espera: com as vagas ocupadas, o 3º não pega (2 s)" waiting c 20
check "espera: aviso de que está esperando"               grep -qxF "# slot: as 2 vagas de teste estão ocupadas ($D); espero uma por até 120s" "$TMP/c.err"
kill -9 "$PA"
check "morte: kill -9 em quem tinha a vaga solta a vaga, e quem esperava pega" got c
check "morte: a vaga pega é a do processo morto"          test "$(cat "$TMP/c.got")" = "rc=0 slot=$SA"
check "morte: o outro processo segue com a dele"          kill -0 "$PB"
sl "$D" 2 0 "$TAKE"
check "morte: as duas vagas seguem ocupadas (a do morto já tem dono)" test "$OUT" = "rc=1 slot=0"

# ---------------------------------------------------------------- 4. slot_release e fim normal do processo
D="$TMP/solta"
sl "$D" 1 0 'slot_take; a="$OUTE_TEST_SLOT"; env -u OUTE_TEST_SLOT bash -c ". \"$1\"; slot_take; echo dentro=\$?" _ "$1" 2>/dev/null
  slot_release; echo "antes=$a depois=${OUTE_TEST_SLOT:-} fd=${SLOT_FD:-}"; env -u OUTE_TEST_SLOT bash -c ". \"$1\"; slot_take; echo solta=\$?" _ "$1"' "$SLOT"
check "release: com a vaga pega, outro processo não pega"  grep -qxF 'dentro=1' <<<"$OUT"
check "release: limpa OUTE_TEST_SLOT e o descritor"        grep -qxF 'antes=1 depois= fd=' <<<"$OUT"
check "release: depois dele, outro processo pega"          grep -qxF 'solta=0' <<<"$OUT"
sl "$D" 1 0 "$TAKE"
check "fim normal: a vaga de um processo que acabou está livre" test "$OUT" = "rc=0 slot=1"
sl "$D" 1 abc "$TAKE"
check "prazo inválido: vale o padrão, e a vaga livre é pega" test "$OUT" = "rc=0 slot=1"

# ---------------------------------------------------------------- 5. sem vaga a pegar: filho, desligado, CI, sem flock
D="$TMP/nada"
OUT="$(env -u CI -u GITHUB_ACTIONS OUTE_TEST_SLOT=2 OUTE_TEST_SLOT_DIR="$D" bash -c ". '$SLOT'; $TAKE" 2>&1)"
check "filho: com OUTE_TEST_SLOT do pai, não pega outra"   test "$OUT" = "rc=0 slot=2"
OUT="$(env -u CI -u GITHUB_ACTIONS OUTE_TEST_SLOT=0 OUTE_TEST_SLOT_DIR="$D" bash -c ". '$SLOT'; $TAKE" 2>&1)"
check "desligado: OUTE_TEST_SLOT=0 não pega vaga"          test "$OUT" = "rc=0 slot=0"
OUT="$(env -u OUTE_TEST_SLOT -u GITHUB_ACTIONS CI=true OUTE_TEST_SLOT_DIR="$D" bash -c ". '$SLOT'; $TAKE" 2>&1)"
check "CI: com CI definido, não pega vaga (segue em série)" test "$OUT" = "rc=0 slot="
OUT="$(env -u OUTE_TEST_SLOT -u CI GITHUB_ACTIONS=true OUTE_TEST_SLOT_DIR="$D" bash -c ". '$SLOT'; $TAKE" 2>&1)"
check "CI: com GITHUB_ACTIONS definido, não pega vaga"     test "$OUT" = "rc=0 slot="
mkdir -p "$TMP/vazio"
OUT="$(env -u OUTE_TEST_SLOT -u CI -u GITHUB_ACTIONS PATH="$TMP/vazio" OUTE_TEST_SLOT_DIR="$D" "$BASH" -c ". '$SLOT'; $TAKE" 2>&1)"
check "sem flock no PATH: roda sem vaga e sem aviso"       test "$OUT" = "rc=0 slot="
check "sem vaga a pegar: a pasta das vagas nem é criada"   test ! -e "$D"
: > "$TMP/arquivo"
sl "$TMP/arquivo/vagas" 2 0 "$TAKE"
check "pasta que não se cria: devolve 1 e segue sem vaga"  test "$OUT" = "rc=1 slot=0"
check "pasta que não se cria: aviso em stderr"             grep -qxF "# slot: não criei a pasta das vagas ($TMP/arquivo/vagas); o teste roda sem vaga" <<<"$ERR"

# ---------------------------------------------------------------- 6. executado: tests/lib/slot.sh <comando…>
D="$TMP/exec"
run_slot() {
  OUT="$(env -u OUTE_TEST_SLOT -u CI -u GITHUB_ACTIONS OUTE_TEST_SLOT_DIR="$D" OUTE_TEST_SLOTS=1 OUTE_TEST_SLOT_WAIT=0 "$SLOT" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  return 0
}
run_slot bash -c 'echo "vaga=$OUTE_TEST_SLOT"; env -u OUTE_TEST_SLOT bash -c ". \"$1\"; slot_take; echo outro=\$?" _ "$1" 2>/dev/null; exit 7' _ "$SLOT"
check "executado: o comando roda com a vaga"               grep -qxF 'vaga=1' <<<"$OUT"
check "executado: a vaga fica presa enquanto o comando roda" grep -qxF 'outro=1' <<<"$OUT"
check "executado: o código de saída é o do comando"        test "$RC" -eq 7
run_slot
check "executado sem comando: código 2 e o uso"            test "$RC$ERR" = "2uso: tests/lib/slot.sh <comando…>"

# ---------------------------------------------------------------- 7. o check.sh pega a vaga: todo tests/*.test.sh
D="$TMP/check"
OUT="$(env -u OUTE_TEST_SLOT -u CI -u GITHUB_ACTIONS OUTE_TEST_SLOT_DIR="$D" OUTE_TEST_SLOTS=1 OUTE_TEST_SLOT_WAIT=0 \
       bash -c ". '$ROOT/tests/lib/check.sh'; echo \"vaga=\$OUTE_TEST_SLOT\"
         env -u OUTE_TEST_SLOT bash -c '. \"\$1\"; ok caso; check_end' _ '$ROOT/tests/lib/check.sh'; echo \"rc=\$?\"" 2>"$TMP/err")"
check "check.sh: carregar o check.sh pega a vaga"          grep -qxF 'vaga=1' <<<"$OUT"
check "check.sh: sem vaga no prazo, o teste roda e conta os casos" bash -c 'grep -qxF "1 ok, 0 falha(s)" <<<"$1" && grep -qxF "rc=0" <<<"$1"' _ "$OUT"
check "check.sh: e avisa em stderr que rodou sem vaga"     grep -qF "soltou em 0s; o teste roda sem vaga" "$TMP/err"
check "tests/*.test.sh: todos carregam o check.sh (e pegam a vaga)" bash -c '[ -z "$(grep -L "tests/lib/check.sh" "$1"/tests/*.test.sh)" ]' _ "$ROOT"

check_end
