#!/usr/bin/env bash
# oci-bootstrap — provisiona o storage do oute-agent no OCI (idempotente; issue #1, ADR-03)
# Roda DENTRO da imagem (oci-cli + bw), chamado por `oute oci-bootstrap` no host.
# Credencial admin: pasta "oute-admin" do Vaultwarden, item "oci-admin"
#   (OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM) — NUNCA exportada pro container do dia a dia.
# Cria: compartment, buckets (+ versionamento/lifecycle), grupo/usuário de serviço/policies,
#       Customer Secret Key (S3) gravada direto no vault (item "oci-storage", pasta "oute-agent"), budget + alertas.
set -euo pipefail

COMPARTMENT="${OUTE_OCI_COMPARTMENT:-oute-agent}"
SHARED_BUCKET="${OUTE_BUCKET:-oute-shared}"
OBS_BUCKET="${OUTE_OBS_BUCKET:-oute-observability}"
SVC="${OUTE_OCI_SVC_USER:-oute-agent-storage}"
BUDGET_USD="${OUTE_OCI_BUDGET_USD:-1}"
BUDGET_EMAIL="${OUTE_OCI_BUDGET_EMAIL:-}"
ADMIN_FOLDER="${OUTE_ADMIN_VAULT_FOLDER:-oute-admin}"
AGENT_FOLDER="${OUTE_VAULT_FOLDER:-oute-agent}"
DRY="${DRY_RUN:-0}"

log() { printf '[oci-bootstrap] %s\n' "$*" >&2; }
die() { log "ERRO: $*"; exit 1; }
run() { if [[ "$DRY" == 1 ]]; then log "dry-run: $*"; else "$@"; fi; }

# PEM colado num custom field do Vaultwarden perde as quebras de linha: reconstrói (64 col.)
normalize_pem() {
  local flat kind body
  flat="$(tr '\r\n' '  ' <<<"$1")"
  kind="$(grep -oE 'BEGIN [A-Z ]*PRIVATE KEY' <<<"$flat" | head -1 | sed 's/^BEGIN //')"
  [[ -n "$kind" ]] || return 1
  # só o que está entre BEGIN e END: o PEM do console da OCI traz a linha "OCI_API_KEY" depois do END
  body="$(sed -E 's/.*-----BEGIN [A-Z ]+-----//; s/-----END [A-Z ]+-----.*//' <<<"$flat" | tr -d ' \t')"
  printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\nOCI_API_KEY\n' "$kind" "$(fold -w64 <<<"$body")" "$kind"
}

# --- credencial admin (pasta separada) -> ~/.oci temporário
bw sync --session "${BW_SESSION:-}" --quiet >/dev/null 2>&1 || true   # itens criados agora no vault
ADMIN_ENV="$(OUTE_VAULT_FOLDER="$ADMIN_FOLDER" oute-secrets export)" || die "não li a pasta '$ADMIN_FOLDER' do vault"
eval "$ADMIN_ENV"; unset ADMIN_ENV
for v in OCI_USER_OCID OCI_TENANCY_OCID OCI_FINGERPRINT OCI_REGION OCI_KEY_PEM; do
  [[ -n "${!v:-}" ]] || die "$v ausente no item oci-admin (pasta $ADMIN_FOLDER)"
done
OCI_DIR="$(mktemp -d)"; trap 'rm -rf "$OCI_DIR"' EXIT
( umask 077
  normalize_pem "$OCI_KEY_PEM" > "$OCI_DIR/key.pem" || die "OCI_KEY_PEM não contém uma chave PRIVADA (colou a pública?)"
  cat > "$OCI_DIR/config" <<CFG
[DEFAULT]
user=$OCI_USER_OCID
fingerprint=$OCI_FINGERPRINT
tenancy=$OCI_TENANCY_OCID
region=$OCI_REGION
key_file=$OCI_DIR/key.pem
CFG
)
export OCI_CLI_CONFIG_FILE="$OCI_DIR/config" OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
TEN="$OCI_TENANCY_OCID"; REGION="$OCI_REGION"
# consulta tolerante: erro ou JMESPath sem resultado ("null") viram vazio
q() { local out; out="$(oci "$@" 2>/dev/null || true)"; [[ "$out" == null ]] && out=""; printf '%s' "$out"; }
# policy nova leva alguns segundos pra propagar no IAM
retry() { local i; for i in 1 2 3 4 5 6; do "$@" && return 0; log "tentativa $i falhou; aguardando IAM propagar"; sleep 15; done; return 1; }

NS="$(oci os ns get --query data --raw-output)" || die "oci os ns get falhou (API key/fingerprint?)"
log "tenancy ok · região $REGION · namespace $NS"

