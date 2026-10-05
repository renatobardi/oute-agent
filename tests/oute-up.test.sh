#!/usr/bin/env bash
# Testes do `oute up`/`oute down` do scripts/oute depois da saída do roteador de modelos (#218): a subida não pede
# mais a key do roteador no agent.env, e a limpeza dos restos (entrada diária no crontab do host e o container do
# serviço que saiu do compose; a pasta dos gerados do roteador no checkout, #271) é idempotente. Bash puro, sem
# Docker: `docker` e `crontab` são falsos, com o estado em arquivos, e um sshd de mentira devolve o banner que o `up`
# espera. O scripts/oute roda de uma cópia num checkout git temporário: a limpeza mexe no checkout, nunca no real.
# Os nomes antigos levam [-] nos padrões, como no scripts/oute, para não voltarem a aparecer no repo.
# Segredos de serviço (#256, casos 9 a 15): os nomes de serviço saem do arquivo do agent (cache antigo ou vault sem
# a pasta oute-services), vão para o services.env e chegam só ao compose; o vault é um scripts/oute-secrets.sh falso
# no checkout de mentira, e o `docker compose up` falso grava o ambiente que recebeu.
# Sessão do vault (#297, caso 17): erro no meio, Ctrl+C e kill deixam a sessão trancada e nada de sessão em disco.
# rclone no macOS (#114, casos 18): `uname` e `rclone` falsos (F_UNAME, F_TAGS, F_FUSE); sem a tag cmount ou sem FUSE o `rclone mount`
# não roda e o `sync-shared` (que é o mount_shared do `up`) termina com rc 0.
# Uso: tests/oute-up.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap '[[ -z "${SSHD_PID:-}" ]] || { kill "$SSHD_PID"; wait "$SSHD_PID"; } 2>/dev/null; rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1   # o bad mostra a saída inteira
command -v python3 >/dev/null || die "python3 ausente (sshd de mentira)"

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home/.ssh" "$TMP/oute"
# docker falso: registra cada chamada em $F_LOG. O container antigo existe enquanto $F_LEGACY existir.
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$F_LOG"
case "$1" in
  compose) case " $* " in
             *" ps "*) echo "NAME  STATUS" ;;
             # o que o compose interpolaria (#256): só o que os casos de segredo de serviço conferem
             *" up "*) printf '%s\n' "ingest=${AGENT_STUDIO_INGEST_TOKEN:-}" "read=${AGENT_STUDIO_READ_TOKEN:-}" \
                         "pass=${AGENT_STUDIO_SURREAL_PASS:-}" "antigo=${AGENT_STUDIO_TOKEN:-}" "otel=${OUTE_OTEL_STUDIO:-}" \
                         "url=${AGENT_STUDIO_URL:-}" "profiles=${COMPOSE_PROFILES:-}" "bw=${BW_SESSION:-}" \
                         "memkey=${OPENROUTER_MEMORY_API_KEY:-}" > "$F_ENV" ;;
           esac ;;
  image)   exit 0 ;;
  volume)  exit 1 ;;
  run)     [[ "${F_RUN_FAIL:-}" == 1 && "$*" == *oci-bootstrap.sh* ]] && exit 1; echo "10485760 0" ;;
  ps)      case "$*" in *'oute-jev[-]router'*) [[ -e "$F_LEGACY" ]] && echo abc123 ;; esac; exit 0 ;;
  rm)      [[ "${F_RM_FAIL:-}" == 1 ]] && exit 1; rm -f "$F_LEGACY" ;;
  *) exit 9 ;;
esac
SH
# crontab falso: o crontab do usuário é o arquivo $F_CRON; toda gravação ou remoção vai para $F_CRON_LOG
cat > "$BIN/crontab" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -l) [[ -f "$F_CRON" ]] || { echo "no crontab for teste" >&2; exit 1; }; cat "$F_CRON" ;;
  -)  cat > "$F_CRON"; echo write >> "$F_CRON_LOG" ;;
  -r) rm -f "$F_CRON"; echo remove >> "$F_CRON_LOG" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN"/*
export F_LOG="$TMP/docker.log" F_LEGACY="$TMP/legacy" F_CRON="$TMP/cron" F_CRON_LOG="$TMP/cron.log" F_ENV="$TMP/compose.env"
: > "$F_LOG"; : > "$F_CRON_LOG"

# sshd de mentira: manda o banner a quem conecta (o `up` espera o SSH-2.0 antes de voltar)
python3 - "$TMP/port" <<'PY' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept(); c.sendall(b"SSH-2.0-teste\r\n"); c.close()
PY
SSHD_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
[[ -s "$TMP/port" ]] || die "sshd de mentira não subiu"

# agent.env sem a key do roteador (o que o vault devolve depois que a nota sair)
printf 'export GH_TOKEN=x\nexport AI_MEMORY_AUTH_TOKEN=y\n' > "$TMP/oute/agent.env"
OLD_KEY="OPEN""ROUTER_API_KEY"   # a key que o `up` exigia; fora do ambiente do teste e do agent.env
grep -q "$OLD_KEY" "$TMP/oute/agent.env" && die "agent.env de teste com a key do roteador"
echo "ssh-ed25519 AAAA teste" > "$TMP/home/.ssh/id_ed25519.pub"
ROUTER_LINE="0 4 * * * cd /repo && ./scripts/oute router""-sync >> /home/x/.oute/router""-sync.log 2>&1"
OTHER_LINE="15 3 * * * /usr/local/bin/backup"

# checkout de mentira: o scripts/oute desta árvore (com as mudanças ainda não commitadas) num repo git em $TMP
REPO="$TMP/repo"; mkdir -p "$REPO/scripts" "$REPO/docker" "$REPO/config"
cp "$ROOT/scripts/oute" "$REPO/scripts/oute"; cp "$ROOT/VERSION" "$REPO/VERSION"; : > "$REPO/docker/compose.yaml"
echo "# config" > "$REPO/config/README.md"
GIT=(git -C "$REPO" -c user.name=teste -c user.email=teste@exemplo.invalid -c commit.gpgsign=false)
"${GIT[@]}" init -q && "${GIT[@]}" add -A && "${GIT[@]}" commit -qm base || die "checkout de mentira não montou"
OLDDIR="config/lite""llm"   # pasta dos gerados do roteador (#271), com o nome partido como no scripts/oute
gerados() { mkdir -p "$REPO/$OLDDIR"; for f in router.yaml config.yaml candidates.json catalog.json; do echo x > "$REPO/$OLDDIR/$f"; done; }

