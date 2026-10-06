#!/usr/bin/env bash
# Testes do `oute update` fora da branch padrão (#649). Bash puro: remoto e clone num diretório temporário.
# O `update` real roda com o `scripts/oute` do repo copiado para o clone; quando passa da checagem, a etapa seguinte
# falha cedo e sem docker (sem GHCR_TOKEN), o que prova que seguiu.
# Uso: tests/oute-update-branch.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
for v in $(compgen -e | grep -E '^(OCI_|GH_TOKEN$|GITHUB_TOKEN$|GHCR_|AGENT_STUDIO_|BW_)' || true); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=5

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c protocol.file.allow=always "$@"; return $?; }

G init -q --bare "$TMP/remote.git"
G clone -q "$TMP/remote.git" "$TMP/work" 2>/dev/null
mkdir -p "$TMP/work/scripts"
cp "$ROOT/scripts/oute" "$TMP/work/scripts/oute"; chmod +x "$TMP/work/scripts/oute"
echo 0.0.1 > "$TMP/work/VERSION"
G -C "$TMP/work" add -A && G -C "$TMP/work" commit -qm init && G -C "$TMP/work" push -q origin HEAD:main 2>/dev/null
G -C "$TMP/work" checkout -q main 2>/dev/null
G --git-dir="$TMP/remote.git" symbolic-ref HEAD refs/heads/main
G clone -q "$TMP/remote.git" "$TMP/host" 2>/dev/null
CO="$TMP/host"
export OUTE_HOME="$TMP/home"; mkdir -p "$OUTE_HOME"

run_update() {
  OUT="$(HOME="$TMP/home" PATH="$PATH" "$CO/scripts/oute" update 2>&1)"; RC=$?
  return 0
}
branch() { G -C "$CO" rev-parse --abbrev-ref HEAD; return $?; }

echo "== na branch padrão: segue"
run_update
check "passa da checagem de branch" bash -c '! grep -q "branch padrão é" <<<"$1"' _ "$OUT"
check "chega à etapa seguinte (pede GHCR_TOKEN)" grep -q GHCR_TOKEN <<<"$OUT"

echo "== em outra branch: para sem alterar nada"
G -C "$CO" checkout -q -b docs/x
HEAD_ANTES="$(G -C "$CO" rev-parse HEAD)"
run_update
check "sai com erro" test "$RC" -ne 0
check "diz a branch atual" grep -qF "na branch docs/x" <<<"$OUT"
check "diz a branch padrão" grep -qF "a branch padrão é main" <<<"$OUT"
check "dá o comando para voltar" grep -qF "git -C $CO checkout main" <<<"$OUT"
check "não pergunta por mudanças locais" bash -c '! grep -qF "mudanças locais" <<<"$1"' _ "$OUT"
check "não chegou ao git pull nem à etapa seguinte" bash -c '! grep -qE "GHCR_TOKEN|git pull falhou" <<<"$1"' _ "$OUT"
check "não trocou de branch" test "$(branch)" = docs/x
check "HEAD intacto" test "$(G -C "$CO" rev-parse HEAD)" = "$HEAD_ANTES"

echo "== sem origin/HEAD gravado: pergunta ao remoto"
G -C "$CO" remote set-head origin -d >/dev/null 2>&1
run_update
check "ainda acha a padrão pelo remoto" grep -qF "a branch padrão é main" <<<"$OUT"

echo "== HEAD solto"
G -C "$CO" checkout -q --detach
run_update
check "sai com erro" test "$RC" -ne 0
check "diz que é HEAD solto" grep -qF "HEAD solto" <<<"$OUT"
check "dá o comando para voltar" grep -qF "git -C $CO checkout main" <<<"$OUT"
check "continua solto" test "$(branch)" = HEAD

echo "== na padrão, git pull falha (sem mudança local)"
G -C "$CO" checkout -q main
G -C "$CO" remote set-url origin "$TMP/nao-existe.git"
run_update
check "sai com erro" test "$RC" -ne 0
check "mantém a mensagem do git pull" grep -qF "git pull falhou em $CO" <<<"$OUT"
check "sem a pergunta, com status vazio" bash -c '! grep -qF "mudanças locais" <<<"$1"' _ "$OUT"

echo "== na padrão, git pull falha com mudança local"
echo x >> "$CO/VERSION.sujo"
run_update
check "mantém a pergunta com status sujo" grep -qF "(mudanças locais?)" <<<"$OUT"
check_end
