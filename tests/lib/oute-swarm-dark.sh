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

# dalive [<segundos atrás>]: a batida do laço `oute approve --dark` do host, como o container a vê (~/.oute/approve/dark.<rodada>.alive);
# sem argumento, agora. O dark_prereqs aceita batida de até 60 s.
dalive() {
  local ago="${1:-0}"
  mkdir -p "$H/.oute/approve"
  date +%s | awk -v a="$ago" '{print $1 - a}' > "$H/.oute/approve/dark.swarm-x.alive"
  return 0
}

# dcontract <repo>: contrato de deploy válido commitado no repo (três scripts 100755, host) e o oute-deploy-contract real no PATH
dcontract() {
  local dir="$1"
  ln -sf "$ROOT/scripts/deploy-contract" "$BIN/oute-deploy-contract"
  mkdir -p "$dir/.oute"
  printf '#!/bin/sh\necho %s\n' deploy > "$dir/.oute/deploy.sh"; printf '#!/bin/sh\necho %s\n' verify > "$dir/.oute/verify.sh"
  printf '#!/bin/sh\necho %s\n' rollback > "$dir/.oute/rollback.sh"; chmod 755 "$dir"/.oute/*.sh
  printf 'deploy = ".oute/deploy.sh"\nverify = ".oute/verify.sh"\nrollback = ".oute/rollback.sh"\nhost = "oute-server"\n' > "$dir/.oute/deploy.toml"
  git -C "$dir" add -A && git -C "$dir" -c user.email=t@t -c user.name=t commit -qm contrato
  return 0
}

# ---- #844: o agent-studio falso (tests/lib/fake-studio-usage.py), o oute-emit falso e a rodada dark em andamento
# dstudio_up <pasta>: sobe o dublê e exporta AGENT_STUDIO_URL e AGENT_STUDIO_READ_TOKEN para o oute-swarm (o token é sorteado)
dstudio_up() {
  local dir="$1" i
  mkdir -p "$dir"; rm -f "${dir:?}/port"
  DSTUDIO_TOKEN="tok-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  python3 "$ROOT/tests/lib/fake-studio-usage.py" "$dir" "$DSTUDIO_TOKEN" &
  DSTUDIO_PID=$!
  for i in $(seq 1 50); do [[ -s "$dir/port" ]] && break; /bin/sleep 0.1; done
  [[ -s "$dir/port" ]] || { echo "FAIL o agent-studio falso não subiu"; return 1; }
  DSTUDIO_DIR="$dir"
  export AGENT_STUDIO_URL="http""://127.0.0.1:$(cat "$dir/port")" AGENT_STUDIO_READ_TOKEN="$DSTUDIO_TOKEN"
  return 0
}

# dstudio_down: derruba o dublê (o PID que dstudio_up abriu)
dstudio_down() {
  [[ -z "${DSTUDIO_PID:-}" ]] || { kill "$DSTUDIO_PID" 2>/dev/null; wait "$DSTUDIO_PID" 2>/dev/null; }
  DSTUDIO_PID=""
  return 0
}

# dcost <rodada> <usd>: o custo que o dublê devolve para a rodada
dcost() {
  local rodada="$1" usd="$2"
  printf '%s\n' "$usd" > "$DSTUDIO_DIR/cost-$rodada"
  return 0
}

# demit: oute-emit falso no PATH do teste; anota `<tipo> <rodada> <linha>` em $FAKE/emit.log
demit() {
  cat > "$BIN/oute-emit" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/emit.log"
SH
  chmod +x "$BIN/oute-emit"
  return 0
}

# ddark [<budget>]: a rodada swarm-test (do round) vira dark; com budget, grava budget= no meta
ddark() {
  local budget="${1:-}"
  printf 'dark=1\n' >> "$STATE/meta"
  [[ -z "$budget" ]] || printf 'budget=%s\n' "$budget" >> "$STATE/meta"
  return 0
}
