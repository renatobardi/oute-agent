#!/usr/bin/env bash
# Testes do `oute up`/`oute down` do scripts/oute depois da saída do roteador de modelos (#218): a subida não pede
# mais a key do roteador no agent.env, e a limpeza dos restos (entrada diária no crontab do host e o container do
# serviço que saiu do compose; a pasta dos gerados do roteador no checkout, #271) é idempotente. Bash puro, sem
# Docker: `docker` e `crontab` são falsos, com o estado em arquivos, e um sshd de mentira devolve o banner que o `up`
# espera. O scripts/oute roda de uma cópia num checkout git temporário: a limpeza mexe no checkout, nunca no real.
# Os nomes antigos levam [-] nos padrões, como no scripts/oute, para não voltarem a aparecer no repo.
# Uso: tests/oute-up.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap '[[ -z "${SSHD_PID:-}" ]] || { kill "$SSHD_PID"; wait "$SSHD_PID"; } 2>/dev/null; rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1   # o bad mostra a saída inteira
has() { grep -q -- "$1" <<<"$OUT"; }
hasnt() { ! has "$1"; }
command -v python3 >/dev/null || die "python3 ausente (sshd de mentira)"

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home/.ssh" "$TMP/oute"
# docker falso: registra cada chamada em $F_LOG. O container antigo existe enquanto $F_LEGACY existir.
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$F_LOG"
case "$1" in
  compose) case " $* " in *" ps "*) echo "NAME  STATUS" ;; esac ;;
  image)   exit 0 ;;
  volume)  exit 1 ;;
  run)     echo "10485760 0" ;;
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
export F_LOG="$TMP/docker.log" F_LEGACY="$TMP/legacy" F_CRON="$TMP/cron" F_CRON_LOG="$TMP/cron.log"
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
# ambiente: com eles (e rclone no host) o `up` montaria o bucket de verdade dentro de $TMP
oute() {
  OUT="$(env -u "$OLD_KEY" -u OUTE_AGENT_STUDIO -u AGENT_STUDIO_TOKEN -u COMPOSE_PROFILES \
    -u OCI_S3_ACCESS_KEY -u OCI_S3_SECRET_KEY -u OCI_S3_ENDPOINT -u OCI_S3_REGION \
    PATH="$BIN:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/oute" OUTE_HOST=teste \
    OUTE_SSH_HOST=127.0.0.1 OUTE_SSH_PORT="$(cat "$TMP/port")" OUTE_SSH_AUTHORIZED_KEYS="$TMP/home/.ssh/id_ed25519.pub" \
    "$REPO/scripts/oute" "$@" 2>&1)"; RC=$?
}
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

check_end
