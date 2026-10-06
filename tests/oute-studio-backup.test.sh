#!/usr/bin/env bash
# Testes do `oute studio backup` e do `oute studio backup --check <nome>` (#570), do scripts/oute (host). Bash puro, sem
# Docker nem OCI: `docker` e `rclone` são falsos. O container é o `docker` falso: o `python -m agent_studio.backup` dele
# grava uma cópia de mentira em $F_CT/backup e imprime o JSON do serviço (ou falha: F_BK_RC); `cat` e `rm` mexem nessa
# pasta; `--check` lê o stdin. O bucket é uma pasta ($F_BUCKET) servida pelo `rclone` falso (rcat/lsf/deletefile/cat).
# Casos: nome e destino (bucket de telemetria, nunca o oute-shared que o agent monta); o arquivo vai do container ao
# bucket por pipe, sem tocar no disco do host; conferência do tamanho; a cópia local some só depois de conferida;
# retenção por origem; cada falha com o seu código (host sem agent-studio, container parado, sem credencial, cópia em
# andamento, cópia que falha, envio que falha, tamanho que não bate, resposta fora do formato); --check.
# Uso: tests/oute-studio-backup.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home/.oute" "$TMP/repo/scripts" "$TMP/ct/backup" "$TMP/bucket"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$F_LOG"
case "$1" in
  ps) [[ "${F_DOWN:-}" == 1 ]] || echo abc123 ;;
  exec) shift; [[ "$1" == -i ]] && shift
        [[ "$1" == oute-agent-studio ]] || exit 9
        shift
        case "$*" in
          "/opt/agent-studio/venv/bin/python -m agent_studio.backup")
            [[ "${F_BK_RC:-0}" == 0 ]] || { echo "backup: motivo do serviço" >&2; exit "$F_BK_RC"; }
            name="${F_BK_NAME:-agent-studio-20261006T010203Z.duckdb}"
            printf 'conteudo-do-banco %s' "$F_MARKER" > "$F_CT/backup/$name"
            if [[ -n "${F_BK_JSON:-}" ]]; then printf '%s\n' "$F_BK_JSON"
            else printf '{"file": "%s", "bytes": %d, "seconds": 1.5, "rows": {"spans": 7, "logs": 3, "metrics": 9}}\n' "$name" "$(wc -c < "$F_CT/backup/$name")"; fi ;;
          "/opt/agent-studio/venv/bin/python -m agent_studio.backup --check")
            got="$(cat)"; [[ "$got" == conteudo-do-banco* ]] || { echo "backup: a cópia não abre como banco do agent-studio (IOException)" >&2; exit 1; }
            echo '{"bytes": 40, "rows": {"spans": 7, "logs": 3, "metrics": 9}}' ;;
          "cat /data/agent-studio/backup/"*) f="${@: -1}"; cat "$F_CT/backup/${f##*/}" ;;
          "rm -f /data/agent-studio/backup/"*) f="${@: -1}"; rm -f "$F_CT/backup/${f##*/}" ;;
          *) exit 9 ;;
        esac ;;
  *) exit 9 ;;
esac
SH
cat > "$BIN/rclone" <<'SH'
#!/usr/bin/env bash
printf 'rclone %s\n' "$*" >> "$F_LOG"
[[ "${RCLONE_CONFIG_OCI_ACCESS_KEY_ID:-}" == "$F_EXPECT_KEY" ]] || { echo "sem a credencial do bucket no ambiente" >&2; exit 1; }
args=("$@"); target="${args[${#args[@]}-1]}"; p="${target#oci:}"
case "${args[0]}" in
  rcat) [[ "${F_RCAT_FAIL:-}" == 1 ]] && { cat >/dev/null; echo "AccessDenied" >&2; exit 1; }
        mkdir -p "$F_BUCKET/${p%/*}"; cat > "$F_BUCKET/$p"
        [[ -z "${F_RCAT_TRUNC:-}" ]] || printf 'x' > "$F_BUCKET/$p" ;;
  lsf) [[ -d "$F_BUCKET/$p" ]] || exit 3
       for f in "$F_BUCKET/$p"/*; do [[ -f "$f" ]] && printf '%s;%d\n' "${f##*/}" "$(wc -c < "$f")"; done ;;
  deletefile) rm -f "$F_BUCKET/$p" ;;
  cat) cat "$F_BUCKET/$p" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN"/*

OCI_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
MARKER="segredo-$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
export F_LOG="$TMP/calls.log" F_BUCKET="$TMP/bucket" F_CT="$TMP/ct" F_EXPECT_KEY="$OCI_KEY" F_MARKER="$MARKER"
PFX=oute-observability/backups/agent-studio
ORIGIN=oute-teste-oute-agent
cp "$ROOT/scripts/oute" "$TMP/repo/scripts/oute"; cp "$ROOT/VERSION" "$TMP/repo/VERSION"