# oute <cmd>: roda o scripts/oute de verdade com os falsos; guarda saída em $OUT e código em $RC. Sem OCI_S3_* no
# ambiente: com eles (e rclone no host) o `up` montaria o bucket de verdade dentro de $TMP. Sem as credenciais do
# agent-studio nem do vault de quem roda o teste; F_AMBIENT=<valor> põe uma credencial de ingestão no ambiente e
# F_SESSION=<valor> uma sessão do vault já aberta por quem chama (#256)
oute_env() {
  env -u "$OLD_KEY" -u OUTE_AGENT_STUDIO -u AGENT_STUDIO_TOKEN -u COMPOSE_PROFILES \
    -u OCI_S3_ACCESS_KEY -u OCI_S3_SECRET_KEY -u OCI_S3_ENDPOINT -u OCI_S3_REGION \
    -u OPENROUTER_MEMORY_API_KEY -u AGENT_STUDIO_INGEST_TOKEN -u AGENT_STUDIO_READ_TOKEN -u AGENT_STUDIO_SURREAL_PASS -u AGENT_STUDIO_URL \
    -u OUTE_AGENT_STUDIO_URL -u OUTE_VAULT_FOLDER -u OUTE_VAULT_SERVICES_FOLDER -u GH_TOKEN -u GHCR_TOKEN \
    -u BW_SESSION -u BW_PASSWORD -u BW_CLIENTID -u BW_CLIENTSECRET -u OUTE_FUSE_PATHS \
    ${F_FUSE:+OUTE_FUSE_PATHS="$F_FUSE"} ${F_OCI:+OCI_S3_ACCESS_KEY="$F_OCI" OCI_S3_SECRET_KEY="$F_OCI" OCI_S3_ENDPOINT="$F_OCI" OCI_S3_REGION="$F_OCI"} \
    ${F_AMBIENT:+AGENT_STUDIO_INGEST_TOKEN="$F_AMBIENT" AGENT_STUDIO_SURREAL_PASS="$F_AMBIENT"} ${F_SESSION:+BW_SESSION="$F_SESSION"} \
    PATH="${F_PATHX:+$F_PATHX:}$BIN:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/oute" OUTE_HOST=teste \
    OUTE_SSH_HOST=127.0.0.1 OUTE_SSH_PORT="$(cat "$TMP/port")" OUTE_SSH_AUTHORIZED_KEYS="$TMP/home/.ssh/id_ed25519.pub" \
    "$@"
}
oute() { OUT="$(oute_env "$REPO/scripts/oute" "$@" 2>&1)"; RC=$?; }
ncron() { grep -c . "$F_CRON_LOG" || true; }

check "sintaxe (bash -n)" bash -n "$REPO/scripts/oute"

# ---------------------------------------------------------------- 1. sobe sem a key; limpa crontab e container
printf '%s\n%s\n' "$OTHER_LINE" "$ROUTER_LINE" > "$F_CRON"; : > "$F_LEGACY"; gerados
oute up
check "up sem a key do roteador: rc 0"                 [ "$RC" -eq 0 ]
check "up: não pede a key do roteador"                 hasnt "$OLD_KEY"
check "up: compose up chamado"                         grep -q -- ' up -d --no-build' "$F_LOG"
check "up: esperou o sshd"                             has 'sshd pronto'
check "crontab: entrada do roteador removida"          bash -c '! grep -q "router[-]sync" "$F_CRON"'
check "crontab: as outras linhas ficam"                test "$(cat "$F_CRON")" = "$OTHER_LINE"
check "crontab: avisa o que fez"                       has 'crontab: entrada diária do roteador removida'
check "container antigo removido antes do compose up"  bash -c 'test "$(grep -n "^rm -f abc123$" "$F_LOG" | cut -d: -f1)" -lt "$(grep -n " up -d --no-build" "$F_LOG" | cut -d: -f1)"'
check "container antigo: avisa o que fez"              has 'container do roteador removido'
check "up não chama mais docker run do roteador"       bash -c '! grep -q "router" <(grep "^run " "$F_LOG")'
check "checkout: pasta dos gerados removida"           test ! -e "$REPO/$OLDDIR"
check "checkout: avisa o que fez, em uma linha"        test "$(grep -c "pasta $OLDDIR do roteador removida" <<<"$OUT")" = 1
check "checkout: árvore limpa"                         test -z "$(git -C "$REPO" status --porcelain)"
check "checkout: o resto do config fica"               test -f "$REPO/config/README.md"

# ---------------------------------------------------------------- 2. de novo: host limpo não muda
N="$(ncron)"; : > "$F_LOG"
oute up
check "segunda subida: rc 0"                           [ "$RC" -eq 0 ]
check "segunda subida: crontab não é regravado"        test "$(ncron)" = "$N"
check "segunda subida: crontab igual"                  test "$(cat "$F_CRON")" = "$OTHER_LINE"
check "segunda subida: nenhum docker rm"               bash -c '! grep -q "^rm " "$F_LOG"'
check "segunda subida: sem aviso de limpeza"           hasnt 'removid'
check "segunda subida: checkout igual"                 test -z "$(git -C "$REPO" status --porcelain)" -a ! -e "$REPO/$OLDDIR"

# ---------------------------------------------------------------- 3. crontab só com a entrada: some inteiro
printf '%s\n' "$ROUTER_LINE" > "$F_CRON"
oute up
check "crontab só com a entrada: rc 0"                 [ "$RC" -eq 0 ]
check "crontab só com a entrada: crontab removido"     test ! -e "$F_CRON"
check "crontab só com a entrada: crontab -r"           test "$(tail -1 "$F_CRON_LOG")" = remove

# ---------------------------------------------------------------- 4. host sem crontab nenhum
N="$(ncron)"
oute up
check "sem crontab do usuário: rc 0"                   [ "$RC" -eq 0 ]
check "sem crontab do usuário: nada gravado"           test "$(ncron)" = "$N" -a ! -e "$F_CRON"

# ---------------------------------------------------------------- 5. docker rm falha: avisa e sobe
: > "$F_LEGACY"; : > "$F_LOG"
F_RM_FAIL=1 oute up
check "docker rm falha: rc 0 (não bloqueia a subida)"  [ "$RC" -eq 0 ]
check "docker rm falha: aviso"                         has 'não consegui remover o container do roteador'
check "docker rm falha: compose up roda mesmo assim"   grep -q -- ' up -d --no-build' "$F_LOG"

# ---------------------------------------------------------------- 6. down também tira o container antigo
: > "$F_LEGACY"; : > "$F_LOG"; printf '%s\n%s\n' "$ROUTER_LINE" "$OTHER_LINE" > "$F_CRON"
oute down
check "down: rc 0"                                     [ "$RC" -eq 0 ]
check "down: container antigo removido antes do compose down" bash -c 'test "$(grep -n "^rm -f abc123$" "$F_LOG" | cut -d: -f1)" -lt "$(grep -n " down$" "$F_LOG" | cut -d: -f1)"'
check "down: crontab limpo"                            test "$(cat "$F_CRON")" = "$OTHER_LINE"

