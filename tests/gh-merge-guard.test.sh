#!/usr/bin/env bash
# Trava do `gh pr merge` (#538): docker/shims/gh recusa o merge de PR de rodada aberta do swarm quando quem chama não é o
# dispatcher dela; fora de rodada, em rodada fechada e no dispatcher passa igual. O `gh` real é um dublê no PATH depois do
# shim (registra o que recebeu); estado da rodada em $HOME/.oute/swarm de um HOME temporário. Sem rede, sem Docker.
# Prova vermelha (corpo do PR): GH_SHIM aponta para um shim que só faz `exec` do gh real.
# Uso: tests/gh-merge-guard.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null || die "precisa de jq"
GH_SHIM="${GH_SHIM:-$ROOT/docker/shims/gh}"

SHIMS="$TMP/shims"; REAL="$TMP/real"; FAKE="$TMP/fake"; H="$TMP/home"
mkdir -p "$SHIMS" "$REAL" "$FAKE" "$H"
cp "$GH_SHIM" "$SHIMS/gh"; chmod 755 "$SHIMS/gh"
# gh real falso: `pr view <sel> … --json …` responde com $FAKE/pr-<sel|atual>.json (e aplica --jq); `pr merge`, e o resto, só registram
cat > "$REAL/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/gh.log"
if [[ "${1:-} ${2:-}" == "pr view" ]]; then
  sel=atual; [[ "${3:-}" == -* || -z "${3:-}" ]] || sel="${3##*/}"
  f="$FAKE/pr-$sel.json"; [[ -f "$f" ]] || { echo "no pull requests found" >&2; exit 1; }
  jq=""; prev=""; for a in "$@"; do [[ "$prev" != --jq ]] || jq="$a"; prev="$a"; done
  if [[ -n "$jq" ]]; then jq -r "$jq" "$f"; else cat "$f"; fi
  exit 0
fi
echo "gh falso: $*"
exit "${FAKE_GH_RC:-0}"
FAKEGH
chmod 755 "$REAL/gh"

pr() {   # pr <sel> <número> <branch> [comentários-json]
  jq -n --argjson n "$2" --arg b "$3" --argjson c "${4:-[]}" \
    '{number: $n, headRefName: $b, url: "https://github.com/dono/oute-agent/pull/\($n)", comments: $c}' > "$FAKE/pr-$1.json"
}
round() {   # round <id> <repo> <slug…> ; marcadores à parte
  local id="$1" repo="$2"; shift 2; mkdir -p "$H/.oute/swarm/$id"
  printf 'repo=%s\nmax=3\n' "$repo" > "$H/.oute/swarm/$id/meta"
  : > "$H/.oute/swarm/$id/spawned"
  for s in "$@"; do printf '%s %%1 claude 2026-10-04T10:00:00Z t1 %s -\n' "$s" "$repo" >> "$H/.oute/swarm/$id/spawned"; done
}
# run <env…> -- <gh args…>: o shim, num cwd fora de worktree de rodada; stdout+stderr em $OUT, código em $RC
run() {
  local envs=(); while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  OUT="$(cd "$TMP" && env -u OUTE_SWARM_ID HOME="$H" FAKE="$FAKE" PATH="$SHIMS:$REAL:$PATH" ${envs[@]+"${envs[@]}"} "$SHIMS/gh" "$@" 2>&1 </dev/null)"; RC=$?
}
merged() { grep -q '^pr merge' "$FAKE/gh.log" 2>/dev/null; }
reset() { : > "$FAKE/gh.log"; }

round swarm-1004-1306 /workspace/oute-agent 507-pagina-rodada 540-outra
pr 517 517 feat/507-pagina-rodada '[{"url":"https://github.com/dono/oute-agent/pull/517#issuecomment-1","body":"x\n<!-- oute-aidlc-qa-pr-audit -->\najustar"}]'
pr 600 600 fix/999-fora-de-rodada
pr 601 601 fix/540-outra-repo

# ---------------------------------------------------------------- 1. rodada aberta, sessão avulsa
reset; run -- pr merge 517 --auto --squash
check "avulsa × rodada aberta: recusa com o código 77"   test "$RC" -eq 77
check "avulsa × rodada aberta: não chama o merge do gh real" bash -c '! grep -q "^pr merge" "$1"' _ "$FAKE/gh.log"
check "avulsa × rodada aberta: mensagem com PR, rodada e sessão" bash -c 'echo "$1" | grep -q "PR #517 é da rodada aberta swarm-1004-1306 (sessão 507-pagina-rodada)"' _ "$OUT"
check "avulsa × rodada aberta: mensagem diz o limite e o link da última auditoria" bash -c 'echo "$1" | grep -q "protege contra engano, não contra contorno" && echo "$1" | grep -q "issuecomment-1"' _ "$OUT"
reset; run OUTE_SWARM_ID=swarm-0101-0101 -- pr merge 517
check "outra rodada: recusa também"                      test "$RC" -eq 77
reset; run -- pr merge https://github.com/dono/oute-agent/pull/517 --squash
check "por URL: o seletor é resolvido e a trava vale"    test "$RC" -eq 77
reset; run -- pr merge -R dono/oute-agent 517
check "com -R antes do número: recusa"                   test "$RC" -eq 77
reset; run -- pr merge --squash --match-head-commit abc123 517
check "valor de flag antes do número não vira seletor: recusa" test "$RC" -eq 77
# sem seletor (branch atual) o dublê responde com pr-atual.json
pr atual 517 feat/507-pagina-rodada; reset; run -- pr merge --squash
check "sem seletor, com PR da branch atual: recusa"      test "$RC" -eq 77

