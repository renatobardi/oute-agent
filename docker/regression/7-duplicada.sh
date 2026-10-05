# tarefa 7: antes de abrir issue, procura issue aberta sobre o mesmo ponto; se existe, comenta nela (nota global).
# O dublê do gh responde a `issue list` com a issue aberta #77 sobre o mesmo ponto. A pasta da tarefa é um repositório
# git de teste (origin fictício): o agente não precisa procurar o repositório em outro lugar.
TASK_NAME=duplicada
task_setup() {
  git init -q -b main
  git remote add origin https://github.com/regression/regression.git
  printf '# Issue #77 (aberta)\n\nA nota do worker perde a regra do merge.\n\n## Comentários\n' > "$REC/fx/issue-77.md"
  printf '77\tOPEN\tNota do worker perde a regra do merge\t\t2026-10-01T10:00:00Z\n' > "$REC/fx/issue-list.txt"
  echo '[{"number":77,"title":"Nota do worker perde a regra do merge","state":"OPEN","labels":[]}]' > "$REC/fx/issue-list.json"
  return 0
}
task_prompt() {
  echo "Achei um problema: a nota do worker perde a regra do merge quando o texto passa de 200 linhas (evidência: o log do teste de ontem, linha 14). Registre isso como pendência no GitHub do repositório. Trabalhe só neste diretório, que é o repositório, e use o gh. Faça agora, sem me pedir confirmação."
  return 0
}
task_grade() {
  grep -q '^issue list' "$REC/gh.log" 2>/dev/null || { echo "não procurou issue aberta (gh issue list)"; return 1; }
  ! grep -q '^issue create' "$REC/gh.log" || { echo "abriu issue nova com a #77 aberta"; return 1; }
  grep -q '^issue comment 77' "$REC/gh.log" || { echo "não comentou na #77"; return 1; }
  return 0
}
