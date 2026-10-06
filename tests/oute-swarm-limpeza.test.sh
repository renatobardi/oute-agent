#!/usr/bin/env bash
# Testes do scripts/swarm-limpeza-lista, tema: a lista da limpeza única das rodadas e dos handoffs antigos (#654).
# O script só lista: rodadas de ~/.oute/swarm sem a marca `fechada` e handoffs abertos do ai-memory por worktree.
# Bash puro, sem herdr, gh nem rede: HOME temporário, repo git de exemplo e o `ai-memory` dublê de tests/lib/fake-ai-memory.sh.
# Uso: tests/oute-swarm-limpeza.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LISTA="${LISTA:-$ROOT/scripts/swarm-limpeza-lista}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/fake-ai-memory.sh"
command -v jq >/dev/null && command -v git >/dev/null || die "precisa de jq e git"

BIN="$TMP/bin"; fake_ai_memory_install "$BIN"
export PATH="$BIN:$PATH" HOME="$TMP/home" FAKE_AI_MEMORY_LOG="$TMP/ai-memory.log" FAKE_AI_MEMORY_HANDOFFS="$TMP/handoffs.json"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset OUTE_HANDOFFS_LIMIT OUTE_HANDOFFS_TIMEOUT FAKE_AI_MEMORY_RC FAKE_AI_MEMORY_SLEEP
ST="$HOME/.oute/swarm"; mkdir -p "$ST"

# repo de exemplo, com a worktree do dispatcher da rodada r-disp (branch sessao/r-disp) e a de outra sessão
REPO="$TMP/ws/proj"; WT="$TMP/ws/wt"; mkdir -p "$REPO" "$WT"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b sessao/r-disp "$WT/proj-r-disp"
git -C "$REPO" worktree add -q -b fix/9-outra "$WT/proj-9-outra"

# rodada <id> <repo> [hora da última linha do log]: pasta com meta e log
rodada() {
  local id="$1" repo="$2" last="${3:-2026-10-02T10:05:00Z}"
  mkdir -p "$ST/$id"
  printf 'repo=%s\nmax=3\nlabel=\nstarted=2026-10-02T10:00:00Z\nagent=claude\n' "$repo" > "$ST/$id/meta"
  printf '2026-10-02T10:00:00Z abertura %s\n%s pergunta x\n' "$id" "$last" > "$ST/$id/log"
  return 0
}
rodada r-sess "$REPO"; printf 'a-1 p1 claude 2026-10-02T10:01:00Z t1\nb-2 p2 claude 2026-10-02T10:02:00Z t2\n' > "$ST/r-sess/spawned"; echo b-2 > "$ST/r-sess/closed"
rodada r-disp "$REPO"
rodada r-cand "$REPO" 2026-10-02T11:30:00Z; echo 'c-3 p3 claude 2026-10-02T10:01:00Z t3' > "$ST/r-cand/spawned"; echo c-3 > "$ST/r-cand/closed"
echo 'name=Wise_Gecko' >> "$ST/r-cand/meta"
rodada r-fechada "$REPO"; echo 2026-10-02T12:00:00Z > "$ST/r-fechada/fechada"
rodada r-marca-vazia "$REPO"; : > "$ST/r-marca-vazia/fechada"
mkdir -p "$ST/avulso"; echo x > "$ST/avulso/log"

# handoffs: um de worktree que existe, um de worktree ausente, um sem cwd, um com cwd nulo e um de id inválido
NOW_MS="$(( $(date +%s) * 1000 ))"; DAY_MS=86400000; HOUR_MS=3600000
jq -n --arg wt "$WT" --argjson now "$NOW_MS" --argjson d "$DAY_MS" --argjson h "$HOUR_MS" '[
  {id: "h-existe", cwd: ($wt + "/proj-9-outra"), created_at_ms: ($now - $h), from_agent: "claude", to_agent: "codex"},
  {id: "h-ausente", cwd: ($wt + "/proj-7-sumiu"), created_at_ms: ($now - 5 * $d - $h), from_agent: "claude", to_agent: "codex"},
  {id: "h-semcwd", created_at_ms: ($now - 2 * $d - $h)},
  {id: "h-nulo", cwd: null},
  {id: "id invalido; x", cwd: ($wt + "/proj-7-sumiu"), created_at_ms: $now}]' > "$FAKE_AI_MEMORY_HANDOFFS"

# lista [args]: roda o script na pasta do repo; stdout em $OUT, stderr em $ERR, código em $RC
lista() {
  OUT="$(cd "${CWD:-$REPO}" && "$LISTA" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  return 0
}
# retrato: o conteúdo de tudo que o script poderia alterar (a pasta das rodadas e o repo), para conferir que só lê
retrato() {
  (cd "$TMP" && find home ws -type f -not -path '*/.git/*' -exec sha256sum {} + | sort; git -C "$REPO" worktree list)
  return 0
}

