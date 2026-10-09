#!/usr/bin/env bash
# Testes do oute-swarm, tema: sessão parada por cota esgotada (#759, ADR-02): o `watch` emite a linha `[cota]`, o
# `oute-swarm switch` reabre a sessão na próxima assinatura da cadeia (mesma worktree e branch), sem cota em nenhuma sai com 6, e o
# `spawn` aplica a trava semanal também à zai. Mais o contrato do `oute-select --next-subscription`.
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh; `oute-quota` falso com $FAKE/quota.json).
# Uso: tests/oute-swarm-cota.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"

TABLE="$ROOT/config/select/models.toml"
export OUTE_SELECT_TABLE="$TABLE"
ZRESET="2026-10-13T00:00:00Z"

# qq <5h claude> <7d claude> <7d zai> <5h codex>: grava o JSON do `oute-quota --json` (zai só com a janela de 7 dias)
qq() {
  local c5="$1" c7="$2" z7="$3" x5="$4"
  jq -n --argjson c5 "$c5" --argjson c7 "$c7" --argjson z7 "$z7" --argjson x5 "$x5" --arg zr "$ZRESET" '{schema: 1, max_pct: 98, reset_grace_s: 1200, agents: {
    claude: {status: "ok", windows: {"5h": {used_pct: $c5, resets_in_s: 9000, resets_at: "2030-01-01T05:00:00Z"}, "7d": {used_pct: $c7, resets_in_s: 90000, resets_at: "2030-01-05T00:00:00Z"}}},
    zai: {status: "ok", windows: {"7d": {used_pct: $z7, resets_in_s: 400000, resets_at: $zr}}},
    codex: {status: "ok", windows: {"5h": {used_pct: $x5, resets_in_s: 8000, resets_at: "2030-01-01T04:00:00Z"}}}}}' > "$FAKE/quota.json"
  return $?
}
# tela do pane com o erro de cota da zai (a da sessão da #747) e uma sem erro
screen_429() {
  printf '%s\n' '● Feito o ajuste no teste.' '  ⎿  API Error: Request rejected (429) · Weekly/Monthly Limit Exhausted' '──────────────────' '❯ ' '──────────────────' > "$FAKE/pane-style"
  return 0
}
screen_ok() {
  printf '%s\n' '● Aguardando o CI do PR.' '──────────────────' '❯ ' '──────────────────' > "$FAKE/pane-style"
  return 0
}
# a sessão 7-foo com assinatura (8º campo do spawned): 1 = a assinatura, 2 = o agente
set_sub() {
  local sub="$1" agent="$2"
  printf '7-foo w1:p1 %s 2026-01-01T00:00:01Z w1:t1 %s - %s\n' "$agent" "$REPO" "$sub" > "$STATE/spawned"
  return 0
}

# ---------------------------------------------------------------- 1. watch: linha [cota]
CASE=watch-cota; round "$CASE"; qq 10 10 92 10; set_sub zai claude; screen_429
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
watch
check "watch: código 0"                                  [ "$RC" -eq 0 ]
check "watch: linha [cota] com a sessão, a assinatura e o reset" logged "[cota] #7 foo: parada por cota esgotada na assinatura zai (7d em 92%, reseta $ZRESET); troque com oute-swarm switch 7-foo"
check "watch: a linha [cota] também vai ao stdout"       grep -qF "[cota] #7 foo: parada por cota esgotada na assinatura zai" <<<"$OUT"
check "watch: continua saindo a linha [sessao] idle"     logged "[sessao] #7 foo: idle (sem PR)"
check "watch: uma [cota] só"                             [ "$(log_events | grep -c '^\[cota\]')" -eq 1 ]

# reinício do watch, sem mudança: a linha não se repete
watch
check "reinício: [cota] não se repete"                   [ "$(log_events | grep -c '^\[cota\]')" -eq 1 ]

# idle sem o erro na tela: nenhuma [cota]
CASE=watch-sem-erro; round "$CASE"; qq 10 10 92 10; set_sub zai claude; screen_ok
echo 'fake-tabs idle' > "$FAKE/on-sleep-1"
watch
check "idle sem erro na tela: sem [cota]"                bash -c '! grep -q "\[cota\]" <<<"$1"' _ "$(log_events)"
check "idle sem erro na tela: segue a [sessao] idle"     logged "[sessao] #7 foo: idle (sem PR)"