# ---------------------------------------------------------------- 6b. down também tira a pasta dos gerados
gerados
oute down
check "down: pasta dos gerados removida"               test ! -e "$REPO/$OLDDIR"
check "down: avisa o que fez"                          has "pasta $OLDDIR do roteador removida"

# ---------------------------------------------------------------- 6c. pasta com arquivo rastreado: nada sai
gerados; "${GIT[@]}" add "$OLDDIR/router.yaml" && "${GIT[@]}" commit -qm rastreado
oute up
check "rastreado: rc 0"                                [ "$RC" -eq 0 ]
check "rastreado: pasta inteira fica"                  test -f "$REPO/$OLDDIR/router.yaml" -a -f "$REPO/$OLDDIR/catalog.json"
check "rastreado: avisa que não removeu"               has "$OLDDIR tem arquivo rastreado; não removi"
echo y > "$REPO/$OLDDIR/router.yaml"
oute down
check "modificado: pasta inteira fica"                 test "$(cat "$REPO/$OLDDIR/router.yaml")" = y -a -f "$REPO/$OLDDIR/catalog.json"
"${GIT[@]}" rm -qrf --cached "$OLDDIR"; "${GIT[@]}" commit -qm volta; rm -rf "${REPO:?}/$OLDDIR"
gerados; "${GIT[@]}" add "$OLDDIR/config.yaml"
oute up
check "staged (nunca commitado): pasta fica"           test -f "$REPO/$OLDDIR/config.yaml" -a -f "$REPO/$OLDDIR/router.yaml"
"${GIT[@]}" rm -qrf --cached "$OLDDIR"; rm -rf "${REPO:?}/$OLDDIR"

# ---------------------------------------------------------------- 6d. rm falha: avisa e sobe
if [[ "$(id -u)" != 0 ]]; then
  gerados; chmod a-w "$REPO/$OLDDIR"
  oute up
  chmod u+w "$REPO/$OLDDIR"
  check "rm falha: rc 0 (não bloqueia a subida)"       [ "$RC" -eq 0 ]
  check "rm falha: aviso"                              has "não consegui remover $OLDDIR"
  check "rm falha: sem aviso de removida"              hasnt "pasta $OLDDIR do roteador removida"
  rm -rf "${REPO:?}/$OLDDIR"
else
  echo "# rm falha: pulado (root ignora a permissão da pasta)"
fi

# ---------------------------------------------------------------- 6e. fora de um checkout git: a pasta fica
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT/scripts" "$NOGIT/docker" "$NOGIT/$OLDDIR"
cp "$REPO/scripts/oute" "$REPO/VERSION" "$NOGIT/scripts/"; mv "$NOGIT/scripts/VERSION" "$NOGIT/VERSION"
: > "$NOGIT/docker/compose.yaml"; echo x > "$NOGIT/$OLDDIR/router.yaml"
SAVED_REPO="$REPO"; REPO="$NOGIT"; oute down; REPO="$SAVED_REPO"
check "sem git: rc 0"                                  [ "$RC" -eq 0 ]
check "sem git: pasta fica"                            test -f "$NOGIT/$OLDDIR/router.yaml"

# ---------------------------------------------------------------- 7. host sem o comando crontab
# só a função, com um PATH mínimo (sem crontab): o script inteiro precisa de mais ferramentas
FUNCS="$(sed -n '/^legacy_cleanup() {/,/^}/p' "$ROOT/scripts/oute")"
[[ -n "$FUNCS" ]] || die "legacy_cleanup não achada em scripts/oute"
MIN="$TMP/min"; mkdir -p "$MIN"; cp "$BIN/docker" "$MIN/docker"
for t in bash grep rm cat; do ln -s "$(command -v "$t")" "$MIN/$t"; done
: > "$F_LEGACY"; N="$(ncron)"; mkdir -p "$TMP/vazio/$OLDDIR"   # sem git no PATH: a pasta fica
OUT="$(ROOT="$TMP/vazio" PATH="$MIN" "$BASH" -c "set -euo pipefail; $FUNCS"$'\n'"legacy_cleanup" 2>&1)"; RC=$?
check "sem o comando crontab: rc 0"                    [ "$RC" -eq 0 ]
check "sem o comando crontab: crontab intocado"        test "$(ncron)" = "$N"
check "sem o comando crontab: container removido"      test ! -e "$F_LEGACY"
check "sem o comando git: pasta fica"                  test -d "$TMP/vazio/$OLDDIR"

# ---------------------------------------------------------------- 8. comandos que saíram
oute schedule
check "schedule saiu: comando desconhecido"            has 'comando desconhecido: schedule'
oute --help
check "ajuda sem o roteador"                           hasnt 'router'

# ================================================================ segredos de serviço fora do agent (#256)
command -v jq >/dev/null || die "jq ausente (leitura do vault)"
rnd() { python3 -c "import secrets; print(secrets.token_hex(12))"; }
T_OLD="$(rnd)"; S_OLD="$(rnd)"; T_ING="$(rnd)"; T_READ="$(rnd)"; S_NEW="$(rnd)"; T_GH="$(rnd)"; T_FOO="$(rnd)"
AENV="$TMP/oute/agent.env"; SENV="$TMP/oute/services.env"
SVC_RE='^export (AGENT_STUDIO_SURREAL_PASS|AGENT_STUDIO_INGEST_TOKEN|AGENT_STUDIO_TOKEN)='
cenv() { sed -n "s/^$1=//p" "$F_ENV"; }
# nenhum valor de segredo na saída do `oute`
quiet() { local v; for v in "$T_OLD" "$S_OLD" "$T_ING" "$T_READ" "$S_NEW" "$T_GH" "$T_FOO"; do ! grep -qF -- "$v" <<<"$OUT" || return 1; done; }
# vault falso: uma pasta = um arquivo em $F_VAULT com as linhas do `oute-secrets export`; pasta sem arquivo = rc 4
# (como o scripts/oute-secrets.sh de verdade); <pasta>.rc = falha de leitura com esse código. Chamadas em $F_VAULT_LOG.
# <pasta>.hang (ou session.hang) = a chamada avisa em $F_VAULT/hanging e fica parada até existir $F_VAULT/release (#297)
export F_VAULT="$TMP/vault" F_VAULT_LOG="$TMP/vault.log"; mkdir -p "$F_VAULT"; : > "$F_VAULT_LOG"
cat > "$REPO/scripts/oute-secrets.sh" <<'SH'
#!/usr/bin/env bash
folder="${OUTE_VAULT_FOLDER:-oute-agent}"
echo "$1 $folder sessao=${BW_SESSION:-nenhuma}" >> "$F_VAULT_LOG"
hang() {
  [[ -e "$F_VAULT/$1.hang" ]] || return 0
  local i=0; : > "$F_VAULT/hanging"
  until [[ -e "$F_VAULT/release" || $i -ge 100 ]]; do sleep 0.1; i=$((i + 1)); done
}
case "$1" in session) hang session ;; export) hang "$folder" ;; esac
case "$1" in
  session) [[ ! -e "$F_VAULT/session.rc" ]] || exit 1; echo sessao-de-teste ;;
  export)  [[ ! -e "$F_VAULT/$folder.rc" ]] || exit "$(cat "$F_VAULT/$folder.rc")"
           [[ -f "$F_VAULT/$folder" ]] || { echo "pasta '$folder' não existe no vault" >&2; exit 4; }
           cat "$F_VAULT/$folder" ;;
