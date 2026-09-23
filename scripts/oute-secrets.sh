#!/usr/bin/env bash
# oute-secrets — ponte Vaultwarden (Bitwarden CLI) -> variáveis de ambiente
#
# Convenção no vault (pasta $OUTE_VAULT_FOLDER, default "oute-agent"):
#   cada item "Secure Note" ou "Login" vira variáveis:
#     - item.name em MAIÚSCULO com '-' -> '_' recebe: login.password (se Login) ou notes (se Note)
#     - cada custom field vira <NOME_DO_CAMPO> (já em maiúsculo)
#   ex.: item "openrouter"  (Login, password=sk-or-...)      -> OPENROUTER_API_KEY via field OPENROUTER_API_KEY
#        item "oci"         (Note, fields OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM)
#        item "gcp"         (Note, field GCP_SA_JSON)
#        item "aws"         (Note, fields AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
#        item "github"      (Note, field GH_TOKEN)
#
# uso:  eval "$(oute-secrets export)"        # dentro do container
#       oute-secrets get OPENROUTER_API_KEY
#       oute-secrets lock                     # apaga sessão em cache (volta a pedir a master password)
# sessão: cacheada em $OUTE_HOME/bw_session (0600); reutilizada enquanto `bw status` = unlocked
set -euo pipefail

BW_SERVER="${BW_SERVER:-https://vault.oute.pro}"
FOLDER="${OUTE_VAULT_FOLDER:-oute-agent}"
CLIENT_FILE="${BW_CLIENT_FILE:-/run/secrets/bw_client}"

die() { printf '[oute-secrets] %s\n' "$*" >&2; exit 1; }

SESSION_FILE="${BW_SESSION_FILE:-${OUTE_HOME:-$HOME/.oute}/bw_session}"

session_ok() { [[ -n "${BW_SESSION:-}" ]] && bw status --session "$BW_SESSION" 2>/dev/null | grep -q '"unlocked"'; }

unlock() {
  # 1) sessão já no ambiente ou em cache -> reutiliza
  session_ok && return 0
  if [[ -z "${BW_SESSION:-}" && -s "$SESSION_FILE" ]]; then
    BW_SESSION="$(<"$SESSION_FILE")"; export BW_SESSION
    session_ok && return 0
    unset BW_SESSION
  fi
  # 2) login por API key (idempotente)
  [[ -f "$CLIENT_FILE" ]] || die "arquivo de API key não encontrado: $CLIENT_FILE"
  # shellcheck disable=SC1090
  source "$CLIENT_FILE"
  export BW_CLIENTID BW_CLIENTSECRET
  local st; st="$(bw status 2>/dev/null || echo '{}')"
  [[ "$(jq -r .serverUrl <<<"$st")" == "$BW_SERVER" ]] || bw config server "$BW_SERVER" >/dev/null
  [[ "$(jq -r .status <<<"$st")" == "unauthenticated" ]] && { bw login --apikey --quiet || die "bw login --apikey falhou (client_id/secret?)"; }
  # 3) master password: env, ou pergunta no tty
  if [[ -z "${BW_PASSWORD:-}" ]]; then
    [[ -r /dev/tty ]] || die "BW_PASSWORD não definido e sem tty para perguntar"
    read -rsp "Vaultwarden master password: " BW_PASSWORD </dev/tty; echo >/dev/tty
    export BW_PASSWORD
  fi
  BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)" || die "bw unlock falhou"
  export BW_SESSION
  # 4) cacheia a sessão (0600). `oute lock` apaga.
  mkdir -p "$(dirname "$SESSION_FILE")"
  ( umask 077; printf '%s' "$BW_SESSION" > "$SESSION_FILE" )
  bw sync --session "$BW_SESSION" --quiet >/dev/null 2>&1 || true
}

folder_id() {
  bw list folders --session "$BW_SESSION" | jq -r --arg n "$FOLDER" '.[] | select(.name==$n) | .id' | head -1
}

export_all() {
  unlock
  local fid; fid="$(folder_id)"
  [[ -n "$fid" ]] || die "pasta '$FOLDER' não existe no vault"
  bw list items --folderid "$fid" --session "$BW_SESSION" | jq -r '
    .[] as $it
    | ($it.name | ascii_upcase | gsub("-"; "_")) as $base
    | (
        # login.password -> <BASE>_PASSWORD ; notes -> <BASE>
        (if ($it.login.password // "") != "" then [{k: ($base+"_PASSWORD"), v: $it.login.password}] else [] end)
        + (if ($it.notes // "") != "" and ($it.fields // [] | length)==0 then [{k: $base, v: $it.notes}] else [] end)
        + ([ ($it.fields // [])[] | select(.value != null) | {k: (.name|ascii_upcase|gsub("-";"_")), v: .value} ])
      )[]
    | "export \(.k)=\(.v|@sh)"'
  printf 'export BW_SESSION=%q\n' "$BW_SESSION"
}

case "${1:-}" in
  export) export_all ;;
  lock)   bw lock >/dev/null 2>&1 || true; rm -f "$SESSION_FILE"; echo "sessão apagada" ;;
  get)    [[ -n "${2:-}" ]] || die "uso: oute-secrets get VAR"; eval "$(export_all)"; [[ -n "${!2:-}" ]] || die "$2 não encontrado no vault"; printf '%s' "${!2}" ;;
  *)      echo "uso: oute-secrets export | get VAR | lock" >&2; exit 2 ;;
esac
