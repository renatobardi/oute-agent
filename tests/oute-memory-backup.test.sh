#!/usr/bin/env bash
# Testes do `oute memory-backup` e do `oute memory-backup --check <arquivo>` (#369), do scripts/oute (host). Bash puro,
# sem Docker nem OCI: `docker` e `rclone` são falsos. O bucket é uma pasta ($F_BUCKET) servida pelo `rclone` falso
# (lsf/deletefile/cat); o container é o `docker` falso, que mapeia /data/shared para o bucket (mount de pé) ou para uma
# pasta local (mount parado) e roda de verdade o `sh -c` do backup e o `python3 -c` do --check, com um `ai-memory`
# falso que escreve um tarball real (db SQLite + wiki), com ou sem páginas, ou falha.
# Casos: nome do arquivo e destino; retenção por origem (nunca apaga outra origem nem arquivo estranho), padrão 8 e
# OUTE_MEMORY_BACKUP_KEEP; aviso de tamanho do banco; código de saída em cada falha (container parado, ai-memory falha,
# sem credencial = só local, mount parado, tamanho que não bate, listagem e apagar da retenção, variável inválida);
# --check (arquivo local, nome no bucket; banco sem páginas, corrompido, sem db, não-tarball, ausente; tmp limpo,
# volume intocado); o conteúdo do tarball nunca na saída.
# Uso: tests/oute-memory-backup.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1
command -v python3 >/dev/null || die "python3 ausente (tarball e --check de mentira)"

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home/.oute" "$TMP/repo/scripts" "$TMP/ct-tmp" "$TMP/local" "$TMP/bucket"
cat > "$BIN/ai-memory" <<'SH'
#!/usr/bin/env bash
# `ai-memory backup --to <tar.gz>` falso: tarball de verdade com db/memory.sqlite ($F_PAGES páginas; F_DB_KIND=corrupt
# põe lixo no lugar do banco, nodb tira o banco) e wiki/ com o marcador $F_MARKER. F_BACKUP_FAIL=1: deixa um arquivo
# pela metade e sai com 1, como um backup que morre no meio.
printf 'ai-memory %s\n' "$*" >> "$F_LOG"
[[ "$1" == backup && "$2" == --to ]] || exit 9
to="$3"
if [[ "${F_BACKUP_FAIL:-}" == 1 ]]; then echo "Error: disco cheio" >&2; printf 'meio' > "$to"; exit 1; fi
d="$(mktemp -d "${TMPDIR:-/tmp}/fake-ai-memory.XXXXXX")"
mkdir -p "$d/db" "$d/wiki/ws/proj"
printf 'segredo da conversa %s\n' "$F_MARKER" > "$d/wiki/ws/proj/pagina.md"
python3 - "$d/db/memory.sqlite" "${F_PAGES:-3}" "${F_DB_KIND:-ok}" <<'PY'
import sqlite3, sys
path, pages, kind = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if kind == "corrupt":
    open(path, "wb").write(b"isto nao e um banco sqlite" * 50)
else:
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE pages (id INTEGER PRIMARY KEY, body TEXT)")
    c.executemany("INSERT INTO pages (body) VALUES (?)", [("p%d" % i,) for i in range(pages)])
    c.commit(); c.close()
PY
[[ "${F_DB_KIND:-ok}" != nodb ]] || rm -f "$d/db/memory.sqlite"
tar czf "$to" -C "$d" .
rm -rf "${d:?}"
SH
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
# docker falso: `ps` (container de pé, a menos de F_DOWN=1) e `exec [-i] oute-agent <cmd…>`, que roda o comando de
# verdade com os caminhos do container trocados pelos da pasta de teste: /data/shared -> $F_SHARED e
# /data/ai-memory/db/memory.sqlite -> $F_DBFILE. O tmp do container é $F_CT_TMP.
printf 'docker %s\n' "$*" >> "$F_LOG"
case "$1" in
  ps) [[ "${F_DOWN:-}" == 1 ]] || echo abc123 ;;
  exec) shift; [[ "$1" == -i ]] && shift
        [[ "$1" == oute-agent ]] || exit 9
        shift
        args=(); for a in "$@"; do a="${a/#\/data\/shared/$F_SHARED}"; a="${a/#\/data\/ai-memory\/db\/memory.sqlite/$F_DBFILE}"; args+=("$a"); done
        env TMPDIR="$F_CT_TMP" PATH="$F_BIN:$PATH" "${args[@]}" ;;
  *) exit 9 ;;
