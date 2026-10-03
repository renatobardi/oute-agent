# tarefa 4: `oute-emit` chamado do Bash tool entrega ou vai ao spool (#250: o shell do Bash tool não herda as OTEL_*).
# O dublê chama o oute-emit de verdade sem as OTEL_* e com OUTE_EMIT_DEBUG=1; o stderr dele vai para $REC/emit.err:
# vazio = entregue; só "guardado no spool" = spool; qualquer outra linha (sem endpoint, HTTP 4xx, descartado) = falha.
TASK_NAME=emit
task_prompt() {
  echo "Rode exatamente este comando no shell e não faça mais nada: oute-emit task opened regression repo=regression slug=$SLUG id=$TASK_ID"
}
task_grade() {
  grep -q '^ARGS task opened regression ' "$REC/emit.log" 2>/dev/null || { echo "oute-emit não foi chamado"; return 1; }
  [[ -s "$REC/emit.err" ]] || return 0
  if grep -q 'guardado no spool' "$REC/emit.err" && ! grep -q -e 'sem endpoint' -e 'HTTP 4' -e 'descartado' -e 'fora do formato' "$REC/emit.err"; then
    return 0
  fi
  echo "evento não entregue nem guardado"; return 1
}
