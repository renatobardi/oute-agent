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
trap 'rcv_stop; chmod -R u+w "${TMP:?}" 2>/dev/null; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v python3 >/dev/null && command -v git >/dev/null || die "precisa de jq, python3 e git"
TASK="$ROOT/docker/oute-task"
[[ -x "$TASK" ]] || die "oute-task ausente ou sem +x: $TASK"

# ---------------------------------------------------------------- fakes e ambiente
# O dublê grava o ambiente: nenhuma credencial real pode chegar aos agentes falsos.
export OUTE_TASK_TEST_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
TEST_OCI_KEY_PEM="fake-oci-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
TEST_GCP_SA_JSON="{\"type\":\"service_account\",\"private_key\":\"fake-gcp-$(python3 -c 'import secrets; print(secrets.token_hex(16))')\"}"
export OCI_KEY_PEM="$TEST_OCI_KEY_PEM" GCP_SA_JSON="$TEST_GCP_SA_JSON"
for task_env_key in $(compgen -e); do
  case "$task_env_key" in
    *TOKEN*|*SECRET*|*PASSWORD*|*API_KEY*|OCI_S3_*|OCI_KEY_PEM|GCP_SA_JSON|AWS_ACCESS_KEY_ID|AGENT_STUDIO_*) unset "$task_env_key" ;;
  esac
done

BIN="$TMP/bin"; NOEMIT="$TMP/bin-noemit"; NOTASK="$TMP/bin-notask"; SHIMS="$TMP/shims"
FAKE="$TMP/fake"; WS="$TMP/ws"; WT="$TMP/wt"
mkdir -p "$BIN" "$NOEMIT" "$NOTASK" "$SHIMS" "$FAKE" "$WS" "$TMP/home"
# agente falso (tests/lib/fake-agent.sh): grava o ambiente, o diretório e os argumentos em $FAKE/<agente>.* e sai com
# $FAKE_RC; `claude auth status`/`codex login status` respondem por $FAKE_CLAUDE_AUTH_RC/$FAKE_CODEX_LOGIN_RC (#258)
cp "$ROOT/tests/lib/fake-agent.sh" "$BIN/claude"
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
# o gatilho de cota do seletor (#355) lê o oute-quota: o falso (cota folgada), nunca o de verdade
cp "$ROOT/tests/lib/fake-oute-quota.sh" "$BIN/oute-quota"; cp "$BIN/oute-quota" "$NOEMIT/oute-quota"
# herdr: `workspace get <id>` responde o label da linha "<id> <label>" de $FAKE/spaces; id desconhecido sai com erro
cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
if [[ "$1 ${2:-}" == "tab list" ]]; then   # abas vivas: $FAKE/tabs (JSON do herdr); sem o arquivo, o herdr "falha" (#374)
  [[ -f "$FAKE/tabs" ]] || { echo "herdr fora do ar" >&2; exit 1; }
  cat "$FAKE/tabs"; exit 0
fi
[[ "$1 ${2:-}" == "workspace get" ]] || { echo "herdr falso: sem suporte a '$*'" >&2; exit 1; }
l="$(awk -v id="${3:-}" '$1 == id {sub(/^[^ ]* /, ""); print; exit}' "$FAKE/spaces" 2>/dev/null)"
[[ -n "$l" ]] || { echo "workspace not found" >&2; exit 1; }
jq -cn --arg id "$3" --arg l "$l" '{id: "cli:workspace:get", result: {type: "workspace_info", workspace: {label: $l, workspace_id: $id}}}'
SH
chmod +x "$BIN/herdr"
# ai-memory falso (#435): o clean lista handoffs pelo ai-memory, e o de verdade (se houver no PATH de quem roda) nunca é chamado
. "$ROOT/tests/lib/fake-ai-memory.sh"; fake_ai_memory_install "$BIN"; fake_ai_memory_install "$NOEMIT"
ln -s "$ROOT/docker/oute-emit" "$BIN/oute-emit"
ln -s "$TASK" "$BIN/oute-task"; ln -s "$TASK" "$NOEMIT/oute-task"   # o shim chama `oute-task --mark`
for a in claude codex; do ln -s "$ROOT/docker/shims/oute-agent-shim" "$SHIMS/$a"; done

ORIGIN="host.name=oute-mac,oute.instance=oute-agent,deployment.environment=oute-mac"
unset CLAUDECODE CODEX_THREAD_ID OUTE_SWARM_ID OUTE_SWARM_ROUND OUTE_SWARM_WORKER OUTE_SWARM_MAX OUTE_SWARM_REPO \
      OUTE_NO_WORKTREE OUTE_EMIT_DEBUG CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION CLAUDE_CONFIG_DIR CODEX_HOME FAKE_RC FAKE_CLAUDE_AUTH_RC FAKE_CODEX_LOGIN_RC FAKE_AUTH_HANG \
      HERDR_ENV HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_SOCKET_PATH OTEL_EXPORTER_OTLP_LOGS_ENDPOINT
