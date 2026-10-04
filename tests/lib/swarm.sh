# Apoio dos tests/oute-swarm-<tema>.test.sh (#425): `herdr`, `gh`, `sleep` e `oute-task` falsos no PATH, e as funções
# que todo tema usa (round, sw, watch, log_events…). Para `source` depois de definir ROOT, SWARM, TMP e carregar check.sh.
# O que só um tema usa fica no próprio tema.
[[ -x "$SWARM" ]] || { echo "FAIL oute-swarm ausente ou sem +x: $SWARM"; exit 1; }
command -v jq >/dev/null || { echo "FAIL precisa de jq"; exit 1; }

# ---------------------------------------------------------------- fakes
BIN="$TMP/bin"; mkdir -p "$BIN"
# herdr: listas lidas de $FAKE/*.json; ações anotadas em $FAKE/herdr.log. `tab create` devolve o JSON do herdr
# com ids no workspace pedido, ou $FAKE/tab-create.out, se existir (saída quebrada, #276); $FAKE/tabs-after.json, se
# existir, vira o `tab list` de depois do `tab create` (a aba nova na lista, #289). O campo de entrada do pane é
# $FAKE/field (send-text escreve, pane read mostra entre réguas como o Claude Code, ctrl+c limpa).
cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/herdr.log"
case "$1 ${2:-}" in
  "tab list") cat "$FAKE/tabs.json" ;;
  "tab create") n=$(( $(cat "$FAKE/tabs.n" 2>/dev/null || echo 1) + 1 )); echo "$n" > "$FAKE/tabs.n"
                [[ ! -e "$FAKE/tabs-after.json" ]] || mv "$FAKE/tabs-after.json" "$FAKE/tabs.json"
                [[ ! -e "$FAKE/tab-create.out" ]] || { cat "$FAKE/tab-create.out"; exit 0; }
                w="$4"   # --workspace <id>: o formato real do herdr 0.9 (root_pane e tab no result, #276)
                echo "{\"id\":\"cli:tab:create\",\"result\":{\"root_pane\":{\"pane_id\":\"$w:p$n\",\"tab_id\":\"$w:t$n\"},\"tab\":{\"tab_id\":\"$w:t$n\",\"label\":\"x\"}}}" ;;
  "tab close") [[ ! -e "$FAKE/tab-close.fail" ]] || exit 1 ;;
  "pane list") cat "$FAKE/panes.json" 2>/dev/null || echo '{"result":{"panes":[]}}' ;;
  "pane run") ;;
  "pane read") printf '%s\n❯ %s\n%s\n' "──────────────────" "$(cat "$FAKE/field" 2>/dev/null)" "──────────────────" ;;
  "pane send-text") printf '%s' "$4" > "$FAKE/field" ;;
  "pane send-keys") [[ "$4" != ctrl+c ]] || : > "$FAKE/field" ;;
  "agent list") cat "$FAKE/agents.json" 2>/dev/null || echo '{"result":{"agents":[]}}' ;;
  *) echo "herdr falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