esac
SH
printf '#!/usr/bin/env bash\necho "bw $*" >> "$F_VAULT_LOG"\n' > "$BIN/bw"
chmod +x "$REPO/scripts/oute-secrets.sh" "$BIN/bw"; : > "$TMP/oute/bw_client.env"
old_cache() {   # agent.env como a versão anterior gravava: tudo da pasta oute-agent, com os segredos de serviço
  printf 'export AGENT_STUDIO_SURREAL_PASS=%s\nexport AGENT_STUDIO_TOKEN=%s\nexport GH_TOKEN=%s\nexport PEM=%q\n' \
    "$S_OLD" "$T_OLD" "$T_GH" $'linha1\nlinha2' > "$AENV"; rm -f "$SENV"
}

# ---------------------------------------------------------------- 9. cache antigo, sem abrir o vault (Mac)
old_cache; rm -f "$REPO/.env"
oute up
check "cache antigo: rc 0"                             [ "$RC" -eq 0 ]
check "cache antigo: agent.env sem os nomes de serviço" bash -c '! grep -qE "$1" "$0"' "$AENV" "$SVC_RE"
check "cache antigo: agent.env sem os valores"         bash -c '! grep -qF -e "$1" -e "$2" "$0"' "$AENV" "$T_OLD" "$S_OLD"
check "cache antigo: o resto do agent.env fica igual"  test "$(cat "$AENV")" = "$(printf 'export GH_TOKEN=%s\nexport PEM=%q' "$T_GH" $'linha1\nlinha2')"
check "cache antigo: services.env com os dois"         test "$(sort "$SENV")" = "$(printf 'export AGENT_STUDIO_SURREAL_PASS=%s\nexport AGENT_STUDIO_TOKEN=%s' "$S_OLD" "$T_OLD")"
check "cache antigo: services.env e agent.env 0600"    test "$(find "$SENV" "$AENV" -perm 600 | wc -l)" -eq 2
check "cache antigo: avisa, com os nomes"              has 'aviso: segredo de serviço fora do arquivo do agent (#256): AGENT_STUDIO_SURREAL_PASS AGENT_STUDIO_TOKEN estava'
check "cache antigo: avisa a pasta a criar"            has 'pasta oute-services do vault'
check "cache antigo: saída sem valor de segredo"       quiet
check "cache antigo: o vault não é aberto"             test ! -s "$F_VAULT_LOG"
check "Mac: collector recebe a credencial de ingestão" test "$(cenv ingest)" = "$T_OLD"
check "Mac: pipeline ligado, pelo vhost da tailnet"    test "$(cenv otel) $(cenv url)" = "agent-studio https://agent-studio.oute.pro"
check "Mac: sem o profile do agent-studio"             test -z "$(cenv profiles)"
check "Mac: o nome antigo não segue ao compose"        test -z "$(cenv antigo)"
check "Mac: avisa a transição do token"                has 'aviso: transição (#256)'
cp "$AENV" "$TMP/aenv.1"; cp "$SENV" "$TMP/senv.1"
oute up
check "de novo: rc 0, arquivos iguais"                 bash -c '[ "$0" -eq 0 ] && cmp -s "$1" "$2" && cmp -s "$3" "$4"' "$RC" "$AENV" "$TMP/aenv.1" "$SENV" "$TMP/senv.1"
check "de novo: sem o aviso de limpeza"                hasnt 'segredo de serviço fora do arquivo'
check "de novo: a transição segue avisada"             has 'aviso: transição (#256)'
check "de novo: collector segue com a ingestão"        test "$(cenv ingest)" = "$T_OLD"

# ---------------------------------------------------------------- 10. cache antigo no host com o agent-studio
old_cache; printf 'OUTE_AGENT_STUDIO=1\n' > "$REPO/.env"
oute up
check "servidor: rc 0 e profile ligado"                test "$RC $(cenv profiles)" = "0 agent-studio"
check "servidor: agent-studio e surrealdb recebem"     test "$(cenv ingest) $(cenv pass)" = "$T_OLD $S_OLD"
check "servidor: collector pela rede docker"           test "$(cenv url)" = "http://agent-studio:8430"
check "servidor: sem credencial de leitura, avisa"     has 'aviso: AGENT_STUDIO_READ_TOKEN não está em'
check "servidor: agent.env sem os nomes de serviço"    bash -c '! grep -qE "$1" "$0"' "$AENV" "$SVC_RE"
check "servidor: saída sem valor de segredo"           quiet

# ---------------------------------------------------------------- 11. vault sem a pasta oute-services (transição)
printf "export GH_TOKEN='%s'\nexport AGENT_STUDIO_TOKEN='%s'\nexport AGENT_STUDIO_SURREAL_PASS='%s'\nexport AGENT_STUDIO_READ_TOKEN='%s'\nexport BW_CLIENTID='x'\n" \
  "$T_GH" "$T_OLD" "$S_OLD" "$T_READ" > "$F_VAULT/oute-agent"
rm -f "$AENV" "$SENV" "$F_VAULT/oute-services"; : > "$F_VAULT_LOG"
oute up --refresh-secrets
check "sem a pasta: rc 0 (sobe)"                       [ "$RC" -eq 0 ]
check "sem a pasta: avisa que ela não existe"          has 'aviso: a pasta oute-services não existe no vault (#256)'
check "sem a pasta: agent.env sem os nomes de serviço" bash -c '! grep -qE "$1" "$0"' "$AENV" "$SVC_RE"
check "sem a pasta: agent.env com a leitura e o resto, sem BW_*" test "$(cat "$AENV")" = "$(printf 'export AGENT_STUDIO_READ_TOKEN=%s\nexport GH_TOKEN=%s' "$T_READ" "$T_GH")"
check "sem a pasta: services.env com os da pasta oute-agent" test "$(sort "$SENV")" = "$(printf 'export AGENT_STUDIO_SURREAL_PASS=%s\nexport AGENT_STUDIO_TOKEN=%s' "$S_OLD" "$T_OLD")"
check "sem a pasta: serviços recebem ingestão, leitura e senha" test "$(cenv ingest) $(cenv read) $(cenv pass) $(cenv profiles)" = "$T_OLD $T_READ $S_OLD agent-studio"
check "sem a pasta: saída sem valor de segredo"        quiet
check "vault: uma sessão para as duas pastas"          test "$(cut -d' ' -f1-2 "$F_VAULT_LOG" | tr '\n' ';')" = "session oute-agent;export oute-agent;export oute-services;bw lock;"
check "vault: as duas leituras com a sessão aberta"    test "$(grep -c '^export .* sessao=sessao-de-teste$' "$F_VAULT_LOG")" = 2
check "vault: a sessão não chega ao compose"           test -z "$(cenv bw)"

