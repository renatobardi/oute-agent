#!/usr/bin/env bash
# Apoio do tests/oute-swarm-dark.test.sh (#841, ADR-10): a cota de 7 dias e a permissão de push que o `dark_prereqs` do `oute-swarm`
# confere. Para `source` depois de tests/lib/swarm.sh (precisa de $BIN, $FAKE e $REPO).

# dq <% 7d do claude> <% 7d do codex> <% 7d da zai>: grava o JSON que o `oute-quota` falso devolve (janela de 5 h folgada)
dq() {
  local c="$1" x="$2" z="$3"
  jq -n --argjson c "$c" --argjson x "$x" --argjson z "$z" '
    def a($u): {status: "ok", windows: {"5h": {used_pct: 10, resets_in_s: 9000}, "7d": {used_pct: $u, resets_in_s: 90000, resets_at: "2030-01-05T00:00:00Z"}}};
    {schema: 1, max_pct: 98, reset_grace_s: 1200, agents: {claude: a($c), codex: a($x), zai: a($z)}}' > "$FAKE/quota.json"
  return $?
}

# dgh <true|false|erro>: o `gh api repos/<dono>/<repo> --jq .permissions.push` falso (o resto vai para o gh falso do swarm.sh);
# anota o repo pedido em $FAKE/gh-api.log
dgh() {
  local push="$1"
  [[ -x "$BIN/gh.base" ]] || mv "$BIN/gh" "$BIN/gh.base"
  cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == api && "\${2:-}" == repos/* ]]; then
  echo "\$2" >> "\$FAKE/gh-api.log"
  case "$push" in true|false) echo "$push" ;; *) echo "gh falso: sem acesso" >&2; exit 1 ;; esac
  exit 0
fi
exec "$BIN/gh.base" "\$@"
SH
  chmod +x "$BIN/gh"
  return 0
}

# dark_repo <pasta>: repo git com remoto origin renatobardi/<nome da pasta>
dark_repo() {
  local dir="$1"
  gitrepo "$dir"
  git -C "$dir" remote add origin "git@github.com:renatobardi/$(basename "$dir").git" 2>/dev/null || true
  return 0
}
