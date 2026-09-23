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
#        item "typesafe"    (Note, field TYPESAFE_API_KEY)
#
# uso:  source <(oute-secrets export)        # dentro do container
#       oute-secrets get OPENROUTER_API_KEY
set -euo pipefail

BW_SERVER="${BW_SERVER:-https://vault.oute.pro}"
FOLDER="${OUTE_VAULT_FOLDER:-oute-agent}"
CLIENT_FILE="${BW_CLIENT_FILE:-/run/secrets/bw_client}"

die() { printf '[oute-secrets] %s\n' "$*" >&2; exit 1; }

unlock() {
  [[ -n "${BW_SESSION:-}" ]] && bw status 2>/dev/null | grep -q '"unlocked"' && return 0
  [[ -f "$CLIENT_FILE" ]] || die "arquivo de API key não encontrado: $CLIENT_FILE"
  # shellcheck disable=SC1090
  source "$CLIENT_FILE"
  export BW_CLIENTID BW_CLIENTSECRET
  bw config server "$BW_SERVER" >/dev/null
  bw login --apikey --quiet 2>/dev/null || true
  [[ -n "${BW_PASSWORD:-}" ]] || die "BW_PASSWORD não definido"
  BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)" || die "bw unlock falhou"
  export BW_SESSION
  bw sync --quiet >/dev/null 2>&1 || true
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
  get)    eval "$(export_all)"; printf '%s' "${!2:?var}" ;;
  *)      echo "uso: oute-secrets export | get VAR" >&2; exit 2 ;;
esac
