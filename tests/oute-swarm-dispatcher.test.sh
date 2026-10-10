#!/usr/bin/env bash
# Testes do oute-swarm, tema: dispatcher no Codex e a entrega do watch digitando no campo dele (#213).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425).
# Uso: tests/oute-swarm-dispatcher.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"

# nenhum pane ou agente de verdade no ambiente de quem roda
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID

# ---------------------------------------------------------------- 1. dispatcher parado: um evento é digitado e enviado
CASE=dlv-idle; dround "$CASE"
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "idle: código 0"                                   [ "$RC" -eq 0 ]
check "idle: o evento sai no stdout como sempre"         grep -qE '^[0-9]{2}:[0-9]{2} \[sessao\] #7 foo: idle \(sem PR\)$' <<<"$OUT"
check "idle: uma digitação e um Enter"                   [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 ]
check "idle: mensagem agrupada com o prefixo do watch"   grep -qE '^\[watch swarm-test\] 1 evento\(s\): [0-9]{2}:[0-9]{2} \[sessao\] #7 foo: idle \(sem PR\)$' <<<"$(sent)"
check "idle: o log da rodada registra a entrega"         grep -qE 'watch entrega ok: 1 evento\(s\) ao dispatcher \(w1:p0\)$' <<<"$(dlog)"
check "idle: a fila ficou vazia"                         [ "$(qlen)" -eq 0 ]
check "idle: o evento continua no log como sempre"       grep -qE ' watch \[sessao\] #7 foo: idle \(sem PR\)$' "$STATE/log"
# 1b. com o dispatcher em 'done' também
CASE=dlv-done; dround "$CASE"; ag done
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "done: digita e envia"                             [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 ]