# ---------------------------------------------------------------- 12. vault com a pasta oute-services
# SURREAL_PASS repetido nas duas pastas e FOO_SVC (nome que o script não conhece) também: nome da pasta de serviço
# nunca entra no arquivo do agent, e o valor dela vence
printf "export AGENT_STUDIO_INGEST_TOKEN='%s'\nexport AGENT_STUDIO_SURREAL_PASS='%s'\nexport FOO_SVC='%s'\n" "$T_ING" "$S_NEW" "$T_FOO" > "$F_VAULT/oute-services"
printf "export GH_TOKEN='%s'\nexport AGENT_STUDIO_SURREAL_PASS='%s'\nexport AGENT_STUDIO_READ_TOKEN='%s'\nexport FOO_SVC='da-pasta-do-agent'\n" \
  "$T_GH" "$S_OLD" "$T_READ" > "$F_VAULT/oute-agent"
oute up --refresh-secrets
check "com a pasta: rc 0, sem aviso"                   bash -c '[ "$0" -eq 0 ] && ! grep -q aviso <<<"$1"' "$RC" "$OUT"
check "com a pasta: agent.env só com o que é do agent" test "$(cat "$AENV")" = "$(printf 'export AGENT_STUDIO_READ_TOKEN=%s\nexport GH_TOKEN=%s' "$T_READ" "$T_GH")"
check "com a pasta: services.env = a pasta (o antigo sai)" test "$(cat "$SENV")" = "$(printf 'export AGENT_STUDIO_INGEST_TOKEN=%s\nexport AGENT_STUDIO_SURREAL_PASS=%s\nexport FOO_SVC=%s' "$T_ING" "$S_NEW" "$T_FOO")"
check "com a pasta: serviços com as credenciais novas" test "$(cenv ingest) $(cenv read) $(cenv pass) $(cenv antigo)" = "$T_ING $T_READ $S_NEW "
check "com a pasta: saída sem valor de segredo"        quiet
# item de serviço esquecido na pasta oute-agent (nome conhecido): sai do agent.env, avisa, e o da pasta de serviço vence
printf "export GH_TOKEN='%s'\nexport AGENT_STUDIO_TOKEN='%s'\nexport AGENT_STUDIO_INGEST_TOKEN='%s'\nexport AGENT_STUDIO_READ_TOKEN='%s'\n" \
  "$T_GH" "$T_OLD" "${T_ING}x" "$T_READ" > "$F_VAULT/oute-agent"
oute up --refresh-secrets
check "esquecido na oute-agent: fora do agent.env"     bash -c '! grep -qE "$1" "$0"' "$AENV" "$SVC_RE"
check "esquecido na oute-agent: avisa o nome"          has 'segredo de serviço fora do arquivo do agent (#256): AGENT_STUDIO_TOKEN estava'
check "esquecido na oute-agent: a pasta de serviço vence" test "$(cenv ingest)" = "$T_ING"
check "esquecido na oute-agent: sem aviso de transição" hasnt 'aviso: transição'
# no Mac, com a pasta: o collector manda com a de ingestão e o agent só tem a de leitura
rm -f "$REPO/.env"
oute up
check "Mac com a pasta: collector com a ingestão, agent sem ela" bash -c '[ "$(sed -n "s/^ingest=//p" "$F_ENV")" = "$1" ] && ! grep -qF "$1" "$0"' "$AENV" "$T_ING"
printf 'OUTE_AGENT_STUDIO=1\n' > "$REPO/.env"

# ---------------------------------------------------------------- 13. leitura igual à ingestão: não vai ao agent
printf "export GH_TOKEN='%s'\nexport AGENT_STUDIO_READ_TOKEN='%s'\n" "$T_GH" "$T_ING" > "$F_VAULT/oute-agent"
oute up --refresh-secrets
check "leitura = ingestão: rc 0"                       [ "$RC" -eq 0 ]
check "leitura = ingestão: fora do agent.env"          test "$(cat "$AENV")" = "export GH_TOKEN=$T_GH"
check "leitura = ingestão: avisa"                      has 'aviso: AGENT_STUDIO_READ_TOKEN é igual à credencial de ingestão'
check "leitura = ingestão: o agent-studio sobe sem ela" test "$(cenv ingest)|$(cenv read)|$(cenv profiles)" = "$T_ING||agent-studio"
check "leitura = ingestão: saída sem valor de segredo" quiet

# ---------------------------------------------------------------- 14. vault que falha: nada regravado, não sobe
printf "export GH_TOKEN='%s'\nexport AGENT_STUDIO_READ_TOKEN='%s'\n" "$T_GH" "$T_READ" > "$F_VAULT/oute-agent"
cp "$AENV" "$TMP/aenv.2"; cp "$SENV" "$TMP/senv.2"; echo 1 > "$F_VAULT/oute-services.rc"; : > "$F_LOG"; : > "$F_VAULT_LOG"
oute up --refresh-secrets
check "pasta de serviço ilegível: rc != 0"             [ "$RC" -ne 0 ]
check "pasta de serviço ilegível: diz qual"            has 'não consegui ler a pasta oute-services do vault'
check "pasta de serviço ilegível: arquivos intactos"   bash -c 'cmp -s "$0" "$1" && cmp -s "$2" "$3"' "$AENV" "$TMP/aenv.2" "$SENV" "$TMP/senv.2"
check "pasta de serviço ilegível: compose up não roda" bash -c '! grep -q -- " up -d" "$F_LOG"'
check "pasta de serviço ilegível: sessão trancada"     grep -qx 'bw lock' "$F_VAULT_LOG"
rm -f "$F_VAULT/oute-services.rc"; echo 1 > "$F_VAULT/oute-agent.rc"; : > "$F_VAULT_LOG"
oute secrets refresh
check "pasta do agent ilegível: rc != 0, sem ler a de serviço" bash -c '[ "$0" -ne 0 ] && ! grep -q "^export oute-services" "$F_VAULT_LOG" && grep -qx "bw lock" "$F_VAULT_LOG"' "$RC"
check "pasta do agent ilegível: arquivos intactos"     bash -c 'cmp -s "$0" "$1" && cmp -s "$2" "$3"' "$AENV" "$TMP/aenv.2" "$SENV" "$TMP/senv.2"
rm -f "$F_VAULT/oute-agent.rc"; : > "$F_VAULT/session.rc"; : > "$F_VAULT_LOG"
oute up --refresh-secrets
check "vault não abre: rc != 0, nenhuma pasta lida"    bash -c '[ "$0" -ne 0 ] && grep -q "não consegui abrir o vault" <<<"$1" && ! grep -q "^export " "$F_VAULT_LOG"' "$RC" "$OUT"
check "vault não abre: tranca mesmo assim (#297)"       grep -qx 'bw lock' "$F_VAULT_LOG"
check "vault não abre: arquivos intactos"              bash -c 'cmp -s "$0" "$1" && cmp -s "$2" "$3"' "$AENV" "$TMP/aenv.2" "$SENV" "$TMP/senv.2"
rm -f "$F_VAULT/session.rc"; : > "$F_VAULT_LOG"
# sessão já aberta por quem chama (oci-bootstrap): usa essa e não tranca (quem abriu é quem tranca)
F_SESSION=de-quem-chama oute secrets refresh
check "sessão de quem chama: usada, sem abrir outra nem trancar" test "$RC $(tr '\n' ';' < "$F_VAULT_LOG")" = "0 export oute-agent sessao=de-quem-chama;export oute-services sessao=de-quem-chama;"

