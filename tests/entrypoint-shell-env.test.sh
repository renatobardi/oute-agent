#!/usr/bin/env bash
# ~/.oute_env nos shells (#250, ADR-04): o shell não interativo com o stdin ligado a um socket (o do Bash tool do Claude
# Code) lê o ~/.bashrc, e a linha que o entrypoint gravava no topo dele punha as credenciais nesse shell. Roda de verdade
# a shell_env_rc do docker/entrypoint.sh (extraída por sed) num HOME temporário, com .bashrc e .profile no layout do
# Ubuntu, e confere, por shell (não interativo, de login, interativo; stdin em socket e em /dev/null), se a variável
# do ~/.oute_env chega. O valor é gerado na hora e não sai na saída. Sem Docker, sem rede.
# Prova vermelha (corpo do PR): base = a linha antiga no topo do .bashrc: o shell não interativo com socket a vê.
# Uso: tests/entrypoint-shell-env.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v python3 >/dev/null || die "precisa de python3"

eval "$(sed -n '/^shell_env_rc() {/,/^}/p' "$ROOT/docker/entrypoint.sh")"
SOCK="$ROOT/tests/lib/sock-stdin.py"
NAME=OUTE_TESTE_RC
VALOR="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
PROBE='printf %s "${'"$NAME"':-ausente}"'

# skel_ubuntu <home>: .bashrc e .profile como o Ubuntu traz (o .bashrc retorna cedo se não for interativo)
skel_ubuntu() {
  local home="$1"
  printf '%s\n' '# ~/.bashrc' 'case $- in' '    *i*) ;;' '      *) return;;' 'esac' 'HISTSIZE=1000' > "$home/.bashrc"
  printf '%s\n' '# ~/.profile' 'if [ -n "$BASH_VERSION" ]; then' '    if [ -f "$HOME/.bashrc" ]; then' '        . "$HOME/.bashrc"' '    fi' 'fi' > "$home/.profile"
  return 0
}
# linha_antiga <home>: o layout que o entrypoint gravava antes desta mudança (linha sem guarda, no topo do .bashrc)
linha_antiga() {
  local home="$1"
  printf '%s\n%s\n' '[ -f ~/.oute_env ] && . ~/.oute_env' "$(cat "$home/.bashrc")" > "$home/.bashrc.tmp" && mv "$home/.bashrc.tmp" "$home/.bashrc"
  return 0
}
# shell_do <home> <modo>: roda a sonda no shell do modo dado, com env -i (só HOME e PATH), e imprime o que ela vê
shell_do() {
  local home="$1" modo="$2"
  case "$modo" in
    nao-interativo-socket) env -i HOME="$home" PATH="$PATH" python3 -I "$SOCK" bash -c "$PROBE" ;;
    nao-interativo-devnull) env -i HOME="$home" PATH="$PATH" bash -c "$PROBE" </dev/null ;;
    login-socket) env -i HOME="$home" PATH="$PATH" python3 -I "$SOCK" bash -lc "$PROBE" ;;
    interativo-socket) env -i HOME="$home" PATH="$PATH" python3 -I "$SOCK" bash -ic "$PROBE" 2>/dev/null ;;
  esac
  return $?
}
# veja <home> <modo> <esperado>: confere o que o shell vê (ausente ou o valor do ~/.oute_env)
veja() {
  local home="$1" modo="$2" esperado="$3" out
  out="$(shell_do "$home" "$modo")"
  if [[ "$esperado" == valor ]]; then [[ "$out" == "$VALOR" ]]; else [[ "$out" == ausente ]]; fi
  return $?
}

# ---------------------------------------------------------------- 1. layout novo, gravado pela shell_env_rc
H="$TMP/novo"; mkdir -p "$H"; skel_ubuntu "$H"
printf 'declare -x %s="%s"\n' "$NAME" "$VALOR" > "$H/.oute_env"
check "shell_env_rc definida no entrypoint"                     test "$(type -t shell_env_rc)" = function
(export HOME="$H"; shell_env_rc)
check "novo: não interativo com stdin em socket não vê o ~/.oute_env" veja "$H" nao-interativo-socket ausente
check "novo: não interativo com stdin em /dev/null não vê"          veja "$H" nao-interativo-devnull ausente
check "novo: de login vê (o .profile carrega)"                     veja "$H" login-socket valor
check "novo: interativo vê (o .bashrc com a guarda carrega)"        veja "$H" interativo-socket valor
check "novo: a linha do ~/.oute_env aparece uma vez no .bashrc"    [ "$(grep -c '\.oute_env' "$H/.bashrc")" -eq 1 ]
check "novo: a guarda de interativo é a primeira linha do .bashrc" bash -c 'head -1 "$1" | grep -qF "case \$- in *i*)"' _ "$H/.bashrc"
(export HOME="$H"; shell_env_rc)
check "novo: rodar de novo não repete a linha (idempotente)"       [ "$(cat "$H/.bashrc" "$H/.profile" | grep -c '\.oute_env')" -eq 2 ]

# ---------------------------------------------------------------- 2. volume de versão anterior: a linha antiga sai
M="$TMP/migra"; mkdir -p "$M"; skel_ubuntu "$M"; linha_antiga "$M"
printf 'declare -x %s="%s"\n' "$NAME" "$VALOR" > "$M/.oute_env"
check "controle: o layout antigo vaza para o shell não interativo com socket" veja "$M" nao-interativo-socket valor
(export HOME="$M"; shell_env_rc)
check "migra: depois da shell_env_rc, não interativo com socket não vê"     veja "$M" nao-interativo-socket ausente
check "migra: depois da shell_env_rc, interativo ainda vê"                  veja "$M" interativo-socket valor
check "migra: a linha antiga saiu (uma linha com o ~/.oute_env no .bashrc)" [ "$(grep -c '\.oute_env' "$M/.bashrc")" -eq 1 ]
check "migra: o HISTSIZE do skel continua no .bashrc"                       grep -q '^HISTSIZE=1000$' "$M/.bashrc"

# ---------------------------------------------------------------- 3. sem ~/.oute_env: nada quebra
S="$TMP/sem"; mkdir -p "$S"; skel_ubuntu "$S"
(export HOME="$S"; shell_env_rc)
check "sem ~/.oute_env: os shells sobem e a variável fica ausente" veja "$S" interativo-socket ausente

check "entrypoint: o serve chama a shell_env_rc, sem o laço antigo" \
  bash -c 'grep -qx "    shell_env_rc" "$1" && ! grep -q "for rc in" "$1"' _ "$ROOT/docker/entrypoint.sh"

check_end
