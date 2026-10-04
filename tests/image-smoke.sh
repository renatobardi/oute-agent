#!/usr/bin/env bash
# Teste de fumaça da imagem (#430, nível 0b do #52): sobe a imagem com segredos fictícios e confere
#   1. o usuário do container é o uid 10001 (o processo principal começa com ele; o sshd sobe via sudo);
#   2. /run/secrets só tem agent_env;
#   3. o sshd responde na porta do container (banner SSH-).
# Roda no workflow `image` (depois do build, antes do push) e à mão contra uma imagem local.
# Uso: tests/image-smoke.sh <imagem>        (ou OUTE_SMOKE_IMAGE=<imagem>)
# Sai 0 se as três conferências passam; senão sai 1 e diz qual falhou. Sem Docker ou sem imagem: sai 2.
# Opcional: DOCKER=<comando> (padrão docker), SMOKE_TIMEOUT=<segundos de espera pelo sshd> (padrão 60).
set -uo pipefail

IMG="${1:-${OUTE_SMOKE_IMAGE:-}}"
DOCKER="${DOCKER:-docker}"
TIMEOUT="${SMOKE_TIMEOUT:-60}"
WANT_UID=10001
SSH_PORT=2222

usage_die() {
  local msg="$1"
  echo "image-smoke: $msg" >&2
  exit 2
}

[[ -n "$IMG" ]] || usage_die "uso: tests/image-smoke.sh <imagem>"
command -v "$DOCKER" >/dev/null 2>&1 || usage_die "$DOCKER não encontrado"
command -v openssl >/dev/null 2>&1 || usage_die "openssl não encontrado"

TMP="$(mktemp -d)"
CNAME="oute-smoke-$(openssl rand -hex 6)"
cleanup() {
  "$DOCKER" rm -f "$CNAME" >/dev/null 2>&1
  rm -rf "${TMP:?}"
  return 0
}
trap cleanup EXIT

FAILS=()
fail() {
  local msg="$1"
  FAILS+=("$msg")
  echo "FALHA: $msg" >&2
  return 0
}

# o entrypoint exige `export NOME=...` e arquivo não vazio; os valores são sorteados agora
SECRETS="$TMP/agent_env"
( umask 077; printf "export GH_TOKEN='smoke%s'\nexport SONAR_TOKEN='smoke%s'\n" \
    "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" > "$SECRETS" )

echo "== subindo $IMG como $CNAME"
"$DOCKER" run -d --name "$CNAME" -v "$SECRETS:/run/secrets/agent_env:ro" "$IMG" >/dev/null \
  || { echo "FALHA: docker run não subiu a imagem $IMG" >&2; exit 1; }

# sshd: banner na porta do container (de dentro dele, sem publicar porta no host)
probe_ssh() {
  local port="$1"
  "$DOCKER" exec "$CNAME" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port && head -c 4 <&3" 2>/dev/null
  return $?
}

up=0
for ((i = 0; i < TIMEOUT; i++)); do
  [[ "$("$DOCKER" inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null)" == true ]] || break
  if [[ "$(probe_ssh "$SSH_PORT")" == "SSH-" ]]; then up=1; break; fi
  sleep 1
done

if [[ "$up" -eq 1 ]]; then
  echo "ok   sshd responde na porta $SSH_PORT"
else
  fail "sshd não respondeu na porta $SSH_PORT em ${TIMEOUT}s"
  "$DOCKER" logs --tail 30 "$CNAME" 2>&1 | sed 's/^/     | /' >&2
fi

got_uid="$("$DOCKER" exec "$CNAME" id -u 2>/dev/null || true)"
if [[ "$got_uid" == "$WANT_UID" ]]; then
  echo "ok   uid do container: $WANT_UID"
else
  fail "uid do container é '${got_uid:-?}', esperado $WANT_UID"
fi

got_secrets="$("$DOCKER" exec "$CNAME" ls -A /run/secrets 2>/dev/null || echo '?')"
if [[ "$got_secrets" == "agent_env" ]]; then
  echo "ok   /run/secrets só tem agent_env"
else
  fail "/run/secrets deveria ter só agent_env, tem: $(tr '\n' ' ' <<<"$got_secrets")"
fi

if [[ ${#FAILS[@]} -gt 0 ]]; then
  echo "image-smoke: ${#FAILS[@]} conferência(s) falharam" >&2
  exit 1
fi
echo "image-smoke: tudo certo"
exit 0