FENV=()
oute() {
  OUT="$(env -i PATH="$BIN:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/home/.oute" LANG=C.UTF-8 TMPDIR="$TMP" \
    OCI_S3_ACCESS_KEY="$OCI_KEY" OCI_S3_SECRET_KEY=segredo-do-teste OCI_S3_ENDPOINT=endpoint-do-teste OCI_S3_REGION=regiao-do-teste \
    OUTE_HOST=oute-teste OUTE_AGENT_STUDIO=1 \
    F_LOG="$F_LOG" F_BUCKET="$F_BUCKET" F_CT="$F_CT" F_EXPECT_KEY="$F_EXPECT_KEY" F_MARKER="$F_MARKER" \
    ${FENV[@]+"${FENV[@]}"} "$TMP/repo/scripts/oute" "$@" 2>&1)"; RC=$?
}
seed() {  # bucket com $1 cópias antigas da origem + de outra origem + um estranho; pasta do container vazia
  rm -rf "${F_BUCKET:?}" "${F_CT:?}/backup"; mkdir -p "$F_BUCKET/$PFX" "$F_CT/backup"; : > "$F_LOG"
  local i
  for i in $(seq 1 "$1"); do printf 'velho %d' "$i" > "$(printf '%s/%s/%s-202601%02dT000000Z.duckdb' "$F_BUCKET" "$PFX" "$ORIGIN" "$i")"; done
  for i in 1 2 3; do printf 'outro' > "$(printf '%s/%s/oute-mac-oute-agent-202601%02dT000000Z.duckdb' "$F_BUCKET" "$PFX" "$i")"; done
  printf 'nota' > "$F_BUCKET/$PFX/LEIAME.txt"
}
mine() { ( cd "$F_BUCKET/$PFX" && ls | grep -E "^$ORIGIN-[0-9]{8}T[0-9]{6}Z\.duckdb\$" | LC_ALL=C sort ); }
NEW="$ORIGIN-20261006T010203Z.duckdb"

# ---------------------------------------------------------------- 1. backup: nome, destino, saída
seed 2; FENV=()
oute studio backup
check "backup: rc 0"                                                    test "$RC" = 0
check "a cópia chega ao bucket de telemetria como <host>-<instância>-<data UTC>.duckdb" test -f "$F_BUCKET/$PFX/$NEW"
check "o conteúdo no bucket é o da cópia do container"                  grep -qF "$MARKER" "$F_BUCKET/$PFX/$NEW"
check "nunca vai ao oute-shared (o bucket que o agent monta)"           bash -c '! grep -q "oute-shared" "$1"' _ "$F_LOG"
check "sai do container por pipe ao rclone rcat (sem arquivo no host)"  bash -c 'grep -q "^docker exec oute-agent-studio cat /data/agent-studio/backup/" "$1" && grep -q "^rclone rcat .*oci:oute-observability/backups/agent-studio/" "$1" && [[ -z "$(ls "$2" | grep -i duckdb)" ]]' _ "$F_LOG" "$TMP"
check "envia em blocos de 64 MiB (o padrão de 5 MiB limita o arquivo a 48,8 GiB; o banco não tem retenção)" grep -q "^rclone rcat --s3-chunk-size 64Mi oci:" "$F_LOG"
check "a cópia local do container some depois de conferida"             bash -c '[[ -z "$(ls "$1")" ]]' _ "$F_CT/backup"
check "imprime o destino"                                               grep -qF "backup: oci:$PFX/$NEW" <<<"$OUT"
check "imprime o tamanho e as linhas"                                   bash -c 'grep -qE "^cópia: +[0-9]+ bytes" <<<"$1" && grep -qF "spans 7" <<<"$1" && grep -qF "metrics 9" <<<"$1"' _ "$OUT"
check "o conteúdo do banco nunca na saída nem no log das chamadas"      bash -c '! grep -qF "$2" <<<"$1" && ! grep -qF "$2" "$3"' _ "$OUT" "$MARKER" "$F_LOG"
check "a credencial do bucket nunca no argv"                            bash -c '! grep -qF "$2" "$1"' _ "$F_LOG" "$OCI_KEY"