unset OUTE_SELECT_FILE OUTE_SELECT_GH_TIMEOUT OUTE_MEMORY_RUN AI_MEMORY_RUN_ID FAKE_AI_MEMORY_LOG FAKE_AI_MEMORY_HANDOFFS FAKE_AI_MEMORY_RC FAKE_AI_MEMORY_SLEEP OUTE_HANDOFFS_TIMEOUT
# Jev (#257): sem a chave e o endereço da TypeSafe de verdade no ambiente; só a seção 10k sobe a falsa
. "$ROOT/tests/lib/typesafe.sh"; ts_off
# OUTE_SELECT_TABLE: a tabela de antes da `zai` (#677); o oute-task só prova o que faz com a escolha, e a sessão `zai` entra em ticket próprio
export PATH="$BIN:$PATH" HOME="$TMP/home" FAKE OUTE_WORKTREES="$WT" OUTE_WORKSPACE="$WS" OTEL_RESOURCE_ATTRIBUTES="$ORIGIN" \
       TESTLIB="$ROOT/tests/lib" OUTE_SELECT_TABLE="$ROOT/tests/lib/select-table-sem-zai.toml" \
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
check "dublê do agente: credenciais ficam fora do ambiente gravado" bash -c \
  '! grep -qE "^([^=]*(TOKEN|SECRET|PASSWORD|API_KEY)[^=]*|OCI_S3_[^=]*|OCI_KEY_PEM|GCP_SA_JSON|AWS_ACCESS_KEY_ID|AGENT_STUDIO_[^=]*)=" "$1" && ! grep -qF "$2" "$1" && ! grep -qF "$3" "$1"' _ "$FAKE/claude.env" "$TEST_OCI_KEY_PEM" "$TEST_GCP_SA_JSON"
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
check "marca: origem preservada + oute.task.*"         [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1,oute.subscription=claude" ]
check "abrir: o agente passa pelo shim sem nova worktree" [ "$(aenv claude OUTE_NO_WORKTREE)" == 1 ]

t s1 codex
check "reabrir: código 0, saída do agente"             [ "$RC" -eq 0 -a "$OUT" == "agente falso codex" -a "$ERR" == "reabrindo $SP/proj-s1 (sessao/s1)" ]
e="$(task_ev '.name == "oute.task.reopened"')"
check "reabrir: um oute.task.reopened"                [ "$(grep -c . <<<"$e")" -eq 1 ]
check "reabrir: reopened com o mesmo id"               jqe --arg id "$id" '.attrs["oute.task.id"] == $id' <<<"$e"
check "reopened: agente da sessão codex, base, sem legacy" jqe '.attrs["oute.task.agent"] == "codex" and .attrs["oute.task.base"] == "main" and (.attrs | has("oute.task.legacy") | not)' <<<"$e"
check "reabrir: id não muda na worktree"               [ "$(mark "$SP/proj-s1" id)" == "$id" ]
check "marca no Codex: a mesma"                        [ "$(aenv codex OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1,oute.subscription=codex" ]

# marca de outra sessão no ambiente de quem chamou: a chave não se repete, vale a nova; o evento leva só a origem
OTEL_RESOURCE_ATTRIBUTES="$ORIGIN,oute.task.id=velho,oute.swarm.round=velha, oute.task.slug=x" t s1 claude
check "marca: chave que já existia não duplica"        [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1,oute.subscription=claude" ]
check "evento: resource sem a marca de quem chamou"    jqe --arg id "$id" '.attrs["oute.task.id"] == $id and (.attrs | has("oute.swarm.round") | not)
                                                         and (.res | has("oute.task.id") or has("oute.swarm.round") or has("oute.task.slug") | not)
                                                         and .res["host.name"] == "oute-mac"' <<<"$(last)"
( unset OTEL_RESOURCE_ATTRIBUTES; t s1 claude )
check "marca: sem origem no ambiente, só oute.task.*"  [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1,oute.subscription=claude" ]
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
WMARK="$ORIGIN,oute.task.id=$wid,oute.task.repo=proj,oute.task.slug=7-foo,oute.swarm.round=swarm-0101-0000,oute.swarm.session=7-foo,oute.subscription=claude"
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
check "dispatcher: marca com a rodada"               [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$cid,oute.task.repo=proj,oute.task.slug=swarm-0202-0000,oute.swarm.round=swarm-0202-0000,oute.subscription=claude" ]
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
t old claude; task_gitdir="$(gitdir "$SP/proj-old")"; rm -f "${task_gitdir:?}/oute-task"
t old claude
oid="$(mark "$SP/proj-old" id)"
check "sem id: a reabertura grava um id novo"          grep -qE '^proj-old-[0-9]{14}$' <<<"$oid"
check "sem id: reopened com legacy=true e o id novo"   jqe --arg id "$oid" '.name == "oute.task.reopened" and .attrs["oute.task.id"] == $id and .attrs["oute.task.legacy"] == true' <<<"$(last)"
check "sem id: a conversa já sai marcada"              [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$oid,oute.task.repo=proj,oute.task.slug=old,oute.subscription=claude" ]
t old claude
check "sem id: na reabertura seguinte, mesmo id e sem legacy" jqe --arg id "$oid" '.attrs["oute.task.id"] == $id and (.attrs | has("oute.task.legacy") | not)' <<<"$(last)"
t nogravo claude; t fixa claude; fid="$(mark "$SP/proj-fixa" id)"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip falha ao gravar o id: rodando como root (o chmod não barra a escrita)"
else
  gd="$(gitdir "$SP/proj-nogravo")"; rm -f "${gd:?}/oute-task"; chmod a-w "${gd:?}"
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
check "restore: a mesma marca do oute-task"            [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1,oute.subscription=claude" ]
shim claude "$WS/proj" --resume conv-w
check "restore de worker: marca com oute.swarm.*"      [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$WMARK" -a "$(aenv claude CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION)" == false ]
shim codex "$WS/proj" resume conv-cx
check "restore do Codex: codex resume <id> marcado"    [ "$(cat "$FAKE/codex.pwd")" == "$(cd "$SP/proj-s1" && pwd -P)" -a "$(aenv codex OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1,oute.subscription=claude" ]
shim claude "$SP/proj-s1" -p "oi"
check "agente aberto direto na worktree (-p): marcado" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$id,oute.task.repo=proj,oute.task.slug=s1,oute.subscription=claude" -a "$(cat "$FAKE/claude.args")" == "$(printf -- '-p\noi')" ]
t semid claude; task_gitdir="$(gitdir "$SP/proj-semid")"; rm -f "${task_gitdir:?}/oute-task"; before=$((before + 1))
printf '{"type":"user","cwd":"%s"}\n' "$SP/proj-semid" > "$HOME/.claude/projects/p/conv-semid.jsonl"
shim claude "$WS/proj" --resume conv-semid
check "restore em worktree sem id: só o repositório principal, sem oute.task.id (#599)" [ "$(cat "$FAKE/claude.pwd")" == "$(cd "$SP/proj-semid" && pwd -P)" -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.repo=proj" ]
shim claude "$WS/proj" -p "no checkout principal"
check "checkout principal: oute.task.repo = a pasta, sem oute.task.id (#599)" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.repo=proj" ]
mkdir -p "$WS/proj/sub/dir"
shim claude "$WS/proj/sub/dir" -p "numa subpasta"
check "subpasta do repositório: o repositório, não a subpasta" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.repo=proj" ]
shim codex "$WS/proj" exec "no checkout principal"
check "checkout principal no Codex: a mesma marca"     [ "$(aenv codex OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.repo=proj" ]
mkdir -p "$TMP/com espaco+x" && git -C "$TMP/com espaco+x" init -q
shim claude "$TMP/com espaco+x" -p "nome com espaco"
check "nome de pasta com caractere fora de [A-Za-z0-9._-]: vira hífen, como no oute-task" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.repo=com-espaco-x" ]
shim claude "$TMP" -p "fora de repo"
check "fora de repo: sem marca"                        [ "$RC" -eq 0 -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN" ]
git init -q --bare "$TMP/nu.git"
shim claude "$TMP/nu.git" -p "repositório bare"
check "repositório sem pasta .git própria (bare): sem marca" [ "$RC" -eq 0 -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN" ]
OUT="$(cd "$WS/proj" && OTEL_RESOURCE_ATTRIBUTES="$ORIGIN,oute.task.id=de-fora,oute.task.slug=x" PATH="$SHIMS:$PATH" "$SHIMS/claude" -p "já marcada" 2>&1 </dev/null)"
check "oute.task.id já no ambiente (quem chamou marcou): o shim não mexe" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=de-fora,oute.task.slug=x" ]
OUT="$(cd "$WS/proj" && OTEL_RESOURCE_ATTRIBUTES="oute.task.repo=outra,$ORIGIN" PATH="$SHIMS:$PATH" "$SHIMS/claude" -p "repo de outra pasta" 2>&1 </dev/null)"
check "oute.task.repo de outra pasta no ambiente: vale o desta, sem repetir a chave" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.repo=proj" ]
OUT="$(cd "$WS/proj" && env -u OTEL_RESOURCE_ATTRIBUTES PATH="$SHIMS:$PATH" "$SHIMS/claude" -p "sem origem" 2>&1 </dev/null)"
check "sem origem no ambiente: só oute.task.repo"       [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "oute.task.repo=proj" ]
OUT="$(cd "$SP/proj-s1" && PATH="$SHIMS:$NOTASK:/usr/bin:/bin" "$SHIMS/claude" -p "sem oute-task" 2>&1 </dev/null)"; RC=$?
check "shim sem oute-task no PATH: abre igual, só com o repositório da pasta" [ "$RC" -eq 0 -a "$OUT" == "agente falso claude" -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.repo=proj" ]
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
[ "$down" == "$up" ] || { echo "--- diferença (coletor no ar × fora do ar):"; diff <(printf '%s\n' "$up") <(printf '%s\n' "$down"); } >&2
check "coletor fora do ar: rápido"                     [ $(( $(date +%s) - t0 )) -le 20 ]
check "coletor fora do ar: os três eventos ficam no spool" [ "$(ls "$HOME/.oute/emit/spool"/*.json 2>/dev/null | wc -l)" -eq 3 ]
export OTEL_EXPORTER_OTLP_ENDPOINT="$live"
oute-emit flush
check "coletor de volta: o spool entrega o ciclo"      [ "$(task_ev '.attrs["oute.task.slug"] == "ciclo-fora"' | jq -r .name | tr '\n' ' ')" == "oute.task.opened oute.task.reopened oute.task.removed " ]
noemit="$(PATH="$NOEMIT:/usr/bin:/bin"; ciclo ciclo-sem)"
check "sem oute-emit: mesma saída, mesmo exec, mesmos códigos" [ "$noemit" == "$up" ]
[ "$noemit" == "$up" ] || { echo "--- diferença (coletor no ar × sem oute-emit):"; diff <(printf '%s\n' "$up") <(printf '%s\n' "$noemit"); } >&2
check "sem oute-emit: nada emitido"                    [ "$(task_ev '.attrs["oute.task.slug"] == "ciclo-sem"' | grep -c .)" -eq 0 ]
check "sem oute-emit: a marca nas conversas não depende dele" grep -qE "^$ORIGIN,oute.task.id=proj-ciclo-sem-[0-9]{14},oute.task.repo=proj,oute.task.slug=ciclo-sem,oute.subscription=codex$" <<<"$(aenv codex OTEL_RESOURCE_ATTRIBUTES)"

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
rm -f "${HOME:?}/.oute_env"

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
check "clean (simulação): nada de fora do space"       bash -c 'for n in "$1/proj-b1" "$1/outro-b2" "$4/proj-semlabel" "$2/proj-legado"; do ! grep -qF "$n" <<<"$3" || exit 1; done' _ "$S2" "$WT" "$OUT" "$SP"
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
check "fase: a marca das conversas não muda"           [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$(mark "$SP/proj-40-build" id),oute.task.repo=proj,oute.task.slug=40-build,oute.subscription=claude" ]
t 41-spec
check "fase spec, sem agente posicional: Opus"         [ "$(args claude)" == "--model claude-opus-5-5" ]
check "fase spec: origem label (o padrão claude não é escolha)" sel_ev spec label claude claude-opus-5-5 ""
t 44-ops claude
check "fase ops: Sonnet"                                [ "$(args claude)" == "--model claude-sonnet-5-5" ]

# 10b. exceção por label
t 42-licao claude "lição"
check "kaizen: Sonnet, mesmo com aidlc:spec"            [ "$(args claude)" == "--model claude-sonnet-5-5 lição" ]
check "kaizen: evento com a fase da issue e origem label" sel_ev spec label claude claude-sonnet-5-5 ""

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
rm "${FAKE:?}/gh.down"

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
rm -f "${FAKE:?}/gh-issue.log"
OUTE_SELECT_FILE="$TMP/sel.json" t 43-arquivo claude "p"
check "OUTE_SELECT_FILE: abre o agente e o modelo do arquivo" [ "$RC" -eq 0 -a "$(args codex)" == "-m gpt-6-astra -c model_reasoning_effort=high p" ]
check "OUTE_SELECT_FILE: evento com a escolha do arquivo" sel_ev arch label codex gpt-6-astra high
check "OUTE_SELECT_FILE: o gh não é chamado"           [ ! -e "$FAKE/gh-issue.log" ]
check "OUTE_SELECT_FILE: não chega ao ambiente do agente" bash -c '! grep -q "^OUTE_SELECT_FILE=" "$1"' _ "$FAKE/codex.env"
# de dentro da sessão (com o que o agente recebeu no ambiente), outro oute-task resolve pela issue dele
OUTE_SELECT_FILE="$(aenv codex OUTE_SELECT_FILE)" t 41-dedentro claude "p"
check "oute-task de dentro da sessão: não herda a escolha do worker" [ "$RC" -eq 0 -a "$(args claude)" == "--model claude-opus-5-5 p" ]
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
oute-emit task opened human repo=a slug=b origin=jev phase=spec model=m confidence=0.87
check "oute-emit task: origem jev com a confiança, como número" jqe '.name == "oute.task.opened" and .attrs["oute.task.origin"] == "jev" and .attrs["oute.task.confidence"] == 0.87' <<<"$(last)"
before="$(total)"
for c in 1.2 abc -0.5 0,8; do oute-emit task opened human repo=a slug=b origin=jev confidence="$c"; done
check "oute-emit task: confiança inválida não emite"   [ "$(total)" -eq "$before" ]
oute-emit task removed human repo=a slug=b reason=merged origin=jev confidence=0.87
check "oute-emit task: removed sem a confiança"        jqe '.name == "oute.task.removed" and (.attrs | has("oute.task.confidence") or has("oute.task.origin") | not)' <<<"$(last)"

# 10k. Jev (#257): sem label de fase e com o texto da tarefa (o prompt), a TypeSafe falsa classifica a fase
ts_start "$TMP/ts"
cf() { jq -r '.attrs["oute.task.confidence"] // ""' <<<"$(last)"; }   # confiança no último evento de sessão
ts_set ok arch 0.91
FAKE_RC=5 t avulsa-jev claude "desenhe a arquitetura do serviço de filas"
check "jev: sessão avulsa abre no Opus, com o código do agente" [ "$RC" -eq 5 -a "$(args claude)" == "--model claude-opus-5-5 desenhe a arquitetura do serviço de filas" ]
check "jev: sem aviso"                                 [ -z "$SELW" ]
check "jev: opened com a fase, a origem jev e o modelo" sel_ev arch jev claude claude-opus-5-5 ""
check "jev: opened com a confiança"                    [ "$(jq -r .name <<<"$(last)") $(cf)" == "oute.task.opened 0.91" ]
check "jev: marca com o modelo (vale no restore)"      [ "$(smark "$SP/proj-avulsa-jev")" == "claude|claude-opus-5-5|" ]
check "jev: só o prompt vai à TypeSafe"                jqe '.body.state == "desenhe a arquitetura do serviço de filas" and (.body | keys == ["model", "questions", "state"])' <<<"$(ts_last)"
check "jev: a chave não chega aos argumentos do agente nem ao evento" bash -c '! grep -qF "$1" "$2" && ! grep -qF "$1" <<<"$3"' _ "$TS_KEY" "$FAKE/claude.args" "$(last)"
ts_set ok ops 0.75
t 43-jev claude "veja por que o custo subiu ontem"
check "jev: issue sem label de fase abre no Sonnet"     [ "$(args claude)" == "--model claude-sonnet-5-5 veja por que o custo subiu ontem" ]
check "jev: confiança no evento da issue sem label"    bash -c '[ "$1" == 0.75 ]' _ "$(cf)"
check "jev: atributos da escolha (issue sem label)"    sel_ev ops jev claude claude-sonnet-5-5 ""
ts_set ok arch 0.4
t avulsa-baixa claude "faça alguma coisa aí"
check "jev com confiança baixa: Sonnet"                [ "$(args claude)" == "--model claude-sonnet-5-5 faça alguma coisa aí" ]
check "jev com confiança baixa: origem padrao, com a confiança" bash -c '[ "$1" == 0.4 ]' _ "$(cf)"
check "jev com confiança baixa: atributos"             sel_ev "" padrao claude claude-sonnet-5-5 ""
check "jev com confiança baixa: aviso"                 grep -qF 'o Jev ficou com confiança baixa (0,40 em arch' <<<"$SELW"
ts_set 5xx
FAKE_RC=9 t avulsa-5xx claude "desenhe a arquitetura do serviço de filas"
check "jev fora (5xx): a sessão abre no Sonnet, com o código do agente" [ "$RC" -eq 9 -a "$(args claude)" == "--model claude-sonnet-5-5 desenhe a arquitetura do serviço de filas" ]
check "jev fora (5xx): origem padrao, sem confiança"   bash -c '[ -z "$1" ]' _ "$(cf)"
check "jev fora (5xx): atributos"                      sel_ev "" padrao claude claude-sonnet-5-5 ""
ts_reset; ts_set ok arch 0.91
t avulsa-mao
check "sem texto (aberta na mão): Sonnet, sem chamar o Jev" [ "$(args claude)" == "--model claude-sonnet-5-5" -a "$(ts_calls)" -eq 0 ]
t avulsa-resume claude --resume abc123
check "valor de opção não é texto da tarefa"           [ "$(args claude)" == "--resume abc123 --model claude-sonnet-5-5" -o "$(args claude)" == "--model claude-sonnet-5-5 --resume abc123" ]
# #313: valor de opção com espaço, no fim da linha, não é texto da tarefa (só o argumento posicional vai ao Jev)
t avulsa-opcao claude --append-system-prompt "responda sempre em português claro"
check "valor de opção com espaço no fim: sem Jev, Sonnet" [ "$(ts_calls)" -eq 0 -a "$(args claude)" == "--model claude-sonnet-5-5 --append-system-prompt responda sempre em português claro" ]
check "valor de opção com espaço no fim: origem padrao" sel_ev "" padrao claude claude-sonnet-5-5 ""
t avulsa-opcao-c codex -c "model_instructions=fale pouco e bem"
check "valor de opção curta com espaço no fim: sem Jev" [ "$(ts_calls)" -eq 0 ]
t avulsa-flag claude --verbose "desenhe a arquitetura do serviço de filas"
check "depois de opção sem valor não dá para saber: sem Jev" [ "$(ts_calls)" -eq 0 ]
# opção de mais de um valor: o último valor tem um valor antes dele, e mesmo assim não é texto da tarefa
t avulsa-adddir claude --add-dir /tmp/a "/tmp/dir com espaço"
check "segundo valor de --add-dir, com espaço: sem Jev" [ "$(ts_calls)" -eq 0 -a "$(args claude)" == "--model claude-sonnet-5-5 --add-dir /tmp/a /tmp/dir com espaço" ]
MCP="{\"mcpServers\": {\"x\": {\"env\": {\"TOKEN\": \"$TS_KEY\"}}}}"
t avulsa-mcp claude --mcp-config a.json "$MCP"
check "segundo valor de --mcp-config (JSON com token): sem Jev" [ "$(ts_calls)" -eq 0 ]
check "segundo valor de --mcp-config: origem padrao"   sel_ev "" padrao claude claude-sonnet-5-5 ""
t avulsa-tools claude --verbose --allowedTools "Bash(git log)" "Edit arquivo x"
check "segundo valor de --allowedTools: sem Jev"       [ "$(ts_calls)" -eq 0 ]
t avulsa-posicional claude --append-system-prompt "responda sempre em português claro" "desenhe a arquitetura do serviço de filas"
check "prompt depois de opção com valor: não dá para saber, sem Jev" [ "$(ts_calls)" -eq 0 ]
t avulsa-fim-valores claude --add-dir /tmp/a "/tmp/dir com espaço" -- "desenhe a arquitetura do serviço de filas"
check "opção de vários valores e -- antes do prompt: só o prompt vai ao Jev" bash -c '[ "$1" -eq 1 ] && jq -e ".body.state == \"desenhe a arquitetura do serviço de filas\" and (.body | tostring | contains(\"dir com\") | not)" <<<"$2" >/dev/null' _ "$(ts_calls)" "$(ts_last)"
ts_reset
t avulsa-igual claude --effort=high "desenhe a arquitetura do serviço de filas"
check "depois de --opção=valor: o prompt vai ao Jev"    bash -c '[ "$1" -eq 1 ] && jq -e ".body.state == \"desenhe a arquitetura do serviço de filas\"" <<<"$2" >/dev/null' _ "$(ts_calls)" "$(ts_last)"
ts_reset
t avulsa-fim claude --verbose -- "desenhe a arquitetura do serviço de filas"
check "depois do -- que fecha as opções: o prompt vai ao Jev" bash -c '[ "$1" -eq 1 ] && jq -e ".body.state == \"desenhe a arquitetura do serviço de filas\"" <<<"$2" >/dev/null' _ "$(ts_calls)" "$(ts_last)"
ts_reset
t avulsa-palavra claude continue
check "prompt de uma palavra só: sem Jev"              [ "$(ts_calls)" -eq 0 ]
t 40-comlabel claude "desenhe a arquitetura do serviço de filas"
check "label de fase: vale o label, sem Jev"           [ "$(args claude)" == "--model claude-sonnet-5-5 desenhe a arquitetura do serviço de filas" -a "$(ts_calls)" -eq 0 ]
t avulsa-shell shell
check "shell: sem Jev"                                 [ "$(ts_calls)" -eq 0 ]
(cd "$WS/proj" && OUTE_TYPESAFE_API_KEY="" "$TASK" avulsa-semchave claude "desenhe a arquitetura do serviço de filas" >/dev/null 2>"$TMP/err" </dev/null)
check "sem chave: abre no Sonnet, com aviso, sem chamar o Jev" bash -c '[ "$1" == "--model claude-sonnet-5-5 desenhe a arquitetura do serviço de filas" ] && grep -qF "sem a chave da TypeSafe" "$2" && [ "$3" -eq 0 ]' _ "$(args claude)" "$TMP/err" "$(ts_calls)"
check "sem chave: origem padrao, sem confiança"        bash -c '[ -z "$1" ]' _ "$(cf)"
ts_stop; ts_off

# 10l. reserva no Codex (#258): `claude auth status` ≠ 0 abre o Codex da linha da fase, grava o agente na marca e manda o motivo
rmark() { jqe '.attrs | has("oute.task.reserve") | not' <<<"$(last)"; }   # o último evento sem o motivo da reserva
t 40-normal claude "p"
check "reserva: claude ok, sem reserve no evento"      rmark
export FAKE_CLAUDE_AUTH_RC=1
rm -f "${FAKE:?}/codex.args" "${FAKE:?}/codex.env" "${FAKE:?}/claude.args"
t 40-reserva claude "faça a 40"
check "reserva: abre o codex da linha build, com -m e esforço" [ "$RC" -eq 0 -a "$(args codex)" == "-m gpt-6.1-sol -c model_reasoning_effort=high faça a 40" ]
check "reserva: o claude não é executado (só o auth status)" [ ! -e "$FAKE/claude.args" ]
check "reserva: opened com agente codex, modelo, esforço e reserve" bash -c 'jq -e ".name == \"oute.task.opened\" and .attrs[\"oute.task.agent\"] == \"codex\" and .attrs[\"oute.task.model\"] == \"gpt-6.1-sol\" and .attrs[\"oute.task.effort\"] == \"high\" and .attrs[\"oute.task.reserve\"] == \"indisponivel\" and .attrs[\"oute.task.origin\"] == \"label\"" <<<"$1" >/dev/null' _ "$(last)"
check "reserva: marca guarda o codex (o restore reabre nele)" [ "$(smark "$SP/proj-40-reserva")" == "codex|gpt-6.1-sol|high" ]
check "reserva: o aviso do seletor sai"                grep -qF "abrindo no Codex (reserva)" <<<"$SELW"
FAKE_RC=0 t 40-reserva claude "faça a 40"
check "reserva, reabertura: reopened com agente codex e reserve" bash -c 'jq -e ".name == \"oute.task.reopened\" and .attrs[\"oute.task.agent\"] == \"codex\" and .attrs[\"oute.task.reserve\"] == \"indisponivel\"" <<<"$1" >/dev/null' _ "$(last)"
check "reserva, reabertura: o evento diz de qual assinatura saiu (reserve_from=claude, #598)" jqe '.attrs["oute.task.reserve_from"] == "claude"' <<<"$(last)"
# escolha explícita não cai na reserva
rm -f "${FAKE:?}/claude.args"
t --agent claude 40-explicito claude "p"
check "explícito (--agent claude): abre o claude com o modelo da fase" [ "$RC" -eq 0 -a "$(args claude)" == "--model claude-sonnet-5-5 p" ]
check "explícito (--agent claude): sem reserve, com aviso" bash -c 'grep -qF "explícita" <<<"$1"' _ "$SELW"
check "explícito (--agent claude): evento sem reserve"  rmark
t 40-modelo claude --model claude-opus-5-5 "p"
check "explícito (--model nos argumentos): abre o claude, sem reserve" bash -c '[ "$1" == "--model claude-opus-5-5 p" ]' _ "$(args claude)"
check "explícito (--model nos argumentos): evento sem reserve" rmark
rm -f "${FAKE:?}/claude.args"
t --phase plan 40-fixa claude "p"
check "fase fixa: abre o claude, sem reserve, com aviso" bash -c '[ "$1" == "--model claude-sonnet-5-5 p" ] && grep -qF "explícita" <<<"$2"' _ "$(args claude)" "$SELW"
# os dois fora: abre no Claude, aviso, código 0
export FAKE_CODEX_LOGIN_RC=1
t 40-doisfora claude "p"
check "os dois fora: abre o claude, código 0, aviso"   bash -c '[ "$1" -eq 0 ] && [ "$2" == "agente falso claude" ] && grep -qF "Claude e Codex indisponíveis" <<<"$3"' _ "$RC" "$OUT" "$SELW"
unset FAKE_CODEX_LOGIN_RC FAKE_CLAUDE_AUTH_RC
check "os dois fora: evento com agente claude, sem reserve" bash -c 'jq -e ".attrs[\"oute.task.agent\"] == \"claude\" and (.attrs | has(\"oute.task.reserve\") | not)" <<<"$1" >/dev/null' _ "$(last)"
# --prefer (#621): pedido de reserva sem ser escolha explícita; com a pedida no teto, a sessão volta para a padrão
. "$ROOT/tests/lib/quota-json.sh"
qcota 10 20; rm -f "${FAKE:?}/codex.args" "${FAKE:?}/claude.args"
t --prefer codex 40-prefer-livre claude "p"
check "--prefer codex com folga: abre o Codex" [ "$RC" -eq 0 -a "$(args codex)" == "-m gpt-6.1-sol -c model_reasoning_effort=high p" ]
check "--prefer codex com folga: evento sem reserve" rmark
qcota 10 99; rm -f "${FAKE:?}/codex.args" "${FAKE:?}/claude.args"
t --prefer codex 40-prefer-cheia claude "p"
check "--prefer codex no teto: volta para o Claude da linha" [ "$RC" -eq 0 -a "$(args claude)" == "$MS p" -a ! -e "$FAKE/codex.args" ]
check "--prefer codex no teto: evento com reserve=cota e reserve_from=codex" jqe '.attrs["oute.task.agent"] == "claude" and .attrs["oute.task.reserve"] == "cota" and .attrs["oute.task.reserve_from"] == "codex"' <<<"$(last)"
t --prefer codex --agent claude 40-prefer-explicito claude "p"
check "--prefer com --agent: a escolha explícita vence, código 0" [ "$RC" -eq 0 ]
check "--prefer com --agent: evento sem reserve" rmark
t --prefer 'X;y' 40-prefer-ruim claude "p"
check "--prefer com formato inválido: recusa, sem worktree" [ "$RC" -ne 0 -a ! -d "$SP/proj-40-prefer-ruim" ]
t --prefer nada 40-prefer-nada claude "p"
check "--prefer fora da tabela: recusa (código do seletor), sem worktree" [ "$RC" -ne 0 -a ! -d "$SP/proj-40-prefer-nada" ]
rm -f "${FAKE:?}/quota.json"
# oute-emit task: reserve só indisponivel|cota, e só no opened/reopened
before="$(total)"
oute-emit task opened human repo=a slug=b reserve=chute
check "oute-emit task: reserve inválido não emite"     [ "$(total)" -eq "$before" ]
oute-emit task opened human repo=a slug=b agent=codex reserve=cota
check "oute-emit task: reserve=cota vale"              jqe '.attrs["oute.task.reserve"] == "cota"' <<<"$(last)"
oute-emit task opened human repo=a slug=b agent=codex reserve=cota reserve_from=claude
check "oute-emit task: reserve_from vale com reserve"  jqe '.attrs["oute.task.reserve_from"] == "claude" and .attrs["oute.task.reserve"] == "cota"' <<<"$(last)"
before="$(total)"
oute-emit task opened human repo=a slug=b agent=codex reserve=cota 'reserve_from=Claude; x'
check "oute-emit task: reserve_from inválido não emite" [ "$(total)" -eq "$before" ]
oute-emit task opened human repo=a slug=b agent=codex reserve_from=claude
check "oute-emit task: reserve_from sem reserve não emite" [ "$(total)" -eq "$before" ]
oute-emit task removed human repo=a slug=b reason=merged reserve=indisponivel reserve_from=claude
check "oute-emit task: removed sem o reserve_from"     jqe '.attrs | has("oute.task.reserve_from") | not' <<<"$(last)"
oute-emit task removed human repo=a slug=b reason=merged reserve=indisponivel
check "oute-emit task: removed sem o reserve"          jqe '.name == "oute.task.removed" and (.attrs | has("oute.task.reserve") | not)' <<<"$(last)"
check "nenhum oute.task.* com corpo (seletor)"         [ "$(task_ev '.body != null' | grep -c .)" -eq 0 ]
rcv_stop

# ---------------------------------------------------------------- 11. snapshot da cota na abertura (#347)
rcv_start "$TMP/r11"
QB="$TMP/qbin"; mkdir -p "$QB"
cat > "$QB/oute-quota" <<'SH'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ ! -f "$d/sleep" ]] || sleep "$(cat "$d/sleep")"
[[ ! -f "$d/json" ]] || cat "$d/json"
exit "$(cat "$d/rc" 2>/dev/null || echo 0)"
SH
chmod +x "$QB/oute-quota"
R5="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"schema":1,"agents":{"claude":{"status":"ok","stale":false,"age_s":0,"windows":{"5h":{"used_pct":15,"resets_at":"%s"}}},"codex":{"status":"unknown","reason":"sem-credencial","windows":{}}}}' "$R5" > "$QB/json"
# espera (até 10 s) o que o segundo plano ainda vai entregar
until_n() { local i; for i in $(seq 1 100); do [[ "$(eval "$1")" -ge "$2" ]] && return 0; sleep 0.1; done; return 1; }
OLDPATH="$PATH"; export PATH="$QB:$PATH"
FAKE_RC=5 t cota-1 claude "p"
check "cota: a abertura mantém o exec e o código do agente" bash -c '[ "$1" -eq 5 ] && [ "$2" = "agente falso claude" ]' _ "$RC" "$OUT"
check "cota: stderr só com a linha da worktree"        [ "$ERR" == "worktree $SP/proj-cota-1 · branch sessao/cota-1 (de origin/main)" ]
check "cota: os pontos do Claude chegam (momento open no evento do Codex)" until_n "mp '.name == \"oute.quota.reset_in_seconds\" and .res[\"oute.agent\"] == \"claude\"' | grep -c ." 1
check "cota: unknown do Codex com o motivo e o momento open" until_n "n '.name == \"oute.quota.unknown\" and .attrs[\"oute.quota.reason\"] == \"sem-credencial\" and .attrs[\"oute.quota.moment\"] == \"open\" and .attrs[\"oute.agent\"] == \"codex\"'" 1
check "cota: o recurso do ponto leva a origem, não a marca da sessão" jqe -s 'length >= 1 and all(.[]; .res["host.name"] == "oute-mac" and (.res | has("oute.task.id") | not))' <<<"$(mp '.name | startswith("oute.quota.")')"
before="$(mp 'true' | grep -c .)"
t cota-1 codex
check "cota: reabrir também faz o snapshot (novos pontos do Claude)" until_n "mp '.name == \"oute.quota.used_pct\"' | grep -c ." $((before / 2 + 1))
# leitura lenta: a abertura volta antes e com a mesma saída
echo 6 > "$QB/sleep"
# O prazo abaixo mede o snapshot assíncrono; a leitura do seletor tem teto curto só neste caso.
t0=$(date +%s); FAKE_RC=5 OUTE_SELECT_QUOTA_TIMEOUT=0.3 t cota-2 claude "p"; dt=$(( $(date +%s) - t0 ))
check "cota lenta: a abertura não espera a leitura ($dt s)" bash -c '[ "$1" -eq 5 ] && [ "$2" -le 4 ] && [ "$3" = "agente falso claude" ]' _ "$RC" "$dt" "$OUT"
# oute-quota que falha (rc 2, sem saída): a abertura é a mesma
rm -f "${QB:?}/sleep"; echo 2 > "${QB:?}/rc"; : > "${QB:?}/json"
FAKE_RC=5 t cota-3 claude "p"
check "cota com falha na leitura: abertura igual"      bash -c '[ "$1" -eq 5 ] && [ "$2" = "agente falso claude" ] && [ "$3" = "worktree $4/proj-cota-3 · branch sessao/cota-3 (de origin/main)" ]' _ "$RC" "$OUT" "$ERR" "$SP"
check "cota com falha na leitura: o oute.task.opened sai" [ "$(task_ev '.attrs["oute.task.slug"] == "cota-3"' | grep -c .)" -eq 1 ]
export PATH="$OLDPATH"
# O receptor segue ativo até o trap: o prazo dos handoffs não deve incluir retries de um coletor fora do ar.

# ---------------------------------------------------------------- 12. clean: sessão em uso (#374)
# Duas rodadas no mesmo space: a swarm-0303-1000 fecha e roda o clean; a swarm-0303-1001 segue aberta, com um worker
# sem commit (aba viva), outro com a aba morta, um fechado (closed) e o dispatcher dela. Tudo "sem commits": antes
# da #374 o clean listava e removia todas.
SW="$HOME/.oute/swarm"; SP11="$WT/_sem-space"
for r in swarm-0303-1000 swarm-0303-1001; do mkdir -p "$SW/$r"; echo "repo=$WS/proj" > "$SW/$r/meta"; done
mark_tab() { jq -cn --argjson ids "$(printf '%s\n' "$@" | jq -R . | jq -cs .)" '{result: {tabs: [$ids[] | {tab_id: .}]}}'; }
OUTE_SWARM_ID=swarm-0303-1001 OUTE_SWARM_ROUND=swarm-0303-1001 t 501-vivo claude    # worker com aba viva
OUTE_SWARM_ID=swarm-0303-1001 OUTE_SWARM_ROUND=swarm-0303-1001 t 502-morto claude   # aba sumiu do herdr
OUTE_SWARM_ID=swarm-0303-1001 OUTE_SWARM_ROUND=swarm-0303-1001 t 503-fechado claude # oute-swarm close já passou
OUTE_SWARM_ROUND=swarm-0303-1000 t 401-propria claude                               # da rodada que fecha
for p in 501-vivo 502-morto 503-fechado; do
  mark_f="$(gitdir "$SP11/proj-$p")/oute-task"; printf 'id=x-%s\nrepo=proj\nslug=%s\nround=swarm-0303-1001\nsession=%s\n' "$p" "$p" "$p" > "$mark_f"
done
mark_f="$(gitdir "$SP11/proj-401-propria")/oute-task"; printf 'id=x-401\nrepo=proj\nslug=401-propria\nround=swarm-0303-1000\nsession=401-propria\n' > "$mark_f"
git -C "$WS/proj" worktree add -q -b sessao/swarm-0303-1001 "$SP11/proj-swarm-0303-1001" origin/main   # dispatcher da outra
git -C "$WS/proj" worktree add -q -b sessao/swarm-0303-1000 "$SP11/proj-swarm-0303-1000" origin/main   # dispatcher que fecha
printf '501-vivo w1:p1 claude 2026-10-03T10:00:00Z w1:t501 %s -\n502-morto w1:p2 claude 2026-10-03T10:00:00Z w1:t502 %s -\n503-fechado w1:p3 claude 2026-10-03T10:00:00Z w1:t503 %s -\n' "$WS/proj" "$WS/proj" "$WS/proj" > "$SW/swarm-0303-1001/spawned"
printf '401-propria w1:p4 claude 2026-10-03T10:00:00Z w1:t401 %s -\n' "$WS/proj" > "$SW/swarm-0303-1000/spawned"
echo 503-fechado > "$SW/swarm-0303-1001/closed"; : > "$SW/swarm-0303-1000/closed"
echo 401-propria >> "$SW/swarm-0303-1000/closed"; date -u +%FT%TZ > "$SW/swarm-0303-1000/fechada"   # rodada que fecha: já fechada
mark_tab w1:t501 w1:t503 > "$FAKE/tabs"
t clean
check "em uso: worker com aba viva fica, com a rodada"      grep -qx "em uso  $SP11/proj-501-vivo (rodada swarm-0303-1001)" <<<"$OUT"
check "em uso: dispatcher de rodada aberta fica"            grep -qx "em uso  $SP11/proj-swarm-0303-1001 (dispatcher da rodada swarm-0303-1001)" <<<"$OUT"
check "em uso: aba morta não protege (a sessão acabou)"     grep -qx "remover $SP11/proj-502-morto (sem commits além de origin/main)" <<<"$OUT"
check "em uso: sessão em closed não protege"                grep -qx "remover $SP11/proj-503-fechado (sem commits além de origin/main)" <<<"$OUT"
check "em uso: worker da rodada fechada não protege"        grep -qx "remover $SP11/proj-401-propria (sem commits além de origin/main)" <<<"$OUT"
check "em uso: dispatcher de rodada fechada não protege"    grep -qx "remover $SP11/proj-swarm-0303-1000 (sem commits além de origin/main)" <<<"$OUT"
t clean --yes
check "clean --yes: o worker e o dispatcher da outra rodada ficam" [ -d "$SP11/proj-501-vivo" -a -d "$SP11/proj-swarm-0303-1001" ]
check "clean --yes: o que não está em uso sai"              [ ! -d "$SP11/proj-502-morto" -a ! -d "$SP11/proj-503-fechado" -a ! -d "$SP11/proj-401-propria" -a ! -d "$SP11/proj-swarm-0303-1000" ]
# herdr fora do ar: vale o spawned (a sessão não fechada fica); sem herdr e sem estado de rodada, o comportamento de antes
rm -f "${FAKE:?}/tabs"
t clean
check "herdr fora do ar: sessão não fechada do spawned fica" grep -qx "em uso  $SP11/proj-501-vivo (rodada swarm-0303-1001)" <<<"$OUT"
# a worktree de quem chama o clean nunca é removida
t 504-propria claude
OUT="$(cd "$SP11/proj-504-propria" && "$TASK" clean --yes 2>&1 </dev/null)"
check "do próprio processo: a worktree onde o clean roda fica" bash -c '[ -d "$1" ] && grep -qx "em uso  $2 (esta sessão)" <<<"$3"' _ "$SP11/proj-504-propria" "$SP11/proj-504-propria" "$OUT"
# agente rodando com o cwd na worktree
t 505-agente claude
cp "$(command -v sleep)" "$TMP/claude"   # processo de nome "claude" (comm), como o agente
( cd "$SP11/proj-505-agente" && exec "$TMP/claude" 30 ) >/dev/null 2>&1 & agpid=$!
sleep 0.3
t clean
check "agente rodando no cwd: fica, com o pid"              grep -qxE "em uso  $SP11/proj-505-agente \(agente rodando \(pid [0-9]+\)\)" <<<"$OUT"
# --force-in-use remove mesmo assim; sem ele nunca
t clean --yes --force-in-use
check "--force-in-use: remove as em uso"                    [ ! -d "$SP11/proj-501-vivo" -a ! -d "$SP11/proj-swarm-0303-1001" -a ! -d "$SP11/proj-505-agente" ]
kill "$agpid" 2>/dev/null; wait "$agpid" 2>/dev/null
t clean --force-in-use --bogus
check "opção desconhecida: código diferente de 0"           [ "$RC" -ne 0 ]
check "opção desconhecida: o uso cita --force-in-use"       grep -qF -- '[--force-in-use]' <<<"$ERR"
# processo que morre no meio da varredura do /proc (#672): o /proc/<pid> fica sem `comm`. A proc_comm do oute-task é
# extraída por sed (como a setup_agents em entrypoint-config.test.sh) e roda com um /proc de mentira.
PCF="$TMP/proc-comm.sh"; sed -n '/^proc_comm() {/,/^}/p' "$TASK" > "$PCF"
check "comm: proc_comm extraída do oute-task"               grep -q '^proc_comm() {' "$PCF"
check "comm: a varredura do /proc lê pela proc_comm"        grep -qF 'comm="$(proc_comm "$c")"' "$TASK"
mkdir -p "$TMP/proc/morto" "$TMP/proc/vivo"; printf 'claude\n' > "$TMP/proc/vivo/comm"
pcomm() {   # <dir>: roda a proc_comm; saída em OUT, stderr em ERR, código em RC
  local d="$1"
  OUT="$(bash -c '. "$1" 2>/dev/null; proc_comm "$2"' _ "$PCF" "$d" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
  return 0
}
pcomm "$TMP/proc/morto"
check "comm: processo que morreu não escreve em stderr"     [ -z "$ERR" ]
check "comm: processo que morreu dá nome vazio e código 0"  [ -z "$OUT" -a "$RC" -eq 0 ]
pcomm "$TMP/proc/vivo"
check "comm: processo vivo dá o nome, sem stderr"           [ "$OUT" = claude -a -z "$ERR" -a "$RC" -eq 0 ]

# ---------------------------------------------------------------- 12b. clean: handoffs abertos das worktrees removidas (#435)
# O clean só LISTA (uma linha por handoff, formato estável); cancelar é do agente (memory_handoff_cancel). Nunca --expire-all.
HFL="$TMP/handoffs.log"; export FAKE_AI_MEMORY_LOG="$HFL"; : > "$HFL"
HF="$TMP/handoffs.json"; export FAKE_AI_MEMORY_HANDOFFS="$HF"
for s in hf1 hf-det hf-fica; do t "$s" claude; done
echo x > "$SP/proj-hf-fica/novo.txt"                                   # mudança local: o clean a pula
git -C "$SP/proj-hf-det" checkout -q --detach origin/main
jq -n --arg a "$SP/proj-hf1" --arg d "$SP/proj-hf-det" --arg f "$SP/proj-hf-fica" --arg x "$SP/proj-hf1/sub" --arg o "$TMP/ws/outro-repo-wt" \
  '[{id:"h-hf1",cwd:$a},{id:"h-det",cwd:$d},{id:"h-fica",cwd:$f},{id:"h-outro",cwd:$o},{id:"h-semcwd"},{id:"h-nulo",cwd:null},
    {id:"h-prefixo",cwd:$x},{id:"h bad;id",cwd:$a},{id:"h-hf1-dup",cwd:$a}]' > "$HF"
t clean
check "handoffs, simulação: lista o da worktree a remover, formato estável" grep -qxF "handoff id=h-hf1 workspace=default project=proj cwd=$SP/proj-hf1" <<<"$OUT"
check "handoffs, simulação: lista o da detached"        grep -qxF "handoff id=h-det workspace=default project=proj cwd=$SP/proj-hf-det" <<<"$OUT"
check "handoffs, simulação: todos os da mesma worktree, uma linha cada" [ "$(grep -c "^handoff .* cwd=$SP/proj-hf1\$" <<<"$OUT")" -eq 2 ]
check "handoffs: worktree pulada, outro repo, sem cwd, cwd nulo, prefixo e id inválido ficam de fora" bash -c '[ "$(grep -c "^handoff " <<<"$1")" -eq 3 ] && ! grep -qE "h-fica|h-outro|h-semcwd|h-nulo|h-prefixo|bad" <<<"$1"' _ "$OUT"
check "handoffs, simulação: não remove e consulta com workspace e project explícitos" bash -c '[ -d "$1" ] && grep -qxF -- "handoffs --workspace default --project proj --limit 500 --json" "$2"' _ "$SP/proj-hf1" "$HFL"
check "handoffs, simulação: código 0, stderr vazio"     [ "$RC" -eq 0 -a -z "$ERR" ]
t clean --yes
check "handoffs, --yes: lista o da worktree removida e a remove" bash -c '[ ! -e "$1" ] && grep -qxF "handoff id=h-hf1 workspace=default project=proj cwd=$1" <<<"$2" && grep -qxF "handoff id=h-det workspace=default project=proj cwd=$3" <<<"$2"' _ "$SP/proj-hf1" "$OUT" "$SP/proj-hf-det"
check "handoffs, --yes: a pulada fica e não é listada"  bash -c '[ -d "$1" ] && ! grep -q "h-fica" <<<"$2"' _ "$SP/proj-hf-fica" "$OUT"
check "handoffs: o clean nunca cancela (nenhuma chamada além de handoffs … --json)" bash -c '! grep -qE "expire|cancel|confirm" "$1" && [ "$(grep -vc "^handoffs .* --json\$" "$1")" -eq 0 ]' _ "$HFL"
: > "$HFL"; t clean --yes
check "handoffs: nada a remover, ai-memory não é consultado" [ "$RC" -eq 0 -a ! -s "$HFL" ] 
check "handoffs: nada a remover, nenhuma linha handoff/aviso" bash -c '! grep -qE "^(handoff|aviso)" <<<"$1"' _ "$OUT"
# escopo do .ai-memory.toml do repo
printf 'workspace = "ws-x"\nproject = "proj-x"\n' > "$WS/proj/.ai-memory.toml"
t toml1 claude; jq -n --arg a "$SP/proj-toml1" '[{id:"h-toml",cwd:$a}]' > "$HF"; : > "$HFL"
t clean --yes
check "handoffs: workspace e project do .ai-memory.toml do repo" bash -c 'grep -qxF "handoff id=h-toml workspace=ws-x project=proj-x cwd=$1" <<<"$2" && grep -qxF -- "handoffs --workspace ws-x --project proj-x --limit 500 --json" "$3"' _ "$SP/proj-toml1" "$OUT" "$HFL"
rm -f "${WS:?}/proj/.ai-memory.toml"
# ai-memory com erro, com lixo, sem resposta e ausente: avisa numa linha e segue
t err1 claude; jq -n --arg a "$SP/proj-err1" '[{id:"h-err",cwd:$a}]' > "$HF"
FAKE_AI_MEMORY_RC=1 t clean
check "ai-memory com erro: avisa numa linha, código 0, sem handoff" bash -c '[ "$1" -eq 0 ] && [ "$(grep -c "^aviso: " <<<"$2")" -eq 1 ] && grep -qxF "aviso: não consegui listar os handoffs do ai-memory (default/proj); nada listado" <<<"$2" && ! grep -q "^handoff " <<<"$2"' _ "$RC" "$OUT"
echo 'isto não é JSON' > "$HF"
t clean
check "ai-memory com lixo: avisa e segue"               bash -c '[ "$1" -eq 0 ] && grep -qxF "aviso: não consegui listar os handoffs do ai-memory (default/proj); nada listado" <<<"$2"' _ "$RC" "$OUT"
jq -n --arg a "$SP/proj-err1" '[{id:"h-err",cwd:$a}]' > "$HF"
# Este caso mede o prazo dos handoffs; a proteção de sessão em uso já foi conferida na seção 12.
t0=$(date +%s); FAKE_AI_MEMORY_SLEEP=40 OUTE_HANDOFFS_TIMEOUT=1 t clean --yes --force-in-use
check "ai-memory sem resposta: avisa, segue e remove, dentro do prazo" bash -c '[ "$1" -eq 0 ] && grep -qxF "aviso: não consegui listar os handoffs do ai-memory (default/proj); nada listado" <<<"$2" && [ ! -e "$3" ] && [ $(( $(date +%s) - $4 )) -le 25 ]' _ "$RC" "$OUT" "$SP/proj-err1" "$t0"
t abs1 claude
NOAM="$TMP/bin-noam"; mkdir -p "$NOAM"
for d in "$BIN" ${PATH//:/ }; do for f in "$d"/*; do [[ -x "$f" && "${f##*/}" != ai-memory ]] && ln -s "$f" "$NOAM/${f##*/}" 2>/dev/null; done; done
OUT="$(cd "$WS/proj" && PATH="$NOAM" "$TASK" clean --yes 2>"$TMP/err" </dev/null)"; RC=$?
check "ai-memory ausente: avisa numa linha, código 0, remove" bash -c '[ "$1" -eq 0 ] && grep -qxF "aviso: ai-memory ou jq ausente; handoffs de proj não listados" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$OUT" "$SP/proj-abs1"
unset FAKE_AI_MEMORY_LOG FAKE_AI_MEMORY_HANDOFFS

# ---------------------------------------------------------------- 12. shim: sessão interativa sob `ai-memory run` (opt-in, #367)
# ai-memory falso (tests/lib/fake-ai-memory.sh): `run` grava a linha no log e executa o --executable com AI_MEMORY_RUN_ID.
# Precisa de terminal (o shim só age com tty): script(1), como a seção 3.
if ! has_pty; then
  echo "skip memory run: sem script(1) do util-linux"
else
  . "$ROOT/tests/lib/fake-ai-memory.sh"
  AMEM="$TMP/amem"; fake_ai_memory_install "$AMEM"
  export FAKE_AI_MEMORY_LOG="$TMP/amem.log"
  amlog() { cat "$FAKE_AI_MEMORY_LOG" 2>/dev/null; }
  amreset() { rm -f "${FAKE_AI_MEMORY_LOG:?}" "${FAKE:?}"/claude.* "${FAKE:?}"/codex.*; }
  # pty <dir> <comando…>: roda com terminal (stdin do script = $PTY_IN); saída sem CR em $OUT, código em $RC
  pty() {
    local d="$1"; shift
    printf '%s' "${PTY_IN:-}" | script -qec "cd '$d' && $*" /dev/null > "$TMP/pty.out" 2>&1; RC=$?
    OUT="$(tr -d '\r' < "$TMP/pty.out")"
  }
  MPATH="$SHIMS:$AMEM:$PATH"
  t mr0 claude
  W="$SP/proj-mr0"; mid="$(mark "$W" id)"
  MARK="$ORIGIN,oute.task.id=$mid,oute.task.repo=proj,oute.task.slug=mr0,oute.subscription=claude"
  : > "$FAKE_AI_MEMORY_LOG"

  # desligado (vazio, 0, ausente): nenhuma chamada ao ai-memory; argumentos e ambiente como hoje
  for v in unset "" 0; do
    amreset
    if [[ "$v" == unset ]]; then PATH="$MPATH" pty "$W" "$SHIMS/claude oi"; else OUTE_MEMORY_RUN="$v" PATH="$MPATH" pty "$W" "$SHIMS/claude oi"; fi
    check "run desligado (${v:-vazio}): nenhuma chamada ao ai-memory" [ -z "$(amlog)" ]
    check "run desligado (${v:-vazio}): argumentos e marca como hoje, sem AI_MEMORY_RUN_ID" bash -c '[ "$(cat "$1/claude.args")" == oi ] && [ "$(sed -n "s/^OTEL_RESOURCE_ATTRIBUTES=//p" "$1/claude.env")" == "$2" ] && ! grep -q "^AI_MEMORY_RUN_ID=" "$1/claude.env"' _ "$FAKE" "$MARK"
  done

  # ligado: exec ai-memory run <agente> --no-autowire --executable <binário real> -- <args>, sem --yolo
  amreset; OUTE_MEMORY_RUN=1 PATH="$MPATH" pty "$W" "$SHIMS/claude oi"
  check "run ligado (claude): a linha do ai-memory é a esperada, sem --yolo" [ "$(amlog)" == "run claude --no-autowire --executable $BIN/claude -- oi" ]
  check "run ligado (claude): o agente roda na worktree, com os argumentos e AI_MEMORY_RUN_ID" bash -c '[ "$(cat "$1/claude.args")" == oi ] && [ "$(cat "$1/claude.pwd")" == "$2" ] && grep -qx "AI_MEMORY_RUN_ID=fake-run" "$1/claude.env"' _ "$FAKE" "$(cd "$W" && pwd -P)"
  check "run ligado (claude): OTEL_RESOURCE_ATTRIBUTES chega ao agente" [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$MARK" ]
  amreset; OUTE_MEMORY_RUN=1 PATH="$MPATH" pty "$W" "$SHIMS/codex oi"
  check "run ligado (codex): run codex ..., sem --yolo" [ "$(amlog)" == "run codex --no-autowire --executable $BIN/codex -- oi" ]
  check "run ligado (codex): marca e AI_MEMORY_RUN_ID chegam" [ "$(aenv codex OTEL_RESOURCE_ATTRIBUTES)" == "$MARK" -a "$(aenv codex AI_MEMORY_RUN_ID)" == fake-run ]
  amreset; OUTE_MEMORY_RUN=yes PATH="$MPATH" pty "$W" "$SHIMS/claude oi"
  check "run ligado com qualquer valor diferente de vazio e 0" [ -n "$(amlog)" ]

  # passa direto, sem chamar o ai-memory
  gw="$(gitdir "$W")"
  no_run() {   # <descrição> <dir> <comando…>
    local d="$1" w="$2" ag="$4"
    amreset; OUTE_MEMORY_RUN=1 PATH="$MPATH" pty "$w" "$3"
    check "run ligado, $d: passa direto, sem ai-memory run" bash -c '[ -z "$(cat "$2" 2>/dev/null)" ] && [ -f "$1/$3.args" ]' _ "$FAKE" "$FAKE_AI_MEMORY_LOG" "$ag"
  }
  no_run "headless (-p)"       "$W" "$SHIMS/claude -p oi" claude
  no_run "--resume"            "$W" "$SHIMS/claude --resume conv-x" claude
  no_run "--continue"          "$W" "$SHIMS/claude -c" claude
  no_run "codex exec"          "$W" "$SHIMS/codex exec oi" codex
  no_run "codex resume"        "$W" "$SHIMS/codex resume conv-x" codex
  no_run "codex mcp (subcomando)" "$W" "$SHIMS/codex mcp list" codex
  no_run "já sob run (AI_MEMORY_RUN_ID)" "$W" "AI_MEMORY_RUN_ID=outro $SHIMS/claude oi" claude
  touch "${gw:?}/oute-swarm-worker"; no_run "worker do swarm" "$W" "$SHIMS/claude oi" claude; rm -f "${gw:?}/oute-swarm-worker"
  amreset; OUT="$(cd "$W" && OUTE_MEMORY_RUN=1 PATH="$MPATH" "$SHIMS/claude" oi 2>&1 </dev/null)"   # só atribuição vazaria o PATH para o resto do arquivo (#678)
  check "run ligado, sem terminal: passa direto" [ -z "$(amlog)" -a -f "$FAKE/claude.args" ]
  no_run "fora de repo"        "$TMP" "$SHIMS/claude oi" claude

  # ai-memory ausente: passa direto, com aviso em stderr
  amreset; OUTE_MEMORY_RUN=1 PATH="$SHIMS:$NOTASK:/usr/bin:/bin" pty "$W" "$SHIMS/claude oi"
  check "ai-memory ausente: avisa e abre o agente igual" bash -c 'grep -qF "ai-memory não está no PATH" <<<"$1" && [ "$(cat "$2/claude.args")" == oi ]' _ "$OUT" "$FAKE"

  # checkout principal: o oute-task vem antes, e a sessão da worktree nasce sob run, com a marca e o modelo
  amreset; PTY_IN=$'mr1\n' OUTE_MEMORY_RUN=1 PATH="$MPATH" pty "$WS/proj" "$SHIMS/claude 'faça x'"
  check "checkout principal: oute-task abre a worktree e a sessão roda sob run" bash -c '[ "$(cat "$1/claude.pwd")" == "$2" ] && [ "$(sed -n "1p" "$3")" == "run claude --no-autowire --executable $4/claude -- --model claude-sonnet-5-5 faça x" ]' _ "$FAKE" "$(cd "$SP/proj-mr1" && pwd -P)" "$FAKE_AI_MEMORY_LOG" "$BIN"
  check "checkout principal: um só run; marca e argumentos de modelo chegam" bash -c '[ "$(grep -c . "$1")" -eq 1 ] && [ "$(cat "$2/claude.args")" == "$(printf -- "--model\nclaude-sonnet-5-5\nfaça x")" ] && grep -q "^OTEL_RESOURCE_ATTRIBUTES=.*oute.task.slug=mr1" "$2/claude.env"' _ "$FAKE_AI_MEMORY_LOG" "$FAKE"
  amreset; PTY_IN=$'mr2\n' PATH="$MPATH" pty "$WS/proj" "$SHIMS/claude 'faça y'"
  check "checkout principal, desligado: sem ai-memory, mesma worktree e modelo" [ -z "$(amlog)" -a -d "$SP/proj-mr2" -a "$(sed -n 1p "$FAKE/claude.args")" == --model ]
fi

# ---------------------------------------------------------------- 13. assinatura zai (#678, ADR-02 e ADR-01)
# a sessão da zai é o `claude` com as variáveis da Z.ai só no processo que abre, --settings negando o Read de imagem, a
# assinatura na marca, na conversa e no evento; a chave (gerada na hora) nunca aparece em argv, tela, marca nem evento
rcv_stop; rcv_start "$TMP/r13"
ZKEY="zai-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
ZTABLE="$ROOT/config/select/models.toml"   # a tabela de verdade: build abre na zai (cadeia zai → claude → codex)
ZSET='{"permissions":{"deny":["Read(**/*.png)","Read(**/*.jpg)","Read(**/*.jpeg)","Read(**/*.gif)","Read(**/*.webp)","Read(**/*.bmp)"]}}'
ZURL="https://api.z.ai/api/anthropic"
tz() { OUTE_ZAI_API_KEY="$ZKEY" OUTE_SELECT_TABLE="$ZTABLE" t "$@"; return $?; }          # com a chave, tabela de verdade
tn() { OUTE_SELECT_TABLE="$ZTABLE" t "$@"; return $?; }                                     # sem a chave
zvars() {   # <agente>: as sete variáveis da zai que o agente recebeu, uma por linha (nome=valor)
  local agent="$1"
  grep -E '^(ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_DEFAULT_OPUS_MODEL|ANTHROPIC_DEFAULT_SONNET_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL|API_TIMEOUT_MS|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)=' "$FAKE/$agent.env" | sort
  return 0
}
ZWANT="$(printf '%s\n' "ANTHROPIC_AUTH_TOKEN=$ZKEY" "ANTHROPIC_BASE_URL=$ZURL" "ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.3" "ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.3" \
  "ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3" "API_TIMEOUT_MS=3000000" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" | sort)"
mkdir -p "$HOME/.claude"; printf '{"permissions":{"defaultMode":"bypassPermissions"}}\n' > "$HOME/.claude/settings.json"
SET_SUM="$(cksum < "$HOME/.claude/settings.json")"
labels 60 aidlc:build; labels 61 aidlc:spec; labels 62 aidlc:build

# 13a. issue aidlc:build, sem opção: abre na zai
rm -f "${FAKE:?}"/claude.* "${FAKE:?}"/codex.*
FAKE_RC=3 tz 60-zai claude "faça a 60"
check "zai: build abre o claude com --model glm-5.3, --settings e o prompt" [ "$RC" -eq 3 -a "$(cat "$FAKE/claude.args")" == "$(printf -- '--model\nglm-5.3\n--settings\n%s\nfaça a 60' "$ZSET")" ]
check "zai: as sete variáveis no ambiente do processo"  [ "$(zvars claude)" == "$ZWANT" ]
check "zai: sem aviso e sem a chave na tela"            bash -c '[ -z "$1" ] && ! grep -qF "$2" <<<"$3"' _ "$SELW" "$ZKEY" "$OUT$ERR"
check "zai: o ~/.claude/settings.json fica igual, byte a byte" [ "$(cksum < "$HOME/.claude/settings.json")" == "$SET_SUM" ]
check "zai: a chave não vai em argv"                    bash -c '! grep -qF "$1" "$2"' _ "$ZKEY" "$FAKE/claude.args"
check "zai: marca com agente claude, modelo glm-5.3 e assinatura zai" [ "$(mark "$SP/proj-60-zai" agent)|$(mark "$SP/proj-60-zai" model)|$(mark "$SP/proj-60-zai" subscription)" == "claude|glm-5.3|zai" ]
check "zai: a chave não está na marca nem em arquivo do git-dir" bash -c '! grep -rqF "$1" "$2"' _ "$ZKEY" "$(gitdir "$SP/proj-60-zai")"
zid="$(mark "$SP/proj-60-zai" id)"
check "zai: a conversa sai com oute.subscription=zai"   [ "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$zid,oute.task.repo=proj,oute.task.slug=60-zai,oute.subscription=zai" ]
check "zai: opened com assinatura zai e agente claude, sem reserva" jqe '.name == "oute.task.opened" and .attrs["oute.task.subscription"] == "zai" and .attrs["oute.task.agent"] == "claude"
                                                         and .attrs["oute.task.model"] == "glm-5.3" and (.attrs | has("oute.task.reserve") or has("oute.task.reserve_from") | not)' <<<"$(last)"

# 13b. uma sessão claude ao lado: nenhuma das variáveis, nem as que vieram do ambiente de quem chamou
rm -f "${FAKE:?}"/claude.*
tz 61-spec claude "faça a 61"
check "claude: o spec abre sem as variáveis da zai e sem --settings" [ -z "$(zvars claude)" -a "$(cat "$FAKE/claude.args")" == "$(printf -- '--model\nclaude-opus-5-5\nfaça a 61')" ]
rm -f "${FAKE:?}"/claude.*
ANTHROPIC_BASE_URL=$ZURL ANTHROPIC_AUTH_TOKEN=$ZKEY API_TIMEOUT_MS=3000000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.3 tz 61-spec claude "faça a 61"
check "claude aberto de dentro de uma sessão zai: não herda as variáveis" [ -z "$(zvars claude)" ]
check "claude: a marca guarda a assinatura claude"      [ "$(mark "$SP/proj-61-spec" subscription)" == claude ]
check "claude: opened com assinatura claude"            jqe '.attrs["oute.task.subscription"] == "claude" and .attrs["oute.task.agent"] == "claude"' <<<"$(last)"
check "claude: o ~/.claude/settings.json segue igual"   [ "$(cksum < "$HOME/.claude/settings.json")" == "$SET_SUM" ]

# 13c. --subscription: escolha explícita, repassada ao oute-select
rm -f "${FAKE:?}"/claude.* "${FAKE:?}"/codex.*
tz --subscription zai 70-sem-label claude "p"
check "--subscription zai: abre na zai mesmo sem label"  [ "$RC" -eq 0 -a "$(sed -n 1,2p "$FAKE/claude.args" | tr '\n' ' ')" == "--model glm-5.3 " -a "$(zvars claude)" == "$ZWANT" ]
rm -f "${FAKE:?}"/claude.*
tz --subscription claude 62-claude claude "p"
check "--subscription claude numa issue build: abre no claude, sem as variáveis" [ -z "$(zvars claude)" -a "$(mark "$SP/proj-62-claude" subscription)" == claude ]
rm -f "${FAKE:?}"/codex.*
tz --subscription codex 62-codex claude "p"
check "--subscription codex: abre o codex, assinatura codex, sem as variáveis" [ "$RC" -eq 0 -a -f "$FAKE/codex.args" -a -z "$(zvars codex)" -a "$(mark "$SP/proj-62-codex" subscription)" == codex ]
check "--subscription codex: a conversa sai com oute.subscription=codex" bash -c 'grep -q ",oute.subscription=codex$" <<<"$1"' _ "$(aenv codex OTEL_RESOURCE_ATTRIBUTES)"
tz --subscription zai --agent codex 62-conflito
check "--subscription zai com --agent codex: recusa e não abre" [ "$RC" -ne 0 -a ! -d "$SP/proj-62-conflito" ]
t --subscription 'Z!' 62-x
check "--subscription inválido: recusa com o motivo"    bash -c '[ "$1" -eq 1 ] && grep -qF -- "--subscription inválido" <<<"$2"' _ "$RC" "$ERR"

# 13d. sem a chave: a zai explícita não abre, e a worktree não é criada
rm -f "${FAKE:?}"/claude.*
tn --subscription zai 71-sem-chave claude "p"
check "zai sem OUTE_ZAI_API_KEY: recusa, sem worktree e sem agente" bash -c '[ "$1" -eq 1 ] && grep -qF "OUTE_ZAI_API_KEY" <<<"$2" && [ ! -d "$3" ] && [ ! -f "$4" ]' _ "$RC" "$ERR" "$SP/proj-71-sem-chave" "$FAKE/claude.args"

# 13e. zai indisponível: a issue build cai no claude (reserva), com a origem no evento
rm -f "${FAKE:?}"/claude.*
FAKE_AVAIL_RC_ZAI=1 tz 62-reserva claude "p"
check "zai indisponível: abre no claude, sem variáveis nem --settings" [ -z "$(zvars claude)" -a "$(cat "$FAKE/claude.args")" == "$(printf -- '--model\nclaude-sonnet-5-5\np')" ]
check "zai indisponível: opened com reserve indisponivel, reserve_from zai e assinatura claude" jqe '.attrs["oute.task.reserve"] == "indisponivel" and .attrs["oute.task.reserve_from"] == "zai"
                                                         and .attrs["oute.task.subscription"] == "claude" and .attrs["oute.task.agent"] == "claude"' <<<"$(last)"

# 13f. restore (shim): reabre com as mesmas variáveis e a mesma regra
rm -f "${FAKE:?}"/claude.*
OUTE_ZAI_API_KEY="$ZKEY" shim claude "$SP/proj-60-zai" --resume conv-z
check "restore zai: --model glm-5.3 e o --settings da marca" [ "$(cat "$FAKE/claude.args")" == "$(printf -- '--resume\nconv-z\n--model\nglm-5.3\n--settings\n%s' "$ZSET")" ]
check "restore zai: as sete variáveis e a marca zai"   [ "$(zvars claude)" == "$ZWANT" -a "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)" == "$ORIGIN,oute.task.id=$zid,oute.task.repo=proj,oute.task.slug=60-zai,oute.subscription=zai" ]
check "restore zai: a chave não vai em argv nem na tela" bash -c '! grep -qF "$1" "$2" && ! grep -qF "$1" <<<"$3"' _ "$ZKEY" "$FAKE/claude.args" "$OUT$ERR"
rm -f "${FAKE:?}"/claude.*
OUTE_ZAI_API_KEY="$ZKEY" shim claude "$SP/proj-60-zai" -c --model glm-5.3
check "restore zai com --model na linha: só o --settings é posto" [ "$(cat "$FAKE/claude.args")" == "$(printf -- '-c\n--model\nglm-5.3\n--settings\n%s' "$ZSET")" -a "$(zvars claude)" == "$ZWANT" ]
rm -f "${FAKE:?}"/claude.*
shim claude "$SP/proj-60-zai" --resume conv-z
check "restore zai sem a chave: avisa, sem as variáveis e sem --settings" bash -c 'grep -qF "OUTE_ZAI_API_KEY" <<<"$1" && [ -z "$2" ] && ! grep -qx -- "--settings" "$3"' _ "$ERR" "$(zvars claude)" "$FAKE/claude.args"
rm -f "${FAKE:?}"/claude.*
OUTE_ZAI_API_KEY="$ZKEY" shim claude "$SP/proj-61-spec" --resume conv-c
check "restore claude: sem variáveis da zai e sem --settings" bash -c '[ -z "$1" ] && ! grep -qx -- "--settings" "$2" && grep -q ",oute.subscription=claude$" <<<"$3"' _ "$(zvars claude)" "$FAKE/claude.args" "$(aenv claude OTEL_RESOURCE_ATTRIBUTES)"
check "restore: o ~/.claude/settings.json segue igual"  [ "$(cksum < "$HOME/.claude/settings.json")" == "$SET_SUM" ]

# 13g. marca anterior à #678 (sem subscription): a conversa leva a assinatura do agente
printf 'id=proj-velha-20260101000000\nrepo=proj\nslug=velha\nagent=codex\nmodel=gpt-6.1-sol\n' > "$(gitdir "$SP/proj-62-codex")/oute-task"
check "marca sem subscription: --mark usa a do agente"  bash -c 'grep -q ",oute.subscription=codex$" <<<"$1"' _ "$(cd "$SP/proj-62-codex" && "$TASK" --mark)"

# 13h. a chave não aparece em nenhum evento recebido
check "a chave não aparece em nenhum evento"            bash -c '! grep -qF "$1" <<<"$2"' _ "$ZKEY" "$(ev true)"
before="$(n true)"; oute-emit task opened human repo=a slug=b "subscription=Z!"
check "oute-emit task: assinatura inválida não emite"   [ "$(n true)" -eq "$before" ]
# 14. trava semanal (#742): sessão aberta à mão só avisa em stderr, nunca recusa; sessão do swarm não repete o aviso
labels 63 aidlc:spec; labels 64 aidlc:spec; labels 65 aidlc:spec
jq -n '{schema: 1, max_pct: 98, agents: {claude: {status: "ok", windows: {"5h": {used_pct: 10, resets_in_s: 9000}, "7d": {used_pct: 90, resets_in_s: 90000}}}}}' > "$FAKE/quota.json"
rm -f "${FAKE:?}"/claude.*
FAKE_RC=3 tn 63-trava claude "faça a 63"
check "trava semanal: 7d=90 (trava 85): abre mesmo assim, com o aviso em stderr" bash -c '[ "$1" -eq 3 ] && [ -s "$2" ] && grep -qF "aviso: trava semanal: a assinatura claude está em 90% da janela de 7 dias (trava em 85%)" <<<"$3"' _ "$RC" "$FAKE/claude.args" "$ERR"
rm -f "${FAKE:?}"/claude.*
FAKE_RC=3 OUTE_SWARM_WORKER=1 tn 64-trava claude "faça a 64"
check "trava semanal: sessão do swarm (OUTE_SWARM_WORKER): sem o aviso repetido" bash -c '[ "$1" -eq 3 ] && ! grep -qF "trava semanal" <<<"$2"' _ "$RC" "$ERR"
jq -n '{schema: 1, max_pct: 98, agents: {claude: {status: "ok", windows: {"5h": {used_pct: 10, resets_in_s: 9000}, "7d": {used_pct: 40, resets_in_s: 90000}}}}}' > "$FAKE/quota.json"
FAKE_RC=3 tn 65-trava claude "faça a 65"
check "trava semanal: 7d=40: sem aviso" bash -c '[ "$1" -eq 3 ] && ! grep -qF "trava semanal" <<<"$2"' _ "$RC" "$ERR"
rm -f "${FAKE:?}/quota.json"

rcv_stop

check_end
