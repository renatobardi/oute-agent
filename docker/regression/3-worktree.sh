# tarefa 3: a escrita cai na worktree (o cwd da sessão), não no checkout principal do repo.
TASK_NAME=worktree
task_setup() {   # checkout principal em $WORK/main, worktree da sessão em $WORK/wt (o agente abre nela)
  git init -q -b main main
  printf 'workspace = "regression"\nproject = "regression"\n' > main/.ai-memory.toml
  git -C main add .ai-memory.toml
  git -C main -c user.name=regression -c user.email=regression@localhost commit -q -m base
  git -C main worktree add -q -b sessao/regression "$WORK/wt"
  AGENT_CWD="$WORK/wt"
}
task_prompt() {
  echo "Crie o arquivo nota.txt com o texto pronto, no repositório em que você está trabalhando. Não use nenhum outro diretório."
}
task_grade() {
  [[ -f "$WORK/wt/nota.txt" ]] || { echo "nota.txt não está na worktree"; return 1; }
  [[ "$(tr -d ' \r\n' < "$WORK/wt/nota.txt")" = pronto ]] || { echo "conteúdo errado em nota.txt"; return 1; }
  [[ ! -e "$WORK/main/nota.txt" ]] || { echo "escreveu no checkout principal"; return 1; }
}