# --- compartment
CID="$(q iam compartment list --compartment-id "$TEN" --name "$COMPARTMENT" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output)"
if [[ -z "$CID" ]]; then
  log "criando compartment $COMPARTMENT"
  CID="$(run oci iam compartment create --compartment-id "$TEN" --name "$COMPARTMENT" \
        --description "oute-agent: storage e observabilidade" --wait-for-state ACTIVE --query data.id --raw-output)"
else log "compartment $COMPARTMENT: existe"; fi

# --- buckets
bucket() { # nome versioning
  if q os bucket get --bucket-name "$1" --query data.name --raw-output | grep -q .; then
    log "bucket $1: existe"
  else
    log "criando bucket $1"
    run oci os bucket create --compartment-id "$CID" --name "$1" --storage-tier Standard \
      --public-access-type NoPublicAccess --versioning "$2" >/dev/null
  fi
}
bucket "$SHARED_BUCKET" Enabled
bucket "$OBS_BUCKET" Disabled

# --- policies: anexadas à raiz (tenancy), escopo "in compartment oute-agent"
# (serviço Object Storage precisa de permissão pra aplicar lifecycle)
policy() { # nome descrição statements-json
  local pid; pid="$(q iam policy list --compartment-id "$TEN" --name "$1" --query 'data[0].id' --raw-output)"
  if [[ -n "$pid" ]]; then
    local cur; cur="$(q iam policy get --policy-id "$pid" --query 'data.statements' | jq -c 'sort')"
    if [[ "$cur" == "$(jq -c 'sort' <<<"$3")" ]]; then log "policy $1: igual"; return 0; fi
    log "policy $1: atualizando"
    # update exige statements + version-date juntos; "" = avalia pelo comportamento atual dos serviços
    run oci iam policy update --policy-id "$pid" --statements "$3" --version-date "" --force >/dev/null
  else
    log "criando policy $1"
    run oci iam policy create --compartment-id "$TEN" --name "$1" --description "$2" --statements "$3" >/dev/null
  fi
}
BUCKETS="any {target.bucket.name='$SHARED_BUCKET', target.bucket.name='$OBS_BUCKET'}"
policy oute-objectstorage-lifecycle "lifecycle do Object Storage no compartment oute-agent" \
  "[\"Allow service objectstorage-$REGION to manage object-family in compartment $COMPARTMENT\"]"

# --- lifecycle
LC="$OCI_DIR/lc.json"
cat > "$LC" <<'J'
[{"name":"apaga-versoes-antigas","action":"DELETE","target":"previous-object-versions","timeAmount":30,"timeUnit":"DAYS","isEnabled":true}]
J
retry run oci os object-lifecycle-policy put --bucket-name "$SHARED_BUCKET" --items "file://$LC" --force >/dev/null && log "lifecycle $SHARED_BUCKET: versões não-correntes > 30d apagadas"
cat > "$LC" <<'J'
[{"name":"infrequent-30d","action":"INFREQUENT_ACCESS","target":"objects","timeAmount":30,"timeUnit":"DAYS","isEnabled":true},
 {"name":"archive-90d","action":"ARCHIVE","target":"objects","timeAmount":90,"timeUnit":"DAYS","isEnabled":true}]
J
retry run oci os object-lifecycle-policy put --bucket-name "$OBS_BUCKET" --items "file://$LC" --force >/dev/null && log "lifecycle $OBS_BUCKET: IA 30d → Archive 90d"

# --- grupo + usuário de serviço (Default identity domain; API IAM clássica)
GID="$(q iam group list --compartment-id "$TEN" --name "$SVC" --query 'data[0].id' --raw-output)"
[[ -n "$GID" ]] || { log "criando grupo $SVC"; GID="$(run oci iam group create --compartment-id "$TEN" --name "$SVC" --description "oute-agent: acesso S3 aos buckets" --query data.id --raw-output)"; }
UID_="$(q iam user list --compartment-id "$TEN" --name "$SVC" --query 'data[0].id' --raw-output)"
if [[ -z "$UID_" ]]; then
  # tenancy com Identity Domains exige e-mail primário (único) no usuário; default: plus-address do e-mail do budget
  SVC_EMAIL="${OUTE_OCI_SVC_EMAIL:-}"
  [[ -n "$SVC_EMAIL" || -z "$BUDGET_EMAIL" ]] || SVC_EMAIL="${BUDGET_EMAIL%@*}+$SVC@${BUDGET_EMAIL#*@}"
  [[ -n "$SVC_EMAIL" ]] || die "defina OUTE_OCI_SVC_EMAIL (ou OUTE_OCI_BUDGET_EMAIL): Identity Domains exige e-mail no usuário"
  log "criando usuário de serviço $SVC ($SVC_EMAIL)"
  UID_="$(run oci iam user create --compartment-id "$TEN" --name "$SVC" --email "$SVC_EMAIL" \
          --description "oute-agent: usuário de serviço (só S3)" --query data.id --raw-output)"