# ---------------------------------------------------------------- 2. dispatcher ocupado ou bloqueado: nunca digita
for st in working blocked unknown; do
  CASE="dlv-$st"; dround "$CASE"; ag "$st"
  echo 'fake-tabs idle' > "$FAKE/on-sleep-1"; echo 'fake-tabs working' > "$FAKE/on-sleep-2"
  wd
  check "$st: nada digitado nem enviado"                 [ "$(texts)" -eq 0 -a "$(enters)" -eq 0 ]
  check "$st: os eventos esperam na fila (2)"            [ "$(qlen)" -eq 2 ]
  check "$st: o adiamento vai ao log uma só vez"         [ "$(grep -cF "watch entrega adiada: dispatcher ocupado ($st) (" <<<"$(dlog)")" -eq 1 ]
  check "$st: os eventos seguem no log da rodada"        [ "$(grep -c ' watch \[sessao\] ' "$STATE/log")" -eq 2 ]
done

# ---------------------------------------------------------------- 3. eventos pendentes saem juntos, numa mensagem só
CASE=dlv-grupo; dround "$CASE"; ag working
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
echo 'fake-tabs working' > "$FAKE/on-sleep-2"
cat > "$FAKE/on-sleep-3" <<SH
jq -n '{result: {agents: [{pane_id: "w1:p0", agent: "claude", agent_status: "idle"}]}}' > "\$FAKE/agents.json"
SH
wd
check "grupo: uma digitação só, com os dois eventos"     [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 ]
check "grupo: '2 evento(s)' na mensagem"                 grep -qF '[watch swarm-test] 2 evento(s): ' <<<"$(sent)"
check "grupo: os dois eventos, em ordem, separados por |" grep -qE '\[sessao\] #7 foo: idle \(sem PR\) \| [0-9]{2}:[0-9]{2} \[sessao\] #7 foo: working \(voltou a trabalhar\)$' <<<"$(sent)"
check "grupo: o log diz 2 eventos entregues"             grep -qE 'watch entrega ok: 2 evento\(s\)' <<<"$(dlog)"
check "grupo: adiou enquanto ocupado, uma vez só"        [ "$(grep -cF 'entrega adiada: dispatcher ocupado (working)' <<<"$(dlog)")" -eq 1 ]
check "grupo: o evento da mensagem não foi digitado antes" [ "$(texts)" -eq 1 ]

# ---------------------------------------------------------------- 4. sem achar o campo, ou com texto nele: não digita
CASE=dlv-sem-campo; dround "$CASE"
printf '%s\n' 'Do you trust the contents of this directory?' '  1. Yes, continue' '  2. No, quit' > "$FAKE/pane-style"
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "sem campo: nada digitado"                         [ "$(texts)" -eq 0 -a "$(enters)" -eq 0 ]
check "sem campo: a fila guarda o evento"                [ "$(qlen)" -eq 1 ]
check "sem campo: o motivo vai ao log"                   grep -qF 'watch entrega adiada: campo de entrada do dispatcher não encontrado na tela' <<<"$(dlog)"
# 4b. codex: o diálogo "›" com opções numeradas não é campo
CASE=dlv-codex-dialogo; dround "$CASE"; ag idle codex
printf '%s\n' '› 1. Yes, continue' '  2. No, quit' '  enter to continue' > "$FAKE/pane-style"
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "codex em diálogo: nada digitado"                  [ "$(texts)" -eq 0 -a "$(qlen)" -eq 1 ]
# 4c. campo com texto (o Bardi digitando)
CASE=dlv-campo-texto; dround "$CASE"; printf '%s' 'frase do Bardi pela metade' > "$FAKE/field"
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "campo com texto: nada digitado por cima"          [ "$(texts)" -eq 0 -a "$(cat "$FAKE/field")" == 'frase do Bardi pela metade' ]
check "campo com texto: motivo no log e fila guardada"   [ "$(grep -cF 'watch entrega adiada: campo do dispatcher com texto' <<<"$(dlog)")" -eq 1 -a "$(qlen)" -eq 1 ]
# 4d. depois do campo livre, a fila sai (o campo voltou)
CASE=dlv-campo-volta; dround "$CASE"; printf '%s' 'rascunho' > "$FAKE/field"
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
echo ': > "$FAKE/field"' > "$FAKE/on-sleep-2"
wd
check "campo livre depois: entrega o evento guardado"    [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 ]
check "campo livre depois: um adiamento no log"          [ "$(grep -cF 'entrega adiada: campo do dispatcher com texto' <<<"$(dlog)")" -eq 1 ]
check "campo livre depois: e a entrega no log"           grep -qF 'watch entrega ok: 1 evento(s)' <<<"$(dlog)"

# ---------------------------------------------------------------- 5. campo que não fica com a mensagem exata: sem Enter
CASE=dlv-nao-bate; dround "$CASE"
printf '%s\n' '──────────────────' '❯ ' '──────────────────' > "$FAKE/pane-style"   # a tela não mostra o que foi digitado
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "não bate: sem Enter"                              [ "$(enters)" -eq 0 ]
check "não bate: digitou ao menos uma vez"               [ "$(texts)" -ge 1 ]
check "não bate: limpou o campo (ctrl+c) e a fila ficou" [ "$(grep -c '^pane send-keys w1:p0 ctrl+c' "$FAKE/herdr.log")" -ge 1 -a "$(qlen)" -eq 1 ]
check "não bate: motivo no log"                          grep -qF 'watch entrega adiada: o campo do dispatcher não ficou com a mensagem exata, sem Enter' <<<"$(dlog)"

# ---------------------------------------------------------------- 6. dispatcher sem agente no pane / herdr falhando
CASE=dlv-sem-agente; dround "$CASE"; ag idle claude w1:p77
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "pane sem agente: nada digitado, motivo no log"    [ "$(texts)" -eq 0 -a "$(grep -cF 'entrega adiada: nenhum agente no pane w1:p0 do dispatcher' <<<"$(dlog)")" -eq 1 ]

# ---------------------------------------------------------------- 7. fila longa: grupos que cabem em 800 caracteres, o resto na vez seguinte
CASE=dlv-longa; dround "$CASE"
for i in $(seq 1 12); do printf '10:%02d [pr] PR #%d aberto (issue #%d) %s\n' "$i" "$i" "$i" "$(printf 'x%.0s' $(seq 1 80))" >> "$STATE/watch.queue"; done
for n in 1 2 3 4; do echo : > "$FAKE/on-sleep-$n"; done
wd
check "fila longa: mais de uma mensagem"                 [ "$(texts)" -ge 2 ]
check "fila longa: nenhuma passa de 800 caracteres"      bash -c '[ "$(grep "^pane send-text" "$1" | awk "length(\$0) - 22 > 800" | wc -l)" -eq 0 ]' _ "$FAKE/herdr.log"
check "fila longa: a fila esvaziou"                      [ "$(qlen)" -eq 0 ]
check "fila longa: a soma dos eventos entregues é 12"    bash -c '[ "$(grep -o "entrega ok: [0-9]* evento" "$1" | grep -o "[0-9]*" | awk "{s += \$1} END {print s}")" -eq 12 ]' _ "$STATE/log"
# um evento sozinho maior que o corpo é cortado, não recusado
CASE=dlv-gigante; dround "$CASE"
printf '10:00 [pr] %s\n' "$(printf 'y%.0s' $(seq 1 1500))" >> "$STATE/watch.queue"
wd
check "evento gigante: enviado uma vez"                  [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 ]
check "evento gigante: cortado em até 800 caracteres"    [ "$(sent | wc -c)" -le 800 ]

# ---------------------------------------------------------------- 8. Codex como dispatcher: campo "›"
CASE=dlv-codex; dround "$CASE"; ag idle codex; : > "$FAKE/pane-codex"
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "codex: digita no campo › e envia"                 [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 ]
check "codex: mensagem com o prefixo do watch"           grep -qF '[watch swarm-test] 1 evento(s): ' <<<"$(sent)"

# ---------------------------------------------------------------- 9. a fila sobrevive a um watch reiniciado
CASE=dlv-reinicio; dround "$CASE"; ag working
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
wd
check "reinício: 1ª execução deixou o evento na fila"    [ "$(qlen)" -eq 1 -a "$(texts)" -eq 0 ]
ag idle
rm -f "$FAKE/on-sleep-1"
wd
check "reinício: a 2ª execução entrega o que ficou"      [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 -a "$(qlen)" -eq 0 ]

# ---------------------------------------------------------------- 10. erros de uso do --deliver
CASE=dlv-sem-meta; round "$CASE"; ag idle
wd
check "sem dispatcher_pane no meta: recusa"              [ "$RC" -ne 0 ]
check "sem dispatcher_pane no meta: diz a causa"         grep -qF 'sem dispatcher_pane' <<<"$ERR"
check "sem dispatcher_pane no meta: nada digitado"       [ "$(texts)" -eq 0 ]

# ---------------------------------------------------------------- 11. o watch sem --deliver (caminho do Claude) não digita nem cria fila
CASE=dlv-padrao; dround "$CASE"
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
watch
check "sem --deliver: o evento sai no stdout"            grep -qE '^[0-9]{2}:[0-9]{2} \[sessao\] #7 foo: idle \(sem PR\)$' <<<"$OUT"
check "sem --deliver: nada digitado, sem fila"           [ "$(texts)" -eq 0 -a ! -e "$STATE/watch.queue" ]
check "sem --deliver: nenhuma linha de entrega no log"   [ -z "$(dlog)" ]

# ---------------------------------------------------------------- 12. abertura com --agent codex: meta, aba do watch, oute-task
CASE=ab-codex; round "$CASE"
opn --max 2 --agent codex
nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
check "codex: código 0 e rodada nova"                    [ "$RC" -eq 0 -a -n "$nr" ]
check "codex: meta com agent=codex, workers=codex e o pane" [ "$(grep -cxE 'agent=codex|workers=codex|dispatcher_pane=w1:p0' "$M")" -eq 3 ]
check "codex: oute-task abre o agente codex na fase plan" [ "$(tr '\n' ' ' < "$FAKE/oute-task.args")" == "--phase plan -r $REPO $nr codex " ]
check "codex: aba do watch criada com o label da rodada" grep -qF -- "tab create --workspace w1 --cwd $REPO --label watch $nr --no-focus" "$FAKE/herdr.log"
check "codex: a aba roda o watch --deliver da rodada"    grep -qF "pane run w1:p2 OUTE_SWARM_ID=$nr oute-swarm watch --round $nr --deliver" "$FAKE/herdr.log"
check "codex: o log registra a aba do watch"             grep -qF " watch --deliver aberto na aba w1:p2 (dispatcher codex, pane w1:p0)" "$H/.oute/swarm/$nr/log"
check "codex: prompt com o watch fora do agente"         grep -qF 'já roda sozinho, fora de você, na aba `watch '"$nr"'` do herdr' "$FAKE/oute-task.all"
check "codex: prompt sem a ferramenta Monitor"           bash -c '! grep -qF "Monitor" "$1"' _ "$FAKE/oute-task.all"
check "codex: prompt sem run_in_background"              bash -c '! grep -qF "run_in_background" "$1"' _ "$FAKE/oute-task.all"
check "codex: prompt com o tell --wait pelo shell"       grep -qF 'nohup oute-swarm tell <n>-<slug> "<mensagem>" --wait' "$FAKE/oute-task.all"
check "codex: prompt com o passo sem ai-memory"          grep -qF '**Sem ai-memory:** se as ferramentas `memory_*` não existem na sua sessão' "$FAKE/oute-task.all"
check "codex: sem marcador nem placeholder no prompt"    [ -z "$(grep -oE '@@/?(CL|CX)@@|\{\{[A-Z_]*\}\}' "$FAKE/oute-task.all")" ]
check "codex: o watch fica de pé também sem workers (agent=codex só com --agent)" [ -n "$(grep -x 'agent=codex' "$M")" ]
# 12b. sem HERDR_PANE_ID (fora do pane do herdr): recusa antes de criar a rodada
CASE=ab-codex-sem-pane; round "$CASE"
OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX -u HERDR_PANE_ID PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 \
       HERDR_WORKSPACE_ID=w1 "$SWARM" "$REPO" --agent codex 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
check "sem pane: recusa"                                 [ "$RC" -ne 0 ]
check "sem pane: diz a causa"                            grep -qF 'precisa de HERDR_PANE_ID e HERDR_WORKSPACE_ID' <<<"$ERR"
check "sem pane: nenhuma rodada, nenhum oute-task"       so_teste
# 12c. herdr tab create falha: dispatcher não abre
CASE=ab-codex-tab-falha; round "$CASE"; echo 'não é json' > "$FAKE/tab-create.out"
opn --agent codex
nr="$(nova)"
check "tab create sem pane: recusa"                      [ "$RC" -ne 0 ]
check "tab create sem pane: diz a causa"                 grep -qF 'não achei o pane da aba do watch' <<<"$ERR"
check "tab create sem pane: o agente não abre"           [ ! -e "$FAKE/oute-task.last" ]
check "tab create sem pane: o log registra"              grep -qF 'watch não iniciado: pane da aba não achado' "$H/.oute/swarm/$nr/log"
# 12d. --agent claude explícito e sem --agent (#761): a mesma aba watch --deliver do Codex, sem Monitor, meta com o pane
for ag_args in "--agent claude" ""; do
  CASE="ab-claude${ag_args:+-explicito}"; round "$CASE"
  # shellcheck disable=SC2086
  opn --max 2 $ag_args
  nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
  check "claude [${ag_args:-sem --agent}]: código 0"      [ "$RC" -eq 0 -a -n "$nr" ]
  check "claude [${ag_args:-sem --agent}]: aba do watch criada" grep -qF -- "tab create --workspace w1 --cwd $REPO --label watch $nr --no-focus" "$FAKE/herdr.log"
  check "claude [${ag_args:-sem --agent}]: a aba roda o watch --deliver" grep -qF "pane run w1:p2 OUTE_SWARM_ID=$nr oute-swarm watch --round $nr --deliver" "$FAKE/herdr.log"
  check "claude [${ag_args:-sem --agent}]: meta com dispatcher_pane, agent=claude" [ "$(grep -cxE 'agent=claude|dispatcher_pane=w1:p0' "$M")" -eq 2 ]
  check "claude [${ag_args:-sem --agent}]: o log registra a aba do watch" grep -qF " watch --deliver aberto na aba w1:p2 (dispatcher claude, pane w1:p0)" "$H/.oute/swarm/$nr/log"
  check "claude [${ag_args:-sem --agent}]: oute-task com claude" [ "$(tr '\n' ' ' < "$FAKE/oute-task.args")" == "--phase plan -r $REPO $nr claude " ]
  check "claude [${ag_args:-sem --agent}]: prompt com o watch fora do agente" grep -qF 'já roda sozinho, fora de você, na aba `watch '"$nr"'` do herdr' "$FAKE/oute-task.all"
  check "claude [${ag_args:-sem --agent}]: prompt sem a ferramenta Monitor" bash -c '! grep -qF "Monitor" "$1"' _ "$FAKE/oute-task.all"
  check "claude [${ag_args:-sem --agent}]: prompt sem o trecho do Codex" bash -c '! grep -qF -e "Sem ai-memory" -e "nohup oute-swarm tell" "$1"' _ "$FAKE/oute-task.all"
  check "claude [${ag_args:-sem --agent}]: sem marcador no prompt" [ -z "$(grep -oE '@@/?(CL|CX)@@' "$FAKE/oute-task.all")" ]
done
# 12e. claude sem HERDR_PANE_ID: recusa antes de criar a rodada; tab create sem pane: o dispatcher não abre
CASE=ab-claude-sem-pane; round "$CASE"
OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX -u HERDR_PANE_ID PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 \
       HERDR_WORKSPACE_ID=w1 "$SWARM" "$REPO" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
check "claude sem pane: recusa"                          [ "$RC" -ne 0 ]
check "claude sem pane: diz a causa"                     grep -qF 'dispatcher claude precisa de HERDR_PANE_ID e HERDR_WORKSPACE_ID' <<<"$ERR"
check "claude sem pane: nenhuma rodada, nenhum oute-task" so_teste
CASE=ab-claude-tab-falha; round "$CASE"; echo 'não é json' > "$FAKE/tab-create.out"
opn
check "claude tab create sem pane: recusa"               [ "$RC" -ne 0 ]
check "claude tab create sem pane: o agente não abre"    [ ! -e "$FAKE/oute-task.last" ]
# o prompt do Claude é o swarm.md sem marcador nem trecho do Codex (o item do watch é comum a todos)
CASE=ab-claude-bytes; round "$CASE"
opn --max 2
nr="$(nova)"
expected="$(sed -e '/^- @@CX@@/d' -e 's/@@CX@@[^@]*@@\/CX@@//g' -e 's/@@\/\?CL@@//g' "$ROOT/docker/swarm.md" | sed -e "s|{{REPO}}|repo|g" -e "s|{{REPO_PATH}}|$REPO|g" -e "s|{{MAX}}|2|g" -e "s|{{LABEL}}|(nenhum)|g" -e "s|{{ID}}|$nr|g" \
  -e 's|{{NOME_TEXTO}}||g' -e "s|{{OUTRAS}}|swarm-test · space - · issues com sessão aberta: #7|g" \
  -e 's|{{WORKERS}}|seletor (a rodada abriu sem `--agent`: `claude`, com o modelo da fase de cada issue)|g' -e 's|{{SELECT_AGENT}}||g')"
