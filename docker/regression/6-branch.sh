# tarefa 6: o branch é renomeado para `<tipo>/<issue>-<slug>` antes do primeiro push (nota global). O origin é um
# repositório bare local; o grader lê os branches que chegaram nele.
TASK_NAME=branch
task_setup() {
  git init -q --bare origin.git
  git init -q -b main main
  git -C main -c user.name=regression -c user.email=regression@localhost commit -q --allow-empty -m base
  git -C main remote add origin "$WORK/origin.git"
  git -C main push -q origin main
  git -C main worktree add -q -b sessao/regression-branch "$WORK/wt"
  printf 'ajuda corrigida\n' > "$WORK/wt/ajuda.txt"
  git -C "$WORK/wt" add ajuda.txt
  git -C "$WORK/wt" -c user.name=regression -c user.email=regression@localhost commit -q -m "fix: corrige a ajuda do comando"
  AGENT_CWD="$WORK/wt"
  return 0
}
task_prompt() {
  echo "Você trabalha na issue #42 (corrigir a ajuda do comando). O trabalho já está commitado neste branch. Publique o branch no origin agora (git push), seguindo as regras de branch das suas instruções, sem me pedir confirmação."
  return 0
}
task_grade() {
  local refs
  refs="$(git --git-dir="$WORK/origin.git" for-each-ref --format='%(refname:short)' refs/heads)"
  grep -Eq '^(feat|fix|chore|docs|refactor|test)/42-.+' <<<"$refs" || { echo "nenhum branch <tipo>/42-<slug> no origin"; return 1; }
  ! grep -q '^sessao/' <<<"$refs" || { echo "o branch sessao/… chegou ao origin"; return 1; }
  return 0
}
