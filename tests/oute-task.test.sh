#!/usr/bin/env bash
# Testes das sessões do oute-task no bucket (#128, ADR-04 "Sessões"): eventos oute.task.* e a marca da sessão nas
# conversas. Bash puro + python3/jq, sem Docker nem rede. Repos git de verdade num diretório temporário, com remote
# bare local.
# Costura 1: receptor OTLP/HTTP falso (tests/lib/otlp.sh) no OTEL_EXPORTER_OTLP_ENDPOINT.
# Costura 2: `claude` e `codex` falsos no PATH, que gravam o próprio ambiente, o diretório e os argumentos e saem: é o
# que o oute-task executa no fim, e o shim também, no restore. `gh` falso para o "PR mergeado".
# Só comportamento externo: o que chega ao receptor, o ambiente que o agente recebe, a saída e o código de saída.
# Uso: tests/oute-task.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"
trap 'rcv_stop; chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v python3 >/dev/null && command -v git >/dev/null || die "precisa de jq, python3 e git"
TASK="$ROOT/docker/oute-task"
[[ -x "$TASK" ]] || die "oute-task ausente ou sem +x: $TASK"

# ---------------------------------------------------------------- fakes e ambiente
BIN="$TMP/bin"; NOEMIT="$TMP/bin-noemit"; NOTASK="$TMP/bin-notask"; SHIMS="$TMP/shims"
FAKE="$TMP/fake"; WS="$TMP/ws"; WT="$TMP/wt"
mkdir -p "$BIN" "$NOEMIT" "$NOTASK" "$SHIMS" "$FAKE" "$WS" "$TMP/home"
# agente falso: grava o ambiente, o diretório e os argumentos em $FAKE/<agente>.* e sai com $FAKE_RC
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
n="$(basename "$0")"
env > "$FAKE/$n.env"; pwd -P > "$FAKE/$n.pwd"; printf '%s\n' "$@" > "$FAKE/$n.args"
echo "agente falso $n"
exit "${FAKE_RC:-0}"
SH
cp "$BIN/claude" "$BIN/codex"
# gh: `pr list --head <branch> …` responde 1 se o branch está em $FAKE/merged
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "pr list") br=""; while [[ $# -gt 0 ]]; do [[ "$1" != --head ]] || br="$2"; shift; done
             if grep -qxF "$br" "$FAKE/merged" 2>/dev/null; then echo 1; else echo 0; fi ;;
  "issue view") exec bash "$TESTLIB/fake-gh-issue.sh" "$@" ;;   # labels da issue, para o seletor (#219)
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
chmod +x "$BIN"/*
cp "$BIN/claude" "$BIN/codex" "$BIN/gh" "$NOEMIT/"; cp "$BIN/claude" "$NOTASK/"
# seletor de modelo (#219): o oute-select de verdade, com a tabela do repo, nas seções todas (o resultado não pode
# depender de haver um oute-select no PATH de quem roda o teste)
ln -s "$ROOT/docker/oute-select" "$BIN/oute-select"; ln -s "$ROOT/docker/oute-select" "$NOEMIT/oute-select"
# herdr: `workspace get <id>` responde o label da linha "<id> <label>" de $FAKE/spaces; id desconhecido sai com erro
cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
[[ "$1 ${2:-}" == "workspace get" ]] || { echo "herdr falso: sem suporte a '$*'" >&2; exit 1; }
l="$(awk -v id="${3:-}" '$1 == id {sub(/^[^ ]* /, ""); print; exit}' "$FAKE/spaces" 2>/dev/null)"
[[ -n "$l" ]] || { echo "workspace not found" >&2; exit 1; }
jq -cn --arg id "$3" --arg l "$l" '{id: "cli:workspace:get", result: {type: "workspace_info", workspace: {label: $l, workspace_id: $id}}}'
SH
chmod +x "$BIN/herdr"
ln -s "$ROOT/docker/oute-emit" "$BIN/oute-emit"
ln -s "$TASK" "$BIN/oute-task"; ln -s "$TASK" "$NOEMIT/oute-task"   # o shim chama `oute-task --mark`
for a in claude codex; do ln -s "$ROOT/docker/shims/oute-agent-shim" "$SHIMS/$a"; done

ORIGIN="host.name=oute-mac,oute.instance=oute-agent,deployment.environment=oute-mac"
unset CLAUDECODE CODEX_THREAD_ID OUTE_SWARM_ID OUTE_SWARM_ROUND OUTE_SWARM_WORKER OUTE_SWARM_MAX OUTE_SWARM_REPO \
      OUTE_NO_WORKTREE OUTE_EMIT_DEBUG CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CONFIG_DIR CODEX_HOME FAKE_RC \
      HERDR_ENV HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_SOCKET_PATH OTEL_EXPORTER_OTLP_LOGS_ENDPOINT
unset OUTE_SELECT_FILE OUTE_SELECT_GH_TIMEOUT
export PATH="$BIN:$PATH" HOME="$TMP/home" FAKE OUTE_WORKTREES="$WT" OUTE_WORKSPACE="$WS" OTEL_RESOURCE_ATTRIBUTES="$ORIGIN" \
       TESTLIB="$ROOT/tests/lib" OUTE_SELECT_TABLE="$ROOT/config/select/models.toml" \
       GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1

# checkout principal em $WS/proj, com remote bare local e origin/HEAD em main
git init -q --bare -b main "$TMP/remote.git"
git init -q -b main "$TMP/seed" && git -C "$TMP/seed" commit -q --allow-empty -m base \
  && git -C "$TMP/seed" push -q "$TMP/remote.git" main && git clone -q "$TMP/remote.git" "$WS/proj" || die "não montei o repo de teste"

# t <args…>: oute-task no checkout principal, sem terminal; stdout em $OUT, stderr em $ERR, código em $RC.
# Os avisos do seletor (#219: slug sem issue abre no padrão, com aviso) saem do $ERR e ficam em $SELW: as seções 1 a 9
# conferem o resto do stderr, e a seção 10 confere os avisos.
t() {
  OUT="$(cd "$WS/proj" && "$TASK" "$@" 2>"$TMP/err" </dev/null)"; RC=$?
  ERR="$(grep -v '^oute-select: aviso: ' "$TMP/err")"; SELW="$(grep '^oute-select: aviso: ' "$TMP/err")"
}
MS="--model claude-sonnet-5-5"   # o que o seletor põe na frente dos argumentos do claude, no padrão
# shim <agente> <dir> <args…>: o shim do agente em <dir>, sem terminal
shim() { local a="$1" d="$2"; shift 2; OUT="$(cd "$d" && PATH="$SHIMS:$PATH" "$SHIMS/$a" "$@" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"; }
gitdir() { git -C "$1" rev-parse --path-format=absolute --git-dir; }
mark() { sed -n "s/^$2=//p" "$(gitdir "$1")/oute-task" 2>/dev/null; }   # <worktree> <chave> da marca da sessão
aenv() { sed -n "s/^$2=//p" "$FAKE/$1.env"; }                            # <agente> <variável> que o agente recebeu
task_ev() { ev "(.name | startswith(\"oute.task.\")) and ($1)"; }
last() { task_ev true | tail -n1; }                                      # último evento de sessão recebido
total() { n '.name | startswith("oute.task.")'; }

SP="$WT/_sem-space"   # fora do herdr, as worktrees ficam em _sem-space (#277); seções 1 a 8

# ---------------------------------------------------------------- 1. abertura e reabertura
rcv_start "$TMP/r1"
FAKE_RC=7 t s1 claude "faça x"
check "abrir: exec do agente (saída e código dele)"    [ "$RC" -eq 7 -a "$OUT" == "agente falso claude" ]
check "abrir: stderr só com a linha da worktree"       [ "$ERR" == "worktree $SP/proj-s1 · branch sessao/s1 (de origin/main)" ]
check "abrir: agente na worktree, com o prompt"        [ "$(cat "$FAKE/claude.pwd")" == "$(cd "$SP/proj-s1" && pwd -P)" -a "$(cat "$FAKE/claude.args")" == "${MS/ /$'\n'}"$'\n'"faça x" ]
id="$(mark "$SP/proj-s1" id)"
check "abrir: id <repo>-<slug>-<AAAAMMDDhhmmss> no git-dir da worktree" grep -qE '^proj-s1-[0-9]{14}$' <<<"$id"
e="$(task_ev '.name == "oute.task.opened"')"
check "abrir: um oute.task.opened"                     [ "$(grep -c . <<<"$e")" -eq 1 -a "$(total)" -eq 1 ]
check "opened: id, repo, slug, agente e base"          jqe --arg id "$id" '.attrs["oute.task.id"] == $id and .attrs["oute.task.repo"] == "proj"
                                                         and .attrs["oute.task.slug"] == "s1" and .attrs["oute.task.agent"] == "claude"
                                                         and .attrs["oute.task.base"] == "main"' <<<"$e"
check "opened: sessão avulsa (sem oute.swarm.*) e sem legacy" jqe '(.attrs | has("oute.swarm.round") or has("oute.swarm.session") or has("oute.task.legacy")) | not' <<<"$e"
check "opened: sem terminal e sem marcador = unknown"  jqe '.attrs["oute.agent"] == "unknown" and .res["oute.agent"] == "unknown"' <<<"$e"
check "opened: origem, service.name=oute, id do evento" jqe '.res["host.name"] == "oute-mac" and .res["oute.instance"] == "oute-agent"
                                                         and .res["service.name"] == "oute" and (.attrs["oute.event.id"] | length) == 32' <<<"$e"
check "marca: origem preservada + oute.task.*"         [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1" ]
check "abrir: o agente passa pelo shim sem nova worktree" [ "$(aenv claude OUTE_NO_WORKTREE)" == 1 ]

t s1 codex
check "reabrir: código 0, saída do agente"             [ "$RC" -eq 0 -a "$OUT" == "agente falso codex" -a "$ERR" == "reabrindo $SP/proj-s1 (sessao/s1)" ]
e="$(task_ev '.name == "oute.task.reopened"')"
check "reabrir: um oute.task.reopened"                [ "$(grep -c . <<<"$e")" -eq 1 ]
check "reabrir: reopened com o mesmo id"               jqe --arg id "$id" '.attrs["oute.task.id"] == $id' <<<"$e"
check "reopened: agente da sessão codex, base, sem legacy" jqe '.attrs["oute.task.agent"] == "codex" and .attrs["oute.task.base"] == "main" and (.attrs | has("oute.task.legacy") | not)' <<<"$e"
check "reabrir: id não muda na worktree"               [ "$(mark "$SP/proj-s1" id)" == "$id" ]
check "marca no Codex: a mesma"                        [ "$(aenv codex OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1" ]

# marca de outra sessão no ambiente de quem chamou: a chave não se repete, vale a nova; o evento leva só a origem
OTEL_RESOURCE_ATTRIBUTES="$ORIGIN,oute.task.id=velho,oute.swarm.round=velha, oute.task.slug=x" t s1 claude
check "marca: chave que já existia não duplica"        [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1" ]
check "evento: resource sem a marca de quem chamou"    jqe --arg id "$id" '.attrs["oute.task.id"] == $id and (.attrs | has("oute.swarm.round") | not)
                                                         and (.res | has("oute.task.id") or has("oute.swarm.round") or has("oute.task.slug") | not)
                                                         and .res["host.name"] == "oute-mac"' <<<"$(last)"
( unset OTEL_RESOURCE_ATTRIBUTES; t s1 claude )
check "marca: sem origem no ambiente, só oute.task.*"  [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1" ]
t s1 shell </dev/null >/dev/null 2>&1
check "shell: oute.task.agent=shell"                   jqe '.name == "oute.task.reopened" and .attrs["oute.task.agent"] == "shell"' <<<"$(last)"

# ---------------------------------------------------------------- 2. sessão de rodada (oute.swarm.*)
mkdir -p "$HOME/.oute/swarm/swarm-0101-0000"; printf 'repo=%s\nmax=3\nagent=codex\n' "$WS/proj" > "$HOME/.oute/swarm/swarm-0101-0000/meta"
OUTE_SWARM_WORKER=1 OUTE_SWARM_ROUND=swarm-0101-0000 t 7-foo claude "instrução"
wid="$(mark "$SP/proj-7-foo" id)"
e="$(last)"
check "worker: opened com a rodada e a sessão"         jqe --arg id "$wid" '.name == "oute.task.opened" and .attrs["oute.task.id"] == $id
                                                         and .attrs["oute.swarm.round"] == "swarm-0101-0000" and .attrs["oute.swarm.session"] == "7-foo"' <<<"$e"
check "worker: quem chamou = agente do dispatcher (meta)" jqe '.attrs["oute.agent"] == "codex" and .res["oute.agent"] == "codex"' <<<"$e"
WMARK="$ORIGIN,oute.task.id=$wid,oute.task.repo=proj,oute.task.slug=7-foo,oute.swarm.round=swarm-0101-0000,oute.swarm.session=7-foo"
check "worker: marca com oute.task.* e oute.swarm.*"   [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$WMARK" ]
check "worker: sugestão de prompt continua desligada"  [ "$(aenv claude CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION)" == false -a -f "$(gitdir "$SP/proj-7-foo")/oute-swarm-worker" ]
t 7-foo claude
check "worker reaberto sem o ambiente: rodada vem da worktree" jqe --arg id "$wid" '.name == "oute.task.reopened" and .attrs["oute.task.id"] == $id
                                                         and .attrs["oute.swarm.round"] == "swarm-0101-0000" and .attrs["oute.swarm.session"] == "7-foo"' <<<"$(last)"
check "worker reaberto: mesma marca"                   [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$WMARK" ]
OUTE_SWARM_ID=swarm-0202-0000 OUTE_SWARM_MAX=3 OUTE_SWARM_REPO="$WS/proj" t swarm-0202-0000 claude
cid="$(mark "$SP/proj-swarm-0202-0000" id)"
check "dispatcher: rodada sem sessão; chamou = claude (rodada sem meta)" jqe '.name == "oute.task.opened" and .attrs["oute.swarm.round"] == "swarm-0202-0000"
                                                         and (.attrs | has("oute.swarm.session") | not) and .attrs["oute.agent"] == "claude"' <<<"$(last)"
check "dispatcher: marca com a rodada"               [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$cid,oute.task.repo=proj,oute.task.slug=swarm-0202-0000,oute.swarm.round=swarm-0202-0000" ]
OUTE_SWARM_WORKER=1 t 8-sem-rodada claude
check "worker de spawn fora de rodada: sessão avulsa"  jqe '.name == "oute.task.opened" and (.attrs | has("oute.swarm.round") or has("oute.swarm.session") | not) and .attrs["oute.agent"] == "claude"' <<<"$(last)"

# ---------------------------------------------------------------- 3. oute.agent = quem chamou
CLAUDECODE=1 t s1 claude
check "quem chamou: CLAUDECODE=1 = claude"             jqe '.attrs["oute.agent"] == "claude" and .attrs["oute.task.agent"] == "claude"' <<<"$(last)"
CODEX_THREAD_ID=th-1 t s1 claude
check "quem chamou: CODEX_THREAD_ID = codex (agente da sessão claude)" jqe '.attrs["oute.agent"] == "codex" and .attrs["oute.task.agent"] == "claude"' <<<"$(last)"
CLAUDECODE=1 OUTE_SWARM_WORKER=1 OUTE_SWARM_ROUND=swarm-0101-0000 t 7-foo claude
check "quem chamou: marcador do agente ganha do ambiente do swarm" jqe '.attrs["oute.agent"] == "claude"' <<<"$(last)"
OUTE_SWARM_ID=../../etc t s1 claude
check "rodada inválida no ambiente: não é lida nem vira oute.swarm.round" jqe '.attrs["oute.agent"] == "claude" and (.attrs | has("oute.swarm.round") | not)' <<<"$(last)"
t s1 claude
check "quem chamou: sem terminal e sem marcador = unknown" jqe '.attrs["oute.agent"] == "unknown"' <<<"$(last)"
if ! has_pty; then
  echo "skip human: sem script(1) do util-linux"
else
  script -qec "cd $WS/proj && $TASK s1 claude" /dev/null >/dev/null 2>&1
  check "quem chamou: terminal sem marcador = human"   jqe '.name == "oute.task.reopened" and .attrs["oute.agent"] == "human"' <<<"$(last)"
  CLAUDECODE=1 script -qec "cd $WS/proj && $TASK s1 claude" /dev/null >/dev/null 2>&1
  check "quem chamou: terminal com marcador = o agente" jqe '.attrs["oute.agent"] == "claude"' <<<"$(last)"
fi

# ---------------------------------------------------------------- 4. worktree sem id (anterior à #128) e falha ao gravar
t old claude; rm -f "$(gitdir "$SP/proj-old")/oute-task"
t old claude
oid="$(mark "$SP/proj-old" id)"
check "sem id: a reabertura grava um id novo"          grep -qE '^proj-old-[0-9]{14}$' <<<"$oid"
check "sem id: reopened com legacy=true e o id novo"   jqe --arg id "$oid" '.name == "oute.task.reopened" and .attrs["oute.task.id"] == $id and .attrs["oute.task.legacy"] == true' <<<"$(last)"
check "sem id: a conversa já sai marcada"              [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$oid,oute.task.repo=proj,oute.task.slug=old" ]
t old claude
check "sem id: na reabertura seguinte, mesmo id e sem legacy" jqe --arg id "$oid" '.attrs["oute.task.id"] == $id and (.attrs | has("oute.task.legacy") | not)' <<<"$(last)"
t nogravo claude; t fixa claude; fid="$(mark "$SP/proj-fixa" id)"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip falha ao gravar o id: rodando como root (o chmod não barra a escrita)"
else
  gd="$(gitdir "$SP/proj-nogravo")"; rm -f "$gd/oute-task"; chmod a-w "$gd"
  FAKE_RC=5 OTEL_RESOURCE_ATTRIBUTES="$ORIGIN,oute.task.id=de-outra" t nogravo claude "segue"
  chmod u+w "$gd"
  check "falha ao gravar o id: a sessão abre igual (exec e código)" [ "$RC" -eq 5 -a "$OUT" == "agente falso claude" -a "$(cat "$FAKE/claude.args")" == "${MS/ /$'\n'}"$'\n'"segue" ]
  check "falha ao gravar o id: só uma linha a mais no stderr" [ "$(grep -c . <<<"$ERR")" -eq 2 ]
  check "falha ao gravar o id: reabre a worktree"      grep -q "^reabrindo $SP/proj-nogravo " <<<"$ERR"
  check "falha ao gravar o id: a linha a mais é o aviso" grep -q '^aviso: não consegui gravar o id da sessão' <<<"$ERR"
  check "falha ao gravar o id: conversa sem marca (nem a de outra sessão)" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN" ]
  check "falha ao gravar o id: reopened sem id e sem legacy" jqe '.name == "oute.task.reopened" and .attrs["oute.task.slug"] == "nogravo" and (.attrs | has("oute.task.id") or has("oute.task.legacy") | not)' <<<"$(last)"
  # marca que já tem id e não aceita a rodada nova: o id fica, sem aviso; a rodada vale nesta abertura
  chmod a-w "$(gitdir "$SP/proj-fixa")/oute-task"
  OUTE_SWARM_ID=swarm-0303-0000 t fixa claude
  chmod u+w "$(gitdir "$SP/proj-fixa")/oute-task"
  check "falha ao atualizar a marca: abre igual, sem aviso" [ "$RC" -eq 0 -a "$ERR" == "reabrindo $SP/proj-fixa (sessao/fixa)" ]
  check "falha ao atualizar a marca: o id fica, com a rodada do ambiente" jqe --arg id "$fid" '.attrs["oute.task.id"] == $id and .attrs["oute.swarm.round"] == "swarm-0303-0000"' <<<"$(last)"
  check "falha ao atualizar a marca: a marca segue com o id, sem rodada" [ "$(mark "$SP/proj-fixa" id)" == "$fid" -a -z "$(mark "$SP/proj-fixa" round)" ]
fi

# ---------------------------------------------------------------- 5. shim: restore do herdr e agente aberto na worktree
before="$(total)"
mkdir -p "$HOME/.claude/projects/p" "$HOME/.codex/sessions/2026"
printf '{"type":"user","cwd":"%s"}\n' "$SP/proj-s1" > "$HOME/.claude/projects/p/conv-s1.jsonl"
printf '{"type":"user","cwd":"%s"}\n' "$SP/proj-7-foo" > "$HOME/.claude/projects/p/conv-w.jsonl"
printf '{"type":"user","cwd":"%s"}\n' "$SP/proj-s1" > "$HOME/.codex/sessions/2026/rollout-2026-conv-cx.jsonl"
shim claude "$WS/proj" --resume conv-s1
check "restore: claude --resume entra na worktree"     [ "$RC" -eq 0 -a "$(cat "$FAKE/claude.pwd")" == "$(cd "$SP/proj-s1" && pwd -P)" ]
check "restore: a mesma marca do oute-task"            [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1" ]
shim claude "$WS/proj" --resume conv-w
check "restore de worker: marca com oute.swarm.*"      [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$WMARK" -a "$(aenv claude CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION)" == false ]
shim codex "$WS/proj" resume conv-cx
check "restore do Codex: codex resume <id> marcado"    [ "$(cat "$FAKE/codex.pwd")" == "$(cd "$SP/proj-s1" && pwd -P)" -a "$(aenv codex OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1" ]
shim claude "$SP/proj-s1" -p "oi"
check "agente aberto direto na worktree (-p): marcado" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1" -a "$(cat "$FAKE/claude.args")" == "$(printf -- '-p\noi')" ]
t semid claude; rm -f "$(gitdir "$SP/proj-semid")/oute-task"; before=$((before + 1))
printf '{"type":"user","cwd":"%s"}\n' "$SP/proj-semid" > "$HOME/.claude/projects/p/conv-semid.jsonl"
shim claude "$WS/proj" --resume conv-semid
check "restore em worktree sem id: sem marca"          [ "$(cat "$FAKE/claude.pwd")" == "$(cd "$SP/proj-semid" && pwd -P)" -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN" ]
shim claude "$WS/proj" -p "no checkout principal"
check "checkout principal: sem marca"                  [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN" ]
shim claude "$TMP" -p "fora de repo"
check "fora de repo: sem marca"                        [ "$RC" -eq 0 -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN" ]
OUT="$(cd "$SP/proj-s1" && PATH="$SHIMS:$NOTASK:/usr/bin:/bin" "$SHIMS/claude" -p "sem oute-task" 2>&1 </dev/null)"; RC=$?
check "shim sem oute-task no PATH: abre igual, sem marca" [ "$RC" -eq 0 -a "$OUT" == "agente falso claude" -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN" ]
check "shim: não emite evento"                         [ "$(total)" -eq "$before" ]
OUT="$(cd "$WS/proj" && "$TASK" --mark 2>&1; cd "$TMP" && "$TASK" --mark 2>&1; "$TASK" --mark /nao/existe 2>&1)"; RC=$?
check "--mark fora de worktree com id: nada, código 0" [ "$RC" -eq 0 -a -z "$OUT" ]
check "--mark: não cria worktree"                      [ ! -e "$SP/proj-mark" -a ! -e "$SP/proj--mark" ]

check "nenhum oute.task.* com corpo (1ª parte)"        [ "$(task_ev '.body != null' | grep -c .)" -eq 0 -a "$(total)" -gt 10 ]
rcv_stop

# ---------------------------------------------------------------- 6. clean: removed com o motivo; simulação e list não emitem
rcv_start "$TMP/r2"
# s1: commit com PR mergeado; old: detached contida na base; 7-foo, swarm-0202-0000, 8-sem-rodada, nogravo, fixa: sem commits;
# semid: sem id e sem commits; fica1: mudança local; fica2: commit sem PR mergeado
git -C "$SP/proj-s1" commit -q --allow-empty -m entrega; echo "sessao/s1" > "$FAKE/merged"
git -C "$SP/proj-old" checkout -q --detach origin/main
t fica1 claude; echo x > "$SP/proj-fica1/novo.txt"
t fica2 claude; git -C "$SP/proj-fica2" commit -q --allow-empty -m "sem PR"
base_n="$(total)"
t list
check "list: lista as worktrees e não emite"           [ "$RC" -eq 0 -a "$(grep -c "^$SP/proj-" <<<"$OUT")" -eq 10 -a "$(total)" -eq "$base_n" ]
t clean
check "fora do herdr: clean só no _sem-space (#277)"   [ "$(head -n1 <<<"$OUT")" == "space _sem-space ($SP)" ]
check "simulação: mostra o que removeria"              grep -qx "remover $SP/proj-s1 (PR mergeado)" <<<"$OUT"
check "simulação: diz como aplicar"                    grep -qx "(simulação — rode 'oute-task clean --yes' para aplicar)" <<<"$OUT"
check "simulação: não remove e não emite"              [ -d "$SP/proj-s1" -a -d "$SP/proj-old" -a "$(total)" -eq "$base_n" ]
CLAUDECODE=1 t clean --yes
check "clean --yes: código 0, 11 linhas, stderr vazio" [ "$RC" -eq 0 -a "$(grep -c . <<<"$OUT")" -eq 11 -a -z "$ERR" ]
check "clean --yes: removida a do PR mergeado"         grep -qx "removida $SP/proj-s1 (PR mergeado)" <<<"$OUT"
check "clean --yes: removida a detached"               grep -qx "removida $SP/proj-old (detached, contida em origin/main)" <<<"$OUT"
check "clean --yes: removida a sem commits"            grep -qx "removida $SP/proj-7-foo (sem commits além de origin/main)" <<<"$OUT"
check "clean --yes: mantém a com mudanças locais"      grep -qx "mantém  $SP/proj-fica1 (mudanças locais)" <<<"$OUT"
check "clean --yes: mantém a com commit sem PR"        grep -qx "mantém  $SP/proj-fica2 (sessao/fica2: 1 commit(s) sem PR mergeado)" <<<"$OUT"
check "clean --yes: worktrees removidas e mantidas"    [ ! -e "$SP/proj-s1" -a ! -e "$SP/proj-old" -a ! -e "$SP/proj-semid" -a -d "$SP/proj-fica1" -a -d "$SP/proj-fica2" ]
r="$(task_ev '.name == "oute.task.removed"')"
check "removed: um por worktree removida (8), nada das mantidas" [ "$(grep -c . <<<"$r")" -eq 8 -a "$(total)" -eq $((base_n + 8)) ]
check "removed: nada das mantidas"                     bash -c '! grep -q fica' _ <<<"$r"
check "removed merged: PR mergeado, com o id da sessão" jqe -s --arg id "$id" 'map(select(.attrs["oute.task.slug"] == "s1")) | length == 1 and (.[0].attrs
                                                         | .["oute.task.id"] == $id and .["oute.task.reason"] == "merged" and .["oute.task.repo"] == "proj" and .["oute.task.base"] == "main")' <<<"$r"
check "removed detached: com o id lido antes"          jqe -s --arg id "$oid" 'map(select(.attrs["oute.task.slug"] == "old")) | length == 1 and .[0].attrs["oute.task.id"] == $id
                                                         and .[0].attrs["oute.task.reason"] == "detached"' <<<"$r"
check "removed empty: worker com a rodada e a sessão"  jqe -s --arg id "$wid" 'map(select(.attrs["oute.task.slug"] == "7-foo")) | length == 1 and (.[0].attrs
                                                         | .["oute.task.id"] == $id and .["oute.task.reason"] == "empty" and .["oute.swarm.round"] == "swarm-0101-0000" and .["oute.swarm.session"] == "7-foo")' <<<"$r"
check "removed sem id: só repo e slug"                 jqe -s 'map(select(.attrs["oute.task.slug"] == "semid")) | length == 1 and (.[0].attrs
                                                         | .["oute.task.repo"] == "proj" and .["oute.task.reason"] == "empty" and (has("oute.task.id") | not))' <<<"$r"
check "removed: quem chamou o clean (claude), sem agente da sessão" jqe -s 'all(.attrs["oute.agent"] == "claude" and .res["oute.agent"] == "claude" and (.attrs | has("oute.task.agent") | not))' <<<"$r"
check "removed: motivo sempre de valores fechados"     jqe -s 'all(.attrs["oute.task.reason"] | IN("merged", "empty", "detached"))' <<<"$r"
# worktree que o git se recusa a remover (travada): fica, e não há removed
t travada claude; git -C "$WS/proj" worktree lock "$SP/proj-travada"
before="$(total)"
t clean --yes
check "clean --yes: remoção recusada pelo git não emite" [ -d "$SP/proj-travada" -a "$(total)" -eq "$before" ]
check "clean --yes: remoção recusada não diz removida" bash -c '! grep -q "$1"' _ "removida $SP/proj-travada" <<<"$OUT"
git -C "$WS/proj" worktree unlock "$SP/proj-travada"
t clean --yes
check "clean --yes: destravada, sai"                   [ ! -e "$SP/proj-travada" ]
check "clean --yes: destravada, com o removed"         jqe '.name == "oute.task.removed" and .attrs["oute.task.slug"] == "travada"' <<<"$(last)"
before="$(total)"
t clean --yes
check "clean --yes de novo: nada a remover, nada emitido" [ "$RC" -eq 0 -a "$(total)" -eq "$before" ]
if [[ "$(id -u)" -ne 0 ]]; then
  # worktree removida, mas o branch não apaga (refs sem permissão de escrita): a sessão acabou, o removed sai;
  # a linha "removida" continua não saindo, como antes, e o clean segue
  t ramo claude; rid="$(mark "$SP/proj-ramo" id)"; chmod a-w "$WS/proj/.git/refs/heads/sessao"
  t clean --yes
  chmod u+w "$WS/proj/.git/refs/heads/sessao"
  check "branch que não apaga: worktree removida, clean segue com código 0" [ "$RC" -eq 0 -a ! -e "$SP/proj-ramo" ]
  check "branch que não apaga: não diz removida"       bash -c '! grep -q "$1"' _ "removida $SP/proj-ramo" <<<"$OUT"
  check "branch que não apaga: clean segue para as outras" grep -q "mantém  $SP/proj-fica2" <<<"$OUT"
  check "branch que não apaga: removed emitido com o id"  jqe --arg id "$rid" '.name == "oute.task.removed" and .attrs["oute.task.id"] == $id and .attrs["oute.task.reason"] == "empty"' <<<"$(last)"
  git -C "$WS/proj" branch -q -D sessao/ramo
fi
if has_pty; then
  t h1 claude
  script -qec "$TASK clean --yes" /dev/null >/dev/null 2>&1
  check "clean no terminal, sem marcador: removed por human" jqe '.name == "oute.task.removed" and .attrs["oute.task.slug"] == "h1" and .attrs["oute.agent"] == "human"' <<<"$(last)"
fi

# ---------------------------------------------------------------- 7. coletor fora do ar e oute-emit ausente: nada muda
# ciclo <slug>: abre, reabre e remove; saída, stderr e código das três chamadas, com o slug trocado por SLUG
ciclo() {
  local s="$1" r=""
  FAKE_RC=3 t "$s" claude "p"; r+="[$RC|$OUT|$ERR|$(cat "$FAKE/claude.args")]"
  t "$s" codex; r+="[$RC|$OUT|$ERR]"
  t clean --yes; r+="[$RC|$OUT|$ERR]"
  printf '%s' "${r//$s/SLUG}"
}
up="$(ciclo ciclo-up)"
check "coletor no ar: o ciclo abre, reabre e remove"   grep -q "^\[3|agente falso claude|worktree $SP/proj-SLUG · branch sessao/SLUG (de origin/main)|$MS p\]\[0|agente falso codex|reabrindo .*removida $SP/proj-SLUG (sem commits além de origin/main)" <<<"$(tr '\n' ' ' <<<"$up")"
check "coletor no ar: opened, reopened e removed do ciclo" [ "$(task_ev '.attrs["oute.task.slug"] == "ciclo-up"' | jq -r .name | tr '\n' ' ')" == "oute.task.opened oute.task.reopened oute.task.removed " ]
live="$OTEL_EXPORTER_OTLP_ENDPOINT"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(closed_port)"
t0=$(date +%s); down="$(ciclo ciclo-fora)"
check "coletor fora do ar: mesma saída, mesmo exec, mesmos códigos" [ "$down" == "$up" ]
check "coletor fora do ar: rápido"                     [ $(( $(date +%s) - t0 )) -le 6 ]
check "coletor fora do ar: os três eventos ficam no spool" [ "$(ls "$HOME/.oute/emit/spool"/*.json 2>/dev/null | wc -l)" -eq 3 ]
export OTEL_EXPORTER_OTLP_ENDPOINT="$live"
oute-emit flush
check "coletor de volta: o spool entrega o ciclo"      [ "$(task_ev '.attrs["oute.task.slug"] == "ciclo-fora"' | jq -r .name | tr '\n' ' ')" == "oute.task.opened oute.task.reopened oute.task.removed " ]
noemit="$(PATH="$NOEMIT:/usr/bin:/bin"; ciclo ciclo-sem)"
check "sem oute-emit: mesma saída, mesmo exec, mesmos códigos" [ "$noemit" == "$up" ]
check "sem oute-emit: nada emitido"                    [ "$(task_ev '.attrs["oute.task.slug"] == "ciclo-sem"' | grep -c .)" -eq 0 ]
check "sem oute-emit: a marca nas conversas não depende dele" grep -qE "^$ORIGIN,oute.task.id=proj-ciclo-sem-[0-9]{14},oute.task.repo=proj,oute.task.slug=ciclo-sem$" <<<"$(aenv codex OTEL_RESOURCE_ATTRIBUTES)"

# ---------------------------------------------------------------- 8. oute-emit task: uso inválido não emite nem falha
before="$(total)"
OUT="$(oute-emit task 2>&1; oute-emit task opened 2>&1; oute-emit task apagada human repo=a slug=b 2>&1
       oute-emit task opened human repo=a 2>&1; oute-emit task opened human repo=a slug=b cor=azul 2>&1
       oute-emit task removed human repo=a slug=b 2>&1; oute-emit task removed human repo=a slug=b reason=sumiu 2>&1
       oute-emit task opened human repo=a slug=b legacy=sim 2>&1; oute-emit task opened human solto 2>&1)"; RC=$?
check "oute-emit task inválido: rc 0, nada na tela, nada emitido" [ "$RC" -eq 0 -a -z "$OUT" -a "$(total)" -eq "$before" ]
oute-emit task opened 'Quem, Chamou=x' repo=a slug=b reason=merged "id="
check "oute-emit task: quem chamou inválido = unknown; valor vazio e motivo fora do removed não entram" \
  jqe '.attrs["oute.agent"] == "unknown" and .attrs["oute.task.repo"] == "a" and (.attrs | has("oute.task.id") or has("oute.task.reason") | not)' <<<"$(last)"

# sem OTEL_* no ambiente (o shell do Bash tool do Claude Code, #250): endpoint e origem do ~/.oute_env do entrypoint
FILE_ORIGIN="host.name=oute-server,oute.instance=oute-agent,deployment.environment=oute-server"
env -i OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN" bash -c 'declare -px' \
  | grep -E '^declare -x (GH_|OUTE_|AI_MEMORY|GOOGLE_APP|AWS_|RCLONE_CONFIG_|OTEL_|CLAUDE_CODE_)' > "$HOME/.oute_env"
t semotel claude
OUT="$(cd "$WS/proj" && env -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_RESOURCE_ATTRIBUTES CLAUDECODE=1 "$TASK" clean --yes 2>&1 </dev/null)"; RC=$?
check "clean --yes sem OTEL_*: rc 0 e a worktree removida" bash -c '[[ $1 -eq 0 ]] && grep -qxF "$2" <<<"$3"' _ "$RC" \
  "removida $SP/proj-semotel (sem commits além de origin/main)" "$OUT"
check "clean --yes sem OTEL_*: removed com a origem do ~/.oute_env" jqe '.name == "oute.task.removed" and .attrs["oute.task.slug"] == "semotel"
  and .attrs["oute.agent"] == "claude" and .res["host.name"] == "oute-server" and .res["oute.instance"] == "oute-agent"' <<<"$(last)"
rm -f "$HOME/.oute_env"

check "nenhum oute.task.* com corpo (2ª parte)"        [ "$(task_ev '.body != null' | grep -c .)" -eq 0 -a "$(total)" -gt 10 ]
check "todo oute.task.* com oute.event.id e event.name" [ "$(task_ev '(.attrs["oute.event.id"] | length) != 32 or .attrs["event.name"] != .name' | grep -c .)" -eq 0 ]
rcv_stop

# ---------------------------------------------------------------- 9. spaces do herdr (#277)
# dois spaces (w1, w2) e dois repos (proj, outro), cada um com a main local atrás da origin; worktree no formato antigo
# direto em $WT. O clean de um space não vê nem remove as do outro, e só avança a main dos repos com worktree nele
printf 'w1 Frentes Engenharia\nw2 oute-agent\nw3 proj-colide\n' > "$FAKE/spaces"
S1="$WT/frentes-engenharia"; S2="$WT/oute-agent"
git init -q --bare -b main "$TMP/remote2.git" && git -C "$TMP/seed" push -q "$TMP/remote2.git" main \
  && git clone -q "$TMP/remote2.git" "$WS/outro" || die "não montei o segundo repo"
sp() { local w="$1"; shift; HERDR_ENV=1 HERDR_WORKSPACE_ID="$w" t "$@"; }   # sp <id do space> <args do oute-task…>
sp w1 a1 claude
check "space: worktree em <space>/<repo>-<slug>, label em nome de pasta" [ "$RC" -eq 0 -a "$ERR" == "worktree $S1/proj-a1 · branch sessao/a1 (de origin/main)" ]
check "space: agente na worktree do space"             [ "$(cat "$FAKE/claude.pwd")" == "$(cd "$S1/proj-a1" && pwd -P)" ]
sp w2 b1 claude; sp w2 -r outro b2 claude
check "space: outro space, outra pasta (e outro repo)" [ -d "$S2/proj-b1" -a -d "$S2/outro-b2" ]
sp w9 semlabel claude
check "space sem label no herdr: _sem-space"           [ "$RC" -eq 0 -a -d "$SP/proj-semlabel" ]
check "space sem label no herdr: com aviso"            grep -q "^aviso: não achei o label do space w9 no herdr; usando _sem-space$" <<<"$ERR"
git -C "$WS/proj" worktree add -q -b sessao/legado "$WT/proj-legado" origin/main
sp w1 legado codex
check "formato antigo: reabre onde está, sem migrar"   [ "$RC" -eq 0 -a "$ERR" == "reabrindo $WT/proj-legado (sessao/legado)" -a ! -e "$S1/proj-legado" ]
check "formato antigo: agente na worktree antiga"      [ "$(cat "$FAKE/codex.pwd")" == "$(cd "$WT/proj-legado" && pwd -P)" ]
git -C "$WS/proj" worktree add -q -b sessao/x "$WT/proj-colide" origin/main
sp w3 outra claude
check "pasta do space ocupada por worktree antiga: recusa" [ "$RC" -ne 0 -a ! -e "$WT/proj-colide/proj-outra" ]
check "pasta do space ocupada: diz o motivo"           grep -q "formato antigo" <<<"$ERR"
git -C "$WS/proj" worktree remove "$WT/proj-colide"; git -C "$WS/proj" branch -q -D sessao/x
sp w1 list
check "list: o space atual"                            grep -q "^$S1/proj-a1 " <<<"$OUT"
check "list: o outro space"                            grep -q "^$S2/proj-b1 " <<<"$OUT"
check "list: o outro space, do outro repo"             grep -q "^$S2/outro-b2 " <<<"$OUT"
check "list: o formato antigo"                         grep -q "^$WT/proj-legado " <<<"$OUT"
# main dos dois repos um commit atrás da origin
git -C "$TMP/seed" commit -q --allow-empty -m novo && git -C "$TMP/seed" push -q "$TMP/remote.git" main && git -C "$TMP/seed" push -q "$TMP/remote2.git" main
sp w1 clean
check "clean (simulação): o space atual no topo"       [ "$RC" -eq 0 -a "$(head -n1 <<<"$OUT")" == "space frentes-engenharia ($S1)" ]
check "clean (simulação): remove a do space atual"     grep -qx "remover $S1/proj-a1 (sem commits além de origin/main)" <<<"$OUT"
check "clean (simulação): nada de fora do space"       bash -c '! grep -qE "b1|b2|legado|fica|semlabel"' _ <<<"$OUT"
check "clean (simulação): atualiza só a main do repo do space" bash -c 'grep -q "^atualizar $1 " <<<"$3" && ! grep -q "$2" <<<"$3"' _ "$WS/proj" "$WS/outro" "$OUT"
check "clean (simulação): avisa do formato antigo"     grep -qx "formato antigo: 1 worktree(s) direto em $WT, fora do escopo; só o 'oute-task clean --all' as considera" <<<"$OUT"
sp w1 clean --yes
check "clean --yes: remove só a worktree do space"     [ "$RC" -eq 0 -a ! -e "$S1/proj-a1" -a -d "$S2/proj-b1" -a -d "$S2/outro-b2" -a -d "$WT/proj-legado" -a -d "$SP/proj-semlabel" ]
check "clean --yes: só a main do repo com worktree no space" [ "$(git -C "$WS/proj" rev-parse HEAD)" == "$(git -C "$WS/proj" rev-parse origin/main)" ]
check "clean --yes: a main do outro repo fica para trás" [ "$(git -C "$WS/outro" rev-parse HEAD)" != "$(git -C "$TMP/remote2.git" rev-parse main)" ]
sp w1 clean --space "OUTE agent"
check "clean --space: outro space, pelo nome normalizado" [ "$(head -n1 <<<"$OUT")" == "space oute-agent ($S2)" ]
check "clean --space: o que removeria do outro space"  grep -qx "remover $S2/outro-b2 (sem commits além de origin/main)" <<<"$OUT"
check "clean --space: diz como aplicar, com o space"   grep -qx "(simulação — rode 'oute-task clean --yes --space oute-agent' para aplicar)" <<<"$OUT"
check "clean --space: simulação não remove"            [ -d "$S2/outro-b2" ]
sp w1 clean --yes --space oute-agent
check "clean --space --yes: remove o outro space e avança a main dele" [ "$RC" -eq 0 -a ! -e "$S2/proj-b1" -a ! -e "$S2/outro-b2" -a -d "$WT/proj-legado" ]
check "clean --space --yes: avança a main do outro repo" [ "$(git -C "$WS/outro" rev-parse HEAD)" == "$(git -C "$TMP/remote2.git" rev-parse main)" ]
t clean --space _sem-space
check "clean --space _sem-space: mantém o nome"         [ "$(head -n1 <<<"$OUT")" == "space _sem-space ($SP)" ]
check "clean --space _sem-space: o que removeria"      grep -qx "remover $SP/proj-semlabel (sem commits além de origin/main)" <<<"$OUT"
sp w2 clean --all --yes
check "clean --all: todos os spaces e o formato antigo" [ "$RC" -eq 0 -a "$(head -n1 <<<"$OUT")" == "todos os spaces ($WT)" -a ! -e "$WT/proj-legado" -a ! -e "$SP/proj-semlabel" -a -d "$SP/proj-fica1" ]
check "clean --all: sem o aviso do formato antigo"     bash -c '! grep -q "^formato antigo"' _ <<<"$OUT"
for a in "--space x --all" "--all --space x" "--space" "--foo"; do
  t clean $a
  check "clean $a: recusa, sem remover nada"           [ "$RC" -ne 0 -a -z "$OUT" -a -d "$SP/proj-fica1" ]
  check "clean $a: diz o erro"                         grep -q "^oute-task: " <<<"$ERR"
done

# ---------------------------------------------------------------- 10. seletor de modelo (#219, ADR-02)
# o oute-task abre com o modelo do oute-select (tabela do repo, gh falso da tests/lib), guarda a escolha na marca da
# sessão e a manda no oute.task.opened; o shim a repõe quando a conversa é retomada
rcv_stop; rcv_start "$TMP/r3"
labels() { local n="$1"; shift; printf '%s\n' "$@" > "$FAKE/labels-$n"; }   # <n> <label…> da issue
args() { tr '\n' ' ' < "$FAKE/$1.args" | sed 's/ $//'; }                   # argumentos que o agente recebeu, numa linha
# sel_ev <fase> <origem> <agente> <modelo> <esforço>: a escolha no último evento de sessão (vazio = atributo ausente)
sel_ev() {
  jqe --arg p "$1" --arg o "$2" --arg a "$3" --arg m "$4" --arg e "$5" '
    def is($k; $v): if $v == "" then (.attrs | has($k) | not) else .attrs[$k] == $v end;
    is("oute.task.phase"; $p) and is("oute.task.origin"; $o) and is("oute.task.agent"; $a)
    and is("oute.task.model"; $m) and is("oute.task.effort"; $e)' <<<"$(last)"
}
smark() { echo "$(mark "$1" agent)|$(mark "$1" model)|$(mark "$1" effort)"; }   # agente|modelo|esforço da marca
labels 40 aidlc:build agentes; labels 41 aidlc:spec; labels 42 aidlc:spec kaizen; labels 43 bug; labels 44 aidlc:ops

# 10a. label de fase
FAKE_RC=4 t 40-build claude "faça a 40"
check "fase: claude --model <id da fase> e o prompt"   [ "$RC" -eq 4 -a "$(args claude)" == "--model claude-sonnet-5-5 faça a 40" ]
check "fase: sem aviso"                                [ -z "$SELW" ]
check "fase: opened com fase, origem label, agente e modelo, sem esforço" bash -c '[ "$1" == oute.task.opened ]' _ "$(jq -r .name <<<"$(last)")"
check "fase: atributos da escolha"                     sel_ev build label claude claude-sonnet-5-5 ""
check "fase: opened continua com o oute.task.id"       jqe --arg id "$(mark "$SP/proj-40-build" id)" '.attrs["oute.task.id"] == $id' <<<"$(last)"
check "fase: marca guarda agente e modelo"             [ "$(smark "$SP/proj-40-build")" == "claude|claude-sonnet-5-5|" ]
check "fase: a marca das conversas não muda"           [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$(mark "$SP/proj-40-build" id),oute.task.repo=proj,oute.task.slug=40-build" ]
t 41-spec
check "fase spec, sem agente posicional: Opus"         [ "$(args claude)" == "--model claude-opus-5-5" ]
check "fase spec: origem label (o padrão claude não é escolha)" sel_ev spec label claude claude-opus-5-5 ""
t 44-ops claude
check "fase ops: Haiku"                                [ "$(args claude)" == "--model claude-haiku-4-5-20251001" ]

# 10b. exceção por label
t 42-licao claude "lição"
check "kaizen: Haiku, mesmo com aidlc:spec"            [ "$(args claude)" == "--model claude-haiku-4-5-20251001 lição" ]
check "kaizen: evento com a fase da issue e origem label" sel_ev spec label claude claude-haiku-4-5-20251001 ""

# 10c. sem label e gh fora do ar: Sonnet, com aviso, e a sessão abre
FAKE_RC=6 t 43-semlabel claude "p"
check "sem label: abre no Sonnet, com o código do agente" [ "$RC" -eq 6 -a "$(args claude)" == "--model claude-sonnet-5-5 p" ]
check "sem label: aviso"                               [ "$SELW" == "oute-select: aviso: issue #43 sem label aidlc:<fase>; abrindo no padrão (claude-sonnet-5-5)" ]
check "sem label: origem padrao, sem fase"             sel_ev "" padrao claude claude-sonnet-5-5 ""
touch "$FAKE/gh.down"
FAKE_RC=8 t 41-fora claude "p"
check "gh fora: abre no Sonnet, com o código do agente" [ "$RC" -eq 8 -a "$(args claude)" == "--model claude-sonnet-5-5 p" -a -d "$SP/proj-41-fora" ]
check "gh fora: aviso"                                 [ "$SELW" == "oute-select: aviso: o gh não respondeu para a issue #41; abrindo no padrão (claude-sonnet-5-5)" ]
check "gh fora: origem padrao"                         sel_ev "" padrao claude claude-sonnet-5-5 ""
rm "$FAKE/gh.down"

# 10d. escolha explícita: --agent, --model, codex posicional, --model nos argumentos do agente
t 40-cx codex "p"
check "codex posicional: -m <id> -c model_reasoning_effort=<e>" [ "$(args codex)" == "-m gpt-6.1-sol -c model_reasoning_effort=high p" ]
check "codex posicional: origem manual, com esforço"   sel_ev build manual codex gpt-6.1-sol high
check "codex posicional: marca com agente, modelo e esforço" [ "$(smark "$SP/proj-40-cx")" == "codex|gpt-6.1-sol|high" ]
t --agent codex 41-flag
check "--agent codex: Codex da linha da fase"          [ "$RC" -eq 0 -a "$(args codex)" == "-m gpt-6-astra -c model_reasoning_effort=high" ]
check "--agent codex: origem manual"                   sel_ev spec manual codex gpt-6-astra high
t --model claude-fable-5-1 42-modelo claude "p"
check "--model: vence a exceção e a fase"              [ "$(args claude)" == "--model claude-fable-5-1 p" ]
check "--model: origem manual"                         sel_ev spec manual claude claude-fable-5-1 ""
t --model gpt-6-luna -r "$WS/proj" 40-luna
check "--model do Codex sem agente: abre o codex"      [ "$RC" -eq 0 -a "$(args codex)" == "-m gpt-6-luna -c model_reasoning_effort=high" ]
t --agent claude 41-explicito claude
check "--agent claude: manual, com o modelo da fase"   sel_ev spec manual claude claude-opus-5-5 ""
t 40-args claude --model 'claude-opus-5-5[1m]' "p"
check "--model nos argumentos do agente: não duplica"  [ "$(args claude)" == "--model claude-opus-5-5[1m] p" ]
check "--model nos argumentos: origem manual, com o id" sel_ev build manual claude 'claude-opus-5-5[1m]' ""
check "--model nos argumentos: a marca guarda o id com [1m]" [ "$(smark "$SP/proj-40-args")" == "claude|claude-opus-5-5[1m]|" ]
t 40-args2 codex -m gpt-6-astra "p"
check "-m nos argumentos do codex: não duplica nem põe esforço" [ "$(args codex)" == "-m gpt-6-astra p" ]
t --phase plan swarm-0909-0000 claude "prompt"
check "--phase plan (dispatcher): Sonnet, sem ler a issue" [ "$(args claude)" == "--model claude-sonnet-5-5 prompt" -a -z "$SELW" ]
check "--phase plan: fase plan, origem padrao"         sel_ev plan padrao claude claude-sonnet-5-5 ""

# 10e. escolha já resolvida pelo oute-swarm spawn (OUTE_SELECT_FILE): vale ela, sem outra leitura da issue
echo '{"phase":"arch","origin":"label","agent":"codex","model":"gpt-6-astra","effort":"high","reason":"x"}' > "$TMP/sel.json"
rm -f "$FAKE/gh-issue.log"
OUTE_SELECT_FILE="$TMP/sel.json" t 43-arquivo claude "p"
check "OUTE_SELECT_FILE: abre o agente e o modelo do arquivo" [ "$RC" -eq 0 -a "$(args codex)" == "-m gpt-6-astra -c model_reasoning_effort=high p" ]
check "OUTE_SELECT_FILE: evento com a escolha do arquivo" sel_ev arch label codex gpt-6-astra high
check "OUTE_SELECT_FILE: o gh não é chamado"           [ ! -e "$FAKE/gh-issue.log" ]
OUTE_SELECT_FILE="$TMP/nao-existe.json" t 40-semarq claude "p"
check "OUTE_SELECT_FILE que não existe: o oute-task resolve" [ "$(args claude)" == "--model claude-sonnet-5-5 p" ]
echo 'lixo' > "$TMP/sel.json"
OUTE_SELECT_FILE="$TMP/sel.json" FAKE_RC=9 t 40-lixo claude "p"
check "OUTE_SELECT_FILE inválido: abre sem modelo, com o código do agente" [ "$RC" -eq 9 -a "$(args claude)" == "p" ]
check "OUTE_SELECT_FILE inválido: aviso"               grep -qxF "aviso: o seletor de modelo não respondeu; a sessão abre com o modelo padrão do agente" <<<"$ERR"
check "OUTE_SELECT_FILE inválido: evento sem a escolha" sel_ev "" "" claude "" ""

# 10f. seletor falhando ou sem tabela: aviso, e a sessão abre com o modelo padrão do agente
BAD="$TMP/bin-bad"; mkdir -p "$BAD"; printf '#!/usr/bin/env bash\necho "estourou" >&2; exit 1\n' > "$BAD/oute-select"; chmod +x "$BAD/oute-select"
OUT="$(cd "$WS/proj" && PATH="$BAD:$PATH" FAKE_RC=3 "$TASK" 40-quebrado claude "p" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"
check "oute-select falhando: abre sem modelo, com o código do agente" [ "$RC" -eq 3 -a "$(args claude)" == "p" -a -d "$SP/proj-40-quebrado" ]
check "oute-select falhando: aviso"                    grep -qxF "aviso: o seletor de modelo não respondeu; a sessão abre com o modelo padrão do agente" <<<"$ERR"
OUTE_SELECT_TABLE="$TMP/sem-tabela.toml" FAKE_RC=2 t 40-semtabela claude "p"
check "sem tabela: abre sem modelo, com o código do agente" [ "$RC" -eq 2 -a "$(args claude)" == "p" ]
check "sem tabela: aviso do seletor"                   grep -qF 'tabela de fase ausente ou inválida' <<<"$SELW"
check "sem tabela: evento com a origem, sem modelo"    sel_ev "" padrao claude "" ""
OUT="$(cd "$WS/proj" && PATH="$NOTASK:$SHIMS:/usr/bin:/bin" "$TASK" 40-semsel claude "p" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"
check "sem oute-select no PATH: abre como antes, sem aviso" [ "$RC" -eq 0 -a "$(args claude)" == "p" -a "$ERR" == "worktree $SP/proj-40-semsel · branch sessao/40-semsel (de origin/main)" ]

# 10g. argumento inválido: erro antes de criar a worktree
t --model 'x y' 40-invalido claude
check "--model inválido: código != 0, sem worktree"    [ "$RC" -ne 0 -a ! -e "$SP/proj-40-invalido" ]
check "--model inválido: diz o motivo"                 grep -qF 'oute-select: modelo inválido: x y' <<<"$ERR"
t --agent pi 40-pi
check "--agent pi: recusado, sem worktree"             [ "$RC" -ne 0 -a ! -e "$SP/proj-40-pi" -a "$ERR" == "oute-task: Pi saiu do stack (#217), use claude ou codex" ]
t --agent gemini 40-gem
check "--agent inválido: recusado"                     [ "$RC" -ne 0 -a ! -e "$SP/proj-40-gem" ]
t --agent codex 40-conflito claude
check "--agent e agente posicional diferentes: recusado" [ "$RC" -ne 0 -a ! -e "$SP/proj-40-conflito" -a "$ERR" == "oute-task: --agent codex e o agente claude não andam juntos" ]
t --model claude-opus-5-5 40-conflito claude --model claude-sonnet-5-5
check "--model e o dos argumentos diferentes: recusado" [ "$RC" -ne 0 -a ! -e "$SP/proj-40-conflito" ]
t --model
check "--model sem valor: recusado"                    [ "$RC" -ne 0 -a "$ERR" == "oute-task: --model sem valor" ]
t --nada x
check "opção desconhecida: recusada, com o uso"        bash -c '[ "$1" -ne 0 ] && grep -q "^oute-task: opção desconhecida: --nada" <<<"$2"' _ "$RC" "$ERR"

# 10h. reabertura: resolve de novo e atualiza a marca; o shell não mexe nela
labels 40 aidlc:spec
t 40-build claude
check "reabrir com o label trocado: modelo novo"       [ "$(args claude)" == "--model claude-opus-5-5" ]
check "reabrir: reopened com a escolha nova, mesmo id" sel_ev spec label claude claude-opus-5-5 ""
check "reabrir: a marca acompanha"                     [ "$(smark "$SP/proj-40-build")" == "claude|claude-opus-5-5|" ]
labels 40 aidlc:build
idb="$(mark "$SP/proj-40-cx" id)"
t 40-cx shell </dev/null >/dev/null 2>&1
check "shell: a marca fica como estava"                [ "$(smark "$SP/proj-40-cx")" == "codex|gpt-6.1-sol|high" -a "$(mark "$SP/proj-40-cx" id)" == "$idb" ]
check "shell: evento sem a escolha"                    sel_ev "" "" shell "" ""

# 10i. restore do herdr: o shim reabre com o modelo da marca
printf '{"type":"user","cwd":"%s"}\n' "$SP/proj-41-spec" > "$HOME/.claude/projects/p/conv-41.jsonl"
printf '{"type":"user","cwd":"%s"}\n' "$SP/proj-40-cx" > "$HOME/.codex/sessions/2026/rollout-2026-conv-40cx.jsonl"
shim claude "$WS/proj" --resume conv-41
check "restore: claude --resume reabre com o modelo da marca" [ "$RC" -eq 0 -a "$(args claude)" == "--resume conv-41 --model claude-opus-5-5" -a "$(cat "$FAKE/claude.pwd")" == "$(cd "$SP/proj-41-spec" && pwd -P)" ]
shim codex "$WS/proj" resume conv-40cx
check "restore: codex resume com modelo e esforço"     [ "$RC" -eq 0 -a "$(args codex)" == "resume conv-40cx -m gpt-6.1-sol -c model_reasoning_effort=high" ]
shim claude "$SP/proj-41-spec" -c
check "claude -c na worktree: o modelo da marca"       [ "$(args claude)" == "-c --model claude-opus-5-5" ]
shim claude "$SP/proj-41-spec" --resume conv-41 --model claude-haiku-4-5-20251001
check "restore com --model na linha: não mexe"         [ "$(args claude)" == "--resume conv-41 --model claude-haiku-4-5-20251001" ]
shim codex "$SP/proj-40-cx" resume conv-40cx -m gpt-6-luna
check "codex resume com -m na linha: não mexe"         [ "$(args codex)" == "resume conv-40cx -m gpt-6-luna" ]
shim claude "$SP/proj-40-cx" --resume outra
check "marca de outro agente: claude abre sem modelo"  [ "$(args claude)" == "--resume outra" ]
shim claude "$SP/proj-41-spec" -p "oi"
check "sem retomar conversa (-p): sem modelo"          [ "$(args claude)" == "-p oi" ]
shim claude "$SP/proj-40-lixo" --resume y
check "worktree com marca sem modelo: sem modelo"      [ "$(args claude)" == "--resume y" ]
OUT="$(cd "$SP/proj-41-spec" && PATH="$SHIMS:$NOTASK:/usr/bin:/bin" "$SHIMS/claude" --resume conv-41 2>&1 </dev/null)"; RC=$?
check "shim sem oute-task no PATH: retoma sem modelo"  [ "$RC" -eq 0 -a "$(args claude)" == "--resume conv-41" ]
check "--model-args: os argumentos da marca, um por linha" [ "$("$TASK" --model-args codex "$SP/proj-40-cx")" == "$(printf -- '-m\ngpt-6.1-sol\n-c\nmodel_reasoning_effort=high')" ]
check "--model-args: outro agente, fora de worktree e sem agente: nada" [ -z "$("$TASK" --model-args claude "$SP/proj-40-cx"; "$TASK" --model-args claude "$TMP"; "$TASK" --model-args)" ]

# 10j. oute-emit task: a escolha só entra no opened/reopened, e a origem é conferida
before="$(total)"
oute-emit task opened human repo=a slug=b origin=chute model=m
check "oute-emit task: origem inválida não emite"      [ "$(total)" -eq "$before" ]
oute-emit task removed human repo=a slug=b reason=merged phase=build origin=label model=m effort=high
check "oute-emit task: removed sem a escolha"          jqe '.name == "oute.task.removed" and (.attrs | has("oute.task.phase") or has("oute.task.origin") or has("oute.task.model") or has("oute.task.effort") | not)' <<<"$(last)"
check "nenhum oute.task.* com corpo (seletor)"         [ "$(task_ev '.body != null' | grep -c .)" -eq 0 ]
rcv_stop

check_end