# erro antigo na tela, mas a sessão voltou a trabalhar: só sessão parada conta
CASE=watch-working; round "$CASE"; qq 10 10 92 10; set_sub zai claude; screen_429
echo 'fake-tabs working' > "$FAKE/on-sleep-1"
watch
check "working com o erro ainda na tela: sem [cota]"     bash -c '! grep -q "\[cota\]" <<<"$1"' _ "$(log_events)"

# linha antiga do spawned (sem assinatura): vale o agente; Codex com a mensagem dele; sem leitura da cota o reset sai como desconhecido
CASE=watch-codex; round "$CASE"; printf '7-foo w1:p1 codex 2026-01-01T00:00:01Z w1:t1\n' > "$STATE/spawned"
printf '%s\n' "■ You've hit your usage limit. Try again later." '──────────────────' '› ' > "$FAKE/pane-style"
echo lixo > "$FAKE/quota.json"
echo 'fake-tabs blocked' > "$FAKE/on-sleep-1"
watch
check "linha antiga + Codex: [cota] na assinatura codex, reset não lido" logged "[cota] #7 foo: parada por cota esgotada na assinatura codex (cota não lida, reset desconhecido); troque com oute-swarm switch 7-foo"

# ---------------------------------------------------------------- 2. switch: reabre na próxima assinatura da cadeia
# issue 8 (aidlc:build): cadeia zai → claude → codex. Abre na zai (7 dias em 50%), depois a zai esgota.
CASE=switch; round "$CASE"; qq 10 10 50 10
INSTR="instrução original da issue 8"
MAX=5 sw spawn 8-troca "$INSTR"
check "setup: a sessão abre na zai"                      [ "$RC" -eq 0 -a "$(awk '$1 == "8-troca" {print $8}' "$STATE/spawned")" == zai ]
qq 10 10 96 10; screen_429; FAKE="$FAKE" "$BIN/fake-tabs" "#8 troca=idle"
tabs0="$(grep -c 'tab create' "$FAKE/herdr.log")"; close0="$(closes)"
MAX=1 sw switch 8-troca
check "switch zai → claude: código 0"                    [ "$RC" -eq 0 ]
check "switch: uma linha dizendo de onde e para onde"    [ "$OUT" == "trocada: #8 zai → claude (cota esgotada; mesma worktree e branch)" ]
check "switch: fecha a aba da sessão parada e abre outra" [ "$(closes)" -eq $((close0 + 1)) -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq $((tabs0 + 1)) ]
check "switch: a mesma sessão no oute-task (mesmo slug, mesma worktree)" bash -c 'tail -1 "$1" | grep -qF -- "oute-task -r $2 8-troca claude"' _ "$FAKE/herdr.log" "$REPO"
check "switch: o spawned segue com uma linha só, já no claude" bash -c '[ "$(grep -c "^8-troca " "$1")" -eq 1 ] && [ "$(awk "\$1 == \"8-troca\" {print \$3, \$8}" "$1")" == "claude claude" ]' _ "$STATE/spawned"
check "switch: a escolha entregue ao oute-task é a claude" [ "$(sel 8-troca subscription) $(sel 8-troca agent)" == "claude claude" ]
check "switch: a instrução leva a retomada e a original" bash -c 'grep -qF "Retomada de #8" "$1" && grep -qF "parou por cota esgotada na assinatura zai" "$1" && grep -qF "instrução original da issue 8" "$1"' _ "$STATE/8-troca.prompt"
check "switch: a instrução leva as regras do worker"      grep -qF "BLOQUEADO #8" "$STATE/8-troca.prompt"
check "switch: log com a troca"                           grep -qE '^[0-9T:Z-]+ troca 8-troca claude claude$' "$STATE/log"
check "switch: o limite --max não atrapalha a troca"      [ "$RC" -eq 0 ]
check "switch: a lista de tentadas guarda a zai"          [ "$(cat "$STATE/8-troca.tried")" == zai ]

