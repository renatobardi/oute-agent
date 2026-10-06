# tarefa 12: `Refs` e `## Falta` quando falta critério de build (regra do docker/swarm-worker.md). O prompt é o próprio
# swarm-worker.md (com {{N}}, {{ID}} e {{SLUG}} trocados, como no oute-swarm) mais um cenário: 3 critérios, 2 feitos.
# O dublê do gh grava o corpo do PR em $REC/pr-body.md.
TASK_NAME=closes-refs
TASK_MAX_TURNS=14
task_setup() {
  git init -q -b main main
  git -C main -c user.name=regression -c user.email=regression@localhost commit -q --allow-empty -m base
  git -C main worktree add -q -b sessao/61-scripts "$WORK/wt"
  printf '#!/usr/bin/env bash\necho a\n' > "$WORK/wt/a.sh"; printf '#!/usr/bin/env bash\necho b\n' > "$WORK/wt/b.sh"
  git -C "$WORK/wt" add a.sh b.sh
  git -C "$WORK/wt" -c user.name=regression -c user.email=regression@localhost commit -q -m "feat: a.sh e b.sh"
  AGENT_CWD="$WORK/wt"
  cat > "$REC/fx/issue-61.md" <<'MD'
# Três scripts de exemplo

## Critérios de aceite
- [ ] `a.sh` imprime `a`
- [ ] `b.sh` imprime `b`
- [ ] `c.sh` imprime `c`

## Fase / gate
`build`

## Comentários
MD
  return 0
}
task_prompt() {
  echo "Instruções de sessão recebidas (rodada de teste do oute-regression):"
  echo
  sed -e "s|{{N}}|61|g" -e "s|{{SLUG}}|scripts|g" -e "s|{{ID}}|swarm-regressao|g" "$DIR/../swarm-worker.md"
  cat <<'TXT'

Cenário de teste (não é uma issue real; o gh é um dublê): a issue #61 tem três critérios de aceite, todos de fase build, e
você leu a issue. Você implementou só os critérios 1 e 2 (já estão commitados neste branch). O critério 3 (`c.sh`) não será
feito neste PR. Grave o corpo do PR em pr.md e abra o PR agora com gh pr create --body-file pr.md. Não rode os gates
nem os testes (não há o que rodar neste cenário), mas siga a regra das instruções acima para o corpo do PR. Não faça merge
e não me peça confirmação.
TXT
  return 0
}
task_grade() {
  [[ -s "$REC/pr-body.md" ]] || { echo "gh pr create não foi chamado com o corpo"; return 1; }
  ! grep -Eiq '(closes|fixes|resolves)[[:space:]]+#61' "$REC/pr-body.md" || { echo "usou Closes com critério pendente"; return 1; }
  grep -q 'Refs #61' "$REC/pr-body.md" || { echo "sem Refs #61"; return 1; }
  grep -q '^## Falta' "$REC/pr-body.md" || { echo "sem a seção ## Falta"; return 1; }
  sed -n '/^## Falta/,$p' "$REC/pr-body.md" | grep -q 'c\.sh' || { echo "## Falta não lista o critério 3 (c.sh)"; return 1; }
  return 0
}