# gh: `pr list` devolve $FAKE/prs-<nome da pasta do repo>.json (o watch roda o gh dentro do repo). `api graphql`
# (checks de um commit, #266) devolve $FAKE/checks-<sha>.json, falha se existir $FAKE/checks-<sha>.fail e anota
# cada leitura em $FAKE/gh.log (<pasta do repo> <sha>)
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr list") cat "$FAKE/prs-$(basename "$PWD").json" 2>/dev/null || echo '[]' ;;
  "api graphql") oid=""; for a in "$@"; do [[ "$a" != oid=* ]] || oid="${a#oid=}"; done
                 echo "$(basename "$PWD") $oid" >> "$FAKE/gh.log"
                 [[ ! -e "$FAKE/checks-$oid.fail" ]] || { echo "gh falso: falha pedida" >&2; exit 1; }
                 cat "$FAKE/checks-$oid.json" 2>/dev/null || echo '{"data":{"repository":{"object":null}}}' ;;
  "issue view") exec bash "$TESTLIB/fake-gh-issue.sh" "$@" ;;   # labels da issue, para o seletor (#219)
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
cat > "$BIN/oute-task" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == list ]] && echo "(worktrees falsas)"
# o último argumento (prompt da rodada, na abertura) fica em $FAKE/oute-task.last; os anteriores, em oute-task.args
[[ -z "${FAKE:-}" ]] || { printf '%s' "${@: -1}" > "$FAKE/oute-task.last"; printf '%s\n' "${@:1:$#-1}" > "$FAKE/oute-task.args"; }
exit 0
SH
# sleep: só no watch (FAKE_WATCH=1) é o gancho entre passadas; nos outros comandos não faz nada
cat > "$BIN/sleep" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_TELLWAIT:-}" ]]; then   # espera do `tell --wait` (#181): $FAKE/on-tsleep-<n> muda o estado; sem gancho, passa 0,2 s de verdade
  n=$(( $(cat "$FAKE/tsleeps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/tsleeps"
  if [[ -f "$FAKE/on-tsleep-$n" ]]; then . "$FAKE/on-tsleep-$n"; else /bin/sleep 0.2; fi
  exit 0
fi
[[ -n "${FAKE_WATCH:-}" ]] || exit 0
n=$(( $(cat "$FAKE/sleeps" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/sleeps"
if [[ -f "$FAKE/on-sleep-$n" ]]; then . "$FAKE/on-sleep-$n"; else date -u +%FT%TZ > "$STATE/fechada"; fi
SH
# fake-tabs [<label>=]<status>...: abas w1:t1, w1:t2… com o agente em <status> (label padrão "#7 foo");
# usável nos ganchos on-sleep-<n>
cat > "$BIN/fake-tabs" <<'SH'
#!/usr/bin/env bash
i=0; for a in "$@"; do
  i=$((i + 1)); [[ "$a" == *=* ]] || a="#7 foo=$a"
  jq -n --arg id "w1:t$i" --arg l "${a%=*}" --arg s "${a##*=}" '{tab_id: $id, label: $l, agent_status: $s}'
done | jq -s '{result: {tabs: .}}' > "$FAKE/tabs.json"
SH
chmod +x "$BIN"/*
# seletor de modelo (#219): o oute-select de verdade, com a tabela do repo, em todas as seções (o resultado não pode
# depender de haver um oute-select no PATH de quem roda o teste). Issue sem $FAKE/labels-<n> = o gh não acha a issue:
# a sessão abre no padrão (Sonnet), com aviso em stderr
ln -s "$ROOT/docker/oute-select" "$BIN/oute-select"
# `claude`/`codex` falsos (#258): o oute-select checa `claude auth status` para a reserva; sem eles, o resultado dependeria
# do claude de quem roda o teste
cp "$ROOT/tests/lib/fake-agent.sh" "$BIN/claude"; cp "$ROOT/tests/lib/fake-agent.sh" "$BIN/codex"
# o gatilho de cota do seletor (#355) lê o oute-quota: o falso (cota folgada), nunca o de verdade; a seção 12 troca por um que repassa ao dela
cp "$ROOT/tests/lib/fake-oute-quota.sh" "$BIN/oute-quota"
export TESTLIB="$ROOT/tests/lib" OUTE_SELECT_TABLE="$ROOT/config/select/models.toml"
unset OUTE_SELECT_FILE OUTE_SELECT_GH_TIMEOUT
# Jev (#257): sem a chave e o endereço da TypeSafe de verdade no ambiente; só a seção 11e sobe a falsa
. "$ROOT/tests/lib/typesafe.sh"; ts_off

# round(<caso>): HOME, rodada swarm-test (repo da rodada = pasta git "repo", início no passado) e $FAKE limpos;
# issue #7 aberta na aba "#7 foo" (linha do spawned no formato antigo, sem repo). Globais: H, STATE, FAKE, REPO.
# As issues #1 a #20 têm o label aidlc:build (o seletor abre no Sonnet, sem aviso); a seção 11 troca os labels.
round() {
  H="$TMP/$1/home"; STATE="$H/.oute/swarm/swarm-test"; FAKE="$TMP/$1/fake"; REPO="$TMP/$1/repo"
  mkdir -p "$STATE" "$FAKE" "$TMP/$1/inbox" "$TMP/$1/outbox"
  local i; for i in $(seq 1 20); do echo aidlc:build > "$FAKE/labels-$i"; done
  gitrepo "$REPO"
  printf 'repo=%s\nmax=3\nlabel=\nstarted=2026-01-01T00:00:00Z\n' "$REPO" > "$STATE/meta"
  printf '7-foo w1:p1 claude 2026-01-01T00:00:01Z w1:t1\n' > "$STATE/spawned"
  FAKE="$FAKE" "$BIN/fake-tabs" working
}
gitrepo() { mkdir -p "$1" && git -C "$1" init -q 2>/dev/null; }
# sw <args>: roda o oute-swarm como o dispatcher da rodada (dentro do herdr); stdout em $OUT, stderr em $ERR
sw() {
  OUT="$(env PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID="${WS:-w1}" \
         OUTE_SWARM_ID=swarm-test OUTE_SWARM_REPO="$REPO" OUTE_SWARM_MAX="${MAX:-3}" \
         "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
# roda o watch até a rodada fechar; stdout em $OUT, stderr em $ERR, código em $RC
watch() {
  local g=(); command -v timeout >/dev/null && g=(timeout 30)
  rm -f "$FAKE/sleeps" "$STATE/fechada"
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" STATE="$STATE" FAKE_WATCH=1 \
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


# swc <dir> <args>: roda o oute-swarm em <dir> sem OUTE_SWARM_ID/REPO/MAX no ambiente (WATCHING=1: o sleep falso vira
# o gancho do watch). coord <dir> <branch>: pasta git com o HEAD em <branch>.
swc() {
  local d="$1" g=(); shift; command -v timeout >/dev/null && g=(timeout 30)
  OUT="$(cd "$d" && env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" \
         STATE="$STATE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 ${WATCHING:+FAKE_WATCH=1} \
         OUTE_INBOX="$TMP/$CASE/inbox" OUTE_OUTBOX="$TMP/$CASE/outbox" \
         ${g[@]+"${g[@]}"} "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
coord() { gitrepo "$1" && git -C "$1" symbolic-ref HEAD "refs/heads/$2"; }
ASSUME='OUTE_SWARM_ID ausente; assumindo a rodada swarm-test (worktree do dispatcher)'

# opn <args>: abre o dispatcher no repo da rodada de teste (HOME do caso); stdout em $OUT, stderr em $ERR.
# so_teste: nenhuma rodada nova nem oute-task chamado. sp_agent <rodada> <slug>: agente gravado no spawned
opn() {
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" \
         OUTE_LIB="$ROOT/docker" HERDR_ENV=1 "$SWARM" "$REPO" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
nova() { ls "$H/.oute/swarm" | grep -v '^swarm-test$' | head -1; }
so_teste() { [ "$(ls "$H/.oute/swarm")" == swarm-test ] && [ ! -e "$FAKE/oute-task.last" ]; }
sp_agent() { awk -v s="$2" '$1 == s {print $3}' "$H/.oute/swarm/$1/spawned"; }
ran() { grep -qF -- "oute-task -r $REPO $1 $2 " "$FAKE/herdr.log"; }

# sel <slug> <campo>: campo do <slug>.select da rodada (a escolha que o spawn resolveu e entrega ao oute-task).
# cmd <slug>: a linha que o spawn mandou rodar no pane
sel() { jq -r --arg k "$2" '.[$k]' "$STATE/$1.select" 2>/dev/null; }
cmd() { grep -- " oute-task -r [^ ]* $1 " "$FAKE/herdr.log" | tail -1; }
labels() { local n="$1"; shift; printf '%s\n' "$@" > "$FAKE/labels-$n"; }

# closes: quantos `tab close` o herdr falso recebeu
closes() { grep -c 'tab close' "$FAKE/herdr.log"; }
