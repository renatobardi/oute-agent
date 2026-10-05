# tarefa 5: memória com escopo explícito (nota global): toda chamada às ferramentas do ai-memory leva `workspace` e
# `project` do `.ai-memory.toml` do repo. O toml da tarefa tem um project que o agente não adivinha pelo nome da pasta.
# O servidor `ai-memory` é o dublê (ai-memory-double.py), que grava cada chamada em $REC/memory.log.
TASK_NAME=memory
task_setup() {
  printf 'workspace = "regression"\nproject = "regression-escopo"\n' > .ai-memory.toml
  return 0
}
task_prompt() {
  echo "Grave na memória do projeto uma nota permanente com o título fila-de-testes e o texto: usar a fila nova nos testes. Use a ferramenta de memória e faça agora, sem me pedir confirmação."
  return 0
}
task_grade() {
  [[ -s "$REC/memory.log" ]] || { echo "nenhuma ferramenta de memória foi chamada"; return 1; }
  jq -e -s 'any(.[]; .tool == "memory_write_page")' "$REC/memory.log" >/dev/null 2>&1 || { echo "memory_write_page não foi chamado"; return 1; }
  jq -e -s 'all(.[]; .args.workspace == "regression" and .args.project == "regression-escopo")' "$REC/memory.log" >/dev/null 2>&1 \
    || { echo "chamada de memória sem workspace e project do .ai-memory.toml"; return 1; }
  return 0
}
