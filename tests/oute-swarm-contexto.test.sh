#!/usr/bin/env bash
# Testes do oute-swarm, tema: o estado em disco (`estado`) e o recomeço do contexto do dispatcher a cada N merges (#752).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh).
# Uso: tests/oute-swarm-contexto.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID OUTE_SWARM_RESTART_MERGES

# merges <n>: n linhas de PR mergeado no log, como o watch grava
merges() { local n="$1" i; for i in $(seq 1 "$n"); do echo "2026-10-09T10:0$i:00Z watch [pr] PR #$i mergeado (issue #$((i + 20)))" >> "$STATE/log"; done; return 0; }
# dtab <rótulo>: a aba do dispatcher (w1:t0) no `tab list`, com o rótulo da rodada
dtab() { local rotulo="$1"; jq --arg l "$rotulo" '.result.tabs += [{tab_id: "w1:t0", label: $l}]' "$FAKE/tabs.json" > "$FAKE/tabs.new" && mv "$FAKE/tabs.new" "$FAKE/tabs.json"; return $?; }
# rd <caso> [merges]: rodada de dispatcher parado, com prompt.md e <merges> merges no log
rd() { local caso="$1" n="${2:-0}"; dround "$caso"; dtab swarm-test; echo "instruções do dispatcher" > "$STATE/prompt.md"; merges "$n"; return 0; }
est() { cat "$STATE/estado.md" 2>/dev/null; return 0; }
estl() { local linha="$1"; grep -qxF -- "$linha" <<<"$(est)"; return $?; }
# hold: o `sleep` falso conta também o do send_field (0,5 s): os dois primeiros não fecham a rodada, para a passada seguinte entregar a fila
hold() { : > "$FAKE/on-sleep-1"; : > "$FAKE/on-sleep-2"; return 0; }
typed() { cat "$FAKE/typed.log" 2>/dev/null; return 0; }

# ---------------------------------------------------------------- 1. a abertura guarda o prompt do dispatcher
CASE=abre; round "$CASE"
opn --max 2
nr="$(ls "$H/.oute/swarm" | grep -v '^swarm-test$' | head -1)"
check "abertura: código 0 e rodada nova"                [ "$RC" -eq 0 -a -n "$nr" ]
check "abertura: prompt.md é o prompt entregue ao dispatcher" cmp -s "$FAKE/oute-task.last" "$H/.oute/swarm/$nr/prompt.md"

# ---------------------------------------------------------------- 2. estado: só do disco
CASE=estado; rd "$CASE" 2
printf '2026-10-09T09:00:00Z pergunta 1. fazer merge do #3?\n' >> "$STATE/log"
printf '8-bar w1:p2 claude 2026-01-01T00:00:02Z w1:t2\n' >> "$STATE/spawned"; echo 8-bar > "$STATE/closed"
mkdir -p "$STATE/etapas"; echo x > "$STATE/etapas/triagem.r1.md"; echo '{}' > "$STATE/etapas/triagem.r1.review.json"
sw estado
check "estado: código 0"                                 [ "$RC" -eq 0 ]
check "estado: diz o caminho do arquivo"                 grep -qF "estado gravado em $STATE/estado.md" <<<"$OUT"
check "estado: cabeçalho com a rodada"                   estl "# Estado da rodada swarm-test"
check "estado: sessão aberta e sessão fechada"           bash -c 'grep -qxF -- "- 7-foo: aberta" <<<"$1" && grep -qxF -- "- 8-bar: fechada" <<<"$1"' _ "$(est)"
check "estado: conta os merges vistos"                   estl "- merges vistos pelo watch: 2"
check "estado: lista os PRs mergeados"                   grep -qF -- "- 2026-10-09T10:02:00Z PR #2 mergeado (issue #22)" <<<"$(est)"
check "estado: pergunta pendente"                        bash -c 'grep -A1 "^## Pergunta pendente" <<<"$1" | grep -qxF "1. fazer merge do #3?"' _ "$(est)"
check "estado: autorização ainda não registrada"         bash -c 'grep -A1 "^## Autorização" <<<"$1" | grep -qxF "nenhuma registrada"' _ "$(est)"
check "estado: etapa publicada, sem o veredito"          bash -c 'grep -qxF -- "- triagem.r1.md" <<<"$1" && ! grep -qF review.json <<<"$1"' _ "$(est)"
check "estado: aponta o prompt.md"                       grep -qF "$STATE/prompt.md" <<<"$(est)"
printf '2026-10-09T09:30:00Z resposta\n' >> "$STATE/log"
sw estado
check "estado: com a resposta, a pergunta não está mais pendente" bash -c 'grep -A1 "^## Pergunta pendente" <<<"$1" | grep -qxF "nenhuma"' _ "$(est)"
sw estado --autorizacao $'merge dos PRs da rodada, pelo Bardi,\nem 2026-10-09'
check "autorização: código 0"                            [ "$RC" -eq 0 ]
check "autorização: vai ao estado numa linha só"         bash -c 'grep -A1 "^## Autorização" <<<"$1" | grep -qxF "merge dos PRs da rodada, pelo Bardi, em 2026-10-09"' _ "$(est)"
sw estado
check "autorização: o estado seguinte a mantém"          bash -c 'grep -A1 "^## Autorização" <<<"$1" | grep -qF "pelo Bardi"' _ "$(est)"
sw estado --autorizacao "$(printf 'x%.0s' $(seq 1 400))"
check "autorização: corta em 300 caracteres"             [ "$(wc -c < "$STATE/autorizacao" | tr -d ' ')" -eq 301 ]
sw estado --nada
check "estado: opção desconhecida, código 1"             [ "$RC" -eq 1 ]