# ---------------------------------------------------------------- 15. credencial só no ambiente de quem chama
printf 'export GH_TOKEN=%s\n' "$T_GH" > "$AENV"; : > "$SENV"
F_AMBIENT="$T_FOO" oute up
check "ambiente de quem chama: não vira credencial dos serviços" test "$RC|$(cenv ingest)|$(cenv pass)|$(cenv otel)" = "0|||none"
check "ambiente de quem chama: arquivos não mudam"     bash -c '[ "$(cat "$0")" = "export GH_TOKEN=$2" ] && [ ! -s "$1" ]' "$AENV" "$SENV" "$T_GH"
# Mac (sem OUTE_AGENT_STUDIO no .env) sem a credencial de ingestão: o collector fica sem o pipeline, mas o agent
# ainda recebe o vhost da tailnet, por onde lê com a credencial de leitura (ops-observe, #259)
mv "$REPO/.env" "$TMP/env.servidor"
oute up
check "Mac sem a ingestão: pipeline desligado, vhost para a leitura" test "$RC|$(cenv otel)|$(cenv url)" = "0|none|https://agent-studio.oute.pro"
mv "$TMP/env.servidor" "$REPO/.env"

# ---------------------------------------------------------------- 16. scripts/oute-secrets.sh: pasta ausente = rc 4
# o script de verdade, com um bw falso (sessão já aberta, duas pastas no cofre, uma com item)
cat > "$TMP/bwbin-bw" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "status "*)      echo '{"status":"unlocked","serverUrl":"https://vault.oute.pro"}' ;;
  "list folders")  echo '[{"id":"f1","name":"oute-agent"}]' ;;
  "list items")    jq -n --arg v "$F_BW_VALUE" '[{name:"github",notes:null,fields:[{name:"GH_TOKEN",value:$v}]}]' ;;
  *) : ;;
esac
SH
mkdir -p "$TMP/bwbin"; mv "$TMP/bwbin-bw" "$TMP/bwbin/bw"; chmod +x "$TMP/bwbin/bw"
secrets() { OUT="$(env -u BW_PASSWORD PATH="$TMP/bwbin:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/oute" BW_SESSION=sessao-de-teste \
  F_BW_VALUE="$T_GH" OUTE_VAULT_FOLDER="$1" "$ROOT/scripts/oute-secrets.sh" export 2>&1)"; RC=$?; }
check "oute-secrets: sintaxe (bash -n)"                bash -n "$ROOT/scripts/oute-secrets.sh"
secrets oute-services
check "oute-secrets: pasta ausente = rc 4"             [ "$RC" -eq 4 ]
check "oute-secrets: diz a pasta"                      has "pasta 'oute-services' não existe no vault"
secrets oute-agent
check "oute-secrets: pasta existente = rc 0 e as linhas" test "$RC|$OUT" = "0|export GH_TOKEN='$T_GH'"

