#!/usr/bin/env bash
# Trava do `git` no checkout principal (#651): docker/shims/git recusa `checkout`, `switch`, `commit`, `merge` e `rebase`
# no checkout principal de um repo da raiz de workspace; leitura, `fetch`, `pull --ff-only`, `merge --ff-only` na branch
# padrão sem mudança local e `worktree add` passam; dentro de uma worktree e em repo de outra pasta nada muda.
# O `git` real é um dublê no PATH depois do shim: registra o que recebeu em $FAKE/git.log e chama o git de verdade, em
# repos de verdade num diretório temporário, com remote bare local. Sem rede, sem Docker.
# Prova vermelha (corpo do PR): GIT_SHIM aponta para um shim que só faz `exec` do git real.
# Uso: tests/git-main-guard.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
GIT_SHIM="${GIT_SHIM:-$ROOT/docker/shims/git}"
TRUE_GIT="$(command -v git)" || die "precisa de git"
TASK="$ROOT/docker/oute-task"

SHIMS="$TMP/shims"; REAL="$TMP/real"; FAKE="$TMP/fake"; H="$TMP/home"; WS="$TMP/ws"; WT="$TMP/wt"; OUTSIDE="$TMP/fora"
mkdir -p "$SHIMS" "$REAL" "$FAKE" "$H" "$WS" "$WT" "$OUTSIDE"
cp "$GIT_SHIM" "$SHIMS/git"; chmod 755 "$SHIMS/git"
# git real falso: registra os argumentos (uma linha por chamada) e executa o git de verdade
cat > "$REAL/git" <<FAKEGIT
#!/usr/bin/env bash
echo "\$*" >> "$FAKE/git.log"
exec "$TRUE_GIT" "\$@"
FAKEGIT
chmod 755 "$REAL/git"

# g <args…>: o git de verdade, sem o shim, para montar e conferir os repos
g() {
  env -i HOME="$H" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid "$TRUE_GIT" "$@"
  return $?
}
# run <dir> <git args…>: o shim, com o cwd em <dir>; stdout+stderr em $OUT, código em $RC
run() {
  local dir="$1"; shift
  OUT="$(cd "$dir" && env -i HOME="$H" FAKE="$FAKE" PATH="$SHIMS:$REAL:/usr/bin:/bin" OUTE_GIT_GUARD_ROOT="$WS" \
    GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL=t@example.invalid "$SHIMS/git" "$@" 2>&1 </dev/null)"; RC=$?
  return 0
}
reset() { : > "$FAKE/git.log"; return 0; }
# reached <sub>: o subcomando chegou ao git real (com ou sem `-C <dir>` na frente)
reached() {
  local sub="$1"
  grep -qE "^(-C [^ ]+ )?$sub( |\$)" "$FAKE/git.log" 2>/dev/null
  return $?
}
head_of() { local dir="$1"; g -C "$dir" rev-parse HEAD; return $?; }
# no_branch <dir> <branch>: a branch local não existe
no_branch() {
  local dir="$1" br="$2"
  ! g -C "$dir" show-ref -q --verify "refs/heads/$br"
  return $?
}
branch_of() { local dir="$1"; g -C "$dir" symbolic-ref -q --short HEAD; return $?; }
# refused <sub>: código 77, a instrução da worktree e nada do subcomando no git real
refused() {
  local sub="$1"
  [[ "$RC" -eq 77 ]] && grep -qF "abra uma worktree: oute-task <slug>" <<<"$OUT" && ! reached "$sub"
  return $?
}

# ---------------------------------------------------------------- repos
# origin bare + checkout principal em $WS/proj (branch padrão main) + worktree de sessão + um clone fora da raiz
g init -q --bare -b main "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/seed" 2>/dev/null
echo um > "$TMP/seed/a.txt"; g -C "$TMP/seed" add a.txt; g -C "$TMP/seed" commit -q -m um
g -C "$TMP/seed" push -q origin HEAD:main
g -C "$TMP/seed" branch -q outra; g -C "$TMP/seed" push -q origin outra
g clone -q "$TMP/origin.git" "$WS/proj"
g -C "$WS/proj" branch -q outra origin/outra
g -C "$WS/proj" worktree add -q -b sessao/x "$WT/proj-x" origin/main
g clone -q "$TMP/origin.git" "$OUTSIDE/proj"
MAIN="$WS/proj"; SESS="$WT/proj-x"
# advance: um commit novo em origin/main
advance() {
  local n="$1"
  echo "$n" >> "$TMP/seed/a.txt"; g -C "$TMP/seed" commit -q -am "avanço $n" && g -C "$TMP/seed" push -q origin HEAD:main
  return $?
}

