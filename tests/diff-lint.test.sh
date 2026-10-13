#!/usr/bin/env bash
# Teste do tests/lib/diff-lint.py (#652): duas regras de shell que já voltaram como lição viram checagem por
# máquina, só sobre o que o diff acrescenta: `rm` com variável sem `${VAR:?}` (#539, #578) e função de shell nova
# sem `local` no parâmetro posicional ou sem `return` explícito no fim (#501, #585; SonarCloud S7679 e S7682).
# Cada caso monta um repositório git pequeno (arquivo antes e depois) e roda o lint sobre o `git diff`. No fim, o
# lint roda sobre o diff do próprio PR (merge-base com a main até HEAD). Sem base nesse clone: fora do CI (sem
# GITHUB_ACTIONS) o teste falha e manda rodar `git fetch -q origin main`; no CI o caso é pulado (#859).
# Bash puro, sem rede. Uso: tests/diff-lint.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1
LINT="$ROOT/tests/lib/diff-lint.py"
RM=rm   # o texto dos arquivos de exemplo monta o comando por aqui, para o lint do próprio PR não achar o exemplo

n=0
# diff_de <arquivo> <antes> <depois>: o lint sobre o diff de <antes> para <depois> (printf %b); define OUT e RC
diff_de() {
  local file="$1" before="$2" after="$3" d
  n=$((n + 1)); d="$TMP/r$n"
  mkdir -p "$d/$(dirname "$file")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  : >"$d/.keep"; printf '%b' "$before" >"$d/$file"
  git -C "$d" add -A; git -C "$d" commit -q -m base
  printf '%b' "$after" >"$d/$file"
  git -C "$d" add -A; git -C "$d" commit -q -m novo
  OUT="$(git -C "$d" diff HEAD~1 HEAD | python3 "$LINT" --root "$d" 2>&1)"; RC=$?
  return 0
}

# ---------------------------------------------------------------- 1. rm com variável
diff_de t.sh 'echo a\n' "echo a\n$RM -rf \"\$d\"/x\n"
check "comando rm com \$d em linha nova: reprova, com arquivo e linha"   has_line "t.sh:2: rm com variável sem \${VAR:?}: $RM -rf \"\$d\"/x"
check "comando rm com \$d: sai 1"                                        test "$RC" = 1
diff_de t.sh '' "$RM -f \$f\n"
check "comando rm com variável sem aspas: reprova"                       test "$RC" = 1
diff_de t.sh '' "trap '$RM -rf \"\$TMP\"' EXIT\n"
check "comando rm dentro de trap com aspas simples: reprova"             test "$RC" = 1
diff_de t.sh '' "[ -n x ] && $RM \"\$(pwd)/a\"\n"
check "comando rm depois de && com \$(…): reprova"                       test "$RC" = 1
diff_de t.sh '' "sudo $RM -rf \"\$d\"\n"
check "sudo e rm com variável: reprova"                            test "$RC" = 1
diff_de scripts/oute '' "$RM -rf \"\$d\"\n"
check "arquivo sem extensão em scripts/: vale"                   test "$RC" = 1

diff_de t.sh '' "$RM -rf \"\${d:?}\"/x\n"
check "comando rm com \${VAR:?}: passa"                                  test "$RC" = 0
diff_de t.sh '' "trap '$RM -rf \"\${TMP:?}\"' EXIT\n"
check "trap com \${TMP:?}: passa"                                test "$RC" = 0
diff_de t.sh '' "$RM -f /tmp/literal.json\n"
check "caminho literal: passa"                                   test "$RC" = 0
diff_de t.sh '' "$RM -rf \"\$(mktemp -d)\"\n"
check "mktemp -d na própria linha: passa"                        test "$RC" = 0
diff_de t.sh '' "$RM -f \"\$f\"  # rm-ok: caminho vem do mktemp acima\n"
check "# rm-ok: <motivo> na linha: passa"                        test "$RC" = 0
diff_de t.sh '' "echo $RM \$x\n"
check "comando rm que não é comando (argumento do echo): passa"          test "$RC" = 0
diff_de t.sh '' "# $RM -rf \$x\n"
check "comando rm em comentário: passa"                                  test "$RC" = 0
diff_de README.md '' "$RM -rf \"\$d\"\n"
check "arquivo que não é shell: passa"                           test "$RC" = 0
diff_de t.sh "$RM -rf \"\$d\"\necho a\n" "$RM -rf \"\$d\"\necho a\necho b\n"
check "linha antiga com variável, intacta no diff: passa"        test "$RC" = 0

# ---------------------------------------------------------------- 2. função nova: local e return
diff_de t.sh 'echo a\n' 'echo a\nfoo() {\n  echo "$1"\n  return 0\n}\n'
check "função nova com \$1 fora de local: reprova"               has_line "t.sh:3: função foo: parâmetro posicional fora de \`local\` (S7679)"
diff_de t.sh '' 'foo() {\n  local a="$1"\n  echo "$a"\n}\n'
check "função nova sem return no fim: reprova"                   has_line "t.sh:1: função foo: sem return explícito no fim (S7682)"
check "sem return: sai 1"                                        test "$RC" = 1
diff_de t.sh '' 'function foo {\n  local a="$1"\n  echo "$a"\n}\n'
check "forma function nome { }: vale também"                     has_line "t.sh:1: função foo: sem return explícito no fim (S7682)"
diff_de t.sh '' 'foo() { echo hi; }\n'
check "função de uma linha sem return: reprova"                  test "$RC" = 1
diff_de t.sh '' 'foo() {\n  local a="$1" b="$2"\n  if [ -n "$a" ]; then\n    echo "$a"\n  fi\n}\n'
check "termina em if/fi sem return: reprova"                     test "$RC" = 1

