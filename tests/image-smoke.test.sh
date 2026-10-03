#!/usr/bin/env bash
# Testes do tests/image-smoke.sh (#430) com um `docker` falso no PATH: cada conferência passa e falha por si,
# a mensagem diz qual caiu, e o container é removido ao fim. O docker falso lê o cenário de FAKE_* e guarda as
# chamadas em $FAKE/calls.
# Uso: tests/image-smoke.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
SMOKE="$ROOT/tests/image-smoke.sh"
[[ -x "$SMOKE" ]] || die "image-smoke.sh ausente ou sem +x"
command -v openssl >/dev/null || die "precisa de openssl"

BIN="$TMP/bin"; FAKE="$TMP/fake"; mkdir -p "$BIN" "$FAKE"
cat > "$BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls"
case "$1" in
  run)
    [[ "${FAKE_RUN_RC:-0}" -eq 0 ]] || exit "$FAKE_RUN_RC"
    # guarda o arquivo de segredos montado, para o teste conferir o modo e o formato
    for a in "$@"; do case "$a" in *:/run/secrets/agent_env:ro) cp "${a%%:*}" "$FAKE/secrets"; stat -c %a "${a%%:*}" > "$FAKE/secrets.mode" ;; esac; done ;;
  inspect) echo "${FAKE_RUNNING:-true}" ;;
  logs) echo "log do container" ;;
  rm) ;;
  exec)
    shift 2
    case "$1" in
      id) echo "${FAKE_UID:-10001}" ;;
      ls) printf '%b' "${FAKE_SECRETS:-agent_env\n}" ;;
      bash) [[ -z "${FAKE_NO_SSH:-}" ]] && printf 'SSH-' || exit 1 ;;
    esac ;;
esac
exit 0
DOCKER
chmod +x "$BIN/docker"
export FAKE PATH="$BIN:$PATH" SMOKE_TIMEOUT=2
unset FAKE_RUN_RC FAKE_RUNNING FAKE_UID FAKE_SECRETS FAKE_NO_SSH OUTE_SMOKE_IMAGE

run() { : > "$FAKE/calls"; OUT="$("$SMOKE" "$@" 2>&1)"; RC=$?; }

run img:t
check "tudo certo: rc 0" test "$RC" -eq 0
check "tudo certo: diz as três conferências" bash -c 'grep -c "^ok   " <<<"$1" | grep -qx 3' _ "$OUT"
check "segredos fictícios: modo 600 e formato export" bash -c '[ "$(cat "$1")" = 600 ] && ! grep -qvE "^export [A-Z_]+=" "$2"' _ "$FAKE/secrets.mode" "$FAKE/secrets"
check "container removido ao fim" grep -q '^rm -f oute-smoke-' "$FAKE/calls"

FAKE_UID=0 run img:t
check "uid errado: rc 1" test "$RC" -eq 1
check "uid errado: mensagem diz uid" has 'FALHA: uid do container'
check "uid errado: as outras duas passam" bash -c 'grep -c "^ok   " <<<"$1" | grep -qx 2' _ "$OUT"

FAKE_SECRETS='agent_env\nextra\n' run img:t
check "segredo extra: rc 1" test "$RC" -eq 1
check "segredo extra: mensagem diz /run/secrets" has 'FALHA: /run/secrets'

FAKE_SECRETS='outro\n' run img:t
check "outro nome no lugar de agent_env: rc 1" test "$RC" -eq 1

FAKE_NO_SSH=1 run img:t
check "sshd mudo: rc 1" test "$RC" -eq 1
check "sshd mudo: mensagem diz sshd" has 'FALHA: sshd não respondeu'
check "sshd mudo: mostra o log do container" has 'log do container'

FAKE_RUNNING=false FAKE_NO_SSH=1 run img:t
check "container morreu: rc 1, sem esperar o prazo" test "$RC" -eq 1

FAKE_UID=1 FAKE_NO_SSH=1 FAKE_SECRETS=x run img:t
check "três falhas juntas: relata 3" has '3 conferência(s) falharam'

FAKE_RUN_RC=125 run img:t
check "docker run falha: rc 1 e mensagem" bash -c '[ "$1" -eq 1 ] && grep -q "docker run não subiu" <<<"$2"' _ "$RC" "$OUT"

run
check "sem imagem: rc 2" test "$RC" -eq 2
OUT="$(OUTE_SMOKE_IMAGE=img:env "$SMOKE" 2>&1)"; RC=$?
check "imagem por OUTE_SMOKE_IMAGE" test "$RC" -eq 0
OUT="$(DOCKER=docker-que-nao-existe "$SMOKE" img:t 2>&1)"; RC=$?
check "sem docker: rc 2" test "$RC" -eq 2

check_end