# ---------------------------------------------------------------- 1. recusa no checkout principal
H0="$(head_of "$MAIN")"
reset; run "$MAIN" checkout outra
check "principal: checkout recusado (77, instrução, não chega ao git)" refused checkout
check "principal: checkout recusado mantém a branch"                     [ "$(branch_of "$MAIN")" = main ]
reset; run "$MAIN" checkout -b nova
check "principal: checkout -b recusado"                                  refused checkout
check "principal: checkout -b não cria a branch"                         no_branch "$MAIN" nova
reset; run "$MAIN" switch outra
check "principal: switch recusado"                                       refused switch
check "principal: switch recusado mantém a branch"                       [ "$(branch_of "$MAIN")" = main ]
echo local > "$MAIN/novo.txt"; g -C "$MAIN" add novo.txt
reset; run "$MAIN" commit -m "no principal"
check "principal: commit recusado"                                       refused commit
check "principal: commit recusado não move o HEAD"                       [ "$(head_of "$MAIN")" = "$H0" ]
g -C "$MAIN" rm -q -f --cached novo.txt; rm -f "${MAIN:?}/novo.txt"
reset; run "$MAIN" merge origin/outra
check "principal: merge recusado"                                        refused merge
reset; run "$MAIN" rebase origin/outra
check "principal: rebase recusado"                                       refused rebase
check "principal: a mensagem diz o subcomando e o checkout"              has_line "oute: git rebase recusado no checkout principal ($(cd "$MAIN" && pwd -P)): abra uma worktree: oute-task <slug>"
check "principal: a mensagem declara o limite"                           has_line "oute: esta trava protege contra engano, não contra contorno."

# opções globais antes do subcomando, e de fora do repo com -C
reset; run "$TMP" -C "$MAIN" checkout outra
check "principal: -C <dir> de fora recusado"                             refused checkout
reset; run "$SESS" -C "$MAIN" commit --allow-empty -m x
check "principal: -C <dir> de dentro de uma worktree recusado"           refused commit
reset; run "$MAIN" -c user.name=x --no-pager switch outra
check "principal: -c k=v e --no-pager antes do subcomando, recusado"     refused switch
mkdir -p "$MAIN/sub/pasta"
reset; run "$MAIN/sub/pasta" commit --allow-empty -m x
check "principal: de uma subpasta, recusado"                             refused commit
rmdir "$MAIN/sub/pasta" "$MAIN/sub"
check "principal: nenhuma recusa moveu o HEAD nem a branch"              [ "$(head_of "$MAIN")" = "$H0" -a "$(branch_of "$MAIN")" = main ]

# ---------------------------------------------------------------- 2. o que continua permitido no checkout principal
reset; run "$MAIN" status --porcelain
check "principal: status passa (código 0, chega ao git)"                 bash -c '[ "$1" -eq 0 ] && grep -qx "status --porcelain" "$2"' _ "$RC" "$FAKE/git.log"
reset; run "$MAIN" log --oneline -1
check "principal: log passa"                                             bash -c '[ "$1" -eq 0 ] && grep -q "um" <<<"$2"' _ "$RC" "$OUT"
reset; run "$MAIN" rev-parse --git-dir
check "principal: rev-parse passa"                                       [ "$RC" -eq 0 -a "$OUT" = .git ]
reset; run "$MAIN" merge-base HEAD origin/outra
check "principal: merge-base (leitura) passa"                            [ "$RC" -eq 0 -a "$OUT" = "$H0" ]
reset; run "$MAIN" diff --stat
check "principal: diff passa"                                            [ "$RC" -eq 0 ]
reset; run "$MAIN" branch --show-current
check "principal: branch --show-current passa"                           [ "$RC" -eq 0 -a "$OUT" = main ]
reset; run "$MAIN"
check "principal: git sem argumento passa ao git real"                   bash -c '[ "$1" -ne 77 ] && [ -s "$2" ]' _ "$RC" "$FAKE/git.log"
reset; run "$MAIN" --version
check "principal: --version passa"                                       bash -c '[ "$1" -eq 0 ] && grep -q "^git version" <<<"$2"' _ "$RC" "$OUT"

advance dois
reset; run "$MAIN" fetch -q origin
check "principal: fetch passa"                                           bash -c '[ "$1" -eq 0 ] && grep -qx "fetch -q origin" "$2"' _ "$RC" "$FAKE/git.log"
check "principal: fetch trouxe o commit novo"                            [ "$(g -C "$MAIN" rev-parse origin/main)" = "$(head_of "$TMP/seed")" ]
reset; run "$MAIN" pull -q --ff-only
check "principal: pull --ff-only na branch padrão, sem mudança local, passa" [ "$RC" -eq 0 ]
check "principal: pull --ff-only avançou o checkout"                     [ "$(head_of "$MAIN")" = "$(head_of "$TMP/seed")" ]

