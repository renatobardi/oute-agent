#!/usr/bin/env bash
# Testes do oute-swarm, tema: `tell` não digita por cima do que já está no campo da sessão (o rascunho do Bardi, #713).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425).
# Uso: tests/oute-swarm-rascunho.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/otlp.sh"
guarda_start "$TMP/guarda"
rcv_stop   # sem receptor neste arquivo: porta fechada, nenhum evento alcança o coletor (a guarda, sem receptor, não vê nada, #815)
. "$ROOT/tests/lib/swarm.sh"

# sessão 7-foo (pane w1:p1, aba "#7 foo") com o agente parado (idle) e o campo com o texto dado (ou vazio)
sessao() {
  local texto="$1"
  echo '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","agent":"claude"}]}}' > "$FAKE/panes.json"
  FAKE="$FAKE" "$BIN/fake-tabs" idle
  ag idle claude w1:p1
  printf '%s' "$texto" > "$FAKE/field"
  return 0
}
# teclas mandadas ao pane da sessão (ctrl+c, enter…), sem o send-text
teclas() { grep -c '^pane send-keys' "$FAKE/herdr.log" 2>/dev/null || true; return 0; }

# ---------------------------------------------------------------- #713: campo com rascunho, sessão idle
# 1. o rascunho do Bardi fica: nada digitado, nada apagado, código próprio, recusa no log
CASE=rascunho; round "$CASE"; sessao 'rascunho do Bardi a meio'
sw tell 7-foo "pode seguir"
check "rascunho: código 7 (não entregue)"                [ "$RC" -eq 7 ]
check "rascunho: nada digitado no campo"                 [ "$(texts)" -eq 0 ]
check "rascunho: nenhuma tecla no pane (sem ctrl+c, sem Enter)" [ "$(teclas)" -eq 0 ]
check "rascunho: o campo continua como estava"           [ "$(cat "$FAKE/field")" == 'rascunho do Bardi a meio' ]
check "rascunho: recusa no log, com a mensagem"          grep -qF -- " tell 7-foo recusado: o campo de entrada de #7 foo tem texto (o Bardi digitando?)"$'\t'"pode seguir" "$STATE/log"
check "rascunho: a saída diz que não foi entregue"       grep -qF 'a mensagem NÃO foi entregue' <<<"$ERR"
check "rascunho: a saída manda não reenviar em laço"     grep -qF 'não reenvie em laço' <<<"$ERR"
check "rascunho: nada registrado como ok"                [ "$(grep -c ' tell 7-foo ok' "$STATE/log")" -eq 0 ]

# 2. --wait não espera: campo com texto não é sessão ocupada, a recusa sai na hora
CASE=rascunho-wait; round "$CASE"; sessao 'rascunho'
rm -f "${FAKE:?}/tsleeps"
sw tell 7-foo "pode seguir" --wait --timeout 5
check "rascunho com --wait: código 7 na primeira volta"  [ "$RC" -eq 7 -a ! -e "$FAKE/tsleeps" ]
check "rascunho com --wait: campo intacto"               [ "$(cat "$FAKE/field")" == 'rascunho' ]

# 3. espaço não é rascunho: campo só com espaços entrega como antes
CASE=espacos; round "$CASE"; sessao '   '
sw tell 7-foo "pode seguir"
check "campo só com espaços: código 0"                   [ "$RC" -eq 0 ]
check "campo só com espaços: digitado e Enter dado"      [ "$(texts)" -eq 1 -a "$(grep -c '^pane send-keys w1:p1 enter' "$FAKE/herdr.log")" -eq 1 ]
check "campo só com espaços: registrado como ok"         grep -qF " tell 7-foo ok"$'\t'"pode seguir" "$STATE/log"

# 4. campo vazio: entrega normal, sem ctrl+c
CASE=vazio; round "$CASE"; sessao ''
sw tell 7-foo "pode seguir"
check "campo vazio: código 0"                            [ "$RC" -eq 0 ]
check "campo vazio: mensagem no campo e Enter"           [ "$(cat "$FAKE/field")" == "[dispatcher swarm-test, repassando o Bardi] pode seguir" -a "$(grep -c '^pane send-keys w1:p1 enter' "$FAKE/herdr.log")" -eq 1 ]
check "campo vazio: sem ctrl+c"                          [ "$(grep -c 'ctrl+c' "$FAKE/herdr.log")" -eq 0 ]

# ---------------------------------------------------------------- #713: field_text com placeholder e sugestão
# Linhas copiadas de `herdr pane read --format ansi` de verdade (herdr 0.9.3; Claude Code 2.1.296 e Codex 0.159.2, abas
# paradas): o placeholder e a sugestão vêm em SGR 2 (esmaecido), depois de NBSP (Claude) ou do fundo (Codex); a régua e o
# fundo do Codex vêm em cor 38/48;2;r;g;b. Sem esconder isso, o campo vazio seria lido como texto e todo `tell` recusaria.
. <(sed -n '/^field_text() {/,/^}/p' "$SWARM")
RUL='\033[0m\033[38;2;136;136;136m──────────\033[0m'
tela() { printf "$1\n" > "$FAKE/pane-style"; return 0; }
herdr() { FAKE="$FAKE" "$BIN/herdr" "$@"; }   # o field_text chama o herdr do PATH; aqui, o dublê
# lê o campo; leitura que falha (campo não achado) não passa por campo vazio
campo() { field_text w1:p1 "$1" 2>/dev/null; return 0; }
campo_vazio() { local out; out="$(field_text w1:p1 "$1" 2>/dev/null)" || return 1; [[ -z "$out" ]]; }

tela "$RUL"'\n❯\xc2\xa0\033[0m\033[2mTry "how does oute-swarm.test.sh work?"\033[0m\n'"$RUL"
check "field_text: placeholder do Claude Code (conversa nova) não é texto"   campo_vazio claude
tela "$RUL"'\n❯\xc2\xa0\033[0m\033[2mabre o PR\033[0m\n'"$RUL"
check "field_text: sugestão do Claude Code (depois de um turno) não é texto" campo_vazio claude
tela "$RUL"'\n❯\xc2\xa0\033[0mrascunho do Bardi\033[0m\n'"$RUL"
check "field_text: texto de verdade do Claude Code é lido"                   [ "$(campo claude)" == "rascunho do Bardi" ]
tela '\033[0m\033[1m\033[48;2;59;64;76m›\033[0m\033[48;2;59;64;76m \033[0m\033[2m\033[48;2;59;64;76mAsk Codex to do anything\033[0m\033[48;2;59;64;76m  \033[0m'
check "field_text: placeholder do Codex não é texto"                         campo_vazio codex
rm -f "${FAKE:?}/pane-style"

guarda_check
guarda_stop
check_end