# ---------------------------------------------------------------- 3. N merges: limpa a conversa e manda reler o disco
CASE=n5; rd "$CASE" 5
printf '2026-10-09T09:00:00Z pergunta 2. ajustar o #9?\n2026-10-09T09:05:00Z resposta\n' >> "$STATE/log"
hold
wd
check "5 merges: código 0"                               [ "$RC" -eq 0 ]
check "5 merges: o /clear é a primeira digitação"        [ "$(typed | sed -n 1p)" == "/clear" ]
check "5 merges: o [contexto] é a segunda, com o prefixo do watch" grep -qE '^\[watch swarm-test\] 1 evento\(s\): [0-9]{2}:[0-9]{2} \[contexto\] contexto reiniciado depois de 5 merge\(s\)' <<<"$(typed | sed -n 2p)"
check "5 merges: manda reler o prompt.md e o estado.md"  bash -c 'l="$(sed -n 2p "$1")"; grep -qF "$2/prompt.md" <<<"$l" && grep -qF "$2/estado.md" <<<"$l"' _ "$FAKE/typed.log" "$STATE"
check "5 merges: manda reler também o trecho da etapa, em prompt/ (#753)" bash -c 'grep -qF "$2/prompt/" <<<"$(sed -n 2p "$1")"' _ "$FAKE/typed.log" "$STATE"
check "5 merges: duas digitações e dois Enter"           [ "$(texts)" -eq 2 -a "$(enters)" -eq 2 ]
check "5 merges: o estado.md foi gravado"                 estl "# Estado da rodada swarm-test"
check "5 merges: reinicio.n guarda a contagem"           [ "$(cat "$STATE/reinicio.n")" == 5 ]
check "5 merges: o evento [contexto] está no log da rodada" grep -q ' watch \[contexto\] contexto reiniciado depois de 5 merge(s)' "$STATE/log"

# 3a. pergunta pendente ao Bardi: não limpa a conversa
CASE=pend; rd "$CASE" 5
printf '2026-10-09T09:00:00Z pergunta 2. ajustar o #9?\n' >> "$STATE/log"
hold
wd
check "pergunta pendente: nada digitado e sem reinicio.n" [ "$(texts)" -eq 0 -a ! -e "$STATE/reinicio.n" ]
# 3b. a contagem recomeça do último reinício: mais 2 merges não reiniciam, mais 5 sim
CASE=n5b; rd "$CASE" 7; echo 5 > "$STATE/reinicio.n"
hold
wd
check "2 merges depois do reinício: nada digitado"       [ "$(texts)" -eq 0 ]
CASE=n5c; rd "$CASE" 10; echo 5 > "$STATE/reinicio.n"
wd
check "5 merges depois do reinício: reinicia de novo"    [ "$(typed | sed -n 1p)" == "/clear" -a "$(cat "$STATE/reinicio.n")" == 10 ]

# ---------------------------------------------------------------- 4. N configurável e desligável
CASE=n3; rd "$CASE" 4; hold
OUTE_SWARM_RESTART_MERGES=3 wd
check "N=3 com 4 merges: reinicia"                       [ "$(typed | sed -n 1p)" == "/clear" ]
check "N=3: a mensagem diz 4 merges"                     grep -qF 'depois de 4 merge(s)' <<<"$(typed | sed -n 2p)"
CASE=n3b; rd "$CASE" 4
wd
check "N padrão (5) com 4 merges: nada digitado"         [ "$(texts)" -eq 0 ]
CASE=n0; rd "$CASE" 20
OUTE_SWARM_RESTART_MERGES=0 wd
check "N=0 desliga: nada digitado"                       [ "$(texts)" -eq 0 -a ! -e "$STATE/reinicio.n" ]
CASE=nruim; rd "$CASE" 20
OUTE_SWARM_RESTART_MERGES=abc wd
check "N que não é número: não reinicia"                 [ "$(texts)" -eq 0 ]

