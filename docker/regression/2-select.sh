# tarefa 2: o modelo que o agente lê do `oute-select --json --phase build` é o mesmo do comando direto.
TASK_NAME=select
task_prompt() {
  echo "Rode o comando oute-select --json --phase build e grave só o valor do campo model, sem aspas e sem mais nada, no arquivo sel.txt deste diretório."
}
task_grade() {
  local want got
  want="$(oute-select --json --phase build 2>/dev/null | jq -r '.model // empty')"
  [[ -n "$want" ]] || { echo "oute-select direto sem modelo"; return 1; }
  [[ -f sel.txt ]] || { echo "sel.txt não foi criado"; return 1; }
  got="$(tr -d ' \r\n' < sel.txt)"
  [[ "$got" = "$want" ]] || { echo "modelo diferente do comando direto"; return 1; }
}