check "sintaxe (bash -n)"                               bash -n "$LISTA"
check "executável"                                      test -x "$LISTA"
ANTES="$(retrato)"; : > "$FAKE_AI_MEMORY_LOG"
lista
# ---------------------------------------------------------------- 1. rodadas sem a marca
check "rodada com sessão aberta: viva (2 sessões, 1 aberta)" has_line "rodada id=r-sess nome=- aberta=2026-10-02T10:00:00Z sessoes=2 abertas=1 dispatcher=ausente ultimo=2026-10-02T10:05:00Z estado=viva"
check "rodada sem sessão e com a worktree do dispatcher: viva" has_line "rodada id=r-disp nome=- aberta=2026-10-02T10:00:00Z sessoes=0 abertas=0 dispatcher=existe ultimo=2026-10-02T10:05:00Z estado=viva"
check "rodada com as sessões fechadas e sem dispatcher: candidata, com o nome e o último evento" has_line "rodada id=r-cand nome=Wise_Gecko aberta=2026-10-02T10:00:00Z sessoes=1 abertas=0 dispatcher=ausente ultimo=2026-10-02T11:30:00Z estado=candidata"
check "rodada com a marca (com hora ou vazia) e pasta sem meta ficam de fora" test "$(grep -c '^rodada ' <<<"$OUT")" = 3
check "resumo das rodadas"                              has_line "resumo rodadas: 3 sem a marca; 2 viva(s), 1 candidata(s), 0 incerta(s)"
# ---------------------------------------------------------------- 2. handoffs por worktree
check "handoff de worktree que existe: mantem"          has_line "handoff id=h-existe workspace=default project=proj cwd=$WT/proj-9-outra worktree=existe idade_dias=0 estado=mantem"
check "handoff de worktree ausente: candidato, com a idade em dias" has_line "handoff id=h-ausente workspace=default project=proj cwd=$WT/proj-7-sumiu worktree=ausente idade_dias=5 estado=candidato"
check "handoff sem cwd: incerto"                        has_line "handoff id=h-semcwd workspace=default project=proj cwd=- worktree=sem-cwd idade_dias=2 estado=incerto"
check "handoff com cwd nulo e sem data: incerto, idade -" has_line "handoff id=h-nulo workspace=default project=proj cwd=- worktree=sem-cwd idade_dias=- estado=incerto"
check "handoff de id inválido fica de fora"             test "$(grep -c '^handoff ' <<<"$OUT")" = 4
check "resumo dos handoffs"                             has_line "resumo handoffs default/proj: 4 aberto(s); 1 de worktree que existe, 1 candidato(s), 2 incerto(s)"
check "lista completa: código 0, sem aviso e sem stderr" bash -c '[ "$1" -eq 0 ] && [ -z "$2" ] && ! grep -q "^aviso: " <<<"$3"' _ "$RC" "$ERR" "$OUT"
check "cabeçalho e rodapé dizem que é só leitura"       bash -c 'head -n1 <<<"$1" | grep -q "só leitura$" && tail -n1 <<<"$1" | grep -qxF "só lista: nada foi marcado como fechado e nenhum handoff foi cancelado"' _ "$OUT"
# ---------------------------------------------------------------- 3. só lê
check "só lê: pastas das rodadas, repo e worktrees iguais depois" test "$(retrato)" = "$ANTES"
check "só lê: uma consulta ao ai-memory, com workspace e project explícitos" bash -c '[ "$(wc -l < "$1")" -eq 1 ] && grep -qxF -- "handoffs --workspace default --project proj --limit 500 --json" "$1"' _ "$FAKE_AI_MEMORY_LOG"
check "só lê: nunca --expire-all nem cancelamento"      bash -c '! grep -qE "expire|cancel|confirm" "$1"' _ "$FAKE_AI_MEMORY_LOG"
check "o texto do script não chama --expire-all (só o comentário que o proíbe)" test "$(grep -c -- '--expire-all' "$LISTA")" = 1

# ---------------------------------------------------------------- 4. escopo do .ai-memory.toml e --repo
OUTRO="$TMP/ws/outro"; mkdir -p "$OUTRO"; git -C "$OUTRO" init -q -b main
printf 'workspace = "ws-x"\nproject = "proj-x"\n' > "$OUTRO/.ai-memory.toml"
: > "$FAKE_AI_MEMORY_LOG"; lista --repo "$OUTRO"
check "--repo: o repo extra entra, com o escopo do .ai-memory.toml" bash -c 'grep -qxF -- "handoffs --workspace ws-x --project proj-x --limit 500 --json" "$1" && grep -qxF "## Handoffs abertos do ai-memory (ws-x/proj-x)" <<<"$2"' _ "$FAKE_AI_MEMORY_LOG" "$OUT"
check "--repo: o repo das rodadas segue na lista, uma vez só" test "$(grep -c -- '--project proj --limit' "$FAKE_AI_MEMORY_LOG")" = 1
CWD="$WT/proj-9-outra" lista
check "rodado numa worktree: o repo é o principal (uma seção de handoffs)" test "$(grep -c '^## Handoffs abertos do ai-memory (default/proj)$' <<<"$OUT")" = 1

