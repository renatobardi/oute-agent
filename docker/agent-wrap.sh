# oute-agent: garante os shims de claude/codex/pi (worktree por sessão) na frente do PATH em shells interativos,
# mesmo que ~/.profile tenha posto ~/.local/bin antes. A lógica fica em /usr/local/lib/oute/shims/oute-agent-shim.
case ":$PATH:" in
  :/usr/local/lib/oute/shims:*) ;;
  *) PATH="/usr/local/lib/oute/shims:$(printf '%s' ":$PATH:" | sed 's#:/usr/local/lib/oute/shims:#:#g; s#^:##; s#:$##')"; export PATH ;;
esac