advance tres; g -C "$MAIN" fetch -q origin
reset; run "$MAIN" merge -q --ff-only origin/main
check "principal: merge --ff-only na branch padrão, sem mudança local, passa" bash -c '[ "$1" -eq 0 ] && grep -qx "merge -q --ff-only origin/main" "$2"' _ "$RC" "$FAKE/git.log"
check "principal: merge --ff-only avançou o checkout"                    [ "$(head_of "$MAIN")" = "$(head_of "$TMP/seed")" ]

# merge --ff-only fora das condições: recusado, com o motivo
advance quatro; g -C "$MAIN" fetch -q origin; H1="$(head_of "$MAIN")"
echo sujo >> "$MAIN/a.txt"
reset; run "$MAIN" merge --ff-only origin/main
check "principal: merge --ff-only com mudança local recusado"            refused merge
check "principal: merge --ff-only com mudança local diz o motivo"        has "há mudança local em arquivo versionado"
g -C "$MAIN" checkout -q -- a.txt
g -C "$MAIN" checkout -q outra
reset; run "$MAIN" merge --ff-only origin/main
check "principal: merge --ff-only fora da branch padrão recusado"        refused merge
check "principal: merge --ff-only fora da branch padrão diz o motivo"    has "o checkout está em 'outra', e não na branch padrão 'main'"
g -C "$MAIN" checkout -q --detach origin/outra
reset; run "$MAIN" merge --ff-only origin/main
check "principal: merge --ff-only com HEAD solto recusado"               refused merge
check "principal: merge --ff-only com HEAD solto diz o motivo"           has "o checkout está em 'HEAD solto'"
g -C "$MAIN" checkout -q main
g -C "$MAIN" symbolic-ref -d refs/remotes/origin/HEAD
reset; run "$MAIN" merge --ff-only origin/main
check "principal: merge --ff-only sem branch padrão definida recusado"   refused merge
check "principal: merge --ff-only sem branch padrão diz o motivo"        has "a branch padrão não está definida"
g -C "$MAIN" remote set-head origin main
check "principal: nenhuma recusa do merge --ff-only moveu o HEAD"        [ "$(head_of "$MAIN")" = "$H1" ]

# ---------------------------------------------------------------- 3. worktree: nada muda
reset; run "$MAIN" worktree add -q -b sessao/y "$WT/proj-y" origin/main
check "principal: worktree add -b passa"                                 bash -c '[ "$1" -eq 0 ] && [ -d "$2" ]' _ "$RC" "$WT/proj-y"
check "worktree nova: está na branch da sessão"                          [ "$(branch_of "$WT/proj-y")" = sessao/y ]
echo w > "$SESS/w.txt"; run "$SESS" add w.txt
reset; run "$SESS" commit -q -m "na worktree"
check "worktree: commit passa"                                           bash -c '[ "$1" -eq 0 ] && grep -q "^commit " "$2"' _ "$RC" "$FAKE/git.log"
check "worktree: o commit existe"                                        [ "$(g -C "$SESS" log -1 --format=%s)" = "na worktree" ]
reset; run "$SESS" checkout -q -b fix/1-x
check "worktree: checkout -b passa"                                      [ "$RC" -eq 0 -a "$(branch_of "$SESS")" = fix/1-x ]
reset; run "$SESS" switch -q -c fix/2-y
check "worktree: switch -c passa"                                        [ "$RC" -eq 0 -a "$(branch_of "$SESS")" = fix/2-y ]
reset; run "$SESS" merge -q --no-edit origin/main
check "worktree: merge passa"                                            bash -c '[ "$1" -eq 0 ] && grep -q "^merge " "$2"' _ "$RC" "$FAKE/git.log"
reset; run "$SESS" rebase -q origin/main
check "worktree: rebase passa"                                           bash -c '[ "$1" -eq 0 ] && grep -q "^rebase " "$2"' _ "$RC" "$FAKE/git.log"
reset; run "$MAIN" -C "$SESS" commit -q --allow-empty -m "de fora"
check "worktree: -C <worktree> a partir do checkout principal passa"     [ "$RC" -eq 0 -a "$(g -C "$SESS" log -1 --format=%s)" = "de fora" ]