esac
SH
cat > "$BIN/rclone" <<'SH'
#!/usr/bin/env bash
# bucket falso: $F_BUCKET/<caminho>; só lsf, deletefile e cat. O argv de cada chamada vai ao $F_LOG.
printf 'rclone %s\n' "$*" >> "$F_LOG"
[[ "${RCLONE_CONFIG_OCI_ACCESS_KEY_ID:-}" == "$F_EXPECT_KEY" ]] || { echo "sem a credencial do bucket no ambiente" >&2; exit 1; }
args=(); for a in "$@"; do args+=("$a"); done
target="${args[${#args[@]}-1]}"; p="${target#oci:*/}"
case "${args[0]}" in
  lsf) n=0; [[ -f "$F_COUNT" ]] && n="$(cat "$F_COUNT")"; n=$((n + 1)); echo "$n" > "$F_COUNT"
       [[ -z "${F_LSF_FAIL_AFTER:-}" || "$n" -le "$F_LSF_FAIL_AFTER" ]] || { echo "AccessDenied" >&2; exit 5; }
       [[ -d "$F_BUCKET/$p" ]] || exit 3
       for f in "$F_BUCKET/$p"/*; do
         [[ -f "$f" ]] || continue
         printf '%s;%d\n' "${f##*/}" "$(( $(stat -c %s "$f") + ${F_LSF_SIZE_OFF:-0} ))"
       done ;;
  deletefile) [[ "${F_DEL_FAIL:-}" == 1 ]] && { echo "AccessDenied" >&2; exit 1; }
              rm -f "$F_BUCKET/$p" ;;
  cat) cat "$F_BUCKET/$p" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN"/*

OCI_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
MARKER="conteudo-$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
export F_LOG="$TMP/calls.log" F_BUCKET="$TMP/bucket" F_COUNT="$TMP/lsf.count" F_EXPECT_KEY="$OCI_KEY"
PFX=backups/ai-memory
ORIGIN=oute-teste-oute-agent
cp "$ROOT/scripts/oute" "$TMP/repo/scripts/oute"; cp "$ROOT/VERSION" "$TMP/repo/VERSION"
: > "$F_LOG"