# ---------------------------------------------------------------- 5. fonte que não foi lida: aviso e código 3
rodada r-sem-repo "$TMP/ws/nao-existe"
lista
check "repo da rodada ilegível: incerta, dispatcher=?"  has_line "rodada id=r-sem-repo nome=- aberta=2026-10-02T10:00:00Z sessoes=0 abertas=0 dispatcher=? ultimo=2026-10-02T10:05:00Z estado=incerta"
check "repo da rodada ilegível: aviso, resumo e código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "aviso: 1 rodada(s) com o repo ilegível (dispatcher=?); ficam fora da limpeza" <<<"$2" && grep -qxF "resumo rodadas: 4 sem a marca; 2 viva(s), 1 candidata(s), 1 incerta(s)" <<<"$2"' _ "$RC" "$OUT"
rm -rf "${ST:?}/r-sem-repo"
FAKE_AI_MEMORY_RC=1 lista
check "ai-memory com erro: aviso, nenhum handoff, as rodadas saem e código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "aviso: não consegui listar os handoffs do ai-memory (default/proj); nada listado" <<<"$2" && ! grep -q "^handoff " <<<"$2" && [ "$(grep -c "^rodada " <<<"$2")" -eq 3 ]' _ "$RC" "$OUT"
FAKE_AI_MEMORY_SLEEP=5 OUTE_HANDOFFS_TIMEOUT=1 lista
check "ai-memory sem resposta: aviso e código 3 no prazo" bash -c '[ "$1" -eq 3 ] && grep -q "^aviso: não consegui listar os handoffs" <<<"$2"' _ "$RC" "$OUT"
echo 'isto não é json' > "$TMP/lixo.json"
FAKE_AI_MEMORY_HANDOFFS="$TMP/lixo.json" lista
check "ai-memory com resposta ilegível: aviso e código 3" bash -c '[ "$1" -eq 3 ] && grep -q "^aviso: não consegui listar os handoffs" <<<"$2" && ! grep -q "^handoff " <<<"$2"' _ "$RC" "$OUT"
OUTE_HANDOFFS_LIMIT=4 lista
check "lista no limite: aviso de que pode haver mais, código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "aviso: a lista de default/proj chegou ao limite de 4 handoffs; pode haver mais" <<<"$2" && grep -qxF -- "handoffs --workspace default --project proj --limit 4 --json" "$3"' _ "$RC" "$OUT" "$FAKE_AI_MEMORY_LOG"
# sem o ai-memory no PATH: só as ferramentas que o script usa, por link
MIN="$TMP/min"; mkdir -p "$MIN"
for t in bash git sed grep tail cut date hostname basename dirname cat jq timeout head env; do ln -s "$(command -v "$t")" "$MIN/$t"; done
PATH="$MIN" lista
check "sem ai-memory: aviso, as rodadas saem e código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "aviso: ai-memory ou jq ausente; handoffs não listados" <<<"$2" && [ "$(grep -c "^rodada " <<<"$2")" -eq 3 ]' _ "$RC" "$OUT"
# sem pasta de rodadas e fora de um repo
VAZIO="$TMP/vazio"; mkdir -p "$VAZIO/home" "$VAZIO/pasta"
HOME="$VAZIO/home" CWD="$VAZIO/pasta" GIT_CEILING_DIRECTORIES="$VAZIO" lista
check "sem pasta de rodadas e fora de repo: dois avisos, código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "aviso: pasta das rodadas ausente: $3/home/.oute/swarm" <<<"$2" && grep -qxF "aviso: nenhum repo identificado (rode numa worktree ou passe --repo); handoffs não listados" <<<"$2"' _ "$RC" "$OUT" "$VAZIO"

# ---------------------------------------------------------------- 6. uso
lista --apagar
check "opção desconhecida: código 2, nada no stdout"    bash -c '[ "$1" -eq 2 ] && [ -z "$2" ] && grep -q "opção desconhecida: --apagar" <<<"$3"' _ "$RC" "$OUT" "$ERR"
lista --repo "$VAZIO/pasta"
check "--repo fora de um repo git: código 2"            bash -c '[ "$1" -eq 2 ] && grep -q "não é um repo git" <<<"$2"' _ "$RC" "$ERR"
lista --repo
check "--repo sem valor: código 2"                      bash -c '[ "$1" -eq 2 ] && grep -q -- "--repo pede o caminho" <<<"$2"' _ "$RC" "$ERR"
OUTE_HANDOFFS_LIMIT=muitos lista
check "OUTE_HANDOFFS_LIMIT inválido: código 2"          bash -c '[ "$1" -eq 2 ] && grep -q "OUTE_HANDOFFS_LIMIT inválido" <<<"$2"' _ "$RC" "$ERR"
lista --help
check "--help: o uso, código 0, sem consultar nada"     bash -c '[ "$1" -eq 0 ] && grep -q "SÓ LISTA" <<<"$2" && grep -q "Código de saída" <<<"$2"' _ "$RC" "$OUT"

check_end