# ---------------------------------------------------------------- 2. o que passa
reset; run OUTE_SWARM_ID=swarm-1004-1306 -- pr merge 517 --auto --squash
check "dispatcher (OUTE_SWARM_ID) com --auto --squash: passa e chega ao gh real" bash -c 'test "$1" -eq 0 && grep -qx "pr merge 517 --auto --squash" "$2"' _ "$RC" "$FAKE/gh.log"
reset; run OUTE_SWARM_ID=swarm-1004-1306 -- pr merge 517 --squash --match-head-commit abc123
check "dispatcher, como a qa-pr-audit (--squash --match-head-commit): passa" bash -c 'test "$1" -eq 0 && grep -qx "pr merge 517 --squash --match-head-commit abc123" "$2"' _ "$RC" "$FAKE/gh.log"
reset; run OUTE_SWARM_ID=swarm-1004-1306 -- pr merge https://github.com/dono/oute-agent/pull/517 --squash
check "dispatcher, por URL: passa"                       bash -c 'test "$1" -eq 0 && grep -q "^pr merge https://github.com/dono/oute-agent/pull/517" "$2"' _ "$RC" "$FAKE/gh.log"
# dispatcher reiniciado sem a variável: a worktree sessao/<rodada>
WT="$TMP/wt"; git init -q -b sessao/swarm-1004-1306 "$WT"; git -C "$WT" -c user.email=a@b -c user.name=t commit -q --allow-empty -m i
reset; OUT="$(cd "$WT" && env -u OUTE_SWARM_ID HOME="$H" FAKE="$FAKE" PATH="$SHIMS:$REAL:$PATH" "$SHIMS/gh" pr merge 517 --squash 2>&1 </dev/null)"; RC=$?
check "dispatcher sem a variável, na worktree sessao/<rodada>: passa" bash -c 'test "$1" -eq 0 && grep -q "^pr merge 517" "$2"' _ "$RC" "$FAKE/gh.log"
reset; run -- pr merge 600
check "PR fora de rodada (issue sem sessão): passa"      bash -c 'test "$1" -eq 0 && grep -q "^pr merge 600" "$2"' _ "$RC" "$FAKE/gh.log"
pr 602 602 feat/rascunho-sem-numero; reset; run -- pr merge 602
check "branch sem número de issue: passa"                bash -c 'test "$1" -eq 0 && grep -q "^pr merge 602" "$2"' _ "$RC" "$FAKE/gh.log"
jq '.url = "https://github.com/dono/outro-repo/pull/601"' "$FAKE/pr-601.json" > "$FAKE/x" && mv "$FAKE/x" "$FAKE/pr-601.json"
reset; run -- pr merge 601
check "PR de issue da rodada, mas de outro repo: passa"  test "$RC" -eq 0
# aba da sessão em closed (rodada sem `fechada`): o PR deixa de ser da rodada
printf '507-pagina-rodada\n' > "$H/.oute/swarm/swarm-1004-1306/closed"
reset; run -- pr merge 517 --squash
check "rodada sem fechada, mas com a aba da sessão em closed: passa" bash -c 'test "$1" -eq 0 && grep -q "^pr merge 517" "$2"' _ "$RC" "$FAKE/gh.log"
: > "$H/.oute/swarm/swarm-1004-1306/closed"
reset; run -- pr merge 517 --squash
check "closed vazio: volta a recusar"                    test "$RC" -eq 77
touch "$H/.oute/swarm/swarm-1004-1306/fechada"
reset; run -- pr merge 517 --squash
check "rodada fechada (fechada): passa"                  bash -c 'test "$1" -eq 0 && grep -q "^pr merge 517" "$2"' _ "$RC" "$FAKE/gh.log"
rm -f "$H/.oute/swarm/swarm-1004-1306/fechada"
rm -rf "${H:?}/.oute/swarm"
reset; run -- pr merge 517 --squash
check "sem estado de rodada: passa"                      bash -c 'test "$1" -eq 0 && grep -q "^pr merge 517" "$2"' _ "$RC" "$FAKE/gh.log"

# ---------------------------------------------------------------- 3. o resto do gh não muda
round swarm-1004-1306 /workspace/oute-agent 507-pagina-rodada
reset; run -- pr list --state all
check "outro subcomando (pr list): passa com os mesmos argumentos" bash -c 'test "$1" -eq 0 && grep -qx "pr list --state all" "$2"' _ "$RC" "$FAKE/gh.log"
reset; run FAKE_GH_RC=3 -- issue view 538
check "o código de saída do gh real é o do shim"         test "$RC" -eq 3
reset; run -- pr view 517 --json number
check "pr view passa direto"                             bash -c 'test "$1" -eq 0 && grep -qx "pr view 517 --json number" "$2"' _ "$RC" "$FAKE/gh.log"
reset; run FAKE_GH_RC=4 -- pr merge 999
check "PR que o gh não resolve: passa ao gh real (erro dele, 4)" bash -c 'test "$1" -eq 4 && grep -q "^pr merge 999" "$2"' _ "$RC" "$FAKE/gh.log"

# ---------------------------------------------------------------- 4. sem o gh real
MIN="$TMP/min"; mkdir -p "$MIN"; for t in env bash dirname sed; do ln -s "$(command -v "$t")" "$MIN/$t"; done
OUT="$(cd "$TMP" && env HOME="$H" PATH="$SHIMS:$MIN" "$SHIMS/gh" pr list 2>&1 </dev/null)"; RC=$?
check "sem gh real no PATH: 127 e mensagem"              bash -c 'test "$1" -eq 127 && echo "$2" | grep -q "gh não encontrado"' _ "$RC" "$OUT"

check_end