fi
if ! q iam group list-users --group-id "$GID" --query 'data[].id' --raw-output | grep -q "$UID_"; then
  run oci iam group add-user --group-id "$GID" --user-id "$UID_" >/dev/null; log "usuário no grupo"
fi
# sem console nem API key: só Customer Secret Key
run oci iam user update-user-capabilities --user-id "$UID_" --can-use-console-password false \
  --can-use-api-keys false --can-use-auth-tokens false --can-use-smtp-credentials false \
  --can-use-customer-secret-keys true >/dev/null 2>&1 || log "aviso: não ajustei capabilities do usuário"
policy oute-agent-storage "S3 nos buckets do oute-agent (menor privilégio)" \
  "[\"Allow group $SVC to read buckets in compartment $COMPARTMENT where $BUCKETS\",\"Allow group $SVC to manage objects in compartment $COMPARTMENT where $BUCKETS\"]"

# --- Customer Secret Key -> vault (nunca em log/argv)
ENDPOINT="https://$NS.compat.objectstorage.$REGION.oraclecloud.com"
AGENT_ENV="$(OUTE_VAULT_FOLDER="$AGENT_FOLDER" oute-secrets export)" || die "não li a pasta '$AGENT_FOLDER' do vault"
eval "$AGENT_ENV"; unset AGENT_ENV
if [[ -n "${OCI_S3_ACCESS_KEY:-}" ]]; then
  log "item oci-storage já existe no vault: chave mantida"
elif [[ "$DRY" == 1 ]]; then
  log "dry-run: criaria Customer Secret Key e item oci-storage"
else
  n="$(q iam customer-secret-key list --user-id "$UID_" --query 'length(data)' --raw-output)"
  [[ "${n:-0}" -lt 2 ]] || die "usuário $SVC já tem 2 Customer Secret Keys (limite); apague uma no console"
  KJ="$OCI_DIR/key.json"
  ( umask 077; oci iam customer-secret-key create --user-id "$UID_" --display-name "oute-agent rclone $(date +%F)" > "$KJ" )
  FID="$(bw list folders --session "$BW_SESSION" | jq -r --arg n "$AGENT_FOLDER" '.[]|select(.name==$n)|.id' | head -1)"
  [[ -n "$FID" ]] || die "pasta $AGENT_FOLDER não existe no vault"
  jq -n --arg fid "$FID" --arg ep "$ENDPOINT" --arg rg "$REGION" --arg ns "$NS" --slurpfile k "$KJ" '{
      type: 2, secureNote: {type: 0}, name: "oci-storage", folderId: $fid,
      notes: "Criado por oute oci-bootstrap. Usuário de serviço OCI oute-agent-storage (só S3 nos buckets do oute-agent).",
      fields: [
        {name:"OCI_S3_ACCESS_KEY", value: $k[0].data.id,  type:1},
        {name:"OCI_S3_SECRET_KEY", value: $k[0].data.key, type:1},
        {name:"OCI_S3_ENDPOINT",   value: $ep, type:0},
        {name:"OCI_S3_REGION",     value: $rg, type:0},
        {name:"OCI_NAMESPACE",     value: $ns, type:0}]}' \
    | bw encode | bw create item --session "$BW_SESSION" >/dev/null
  bw sync --session "$BW_SESSION" --quiet >/dev/null 2>&1 || true
  log "Customer Secret Key criada e gravada no vault (item oci-storage)"
fi

# --- budget + alertas (compartment)
BID="$(q budgets budget budget list --compartment-id "$TEN" --all --query "data[?\"display-name\"=='$COMPARTMENT'].id | [0]" --raw-output)"
if [[ -z "$BID" ]]; then
  log "criando budget US\$$BUDGET_USD/mês"
  BID="$(run oci budgets budget budget create --compartment-id "$TEN" --amount "$BUDGET_USD" --reset-period MONTHLY \
        --target-type COMPARTMENT --targets "[\"$CID\"]" --display-name "$COMPARTMENT" \
        --description "oute-agent storage" --query data.id --raw-output)"
  if [[ -n "$BUDGET_EMAIL" && -n "$BID" ]]; then
    for t in ACTUAL FORECAST; do
      run oci budgets alert-rule create --budget-id "$BID" --type "$t" --threshold 100 --threshold-type PERCENTAGE \
        --recipients "$BUDGET_EMAIL" --display-name "oute-$t" >/dev/null
    done
    log "alertas ACTUAL/FORECAST 100% → $BUDGET_EMAIL"
  else log "aviso: sem OUTE_OCI_BUDGET_EMAIL, budget criado sem alerta"; fi
else log "budget $COMPARTMENT: existe"; fi

log "pronto · endpoint $ENDPOINT · buckets $SHARED_BUCKET, $OBS_BUCKET"
