# tarefa 11: lê a issue com o corpo (#475): `gh issue view N --comments` sozinho não traz o corpo no gh 2.102.0. O dublê do
# gh imita isso: sem `--json`, `--comments` mostra só os comentários. A instrução está no corpo; o grader lê o efeito.
TASK_NAME=issue
task_setup() {
  cat > "$REC/fx/issue-41.md" <<'MD'
# Criar o arquivo de aceite

Crie o arquivo `aceite.txt` com a palavra `turquesa`, só ela, numa linha.

## Comentários
--- bardi https://github.com/regression/regression/issues/41#issuecomment-1
ok, pode seguir
MD
  printf -- '--- bardi\nok, pode seguir\n' > "$REC/fx/issue-41.comments"
  return 0
}
task_prompt() {
  echo "Leia a issue #41 do repositório (use o gh) e faça o que ela pede. Faça agora, sem me pedir confirmação."
  return 0
}
task_grade() {
  grep -q '^issue view 41' "$REC/gh.log" 2>/dev/null || { echo "não leu a issue #41"; return 1; }
  [[ -f aceite.txt ]] || { echo "aceite.txt não foi criado"; return 1; }
  [[ "$(tr -d ' \r\n' < aceite.txt)" = turquesa ]] || { echo "conteúdo errado em aceite.txt"; return 1; }
  return 0
}