check "claude: o prompt = swarm.md sem os trechos do Codex" [ "$(cat "$FAKE/oute-task.last")" == "$expected" ]

# ---------------------------------------------------------------- 13. as etapas do prompt (#753): renderizadas na pasta da rodada
CASE=etapas-claude; round "$CASE"
opn --max 2
nr="$(nova)"; PD="$H/.oute/swarm/$nr/prompt"
check "etapas: uma por arquivo de docker/swarm/, na pasta prompt/ da rodada" [ "$(ls "$PD")" == "$(ls "$ROOT/docker/swarm")" ]
check "etapas: sem placeholder nem marcador de agente em nenhuma" bash -c '[ -z "$(cat "$1"/*.md | grep -oE "@@/?(CL|CX)@@|[{][{][A-Z_]+[}][}]")" ]' _ "$PD"
check "etapas: o id da rodada entra no texto da etapa"  grep -qF "~/.oute/swarm/$nr/log" "$PD/acompanhamento.md"
expected="$(sed -e '/^- @@CX@@/d' -e 's/@@CX@@[^@]*@@\/CX@@//g' -e 's/@@\/\?CL@@//g' "$ROOT/docker/swarm/pagina.md" | sed -e "s|{{ID}}|$nr|g")"
check "etapas: claude, a etapa é o arquivo sem os trechos do Codex" [ "$(cat "$PD/pagina.md")" == "$expected" ]
check "etapas: o prompt entregue é só o núcleo, sem texto de etapa" bash -c '! grep -qF "## 1. Triagem" "$1" && grep -qF "## Etapas: o texto é dividido em trechos" "$1"' _ "$FAKE/oute-task.last"
check "etapas: o núcleo cita cada arquivo de etapa, e cada citado existe" bash -c 'for f in "$2"/*.md; do grep -qF "\`$(basename "$f")\`" "$1" || exit 1; done; for c in $(grep -o "\`[a-z]*\.md\`" "$1" | tr -d "\`" | sort -u); do [ "$c" == swarm.md ] || [ -e "$2/$c" ] || exit 1; done' _ "$ROOT/docker/swarm.md" "$ROOT/docker/swarm"
check "etapas: a imagem copia docker/swarm/ para o lugar que o oute-swarm lê" grep -qxF 'COPY docker/swarm/ /usr/local/lib/oute/swarm/' "$ROOT/docker/Dockerfile"
CASE=etapas-codex; round "$CASE"
opn --max 2 --agent codex
nr="$(nova)"; PD="$H/.oute/swarm/$nr/prompt"
check "etapas: codex, a etapa tem o nohup do review e não o run_in_background" bash -c 'grep -qF "nohup oute-swarm step review" "$1/pagina.md" && ! grep -qF "run_in_background" "$1/pagina.md" "$1/acompanhamento.md"' _ "$PD"
check "etapas: codex, o passo sem ai-memory está no fechamento" grep -qF '**Sem ai-memory:**' "$PD/fechamento.md"
# 13b. sem a pasta das etapas na lib: recusa antes de criar a rodada
CASE=etapas-ausentes; round "$CASE"
LIBX="$TMP/libx"; mkdir -p "$LIBX"; cp "$ROOT/docker/swarm.md" "$ROOT/docker/swarm-worker.md" "$LIBX/"
OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$LIBX" HERDR_ENV=1 \
       HERDR_WORKSPACE_ID=w1 HERDR_PANE_ID=w1:p0 "$SWARM" "$REPO" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
check "sem etapas: recusa"                               [ "$RC" -ne 0 ]
check "sem etapas: diz a causa"                          grep -qF 'etapas do prompt ausentes' <<<"$ERR"
check "sem etapas: nenhum agente aberto"                 [ ! -e "$FAKE/oute-task.last" ]

check_end