# o claude também esgota: a zai, que já parou, não volta mesmo com a cota dela lida abaixo do teto; vai para o codex
qq 99 10 20 10; screen_429
MAX=5 sw switch 8-troca
check "switch claude → codex (a zai já tentada não volta): código 0" [ "$RC" -eq 0 -a "$OUT" == "trocada: #8 claude → codex (cota esgotada; mesma worktree e branch)" ]
check "switch codex: o agente do spawned é o codex"       [ "$(sp_agent swarm-test 8-troca)" == codex ]
check "switch: tentadas = zai e claude"                   [ "$(tr '\n' ' ' < "$STATE/8-troca.tried")" == "zai claude " ]

# nenhuma assinatura com cota: nada muda, resets de cada uma, código 6
qq 99 10 20 99
before="$(cat "$STATE/spawned")"; tabs1="$(grep -c 'tab create' "$FAKE/herdr.log")"; close1="$(closes)"
MAX=5 sw switch 8-troca
check "sem cota em nenhuma: código 6"                     [ "$RC" -eq 6 ]
check "sem cota: diz a issue, e cada assinatura com o estado e o reset" bash -c 'for t in "sem cota em nenhuma assinatura da cadeia para #8" "zai parada" "claude parada" "codex parada" "7d em 20%"; do grep -qF -- "$t" <<<"$1" || exit 1; done' _ "$OUT"
check "sem cota: nada fechado nem aberto, spawned igual"  [ "$(closes)" -eq "$close1" -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq "$tabs1" -a "$(cat "$STATE/spawned")" == "$before" ]
check "sem cota: linha sem-cota no log"                   grep -qE '^[0-9T:Z-]+ troca 8-troca sem-cota codex$' "$STATE/log"

# a trava semanal não deixa a troca cair numa assinatura quase esgotada: claude em 7d=90 (trava 85) conta como trava, não como opção
CASE=switch-trava; round "$CASE"; qq 10 90 96 10; screen_429
printf '9-b w1:p1 claude 2026-01-01T00:00:01Z w1:t1 %s - zai\n' "$REPO" >> "$STATE/spawned"; FAKE="$FAKE" "$BIN/fake-tabs" "#9 b=idle"
MAX=5 sw switch 9-b
check "zai parada, claude com 7d=90 (trava 85): vai ao codex" [ "$RC" -eq 0 -a "$OUT" == "trocada: #9 zai → codex (cota esgotada; mesma worktree e branch)" ]

# erros de uso
CASE=switch-uso; round "$CASE"
MAX=5 sw switch 99-nao
check "switch de sessão que não é da rodada: recusa"       bash -c '[ "$1" -ne 0 ] && grep -qF "99-nao não é desta rodada" <<<"$2"' _ "$RC" "$ERR"
MAX=5 sw switch
check "switch sem argumento: uso"                          bash -c '[ "$1" -ne 0 ] && grep -qF "uso: oute-swarm switch" <<<"$2"' _ "$RC" "$ERR"
echo 7-foo > "$STATE/closed"
MAX=5 sw switch 7-foo
check "switch de sessão fechada: recusa"                   bash -c '[ "$1" -ne 0 ] && grep -qF "já foi fechada" <<<"$2"' _ "$RC" "$ERR"

# ---------------------------------------------------------------- 3. spawn: a trava semanal vale para a zai
CASE=trava-zai; round "$CASE"; qq 10 10 92 10
before="$(cat "$STATE/spawned")"; tabs2="$(grep -c 'tab create' "$FAKE/herdr.log" 2>/dev/null || true)"
MAX=5 sw spawn 8-zai "instrução"
check "zai com 7d=92 (trava 85): código 5"                 [ "$RC" -eq 5 ]
check "zai: diz a assinatura, os números e as opções"       bash -c 'for t in "trava semanal" "assinatura zai" "92% da janela de 7 dias" "trava de 85%" "reseta em cerca de 111 h" "#8 não abre (código 5)" "--force"; do grep -qF -- "$t" <<<"$1" || exit 1; done' _ "$ERR"
check "zai: nada aberto nem registrado"                    [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log" 2>/dev/null || true)" == "$tabs2" ]
check "zai: linha guard no log"                            grep -qE '^[0-9T:Z-]+ guard 8-zai zai 7d=92% trava=85%$' "$STATE/log"
qq 10 10 84 10
MAX=5 sw spawn 9-zai "instrução"
check "zai com 7d=84: abre, no agente claude"              [ "$RC" -eq 0 -a "$(sp_agent swarm-test 9-zai)" == claude ]
check "zai com 7d=84: assinatura zai no spawned"           [ "$(awk '$1 == "9-zai" {print $8}' "$STATE/spawned")" == zai ]
qq 10 10 99 10
MAX=5 sw spawn 10-zai "instrução" --force
check "zai com 7d=99 e --force: abre"                      [ "$RC" -eq 0 ]
check "a tabela do repo tem weekly_guard_pct = 85 na claude e na zai" bash -c 'python3 -I -c "import sys,tomllib; t=tomllib.load(open(sys.argv[1],\"rb\")); print({s[\"name\"]: s.get(\"weekly_guard_pct\") for s in t[\"subscription\"]})" "$1" | grep -qxF "{'"'"'claude'"'"': 85, '"'"'zai'"'"': 85, '"'"'codex'"'"': None}"' _ "$TABLE"