# ---------------------------------------------------------------- 5. quando não reinicia
CASE=ocupado; rd "$CASE" 5; ag working
hold
wd
check "dispatcher ocupado: nada digitado"                [ "$(texts)" -eq 0 -a ! -e "$STATE/reinicio.n" ]
CASE=campo; rd "$CASE" 5; printf '%s' 'rascunho do Bardi' > "$FAKE/field"
wd
check "campo com texto: não digita por cima"             [ "$(texts)" -eq 0 -a "$(cat "$FAKE/field")" == 'rascunho do Bardi' ]
CASE=sem-prompt; rd "$CASE" 5; rm -f "$STATE/prompt.md"
wd
check "rodada sem prompt.md (anterior à #752): não reinicia" [ "$(texts)" -eq 0 ]
CASE=fila; rd "$CASE" 5; echo "10:00 [pr] PR #1 aberto" > "$STATE/watch.queue"
hold
wd
check "evento na fila: o evento sai primeiro e o /clear só na passada seguinte" bash -c 'grep -qF "[pr] PR #1 aberto" <<<"$(sed -n 1p "$1")" && [ "$(sed -n 2p "$1")" == "/clear" ]' _ "$FAKE/typed.log"
CASE=falha-digita; rd "$CASE" 5
printf '%s\n' '──────────────────' '❯ ' '──────────────────' > "$FAKE/pane-style"   # a tela não mostra o que foi digitado
hold
wd
check "/clear que não ficou no campo: sem Enter e sem reinicio.n" [ "$(enters)" -eq 0 -a ! -e "$STATE/reinicio.n" ]
check "/clear que não ficou no campo: adiado, com o motivo no log" grep -qF 'watch reinício do contexto adiado: /clear não digitado em w1:p0 (código 3, tentativa 1 de 3)' "$STATE/log"
CASE=sem-agente; rd "$CASE" 5; echo '{"result":{"agents":[]}}' > "$FAKE/agents.json"
wd
check "sem agente no pane: nada digitado"                [ "$(texts)" -eq 0 ]

# ---------------------------------------------------------------- 6. dispatcher no Codex: /new
CASE=codex; rd "$CASE" 5; ag idle codex; : > "$FAKE/pane-codex"
hold
wd
check "codex: o comando é /new"                          [ "$(typed | sed -n 1p)" == "/new" ]

# ---------------------------------------------------------------- 7. sem --deliver o watch não mexe no dispatcher
CASE=sem-deliver; rd "$CASE" 9; : > "$STATE/x"
watch
check "watch sem --deliver: nada digitado e sem reinicio.n" [ "$(texts)" -eq 0 -a ! -e "$STATE/reinicio.n" ]

# ---------------------------------------------------------------- 8. pane que não é o da aba do dispatcher
CASE=pane-alheio; rd "$CASE" 5; echo '{"result":{"tabs":[{"tab_id":"w1:t0","label":"#7 foo"}]}}' > "$FAKE/tabs.json"
hold
wd
check "aba sem o rótulo da rodada: nada digitado"        [ "$(texts)" -eq 0 -a ! -e "$STATE/reinicio.n" ]
CASE=pane-sem-aba; rd "$CASE" 5; echo '{"result":{"tabs":[]}}' > "$FAKE/tabs.json"
wd
check "aba que o herdr não lista: nada digitado"         [ "$(texts)" -eq 0 ]
CASE=pane-nome; rd "$CASE" 5; echo '{"result":{"tabs":[]}}' > "$FAKE/tabs.json"; dtab "Mighty_Badger · swarm-test"
wd
check "rótulo com o nome da rodada e o id: reinicia"     [ "$(typed | sed -n 1p)" == "/clear" ]

# ---------------------------------------------------------------- 9. teto de tentativas
CASE=teto; rd "$CASE" 5
printf '%s\n' '──────────────────' '❯ ' '──────────────────' > "$FAKE/pane-style"   # a tela não mostra o que foi digitado
hold
wd; wd; wd
check "teto: três falhas seguidas contadas"              [ "$(cat "$STATE/reinicio.falhas")" == 3 ]
antes="$(texts)"; wd
check "teto: a quarta passada não digita mais"           [ "$(texts)" -eq "$antes" ]
check "teto: cada tentativa vai ao log com o número"     grep -qF 'tentativa 3 de 3' "$STATE/log"
CASE=teto-zera; rd "$CASE" 5; echo 2 > "$STATE/reinicio.falhas"
hold
wd
check "sucesso zera o contador de falhas"                [ ! -e "$STATE/reinicio.falhas" -a "$(cat "$STATE/reinicio.n")" == 5 ]

check_end
