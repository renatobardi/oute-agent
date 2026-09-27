#!/usr/bin/env bash
# Testes do oute-swarm (#84, parte da #54). Bash puro, sem herdr, gh nem rede de verdade.
# `herdr`, `gh` e `sleep` falsos no PATH: o herdr e o gh leem JSON de $FAKE (o teste troca entre passadas),
# e o `sleep` do laço do `watch` é o gancho entre as passadas (roda $FAKE/on-sleep-<n>; sem gancho, fecha a
# rodada e o watch sai sozinho). Só comportamento externo: stdout, log e estado da rodada.
# Uso: tests/oute-swarm.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

[[ -x "$SWARM" ]] || { echo "FAIL oute-swarm ausente ou sem +x: $SWARM"; exit 1; }
command -v jq >/dev/null || { echo "FAIL precisa de jq"; exit 1; }

# ---------------------------------------------------------------- fakes
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "tab list") cat "$FAKE/tabs.json" ;;
  "pane list") cat "$FAKE/panes.json" 2>/dev/null || echo '{"result":{"panes":[]}}' ;;
  "agent list") cat "$FAKE/agents.json" 2>/dev/null || echo '{"result":{"agents":[]}}' ;;
  *) echo "herdr falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr list") cat "$FAKE/prs.json" ;;
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
cat > "$BIN/sleep" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE/sleeps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/sleeps"
if [[ -f "$FAKE/on-sleep-$n" ]]; then . "$FAKE/on-sleep-$n"; else date -u +%FT%TZ > "$STATE/fechada"; fi
SH
# fake-tabs <status>: a aba "#7 foo" com o agente em <status> (usável nos ganchos on-sleep-<n>)
cat > "$BIN/fake-tabs" <<'SH'
#!/usr/bin/env bash
printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"#7 foo","agent_status":"%s"}]}}\n' "$1" > "$FAKE/tabs.json"
SH
chmod +x "$BIN"/*

# round(<caso>): HOME, rodada swarm-test (repo falso, início no passado) e $FAKE limpos; issue #7 aberta na aba
# "#7 foo". Globais: H, STATE, FAKE.
round() {
  H="$TMP/$1/home"; STATE="$H/.oute/swarm/swarm-test"; FAKE="$TMP/$1/fake"
  mkdir -p "$STATE" "$FAKE" "$TMP/$1/repo" "$TMP/$1/inbox" "$TMP/$1/outbox"
  printf 'repo=%s\nmax=3\nlabel=\nstarted=2026-01-01T00:00:00Z\n' "$TMP/$1/repo" > "$STATE/meta"
  printf '7-foo w1:p1 claude 2026-01-01T00:00:01Z w1:t1\n' > "$STATE/spawned"
  FAKE="$FAKE" "$BIN/fake-tabs" working; echo '[]' > "$FAKE/prs.json"
}
# roda o watch até a rodada fechar; stdout em $OUT, stderr em $ERR, código em $RC
watch() {
  local g=(); command -v timeout >/dev/null && g=(timeout 30)
  rm -f "$FAKE/sleeps" "$STATE/fechada"
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" STATE="$STATE" \
         OUTE_INBOX="$TMP/$CASE/inbox" OUTE_OUTBOX="$TMP/$CASE/outbox" \
         ${g[@]+"${g[@]}"} "$SWARM" watch --round swarm-test 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
LOGRE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z watch \[[a-z]+\] .+$'
wlog() { grep ' watch \[' "$STATE/log" 2>/dev/null || true; }
# eventos do stdout (sem o HH:MM) e do log (sem timestamp e "watch"), para comparar
out_events() { sed -E 's/^[0-9]{2}:[0-9]{2} //' <<<"$OUT"; }
log_events() { wlog | sed -E 's/^[^ ]+ watch //'; }
logged() { grep -qxF -- "$1" <<<"$(log_events)"; }
count() { grep -cxF -- "$1" <<<"$(log_events)" || true; }

# 1. watch: cada evento impresso vai também para o log da rodada; a linha de base não grava nada
CASE=eventos; round "$CASE"
# entre a 1ª e a 2ª passada: sessão fica idle, PR #12 da issue #7 abre com CI vermelho
cat > "$FAKE/on-sleep-1" <<'SH'
cp "$STATE/log" "$FAKE/log.p1" 2>/dev/null || : > "$FAKE/log.p1"
fake-tabs idle
cat > "$FAKE/prs.json" <<'J'
[{"number":12,"headRefName":"feat/7-foo","state":"OPEN","mergeable":"MERGEABLE","createdAt":"2026-06-01T00:00:00Z",
  "url":"https://github.com/x/y/pull/12","statusCheckRollup":[{"name":"test","conclusion":"FAILURE","completedAt":"2026-06-01T00:05:00Z"}]}]
J
SH
watch
check "eventos: watch sai com código 0"                  [ "$RC" -eq 0 ]
check "eventos: linha de base não grava nada no log"     [ ! -s "$FAKE/log.p1" ]
check "eventos: stdout tem o PR aberto"                  grep -q '\[pr\] PR #12 aberto' <<<"$OUT"
check "eventos: log tem a sessão idle"                   logged "[sessao] #7 foo: idle (PR #12 open)"
check "eventos: log tem o PR aberto"                     logged "[pr] PR #12 aberto (issue #7) https://github.com/x/y/pull/12"
check "eventos: log tem o CI vermelho"                   logged "[ci] PR #12 · test: fail"
check "eventos: log tem o fechamento da rodada"          logged "[rodada] swarm-test fechada (oute-swarm close --all); watch encerrado"
check "eventos: log = stdout, na mesma ordem"            [ "$(log_events)" == "$(out_events)" ]
check "eventos: timestamp UTC completo em toda linha"    [ -n "$(wlog)" -a -z "$(wlog | grep -Ev "$LOGRE")" ]

# 2. watch reiniciado sem mudança: compara com o último estado salvo e não repete o que já foi gravado
before="$(log_events)"
watch
check "reinício: código 0"                               [ "$RC" -eq 0 ]
check "reinício: nenhum evento repetido"                 [ "$(count "[pr] PR #12 aberto (issue #7) https://github.com/x/y/pull/12")$(count "[ci] PR #12 · test: fail")$(count "[sessao] #7 foo: idle (PR #12 open)")" == 111 ]
check "reinício: só o fechamento novo entrou no log"     [ "$(log_events)" == "$before"$'\n'"[rodada] swarm-test fechada (oute-swarm close --all); watch encerrado" ]

# 3. o log é o mesmo do tell: registros de outros comandos continuam lá
CASE=convive; round "$CASE"
echo "2026-01-01T00:00:02Z tell 7-foo ok" > "$STATE/log"
watch
check "convive: registro do tell preservado"             [ "$(head -1 "$STATE/log")" == "2026-01-01T00:00:02Z tell 7-foo ok" ]
check "convive: evento do watch anexado"                 logged "[rodada] swarm-test fechada (oute-swarm close --all); watch encerrado"

# 4. sessão parada sem PR: "(sem PR)", sem repetir nada
CASE=sempr; round "$CASE"
echo 'fake-tabs blocked' > "$FAKE/on-sleep-1"
watch
check "sem PR: evento da sessão"                         logged "[sessao] #7 foo: blocked (sem PR)"

printf '\n%d ok, %d falha(s)\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