# oute <args…>: o scripts/oute real num ambiente só do teste (nada de credencial do host). FENV: variáveis do caso.
FENV=()
oute() {
  OUT="$(env -i PATH="$BIN:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/home/.oute" LANG=C.UTF-8 TMPDIR="$TMP" \
    OCI_S3_ACCESS_KEY="$OCI_KEY" OCI_S3_SECRET_KEY=segredo-do-teste OCI_S3_ENDPOINT=endpoint-do-teste OCI_S3_REGION=regiao-do-teste \
    OUTE_HOST=oute-teste OUTE_MEMORY_BACKUP_WAIT=0 \
    F_LOG="$F_LOG" F_BUCKET="$F_BUCKET" F_COUNT="$F_COUNT" F_EXPECT_KEY="$F_EXPECT_KEY" F_MARKER="$MARKER" \
    F_SHARED="${F_SHARED:-$F_BUCKET}" F_DBFILE="$TMP/memory.sqlite" F_CT_TMP="$TMP/ct-tmp" F_BIN="$BIN" \
    ${FENV[@]+"${FENV[@]}"} "$TMP/repo/scripts/oute" "$@" 2>&1)"; RC=$?
}
# estado do caso: bucket com $1 arquivos da origem (datas antigas) + de outras origens + um estranho; banco de $2 MB
seed() {
  rm -rf "${F_BUCKET:?}" "${TMP:?}/local" "${TMP:?}"/ct-tmp/*; mkdir -p "$F_BUCKET/$PFX" "$TMP/local"
  rm -f "$F_COUNT" "$TMP/memory.sqlite"; : > "$F_LOG"
  local i
  for i in $(seq 1 "$1"); do printf 'velho %d' "$i" > "$(printf '%s/%s/%s-202601%02dT000000Z.tar.gz' "$F_BUCKET" "$PFX" "$ORIGIN" "$i")"; done
  for i in $(seq 1 12); do printf 'outro %d' "$i" > "$(printf '%s/%s/oute-mac-oute-agent-202601%02dT000000Z.tar.gz' "$F_BUCKET" "$PFX" "$i")"; done
  printf 'outra instancia' > "$F_BUCKET/$PFX/$ORIGIN-extra-20260101T000000Z.tar.gz"
  printf 'nota' > "$F_BUCKET/$PFX/LEIAME.txt"
  truncate -s "${2:-10}M" "$TMP/memory.sqlite"
}
# arquivos da origem no bucket (nome só, ordenados)
mine() { ( cd "$F_BUCKET/$PFX" && ls | grep -E "^$ORIGIN-[0-9]{8}T[0-9]{6}Z\.tar\.gz\$" | LC_ALL=C sort ); }
newest() { mine | tail -n 1; }
NAME_RE="^$ORIGIN-[0-9]{8}T[0-9]{6}Z\\.tar\\.gz\$"

# ---------------------------------------------------------------- 1. backup: nome, destino, saída
seed 2 10; FENV=()
oute memory-backup
check "backup: rc 0" test "$RC" = 0
new="$(newest)"
check "arquivo <host>-<instância>-<data UTC>.tar.gz em backups/ai-memory do bucket" bash -c '[[ "$1" =~ $2 ]]' _ "$new" "$NAME_RE"
check "o ai-memory rodou no container oute-agent, com --to /data/shared/backups/ai-memory/<nome>" \
  bash -c 'grep -F "docker exec oute-agent sh -c" "$1" | grep -qF "ai-memory backup --to" && grep -qF -- "$2" "$1"' _ "$F_LOG" "/data/shared/$PFX/$new"
check "o arquivo no bucket é um tarball de verdade (tar t abre e acha o banco)" bash -c 'tar tzf "$1" | grep -q "db/memory.sqlite"' _ "$F_BUCKET/$PFX/$new"
check "o marcador está mesmo dentro do tarball (a conferência de vazamento abaixo vale)" \
  bash -c 'tar xzOf "$1" ./wiki/ws/proj/pagina.md | grep -qF "$2"' _ "$F_BUCKET/$PFX/$new" "$MARKER"
check "imprime o tamanho do tarball (bytes) e do banco (10 MiB)" bash -c 'grep -qE "^tarball: [0-9]+ bytes" <<<"$1" && grep -qxF "banco:   10485760 bytes (10 MiB)" <<<"$1"' _ "$OUT"
check "imprime o nome do backup" grep -qF "oci:oute-shared/$PFX/$new" <<<"$OUT"
check "banco abaixo do limite: sem aviso de tamanho" bash -c '! grep -q "^aviso:" <<<"$1"' _ "$OUT"
check "o conteúdo do tarball nunca na saída" bash -c '! grep -qF "$2" <<<"$1"' _ "$OUT" "$MARKER"
check "o conteúdo do tarball nunca no log das chamadas" bash -c '! grep -qF "$2" "$1"' _ "$F_LOG" "$MARKER"
check "o rclone não leu nem enviou o tarball (só lsf: o mount é quem sobe)" bash -c '! grep -qE "^rclone (cat|copy|rcat|move|sync)" "$1"' _ "$F_LOG"
check "o ai-memory falso não deixou tmp no host" bash -c '[[ -z "$(ls "$1" 2>/dev/null | grep oute-memory-backup)" ]]' _ "$TMP"

# ---------------------------------------------------------------- 2. retenção por origem
seed 10 10; FENV=()
oute memory-backup
check "retenção padrão: rc 0" test "$RC" = 0
check "ficam 8 da origem (de 10 antigos + 1 novo)" test "$(mine | wc -l | tr -d ' ')" = 8
check "ficam os mais recentes: o novo, e dos antigos só do dia 04 em diante" bash -c '
  m="$(cd "$1" && ls | grep -E "^$2-[0-9]{8}T[0-9]{6}Z\.tar\.gz\$" | LC_ALL=C sort)"
  [[ "$(head -n 1 <<<"$m")" == "$2-20260104T000000Z.tar.gz" ]] && [[ "$(tail -n 1 <<<"$m")" == "$3" ]]' _ "$F_BUCKET/$PFX" "$ORIGIN" "$(newest)"
check "apagou 3 e disse quais" bash -c 'grep -c "^retenção: apagado " <<<"$1" | grep -qx 3 && grep -qF "retenção: apagado '"$ORIGIN"'-20260101T000000Z.tar.gz" <<<"$1"' _ "$OUT"
check "nunca apagou arquivo de outra origem (oute-mac: 12 de pé)" test "$(ls "$F_BUCKET/$PFX" | grep -c '^oute-mac-oute-agent-')" = 12
check "nem de outra instância do mesmo host, nem arquivo estranho" bash -c '[[ -f "$1/$2-extra-20260101T000000Z.tar.gz" && -f "$1/LEIAME.txt" ]]' _ "$F_BUCKET/$PFX" "$ORIGIN"
check "o deletefile só mirou nomes da origem" bash -c '! grep "^rclone deletefile" "$1" | grep -vq "'"$ORIGIN"'-2026"' _ "$F_LOG"

seed 5 10; FENV=(OUTE_MEMORY_BACKUP_KEEP=2)
oute memory-backup
check "OUTE_MEMORY_BACKUP_KEEP=2: rc 0 e ficam 2 da origem" bash -c '[[ "$1" = 0 && "$2" = 2 ]]' _ "$RC" "$(mine | wc -l | tr -d ' ')"
check "o novo está entre os 2" bash -c '[[ "$(cd "$1" && ls | grep -E "^$2-[0-9]{8}T[0-9]{6}Z\.tar\.gz\$" | LC_ALL=C sort | tail -n 1)" == "$3" ]]' _ "$F_BUCKET/$PFX" "$ORIGIN" "$(newest)"

seed 3 10; FENV=()
oute memory-backup
check "menos arquivos que o limite: nada apagado (4 de 8)" bash -c '[[ "$1" = 4 ]] && ! grep -q "^rclone deletefile" "$2"' _ "$(mine | wc -l | tr -d ' ')" "$F_LOG"

for bad_keep in 0 abc -1 ""; do
  seed 1 10; FENV=(OUTE_MEMORY_BACKUP_KEEP="$bad_keep")
  oute memory-backup
  if [[ -z "$bad_keep" ]]; then
    check "OUTE_MEMORY_BACKUP_KEEP vazio vale o padrão: rc 0" test "$RC" = 0
  else
    check "OUTE_MEMORY_BACKUP_KEEP='$bad_keep' inválido: rc 2, sem backup, sem apagar" bash -c '[[ "$1" = 2 ]] && ! grep -q "^ai-memory" "$2" && ! grep -q deletefile "$2"' _ "$RC" "$F_LOG"
  fi
done
seed 1 10; FENV=(OUTE_MEMORY_WARN_MB=abc)
oute memory-backup
check "OUTE_MEMORY_WARN_MB inválido: rc 2, sem backup" bash -c '[[ "$1" = 2 ]] && ! grep -q "^ai-memory" "$2"' _ "$RC" "$F_LOG"

# ---------------------------------------------------------------- 3. aviso de tamanho
seed 1 600; FENV=()
oute memory-backup
check "banco de 600 MB passa do padrão (500): aviso, backup segue, rc 0" bash -c '[[ "$1" = 0 ]] && grep -qF "aviso: o banco passou de 500 MB" <<<"$2"' _ "$RC" "$OUT"
check "o tamanho do banco impresso é o de 600 MiB" has_line "banco:   629145600 bytes (600 MiB)"
seed 1 10; FENV=(OUTE_MEMORY_WARN_MB=5)
oute memory-backup
check "OUTE_MEMORY_WARN_MB=5 com banco de 10 MB: aviso com o limite 5" bash -c 'grep -qF "aviso: o banco passou de 5 MB" <<<"$1"' _ "$OUT"
seed 1 10; FENV=(OUTE_MEMORY_WARN_MB=20)
oute memory-backup
check "OUTE_MEMORY_WARN_MB=20 com banco de 10 MB: sem aviso" bash -c '! grep -q "^aviso:" <<<"$1"' _ "$OUT"

# ---------------------------------------------------------------- 4. falhas e código de saída
seed 2 10; FENV=(F_DOWN=1)
oute memory-backup
check "container parado: rc 1, não chama o ai-memory" bash -c '[[ "$1" = 1 ]] && grep -qF "não está de pé" <<<"$2" && ! grep -q "^ai-memory" "$3"' _ "$RC" "$OUT" "$F_LOG"

seed 2 10; FENV=(F_BACKUP_FAIL=1)
oute memory-backup
check "ai-memory backup falha: rc 1 e diz que nada foi gravado" bash -c '[[ "$1" = 1 ]] && grep -qF "ai-memory backup falhou" <<<"$2" && grep -qF "nada foi gravado" <<<"$2"' _ "$RC" "$OUT"
check "mostra o erro do ai-memory (cauda do log), sem apagar o que já havia" bash -c 'grep -qF "disco cheio" <<<"$1" && [[ "$(ls "$2" | wc -l | tr -d " ")" = "$3" ]]' _ "$OUT" "$F_BUCKET/$PFX" "$(ls "$F_BUCKET/$PFX" | wc -l | tr -d ' ')"
check "o arquivo pela metade é removido (nenhum <origem>-<data> novo no bucket)" test "$(mine | wc -l | tr -d ' ')" = 2
check "a retenção não rodou depois da falha" bash -c '! grep -q "^rclone" "$1"' _ "$F_LOG"

seed 2 10; FENV=(OCI_S3_ACCESS_KEY=)
oute memory-backup
check "sem credencial do bucket: rc 1 e diz que ficou só local" bash -c '[[ "$1" = 1 ]] && grep -qF "ficou só local" <<<"$2"' _ "$RC" "$OUT"
check "o rclone nem foi chamado" bash -c '! grep -q "^rclone" "$1"' _ "$F_LOG"
check "o arquivo existe (no mount/volume do container, que aqui é o bucket de teste)" bash -c '[[ -n "$1" ]]' _ "$(newest)"

seed 2 10; FENV=(F_SHARED="$TMP/local")
oute memory-backup
check "mount parado (grava num volume local): rc 1, não chegou ao bucket" bash -c '[[ "$1" = 1 ]] && grep -qF "não chegou ao bucket" <<<"$2" && grep -qF "ficou só local" <<<"$2"' _ "$RC" "$OUT"
check "o arquivo ficou no volume local, e o bucket segue como estava (2 da origem)" bash -c '[[ "$(ls "$1" | grep -c "^$2-")" = 1 && "$(ls "$3" | grep -c "^$2-2026")" = 2 ]]' _ "$TMP/local/$PFX" "$ORIGIN" "$F_BUCKET/$PFX"
check "sem retenção quando não chegou (nada apagado)" bash -c '! grep -q deletefile "$1"' _ "$F_LOG"

seed 2 10; FENV=(F_LSF_SIZE_OFF=1)
oute memory-backup
check "tamanho no bucket diferente do arquivo (envio incompleto): rc 1, não chegou" bash -c '[[ "$1" = 1 ]] && grep -qF "não chegou ao bucket" <<<"$2"' _ "$RC" "$OUT"

seed 10 10; FENV=(F_LSF_FAIL_AFTER=1)
oute memory-backup
check "a conferência passou mas a listagem da retenção falhou: rc 1, nada apagado, diz por quê" bash -c '[[ "$1" = 1 ]] && grep -qF "nada apagado" <<<"$2" && ! grep -q deletefile "$3"' _ "$RC" "$OUT" "$F_LOG"

seed 10 10; FENV=(F_DEL_FAIL=1)
oute memory-backup
check "retenção não consegue apagar: rc 1 e diz o arquivo, mas o backup novo está lá" bash -c '[[ "$1" = 1 ]] && grep -qF "não consegui apagar '"$ORIGIN"'-20260101T000000Z.tar.gz" <<<"$2" && [[ -n "$3" ]]' _ "$RC" "$OUT" "$(newest)"

# ---------------------------------------------------------------- 5. --check
seed 2 10; FENV=(F_PAGES=7)
oute memory-backup
good="$(newest)"; cp "$F_BUCKET/$PFX/$good" "$TMP/good.tar.gz"
before="$(find "$F_BUCKET" "$TMP/local" -type f | sort | xargs cksum | cksum)"
FENV=(); oute memory-backup --check "$TMP/good.tar.gz"
check "--check de arquivo local: rc 0, banco íntegro e 7 páginas" bash -c '[[ "$1" = 0 ]] && grep -qxF "ok: banco íntegro, 7 páginas, 1 arquivos no wiki" <<<"$2"' _ "$RC" "$OUT"
check "--check não grava em volume/bucket (tudo igual) e não deixa tmp no container" bash -c '[[ "$(find "$1" "$2" -type f | sort | xargs cksum | cksum)" == "$3" && -z "$(ls -A "$4")" ]]' _ "$F_BUCKET" "$TMP/local" "$before" "$TMP/ct-tmp"
check "--check: o conteúdo do tarball nunca na saída" bash -c '! grep -qF "$2" <<<"$1"' _ "$OUT" "$MARKER"
oute memory-backup --check "$good"
check "--check pelo nome no bucket: rc 0" bash -c '[[ "$1" = 0 ]] && grep -q "^ok: banco íntegro, 7 páginas" <<<"$2"' _ "$RC" "$OUT"
oute memory-backup --check "$PFX/$good"
check "--check por backups/ai-memory/<nome>: rc 0" test "$RC" = 0
check "--check pelo bucket lê com rclone cat, sem copiar para o host" bash -c 'grep -q "^rclone cat oci:oute-shared/'"$PFX"'/'"$good"'" "$1"' _ "$F_LOG"

for kind in corrupt nodb; do
  seed 0 10; FENV=(F_DB_KIND="$kind"); oute memory-backup; bk="$(newest)"
  FENV=(); oute memory-backup --check "$bk"
  case "$kind" in
    corrupt) check "--check com banco corrompido: rc 1, 'o banco não abre'" bash -c '[[ "$1" = 1 ]] && grep -q "^falhou: o banco não abre" <<<"$2"' _ "$RC" "$OUT" ;;
    nodb)    check "--check sem db/memory.sqlite: rc 1" bash -c '[[ "$1" = 1 ]] && grep -qF "falhou: o tarball não tem db/memory.sqlite" <<<"$2"' _ "$RC" "$OUT" ;;
  esac
  check "--check ($kind): sem tmp sobrando no container" test -z "$(ls -A "$TMP/ct-tmp")"
done
seed 0 10; FENV=(F_PAGES=0); oute memory-backup; bk="$(newest)"
FENV=(); oute memory-backup --check "$bk"
check "--check com banco sem páginas: rc 1, 'nenhuma página'" bash -c '[[ "$1" = 1 ]] && grep -qF "falhou: o banco abre, mas não tem nenhuma página" <<<"$2"' _ "$RC" "$OUT"
check "--check (sem páginas): sem tmp sobrando no container" test -z "$(ls -A "$TMP/ct-tmp")"
printf 'isto nao e um tarball %s' "$MARKER" > "$TMP/lixo.tar.gz"
oute memory-backup --check "$TMP/lixo.tar.gz"
check "--check de arquivo que não é tarball: rc 1, 'ilegível', sem repetir o conteúdo" bash -c '[[ "$1" = 1 ]] && grep -qF "falhou: tarball ilegível" <<<"$2" && ! grep -qF "$3" <<<"$2"' _ "$RC" "$OUT" "$MARKER"
oute memory-backup --check "oute-teste-oute-agent-20990101T000000Z.tar.gz"
check "--check de nome que não está no bucket: rc 1" bash -c '[[ "$1" = 1 ]] && grep -qF "backup não encontrado no bucket" <<<"$2"' _ "$RC" "$OUT"
: > "$F_LOG"
oute memory-backup --check "../segredo/x"
check "--check de caminho que não é arquivo nem nome de backup: rc 1, sem chamar o rclone" bash -c '[[ "$1" = 1 && "$2" == *"arquivo não encontrado"* ]] && ! grep -q "^rclone cat" "$3"' _ "$RC" "$OUT" "$F_LOG"
FENV=(F_DOWN=1); oute memory-backup --check "$TMP/good.tar.gz"
check "--check com o container parado: rc 1" bash -c '[[ "$1" = 1 ]] && grep -qF "não está de pé" <<<"$2"' _ "$RC" "$OUT"
FENV=(OCI_S3_ACCESS_KEY=); oute memory-backup --check "$good"
check "--check de nome do bucket sem credencial: rc 1" bash -c '[[ "$1" = 1 ]] && grep -qF "oci-storage ausente" <<<"$2"' _ "$RC" "$OUT"
FENV=()
for a in "--check" "--check a b" "--nada"; do
  # shellcheck disable=SC2086
  oute memory-backup $a
  check "uso errado ('memory-backup $a'): rc 2 com o uso" bash -c '[[ "$1" = 2 ]] && grep -q "^uso: oute memory-backup" <<<"$2"' _ "$RC" "$OUT"
done

check_end