# ---------------------------------------------------------------- 2. retenção por origem
seed 9; FENV=()
oute studio backup
check "retenção padrão: ficam as 7 mais novas da origem"                test "$(mine | wc -l | tr -d ' ')" = 7
check "retenção: a nova fica e a mais antiga sai"                       bash -c '[[ -f "$1/$2" && ! -f "$1/$3-20260101T000000Z.duckdb" && ! -f "$1/$3-20260103T000000Z.duckdb" && -f "$1/$3-20260104T000000Z.duckdb" ]]' _ "$F_BUCKET/$PFX" "$NEW" "$ORIGIN"
check "retenção: outra origem e arquivo estranho ficam"                 bash -c '[[ "$(ls "$1" | grep -c "^oute-mac-")" == 3 && -f "$1/LEIAME.txt" ]]' _ "$F_BUCKET/$PFX"
seed 9; FENV=(OUTE_STUDIO_BACKUP_KEEP=2)
oute studio backup
check "OUTE_STUDIO_BACKUP_KEEP=2: ficam 2"                              test "$(mine | wc -l | tr -d ' ')" = 2
seed 1; FENV=(OUTE_STUDIO_BACKUP_CHUNK=128Mi)
oute studio backup
check "OUTE_STUDIO_BACKUP_CHUNK troca o tamanho do bloco"              grep -q "^rclone rcat --s3-chunk-size 128Mi oci:" "$F_LOG"
seed 1; FENV=(OUTE_STUDIO_BACKUP_CHUNK='1Mi; rm -rf /')
oute studio backup
check "OUTE_STUDIO_BACKUP_CHUNK inválido: rc 2, nada feito"            bash -c '[[ "$1" == 2 ]] && ! grep -q "^docker exec" "$2"' _ "$RC" "$F_LOG"
seed 1; FENV=(OUTE_STUDIO_BACKUP_KEEP=zero)
oute studio backup
check "OUTE_STUDIO_BACKUP_KEEP inválido: rc 2, nada feito"              bash -c '[[ "$1" == 2 ]] && ! grep -q "^docker exec" "$2"' _ "$RC" "$F_LOG"

# ---------------------------------------------------------------- 3. falhas
seed 1; FENV=(OUTE_AGENT_STUDIO=0)
oute studio backup
check "host sem agent-studio: rc != 0, sem chamar o container"          bash -c '[[ "$1" != 0 ]] && ! grep -q "^docker exec" "$2"' _ "$RC" "$F_LOG"
seed 1; FENV=(F_DOWN=1)
oute studio backup
check "container parado: rc != 0 e diz qual"                            bash -c '[[ "$1" != 0 ]] && grep -q "oute-agent-studio" <<<"$2"' _ "$RC" "$OUT"
seed 1; FENV=(OCI_S3_ACCESS_KEY=)
oute studio backup
check "sem credencial do bucket: rc != 0, antes de pedir a cópia"       bash -c '[[ "$1" != 0 ]] && ! grep -q "^docker exec" "$2"' _ "$RC" "$F_LOG"
seed 1; FENV=(F_BK_RC=3)
oute studio backup
check "cópia em andamento: rc 3, nada enviado"                          bash -c '[[ "$1" == 3 ]] && ! grep -q "^rclone rcat" "$2"' _ "$RC" "$F_LOG"
seed 1; FENV=(F_BK_RC=1)
oute studio backup
check "cópia que falha: rc 1, nada enviado, retenção não roda"          bash -c '[[ "$1" == 1 ]] && ! grep -q "^rclone" "$2"' _ "$RC" "$F_LOG"
seed 1; FENV=(F_BK_JSON='{"file": "../../etc/passwd", "bytes": 1}')
oute studio backup
check "resposta com nome fora do formato: rc != 0, nada lido nem enviado" bash -c '[[ "$1" != 0 ]] && ! grep -q "^docker exec oute-agent-studio cat\|^rclone rcat" "$2"' _ "$RC" "$F_LOG"
seed 3; FENV=(F_RCAT_FAIL=1)
oute studio backup
check "envio que falha: rc != 0"                                        test "$RC" != 0
check "envio que falha: a cópia fica no container e a retenção não roda" bash -c '[[ -n "$(ls "$1")" ]] && ! grep -q "^rclone deletefile" "$2"' _ "$F_CT/backup" "$F_LOG"
seed 3; FENV=(F_RCAT_TRUNC=1)
oute studio backup
check "tamanho no bucket não bate: rc != 0, cópia local fica, retenção não roda" bash -c '[[ "$1" != 0 ]] && [[ -n "$(ls "$2")" ]] && ! grep -q "^rclone deletefile" "$3"' _ "$RC" "$F_CT/backup" "$F_LOG"

# ---------------------------------------------------------------- 4. --check
seed 1; FENV=()
oute studio backup
oute studio backup --check "$NEW"
check "--check de uma cópia do bucket: rc 0 e as linhas"                bash -c '[[ "$1" == 0 ]] && grep -qF "spans 7" <<<"$2"' _ "$RC" "$OUT"
check "--check: passa por stdin ao container, sem arquivo no host"      grep -q "^docker exec -i oute-agent-studio /opt/agent-studio/venv/bin/python -m agent_studio.backup --check" "$F_LOG"
oute studio backup --check "$ORIGIN-20260101T000000Z.duckdb"
check "--check de arquivo que não é banco: rc != 0"                     test "$RC" != 0
oute studio backup --check "nao-existe-20260101T000000Z.duckdb"
check "--check de nome que não está no bucket: rc != 0"                 bash -c '[[ "$1" != 0 ]] && grep -q "não encontrad" <<<"$2"' _ "$RC" "$OUT"
oute studio backup --check "../../segredo"
check "--check com nome fora do formato: rc != 0, sem ler o bucket"     bash -c '[[ "$1" != 0 ]] && ! tail -n 1 "$2" | grep -q "^rclone cat"' _ "$RC" "$F_LOG"
oute studio backup --outra
check "opção desconhecida: rc 2"                                        test "$RC" = 2
check_end
