#!/usr/bin/env bash
# Testes da reserva de disco da fila do collector no scripts/oute (#163): aviso do `oute up` e linha do
# `oute status`. Bash puro, sem Docker: `docker` é falso, controlado por variáveis F_*. Com F_RUN_OUT, o
# `docker run` devolve esse texto; sem ele, roda o script do container de verdade, com /q trocado por um
# diretório temporário (confere o df/du). Uso: tests/oute-queue-disk.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1   # o bad mostra a saída inteira
has() { grep -q -- "$1" <<<"$OUT"; }
hasnt() { ! has "$1"; }

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/q"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  compose) echo "NAME  STATUS" ;;
  image)   [[ "${F_NOIMAGE:-}" == 1 ]] && exit 1; exit 0 ;;
  volume)  [[ "${F_NOVOL:-}" == 1 ]] && exit 1; exit 0 ;;
  run)     printf '%s\n' "$*" > "$F_ARGS"
           [[ -n "${F_RUN_OUT:-}" ]] && { printf '%s\n' "$F_RUN_OUT"; exit 0; }
           q=/nao-existe; [[ "$*" == *":/q:ro "* ]] && q="$F_Q"
           exec sh -c "$(printf '%s' "${!#}" | sed "s#/q#$q#g")" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH" F_ARGS="$TMP/args" F_Q="$TMP/q" HOME="$TMP/home"

# só as funções da reserva (o script inteiro roda o case no fim)
FUNCS="$(sed -n '/^# --- reserva de disco da fila/,/^oci_bootstrap()/p' "$ROOT/scripts/oute" | sed '$d')"
[[ -n "$FUNCS" ]] || { echo "FAIL funções da reserva não achadas em scripts/oute"; exit 1; }
up_check() { OUT="$(IMAGE=img:1 bash -c "set -euo pipefail; $FUNCS"$'\n'"queue_reserve_check" 2>&1)"; RC=$?; }
G=1048576   # 1 GB em KB

F_RUN_OUT="$((10 * G)) 0" up_check
check "10 GB livres, fila vazia: sem aviso, rc 0" test "$RC" = 0 -a -z "$OUT"
F_RUN_OUT="$((3 * G)) 0" up_check
check "3 GB livres, fila vazia: avisa que faltam 1 GB" has "faltam 1.0 GB"
check "aviso não bloqueia (rc 0)" test "$RC" = 0
check "aviso cita a reserva de 4 GB" has "reserva de 4 GB"
F_RUN_OUT="$((3 * G)) $((3 * G / 2))" up_check
check "3 GB livres, fila com 1,5 GB: desconta o que a fila ocupa, sem aviso" test "$RC" = 0 -a -z "$OUT"
F_RUN_OUT="$G $((2 * G))" up_check
check "1 GB livre, fila com 2 GB: avisa que faltam 1 GB" has "faltam 1.0 GB"
check "aviso mostra quanto a fila ocupa" has "a fila já ocupa 2.0 GB"
F_RUN_OUT="$G $((5 * G))" up_check
check "fila acima da reserva: sem aviso" test "$RC" = 0 -a -z "$OUT"
F_NOIMAGE=1 up_check
check "sem imagem local: avisa que não mediu, rc 0" test "$RC" = 0
check "sem imagem local: texto do aviso" has "não medi o disco"
F_RUN_OUT="lixo" up_check
check "saída estranha do container: avisa que não mediu, rc 0" has "não medi o disco"
F_RUN_OUT="$((10 * G)) 0" F_NOVOL=1 up_check
check "volume ainda não criado: docker run sem -v" bash -c '! grep -q -- ":/q:ro" "$0"' "$F_ARGS"
F_RUN_OUT="$((10 * G)) 0" up_check
check "volume existe: montado read-only" grep -q -- "-v oute-agent_oute-otel-queue:/q:ro" "$F_ARGS"
check "docker run nunca baixa imagem nem usa rede" grep -q -- "--pull never --network none" "$F_ARGS"

# script do container de verdade (df/du no diretório temporário)
dd if=/dev/zero of="$TMP/q/db" bs=1024 count=2048 2>/dev/null
up_check
check "df/du reais: rc 0" test "$RC" = 0
check "df/du reais: mediu (não caiu no 'não medi')" hasnt "não medi"

# `oute status` de ponta a ponta
OUT="$(IMAGE=x "$ROOT/scripts/oute" status 2>&1)"; RC=$?
check "status: rc 0" test "$RC" = 0
check "status: mostra os serviços" has "NAME  STATUS"
check "status: linha de disco com a fila" grep -qE '^disco do Docker: [0-9]+\.[0-9] GB livres · fila do collector \(oute-agent_oute-otel-queue\): 0\.0 GB de 4 GB reservados$' <<<"$OUT"
OUT="$(F_NOIMAGE=1 "$ROOT/scripts/oute" status 2>&1)"; RC=$?
check "status sem imagem: rc 0 e diz que não mediu" test "$RC" = 0
check "status sem imagem: texto" has "disco do Docker: não medido"

check_end