diff_de t.sh '' 'foo() {\n  local a="$1" b="${2:-x}"\n  echo "$a$b"\n  return 0\n}\n'
check "local com \$1 e \${2:-x}, return 0: passa"                test "$RC" = 0
diff_de t.sh '' 'foo() {\n  local a="$1"\n  grep -q x <<<"$a"\n  return $?\n}\n'
check "return \$? no fim: passa"                                 test "$RC" = 0
diff_de t.sh '' 'foo() { echo hi; return 0; }\n'
check "função de uma linha com return: passa"                    test "$RC" = 0
diff_de t.sh '' "foo() {\n  local a=\"\$1\"\n  awk '{print \$1}' <<<\"\$a\"\n  return 0\n}\n"
check "\$1 do awk entre aspas simples: passa"                    test "$RC" = 0
diff_de t.sh '' 'foo() {\n  local a="${1}"\n  cat <<EOF\n} texto $1\nEOF\n  return 0\n}\n'
check "heredoc com } e \$1 no corpo: passa"                      test "$RC" = 0
diff_de t.sh 'foo() {\n  echo "$1"\n}\n' 'foo() {\n  echo "$1"\n  echo mais\n}\n'
check "função antiga alterada (definição fora do diff): passa"   test "$RC" = 0
diff_de t.sh 'foo() {\n  echo a\n}\n' 'foo() {\n  echo a\n}\nbar() {\n  local x="$1"\n  return 0\n}\n'
check "função nova ao lado de antiga: só a nova conta"           test "$RC" = 0
diff_de README.md '' 'foo() {\n  echo "$1"\n}\n'
check "função em arquivo que não é shell: passa"                 test "$RC" = 0

# ---------------------------------------------------------------- 3. o diff deste PR
# caso_do_pr <raiz> <ci>: o lint sobre o diff de merge-base(origin/main ou main, HEAD) até HEAD, na raiz dada. Sai 0 se
# passa; 1 se o lint reprova ou se falta a base fora do CI (nesse caso OUT diz o que rodar, #859); 2 se pula (sem base
# no CI, com <ci> preenchido). Define OUT.
caso_do_pr() {
  local raiz="$1" ci="$2" base="" ref
  for ref in origin/main main; do
    if git -C "$raiz" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
      base="$(git -C "$raiz" merge-base "$ref" HEAD 2>/dev/null)" && break
    fi
  done
  if [[ -z "$base" ]]; then
    if [[ -n "$ci" ]]; then return 2; fi
    OUT="sem base do PR: rode git fetch -q origin main e tente de novo"
    return 1
  fi
  OUT="$(git -C "$raiz" diff "$base" HEAD | python3 "$LINT" --root "$raiz" 2>&1)"
  return $?
}

caso_do_pr "$ROOT" "${GITHUB_ACTIONS:-}"; RC=$?
if [[ "$RC" -eq 2 ]]; then
  ok "diff do PR: sem base no CI (checkout raso), pulado"
else
  check "diff do PR: nenhuma linha ou função nova quebra as duas regras" test "$RC" = 0
fi

# ---------------------------------------------------------------- 4. base do diff do PR fora e dentro do CI (#859)
# pr_repo <dir> <origin: sim|nao> <depois>: repositório com um commit base (t.sh = `echo a`) e um commit novo com
# <depois> em t.sh. Com origin = sim, refs/remotes/origin/main aponta para o commit base. A branch é `trunk`, sem `main`.
pr_repo() {
  local d="$1" origin="$2" depois="$3"
  mkdir -p "$d"
  git -C "$d" -c init.defaultBranch=trunk init -q
  printf 'echo a\n' >"$d/t.sh"
  git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base
  if [[ "$origin" = sim ]]; then git -C "$d" update-ref refs/remotes/origin/main HEAD; fi
  printf '%b' "$depois" >"$d/t.sh"
  git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m novo
  return 0
}

pr_repo "$TMP/pr-sem-base" nao 'echo b\n'
caso_do_pr "$TMP/pr-sem-base" ""; RC=$?
check "sem origin/main, fora do CI: reprova (sai 1)"                    test "$RC" = 1
check "sem origin/main, fora do CI: a mensagem manda git fetch -q origin main" has 'git fetch -q origin main'
caso_do_pr "$TMP/pr-sem-base" true; RC=$?
check "sem origin/main, no CI (GITHUB_ACTIONS definido): pula (sai 2)"  test "$RC" = 2

pr_repo "$TMP/pr-limpo" sim 'echo a\necho b\n'
caso_do_pr "$TMP/pr-limpo" ""; RC=$?
check "com origin/main e diff limpo: passa (sai 0)"                     test "$RC" = 0

pr_repo "$TMP/pr-rm" sim "echo a\n$RM -rf \"\$d\"/x\n"
caso_do_pr "$TMP/pr-rm" ""; RC=$?
check "com origin/main e rm com variável no diff: reprova (sai 1)"      test "$RC" = 1
check "com origin/main: o lint aponta arquivo e linha"                  has_line "t.sh:2: rm com variável sem \${VAR:?}: $RM -rf \"\$d\"/x"

check_end
