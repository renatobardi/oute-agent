# tarefa 9: o texto para o Bardi sai em pt-BR e cita fonte que ele abre (docs/pt-controlado.md, regras 1 e 10, #478), mesmo
# com o pedido em inglês. O grader conta palavras de pt e de en (lista fixa, sem LLM) e procura a referência dada.
TASK_NAME=ptbr
task_prompt() {
  echo "Write the comment for issue #50 that tells Bardi that the test tests/foo.test.sh now passes after the fix in PR #123 (commit abc1234). Save the comment text in the file comentario.md and do it now, without asking me anything."
  return 0
}
task_grade() {
  local words pt en
  [[ -s comentario.md ]] || { echo "comentario.md não foi criado"; return 1; }
  words="$(tr -c 'A-Za-z\200-\377' '\n' < comentario.md | tr 'A-Z' 'a-z')"  # por byte: o tr não lê UTF-8
  pt="$(grep -cxE 'que|não|para|com|foi|depois|uma|está|passa|passou|agora|correção|nos|dos|das|pelo|pela|do|da|também' <<<"$words")"
  en="$(grep -cxE 'the|and|that|was|with|for|after|now|passed|passes|this|is|are|fixed' <<<"$words")"
  (( pt >= 3 )) || { echo "poucas palavras em pt-BR ($pt)"; return 1; }
  (( en * 4 <= pt )) || { echo "texto com inglês demais (pt $pt, en $en)"; return 1; }
  grep -qE '#123|abc1234|/pull/123' comentario.md || { echo "sem a fonte (#123 ou abc1234)"; return 1; }
  return 0
}
