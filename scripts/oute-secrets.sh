#!/usr/bin/env bash
# oute-secrets — ponte Vaultwarden (Bitwarden CLI) -> variáveis de ambiente
#
# Convenção no vault (pasta $OUTE_VAULT_FOLDER, default "oute-agent"):
#   cada item "Secure Note" ou "Login" vira variáveis:
#     - item.name em MAIÚSCULO com '-' -> '_' recebe: login.password (se Login) ou notes (se Note)
#     - cada custom field vira <NOME_DO_CAMPO> (já em maiúsculo)
#   ex.: item "oci"         (Note, fields OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM)
#        item "gcp"         (Note, field GCP_SA_JSON)
#        item "aws"         (Note, fields AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
#        item "github"      (Note, field GH_TOKEN)
#        item "sonar"       (Note, fields SONAR_TOKEN, OUTE_SONAR_ORG: o oute-sonar, só leitura, #226)
#        item "zai"         (Note, field OUTE_ZAI_API_KEY: a assinatura zai, o claude na API da Z.ai; só o ambiente do processo da sessão zai e do oute-regression --subscription zai, #680)
#
# uso:  eval "$(oute-secrets export)"       # sai com 4 se a pasta não existe no vault
#       oute-secrets get GH_TOKEN
#       BW_SESSION="$(oute-secrets session)"  # sessão para quem chama; quem chama faz `bw lock` depois
#       oute-secrets lock                     # bw lock + apaga resto legado ($OUTE_HOME/bw_session)
# sessão (#21): nunca vai para disco. Com BW_SESSION válido no ambiente, usa e deixa como está (o dono tranca);
# senão abre com a master password e, ao fim de export/get, faz `bw lock` (a chave some do estado do bw).
set -euo pipefail

BW_SERVER="${BW_SERVER:-https://vault.oute.pro}"
FOLDER="${OUTE_VAULT_FOLDER:-oute-agent}"
CLIENT_FILE="${BW_CLIENT_FILE:-/run/secrets/bw_client}"

die() { printf '[oute-secrets] %s\n' "$*" >&2; exit 1; }

# só para limpar o cache das versões <= 0.7.x (`lock`); nada é gravado nele
SESSION_FILE="${BW_SESSION_FILE:-${OUTE_HOME:-$HOME/.oute}/bw_session}"
OWN_SESSION=0

session_ok() { [[ -n "${BW_SESSION:-}" ]] && bw status --session "$BW_SESSION" 2>/dev/null | grep -q '"unlocked"'; }

unlock() {
  # 1) sessão recebida do chamador (ex.: oci-bootstrap) -> usa; quem abriu é quem tranca
  session_ok && return 0
  unset BW_SESSION
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
    { : </dev/tty; } 2>/dev/null || die "BW_PASSWORD não definido e sem tty para perguntar"   # -r passa sem terminal de controle (cron)
    read -rsp "Vaultwarden master password: " BW_PASSWORD </dev/tty; echo >/dev/tty
    export BW_PASSWORD
  fi
  BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)" || die "bw unlock falhou"
  export BW_SESSION; OWN_SESSION=1
  # 4) sessão só neste processo: se sair no meio (erro, Ctrl+C), tranca igual
  trap relock EXIT
  bw sync --session "$BW_SESSION" --quiet >/dev/null 2>&1 || true
}

# descarta a chave da sessão que ESTE processo abriu (`bw lock` apaga a chave protegida do estado do bw)
relock() {
  [[ "$OWN_SESSION" == 1 ]] || return 0
  bw lock >/dev/null 2>&1 || true
  OWN_SESSION=0; unset BW_SESSION
}

folder_id() {
  bw list folders --session "$BW_SESSION" | jq -r --arg n "$FOLDER" '.[] | select(.name==$n) | .id' | head -1
}

export_all() {
  unlock
  # sessão recebida pode ter estado de antes de um item novo (ex.: oci-storage criado agora)
  [[ "$OWN_SESSION" == 1 ]] || bw sync --session "$BW_SESSION" --quiet >/dev/null 2>&1 || true
  local fid; fid="$(folder_id)"
  # rc 4 = a pasta não existe (o `oute` distingue de falha de leitura: pasta oute-services na transição, #256)
  [[ -n "$fid" ]] || { relock; printf "[oute-secrets] pasta '%s' não existe no vault\n" "$FOLDER" >&2; exit 4; }
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
}

case "${1:-}" in
  export)  export_all; relock ;;
  get)     [[ -n "${2:-}" ]] || die "uso: oute-secrets get VAR"
           # abre aqui (não no subshell do $(…)): a sessão é deste processo, que a tranca
           unlock; envs="$(export_all)"; relock; eval "$envs"; unset envs
           [[ -n "${!2:-}" ]] || die "$2 não encontrado no vault"; printf '%s' "${!2}" ;;
  session) unlock; OWN_SESSION=0; printf '%s' "$BW_SESSION" ;;   # quem chama tranca (bw lock)
  lock)    bw lock >/dev/null 2>&1 || true; rm -f "$SESSION_FILE"; echo "sessão descartada" ;;
  *)       echo "uso: oute-secrets export | get VAR | session | lock" >&2; exit 2 ;;
esac