# ---------------------------------------------------------------- 17. sessão do vault trancada em qualquer saída (#297)
printf "export GH_TOKEN='%s'\n" "$T_GH" > "$F_VAULT/oute-agent"; printf "export AGENT_STUDIO_INGEST_TOKEN='%s'\n" "$T_ING" > "$F_VAULT/oute-services"
oute secrets refresh
cp "$AENV" "$TMP/aenv.3"; cp "$SENV" "$TMP/senv.3"
vlog() { tr '\n' ';' < "$F_VAULT_LOG"; }
intact() { cmp -s "$AENV" "$TMP/aenv.3" && cmp -s "$SENV" "$TMP/senv.3"; }
# nada de sessão em disco: nem o arquivo das versões antigas nem o valor da sessão em arquivo do host
nofile() { [[ ! -e "$TMP/oute/bw_session" ]] && ! grep -rqF sessao-de-teste "$TMP/oute" "$TMP/home"; }
safe() { intact && nofile; }
# rc_lock <código>: o `oute` saiu com esse código e o vault foi trancado uma vez só, por último
rc_lock() { [[ "$RC" -eq "$1" && "$(grep -cx 'bw lock' "$F_VAULT_LOG")" == 1 && "$(tail -1 "$F_VAULT_LOG")" == 'bw lock' ]]; }
# sig <sinal> <grupo|pid> <chamada que para> <oute …>: roda o `oute` em sessão própria (SIGINT no padrão: comando em
# segundo plano de script nasce com ele ignorado), espera o vault falso parar na chamada e manda o sinal ao grupo
# inteiro (Ctrl+C no terminal) ou só ao `oute` (kill <pid>; a chamada é solta depois). Saída em $OUT, código em $RC
sig() {
  local s="$1" alvo="$2" onde="$3" pid i=0; shift 3
  rm -f "$F_VAULT"/*.hang "$F_VAULT/hanging" "$F_VAULT/release" "$TMP/sig.pid"; : > "$F_VAULT/$onde.hang"; : > "$F_VAULT_LOG"
  oute_env python3 -c 'import os, signal, sys
os.setsid(); signal.signal(signal.SIGINT, signal.SIG_DFL)
open(sys.argv[1], "w").write(str(os.getpid()))
os.execv(sys.argv[2], sys.argv[2:])' "$TMP/sig.pid" "$REPO/scripts/oute" "$@" > "$TMP/sig.out" 2>&1 &
  until [[ -e "$F_VAULT/hanging" || $i -ge 100 ]]; do sleep 0.1; i=$((i + 1)); done
  pid="$(cat "$TMP/sig.pid")"
  if [[ "$alvo" == grupo ]]; then kill "-$s" -- "-$pid"; else kill "-$s" "$pid"; sleep 0.3; : > "$F_VAULT/release"; fi
  wait $!; RC=$?; OUT="$(cat "$TMP/sig.out")"
  rm -f "$F_VAULT"/*.hang "$F_VAULT/hanging" "$F_VAULT/release"
}
sig INT grupo oute-services secrets refresh
check "Ctrl+C na leitura: sai com 130"                 [ "$RC" -eq 130 ]
check "Ctrl+C na leitura: sessão trancada, uma vez"    test "$(vlog)" = "session oute-agent sessao=nenhuma;export oute-agent sessao=sessao-de-teste;export oute-services sessao=sessao-de-teste;bw lock;"
check "Ctrl+C na leitura: arquivos intactos"           intact
check "Ctrl+C na leitura: nada de sessão em disco"     nofile
: > "$F_LOG"
sig TERM grupo oute-agent up --refresh-secrets
check "TERM na leitura: sai com 143, trancada"         test "$RC $(vlog)" = "143 session oute-agent sessao=nenhuma;export oute-agent sessao=sessao-de-teste;bw lock;"
check "TERM na leitura: intactos, sem sessão em disco" safe
check "TERM na leitura: compose up não roda"           bash -c '! grep -q -- " up -d" "$F_LOG"'
sig TERM pid oute-agent secrets refresh
check "kill só no oute: sai com 143, trancada"         rc_lock 143
check "kill só no oute: intactos, sem sessão em disco" safe
sig HUP grupo oute-agent secrets refresh
check "terminal fechado (HUP): sai com 129, trancada"  rc_lock 129
check "terminal fechado: intactos, sem sessão em disco" safe
sig INT grupo session secrets refresh
check "Ctrl+C ao abrir o vault: sai com 130, trancada" test "$RC $(vlog)" = "130 session oute-agent sessao=nenhuma;bw lock;"
check "Ctrl+C ao abrir: intactos, sem sessão em disco" safe
# erro no meio fora dos ramos que já trancam: a gravação do agent.env falha depois da leitura
: > "$F_VAULT_LOG"; rm -f "$AENV.tmp"; mkdir "$AENV.tmp"
oute secrets refresh
rmdir "$AENV.tmp"
check "gravação falha depois da leitura: rc 1, trancada" rc_lock 1
check "gravação falha: nada de sessão em disco"        nofile
# resto das versões antigas (sessão em arquivo): some no primeiro comando que passa pelos segredos
echo sessao-de-teste > "$TMP/oute/bw_session"; : > "$F_VAULT_LOG"
oute secrets refresh
check "arquivo de sessão antigo: vault trancado"       rc_lock 0
check "arquivo de sessão antigo: apagado"              nofile
# oci-bootstrap: o outro caminho que abre o vault. Uma sessão para o provisionamento e para a releitura, trancada na saída
: > "$F_VAULT_LOG"
oute oci-bootstrap
check "oci-bootstrap: uma sessão, trancada só no fim"  test "$RC $(cut -d' ' -f1-2 "$F_VAULT_LOG" | tr '\n' ';')" = "0 session oute-agent;export oute-agent;export oute-services;bw lock;"
: > "$F_VAULT_LOG"
F_RUN_FAIL=1 oute oci-bootstrap
check "oci-bootstrap que falha: rc != 0, trancada"     test "$(( RC != 0 )) $(cut -d' ' -f1-2 "$F_VAULT_LOG" | tr '\n' ';')" = "1 session oute-agent;bw lock;"
: > "$F_VAULT_LOG"
DRY_RUN=1 oute oci-bootstrap
check "oci-bootstrap em dry-run: trancada, sem releitura" test "$RC $(cut -d' ' -f1-2 "$F_VAULT_LOG" | tr '\n' ';')" = "0 session oute-agent;bw lock;"
sig TERM grupo oute-services oci-bootstrap
check "TERM no oci-bootstrap: sai com 143, trancada"   rc_lock 143
check "TERM no oci-bootstrap: nada de sessão em disco" nofile

# ---------------------------------------------------------------- 18. rclone no macOS (#114)
FK="$TMP/fk"; mkdir -p "$FK" "$TMP/fuse"
cat > "$FK/uname" <<'SH'
#!/usr/bin/env bash
[[ $# -eq 0 && -n "${F_UNAME:-}" ]] && { echo "$F_UNAME"; exit 0; }
exec /usr/bin/uname "$@"
SH
cat > "$FK/rclone" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$F_RCLONE_LOG"
[[ "$1" == version ]] && printf 'rclone v1.70.0\n- os/type: darwin\n- go/tags: %s\n' "$F_TAGS"
exit 0
SH
chmod +x "$FK"/*
export F_RCLONE_LOG="$TMP/rclone.log" F_PATHX="$FK"
FUSE_OK="$TMP/fuse/fuse-t"; : > "$FUSE_OK"; FUSE_NO="$TMP/fuse/ausente"
HB="o rclone do Homebrew não faz 'mount' no macOS"; NF="FUSE-T (ou macFUSE) não está instalado"
KEY="k$RANDOM$RANDOM$RANDOM"   # credencial de mentira, só para passar de oci_remote_env
mac() { : > "$F_RCLONE_LOG"; F_UNAME=Darwin F_TAGS="$1" F_FUSE="$2" F_OCI="$KEY" oute sync-shared; }
nomount() { ! grep -qx mount "$F_RCLONE_LOG"; }

mac none "$FUSE_OK"
check "Homebrew: rc 0"                                 [ "$RC" -eq 0 ]
check "Homebrew: diz que não faz mount"                has "$HB"
check "Homebrew: diz a correção"   has "brew uninstall rclone"
check "Homebrew: com FUSE, não reclama do FUSE"        hasnt "$NF"
check "Homebrew: rclone mount não é chamado"           nomount
check "Homebrew: termina em /data/shared fica local"   bash -c 'tail -1 <<<"$1" | grep -q "/data/shared fica local$"' _ "$OUT"

mac cmount "$FUSE_NO:$TMP/fuse/outro"
check "oficial sem FUSE: rc 0"                         [ "$RC" -eq 0 ]
check "oficial sem FUSE: diz o que falta e a correção" has "$NF"
check "oficial sem FUSE: instalar o FUSE-T"            has 'instalar o FUSE-T'
check "oficial sem FUSE: não acusa o Homebrew"         hasnt "$HB"
check "oficial sem FUSE: rclone mount não é chamado"   nomount
check "oficial sem FUSE: termina em fica local"        bash -c 'tail -1 <<<"$1" | grep -q "/data/shared fica local$"' _ "$OUT"

mac none "$FUSE_NO"
check "as duas faltas: rc 0"                           [ "$RC" -eq 0 ]
check "as duas faltas: as duas mensagens"              bash -c 'grep -qF "$1" <<<"$3" && grep -qF "$2" <<<"$3"' _ "$HB" "$NF" "$OUT"
check "as duas faltas: rclone mount não é chamado"     nomount
check "as duas faltas: termina em fica local"          bash -c 'tail -1 <<<"$1" | grep -q "/data/shared fica local$"' _ "$OUT"

mac cmount "$FUSE_NO:$FUSE_OK"
check "oficial com FUSE (segundo caminho): rc 0"       [ "$RC" -eq 0 ]
check "oficial com FUSE: chega ao rclone mount"        grep -qx mount "$F_RCLONE_LOG"
check "oficial com FUSE: sem mensagem nova"            bash -c '! grep -qF -e "$1" -e "$2" <<<"$3"' _ "$HB" "$NF" "$OUT"

: > "$F_RCLONE_LOG"; F_UNAME=Linux F_TAGS=none F_FUSE="$FUSE_NO" oute sync-shared
check "Linux: sem mensagem nova"                       bash -c '! grep -qF -e "$1" -e "$2" <<<"$3"' _ "$HB" "$NF" "$OUT"
check "Linux: nenhuma chamada ao rclone"               test ! -s "$F_RCLONE_LOG"
unset F_PATHX

# ================================================================ proxy do LLM do ai-memory (#459)
# a chave da memória (item openrouter-memoria, pasta oute-services) só chega ao compose, que a interpola só no serviço
# llm-proxy; o profile liga com ela e desliga sem ela; o agent.env nunca a leva
T_MEM="$(rnd)"
rm -f "$REPO/.env" "$AENV" "$SENV"
printf "export GH_TOKEN='%s'\n" "$T_GH" > "$F_VAULT/oute-agent"
printf "export AGENT_STUDIO_INGEST_TOKEN='%s'\n" "$T_ING" > "$F_VAULT/oute-services"
oute up --refresh-secrets
check "proxy do LLM, sem a chave: rc 0 e sobe"         [ "$RC" -eq 0 ]
check "proxy do LLM, sem a chave: profile desligado"   test -z "$(cenv profiles)"
check "proxy do LLM, sem a chave: nada de chave ao compose" test -z "$(cenv memkey)"
check "proxy do LLM, sem a chave: a nota diz como ligar" has 'nota: OPENROUTER_MEMORY_API_KEY não está em .*item openrouter-memoria da pasta oute-services'
printf "export AGENT_STUDIO_INGEST_TOKEN='%s'\nexport OPENROUTER_MEMORY_API_KEY='%s'\n" "$T_ING" "$T_MEM" > "$F_VAULT/oute-services"
oute up --refresh-secrets
check "proxy do LLM, com a chave: rc 0"                [ "$RC" -eq 0 ]
check "proxy do LLM, com a chave: profile llm-proxy"   test "$(cenv profiles)" = "llm-proxy"
check "proxy do LLM, com a chave: o compose a recebe"  test "$(cenv memkey)" = "$T_MEM"
check "proxy do LLM, com a chave: services.env a guarda" grep -qxF "export OPENROUTER_MEMORY_API_KEY=$T_MEM" "$SENV"
check "proxy do LLM, com a chave: agent.env sem ela"   bash -c '! grep -qF -e OPENROUTER_MEMORY -e "$1" "$0"' "$AENV" "$T_MEM"
check "proxy do LLM, com a chave: sem a nota"          hasnt 'nota: OPENROUTER_MEMORY_API_KEY'
check "proxy do LLM, com a chave: saída sem o valor"   hasnt_str "$T_MEM"
# no oute-server o profile soma ao do agent-studio
printf 'OUTE_AGENT_STUDIO=1\n' > "$REPO/.env"
printf "export AGENT_STUDIO_INGEST_TOKEN='%s'\nexport AGENT_STUDIO_SURREAL_PASS='%s'\nexport OPENROUTER_MEMORY_API_KEY='%s'\n" "$T_ING" "$S_NEW" "$T_MEM" > "$F_VAULT/oute-services"
oute up --refresh-secrets
check "proxy do LLM no oute-server: os dois profiles"  test "$(cenv profiles)" = "agent-studio,llm-proxy"
# chave esquecida na pasta oute-agent (nome de serviço): sai do agent.env e o services.env a guarda
rm -f "$AENV" "$SENV" "$F_VAULT/oute-services"
printf "export GH_TOKEN='%s'\nexport OPENROUTER_MEMORY_API_KEY='%s'\n" "$T_GH" "$T_MEM" > "$F_VAULT/oute-agent"
oute up --refresh-secrets
check "chave na pasta do agent: sai do agent.env"      bash -c '! grep -qF -e OPENROUTER_MEMORY -e "$1" "$0"' "$AENV" "$T_MEM"
check "chave na pasta do agent: vai ao services.env e ao compose" test "$(grep -cxF "export OPENROUTER_MEMORY_API_KEY=$T_MEM" "$SENV")$(cenv memkey)" = "1$T_MEM"
check "chave na pasta do agent: avisa o nome, sem o valor" bash -c 'grep -q "segredo de serviço fora do arquivo do agent (#256): OPENROUTER_MEMORY_API_KEY estava" <<<"$0" && ! grep -qF "$1" <<<"$0"' "$OUT" "$T_MEM"
: > "$F_LOG"
oute down
check "down enxerga o profile do llm-proxy"            grep -qF -e '--profile llm-proxy' "$F_LOG"
rm -f "$REPO/.env"

# ================================================================ rede (#230): derivação e validação
# Mac com subnet customizada: range derivado, IP fixo validado
printf 'OUTE_NET_SUBNET=172.29.0.0/16\nOUTE_NET_GATEWAY=172.29.0.1\nOUTE_AGENT_IP=172.29.0.5\n' > "$REPO/.env"
: > "$F_LOG"
oute up
check "Mac subnet 172.29: rc 0, sobe"                   [ "$RC" -eq 0 ]
check "Mac subnet 172.29: nenhuma mensagem de erro de rede" bash -c '! grep -qE "OUTE_NET|fora da subnet" <<<"$OUT"'
check "Mac subnet 172.29: compose up chamado"           grep -q -- ' up -d --no-build' "$F_LOG"

# Range inválido: erro antes do docker
printf 'OUTE_NET_SUBNET=172.29.0.0/16\nOUTE_NET_IP_RANGE=172.19.0.0/16\n' > "$REPO/.env"
: > "$F_LOG"
oute up
check "range fora da subnet: rc != 0"                   [ "$RC" -ne 0 ]
check "range fora: aviso"                               has 'está fora da subnet'
check "range fora: compose up não chamado"              bash -c '! grep -q -- " up -d" "$F_LOG"'

# IP fixo dentro do range: erro antes do docker
printf 'OUTE_NET_SUBNET=172.29.0.0/16\nOUTE_NET_IP_RANGE=172.29.128.0/17\nOUTE_AGENT_IP=172.29.128.5\n' > "$REPO/.env"
: > "$F_LOG"
oute up
check "IP no range: rc != 0"                           [ "$RC" -ne 0 ]
check "IP no range: aviso"                             has 'está dentro do range'
check "IP no range: compose up não chamado"            bash -c '! grep -q -- " up -d" "$F_LOG"'

check_end