# ---------------------------------------------------------------- 4. repo fora da raiz de workspace e fora de repositório
reset; run "$OUTSIDE/proj" checkout -q -b qualquer
check "repo fora da raiz: checkout -b passa"                             [ "$RC" -eq 0 -a "$(branch_of "$OUTSIDE/proj")" = qualquer ]
reset; run "$OUTSIDE/proj" commit -q --allow-empty -m "fora"
check "repo fora da raiz: commit passa"                                  [ "$RC" -eq 0 -a "$(g -C "$OUTSIDE/proj" log -1 --format=%s)" = "fora" ]
mkdir -p "$WS/grupo"; g clone -q "$TMP/origin.git" "$WS/grupo/proj"
reset; run "$WS/grupo/proj" commit -q --allow-empty -m "dois níveis"
check "repo dois níveis abaixo da raiz: commit passa"                    [ "$RC" -eq 0 ]
mkdir -p "$TMP/vazio"
reset; run "$TMP/vazio" commit -m x
check "fora de repositório: passa ao git real, que dá o erro dele"       bash -c '[ "$1" -ne 0 ] && [ "$1" -ne 77 ] && grep -q "^commit " "$2" && grep -qi "not a git repository" <<<"$3"' _ "$RC" "$FAKE/git.log" "$OUT"
reset; run "$TMP/origin.git" commit -m x
check "repo bare: passa ao git real"                                     bash -c '[ "$1" -ne 77 ] && grep -q "^commit " "$2"' _ "$RC" "$FAKE/git.log"
# sem git real no PATH
OUT="$(cd "$MAIN" && env -i HOME="$H" PATH="$SHIMS" OUTE_GIT_GUARD_ROOT="$WS" /bin/bash "$SHIMS/git" status 2>&1)"; RC=$?
check "sem git real no PATH: 127 e diz o motivo"                         [ "$RC" -eq 127 -a "$OUT" = "oute: git não encontrado" ]
# raiz de workspace que não existe: passa
OUT="$(cd "$MAIN" && env -i HOME="$H" PATH="$SHIMS:$REAL:/usr/bin:/bin" OUTE_GIT_GUARD_ROOT="$TMP/nao-existe" GIT_AUTHOR_NAME=t \
  GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid "$SHIMS/git" commit -q --allow-empty -m raiz 2>&1)"; RC=$?
check "raiz de workspace ausente: passa ao git real"                     [ "$RC" -eq 0 ]
g -C "$MAIN" reset -q --hard "$H1"

# ---------------------------------------------------------------- 5. oute-task com o shim no PATH
# o oute-task de verdade: abre a sessão (worktree prune, fetch e worktree add a partir do checkout principal) e o
# clean --yes avança o checkout principal com merge --ff-only
task() {
  OUT="$(cd "$MAIN" && env -i HOME="$H" FAKE="$FAKE" PATH="$SHIMS:$REAL:/usr/bin:/bin" OUTE_GIT_GUARD_ROOT="$WS" \
    OUTE_WORKSPACE="$WS" OUTE_WORKTREES="$WT" GIT_CONFIG_NOSYSTEM=1 "$TASK" "$@" 2>&1 </dev/null)"; RC=$?
  return 0
}
if [[ -x "$TASK" ]]; then
  advance cinco
  reset; task -r proj 651-abre shell
  NEW="$WT/_sem-space/proj-651-abre"
  check "oute-task: abre a worktree a partir do checkout principal"       bash -c '[ -d "$1" ] && grep -q "worktree $1 · branch sessao/651-abre (de origin/main)" <<<"$2"' _ "$NEW" "$OUT"
  check "oute-task: fetch e worktree add chegaram ao git real"            bash -c 'grep -qE "fetch -q origin --prune$" "$1" && grep -qE "worktree add -q -b sessao/651-abre " "$1"' _ "$FAKE/git.log"
  check "oute-task: a worktree nova sai do origin/main atualizado"        [ "$(head_of "$NEW")" = "$(head_of "$TMP/seed")" ]
  check "oute-task: o checkout principal continua na branch padrão"       [ "$(branch_of "$MAIN")" = main -a "$(head_of "$MAIN")" = "$H1" ]
  reset; task clean --yes --all
  check "oute-task clean --yes: avança o checkout principal"              bash -c '[ "$1" -eq 0 ] && grep -q "^atualizada $2 (main → " <<<"$3"' _ "$RC" "$MAIN" "$OUT"
  check "oute-task clean --yes: o HEAD é o do origin/main"                [ "$(head_of "$MAIN")" = "$(head_of "$TMP/seed")" ]
else
  bad "oute-task ausente ou sem +x: $TASK"
fi

check_end
