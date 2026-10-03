# Dublê do `ai-memory` para os testes do entrypoint (#365), para `source`. Sem rede, sem servidor.
# fake_ai_memory_install <pasta>: cria <pasta>/ai-memory (a pôr no PATH). O dublê escreve o que o ai-memory real escreve
# e o merge do entrypoint tem que preservar, no $HOME de quem o chama:
#   install-mcp   --client codex        -> [mcp_servers.ai-memory] em ~/.codex/config.toml
#   install-hooks --agent codex         -> [hooks.state."…"] com trusted_hash em ~/.codex/config.toml e ~/.codex/hooks.json
#   install-mcp   --client claude-code  -> mcpServers em ~/.claude.json
#   install-hooks --agent claude-code   -> hooks em ~/.claude/settings.json (jq, sem apagar o resto)
#   run <agente> [opções] --executable <bin> -- <args…> (#367) -> como o real: AI_MEMORY_RUN_ID no ambiente e exec do <bin>
#       com <args…>, no mesmo cwd; a linha do log leva as opções (--no-autowire, --yolo…) para o teste conferir
# Idempotente como o real: o que já está lá não é escrito de novo; se o arquivo já existia e muda, deixa um
# <arquivo>.bak-<n> (o real deixa .bak-<ts> a cada --apply); FAKE_AI_MEMORY_BAK=0 não deixa .bak. Cada chamada vai, em uma linha, em $FAKE_AI_MEMORY_LOG.
fake_ai_memory_install() {
  mkdir -p "$1"
  cat > "$1/ai-memory" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"; shift || true
echo "$cmd $*" >> "${FAKE_AI_MEMORY_LOG:-/dev/null}"
if [[ "$cmd" == run ]]; then
  exe=""
  while [[ $# -gt 0 && "$1" != -- ]]; do [[ "$1" != --executable ]] || exe="$2"; shift; done
  shift || true
  [[ -n "$exe" ]] || { echo "ai-memory falso: run sem --executable" >&2; exit 2; }
  export AI_MEMORY_RUN_ID=fake-run
  exec "$exe" "$@"
fi
agent=""; apply=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client|--agent) agent="$2"; shift ;;
    --apply) apply=1 ;;
  esac
  shift
done
[[ "$apply" == 1 ]] || exit 0
bak() { [[ "${FAKE_AI_MEMORY_BAK:-1}" == 1 ]] || return 0; [[ -e "$1" ]] && cp -p "$1" "$1.bak-$(( $(ls "$1".bak-* 2>/dev/null | wc -l) + 1 ))" || true; }
# append_once <arquivo> <marca> <texto>
append_once() {
  grep -qF -- "$2" "$1" 2>/dev/null && return 0
  bak "$1"; mkdir -p "$(dirname "$1")"; printf '%s\n' "$3" >> "$1"
}
case "$agent:$cmd" in
  codex:install-mcp)
    append_once "$HOME/.codex/config.toml" '[mcp_servers.ai-memory]' $'[mcp_servers.ai-memory]\ncommand = "ai-memory"\nargs = ["serve", "--transport", "stdio"]' ;;
  codex:install-hooks)
    append_once "$HOME/.codex/config.toml" 'trusted_hash' $'[hooks.state."/home/oute/.codex/hooks.json:pre_tool_use:0:0"]\ntrusted_hash = "sha256:0123abcd"'
    if [[ ! -s "$HOME/.codex/hooks.json" ]]; then
      mkdir -p "$HOME/.codex"; echo '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"ai-memory hook"}]}]}}' > "$HOME/.codex/hooks.json"
    fi ;;
  claude-code:install-mcp)
    [[ -s "$HOME/.claude.json" ]] || echo '{}' > "$HOME/.claude.json"
    jq '.mcpServers["ai-memory"] = {command:"ai-memory",args:["serve","--transport","stdio"]}' "$HOME/.claude.json" > "$HOME/.claude.json.tmp"
    mv "$HOME/.claude.json.tmp" "$HOME/.claude.json" ;;
  claude-code:install-hooks)
    mkdir -p "$HOME/.claude"; s="$HOME/.claude/settings.json"; [[ -s "$s" ]] || echo '{}' > "$s"
    jq '.hooks.SessionStart = (.hooks.SessionStart // [{"hooks":[{"type":"command","command":"ai-memory hook"}]}])' "$s" > "$s.tmp"
    mv "$s.tmp" "$s" ;;
esac
FAKE
  chmod +x "$1/ai-memory"
}
