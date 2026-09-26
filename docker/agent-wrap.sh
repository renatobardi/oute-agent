# oute-agent: em shell interativo, `claude` / `codex` / `pi` digitados no CHECKOUT PRINCIPAL de um repo git
# abrem a sessão numa worktree própria (oute-task). Uso headless (-p/--print/exec) e worktrees passam direto.
# Desligar numa chamada: OUTE_NO_WORKTREE=1 claude …
[[ $- == *i* ]] || return 0
_oute_is_main_checkout() {
  local gd cd
  gd="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  cd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$gd" == "$cd" ]]
}
_oute_agent() {
  local a="$1"; shift
  local x; for x in "$@"; do case "$x" in -p|--print|exec|-h|--help|--version|-v) command "$a" "$@"; return ;; esac; done
  if [[ -n "${OUTE_NO_WORKTREE:-}" ]] || ! _oute_is_main_checkout; then command "$a" "$@"; return; fi
  local def s; def="sessao-$(date +%m%d-%H%M)"
  read -r -p "nova sessão em worktree própria — nome da tarefa [$def]: " s || return
  ( oute-task "${s:-$def}" "$a" "$@" )
}
claude() { _oute_agent claude "$@"; }
codex()  { _oute_agent codex "$@"; }
pi()     { _oute_agent pi "$@"; }