# ---------------------------------------------------------------- 4. oute-select --next-subscription
CASE=select-next; round "$CASE"
nx() { local list="$1"; shift; env PATH="$BIN:$PATH" FAKE="$FAKE" "$ROOT/docker/oute-select" --next-subscription "$list" "$@"; return $?; }
qq 10 10 96 10
j="$(nx zai --phase build)"
check "next: cadeia da fase build, na ordem da tabela"     [ "$(jq -c .chain <<<"$j")" == '["zai","claude","codex"]' ]
check "next: parada, ok, ok; a próxima é a claude, com agente e modelo" [ "$(jq -c '[.options[].status], .next, .next_agent, .next_model' <<<"$j" | tr '\n' ' ')" == '["parada","ok","ok"] "claude" "claude" "claude-sonnet-5-5" ' ]
check "next: a parada traz o reset da janela cheia"        [ "$(jq -r '.options[0] | "\(.resets_at) \(.resets_in_s)"' <<<"$j")" == "$ZRESET 400000" ]
j="$(nx zai,claude --phase build)"
check "next: com a claude também tentada, vai ao codex (esforço da linha)" [ "$(jq -r '[.next, .next_effort] | join(" ")' <<<"$j")" == "codex high" ]
qq 99 90 96 99
j="$(nx zai --phase build)"
check "next: claude cheia (5h 99%) e codex cheia: sem próxima"  [ "$(jq -c '[.next, (.options|map(.status))]' <<<"$j")" == '["",["parada","cheia","cheia"]]' ]
qq 10 90 96 10
check "next: claude com 7d=90 (trava 85): status trava, com o reset de 7 dias" bash -c '[ "$(jq -r ".options[1] | \"\(.status) \(.resets_at)\"" <<<"$1")" == "trava 2030-01-05T00:00:00Z" ]' _ "$(nx zai --phase build)"
qq 10 10 96 10
check "next: assinatura indisponível (status da tabela) não é candidata" bash -c 'env PATH="$1:$PATH" FAKE="$2" FAKE_CODEX_LOGIN_RC=1 "$3" --next-subscription zai,claude --phase build | jq -e ".next == \"\" and .options[2].status == \"indisponivel\"" >/dev/null' _ "$BIN" "$FAKE" "$ROOT/docker/oute-select"
echo lixo > "$FAKE/quota.json"
check "next: cota não lida: desconhecida, e a primeira vira a próxima" bash -c '[ "$(jq -r ".next" <<<"$1")" == claude ] && [ "$(jq -r ".options[1].status" <<<"$1")" == desconhecida ]' _ "$(nx zai --phase build)"
qq 10 10 96 10
echo aidlc:spec > "$FAKE/labels-8"
check "next: pela issue (fase spec): cadeia claude → zai → codex" bash -c '[ "$(jq -c .chain <<<"$1")" == "[\"claude\",\"zai\",\"codex\"]" ]' _ "$(nx claude --repo "$REPO" --issue 8)"
check "next: assinatura fora da tabela: código 2"          bash -c 'env PATH="$1:$PATH" FAKE="$2" "$3" --next-subscription zzz --phase build >/dev/null 2>&1; [ $? -eq 2 ]' _ "$BIN" "$FAKE" "$ROOT/docker/oute-select"
check "next: sem valor: código 2"                          bash -c 'env PATH="$1:$PATH" FAKE="$2" "$3" --next-subscription >/dev/null 2>&1; [ $? -eq 2 ]' _ "$BIN" "$FAKE" "$ROOT/docker/oute-select"
check_end
