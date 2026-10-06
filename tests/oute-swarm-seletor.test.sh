#!/usr/bin/env bash
# Testes do oute-swarm, tema: seletor de modelo no spawn: fase da issue, --model, reserva no Codex, Jev, seletor ausente (#219, #257, #258).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-seletor.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/swarm-otlp.sh"
trap 'rcv_stop; rm -rf "${TMP:?}"' EXIT

# ---------------------------------------------------------------- #219: seletor de modelo (ADR-02)
# 11. spawn: fase da issue, exceção, sem label, gh fora
CASE=seletor; round "$CASE"
labels 8 aidlc:spec agentes; labels 9 aidlc:spec kaizen; labels 10 bug; labels 12 aidlc:ops
sw spawn 8-arq "instrução"
check "fase: código 0, sem aviso"                        [ "$RC" -eq 0 -a -z "$ERR" ]
check "fase: escolha em <slug>.select (Opus, origem label)" [ "$(sel 8-arq phase) $(sel 8-arq origin) $(sel 8-arq agent) $(sel 8-arq model)" == "spec label claude claude-opus-5-5" ]
check "fase: o oute-task recebe a escolha e o agente"    grep -qF -- "OUTE_SWARM_ROUND=swarm-test OUTE_SELECT_FILE=$STATE/8-arq.select oute-task -r $REPO 8-arq claude " <<<"$(cmd 8-arq)"
check "fase: saída com agente, modelo, fase e origem"    [ "$OUT" == "aberta: #8 → pane w1:p2 · worktree repo-8-arq · agente claude · modelo claude-opus-5-5 (fase spec, label)" ]
check "fase: a issue é lida no repo da sessão"           grep -qxF "repo 8" "$FAKE/gh-issue.log"
sw spawn 9-licao "instrução" --kaizen
check "kaizen: Sonnet pela exceção do label"              [ "$RC" -eq 0 -a "$(sel 9-licao model) $(sel 9-licao origin)" == "claude-sonnet-5-5 label" ]
sw spawn 10-semlabel "instrução"
check "sem label: abre no Sonnet, código 0"              [ "$RC" -eq 0 -a "$(sel 10-semlabel model) $(sel 10-semlabel origin) $(sp_agent swarm-test 10-semlabel)" == "claude-sonnet-5-5 padrao claude" ]
check "sem label: aviso (sem a chave, o Jev não é chamado)" [ "$ERR" == "oute-select: aviso: issue #10 sem label aidlc:<fase>, e sem a chave da TypeSafe (\$OUTE_TYPESAFE_API_KEY) o Jev não classifica; abrindo no padrão (claude-sonnet-5-5)" ]
touch "$FAKE/gh.down"
MAX=5 sw spawn 12-fora "instrução"
check "gh fora: abre no Sonnet, código 0"                [ "$RC" -eq 0 -a "$(sel 12-fora model) $(sel 12-fora origin)" == "claude-sonnet-5-5 padrao" ]
check "gh fora: aviso, e a aba abre"                     bash -c 'grep -qF "o gh não respondeu para a issue #12" <<<"$1" && grep -q "^12-fora " "$2"' _ "$ERR" "$STATE/spawned"
rm "${FAKE:?}/gh.down"
# 11b. escolha explícita: --model, --agent e os dois; o agente gravado é o que de fato abre
CASE=seletor-manual; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
labels 8 aidlc:spec
MAX=5 sw spawn 8-mod "instrução" --model claude-fable-5-1
check "--model: vence a fase, origem manual"             [ "$RC" -eq 0 -a "$(sel 8-mod model) $(sel 8-mod origin) $(sel 8-mod phase)" == "claude-fable-5-1 manual spec" ]
MAX=5 sw spawn 9-cx "instrução" --agent codex
check "--agent codex: Codex da linha da fase"            [ "$(sel 9-cx agent) $(sel 9-cx model) $(sel 9-cx effort) $(sel 9-cx origin)" == "codex gpt-6.1-sol high manual" ]
MAX=5 sw spawn 10-astra "instrução" --model gpt-6-astra
check "--model do Codex sem --agent: código 0"           [ "$RC" -eq 0 ]
check "--model do Codex: spawned com o agente que abriu" [ "$(sp_agent swarm-test 10-astra)" == codex ]
check "--model do Codex: oute-task com codex"            ran 10-astra codex
check "--model do Codex: log com codex"                  grep -q ' spawn 10-astra codex$' "$STATE/log"
check "--model do Codex: session.spawned com o agente que abriu" [ "$(n '.name == "oute.swarm.session.spawned" and .attrs["oute.swarm.session"] == "10-astra" and .attrs["oute.swarm.session.agent"] == "codex"')" -eq 1 ]
before="$(cat "$STATE/spawned")"; tabs="$(grep -c 'tab create' "$FAKE/herdr.log")"
MAX=5 sw spawn 11-ruim "instrução" --model 'x y'
check "--model inválido: código != 0, com o motivo"      bash -c '[ "$1" -ne 0 ] && grep -qF "oute-select: modelo inválido: x y" <<<"$2" && grep -qF "seletor recusou a sessão 11-ruim" <<<"$2"' _ "$RC" "$ERR"
check "--model inválido: nada registrado nem aberto"     [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq "$tabs" ]
rcv_stop
# 11b2. reserva no Codex (#258): com o claude indisponível, o spawn grava e abre o agente que de fato abre
CASE=seletor-reserva; round "$CASE"
labels 8 aidlc:build; labels 9 aidlc:build
export FAKE_CLAUDE_AUTH_RC=1
MAX=5 sw spawn 8-rsv "instrução"
check "reserva: código 0, escolha do Codex com reserve"  [ "$RC" -eq 0 -a "$(sel 8-rsv agent) $(sel 8-rsv model) $(sel 8-rsv effort) $(sel 8-rsv reserve)" == "codex gpt-6.1-sol high indisponivel" ]
check "reserva: spawned e log com codex"                 bash -c '[ "$(awk "\$1 == \"8-rsv\" {print \$3}" "$1")" == codex ] && grep -q " spawn 8-rsv codex$" "$2"' _ "$STATE/spawned" "$STATE/log"
check "reserva: oute-task recebe o codex e a escolha"    grep -qF -- "OUTE_SELECT_FILE=$STATE/8-rsv.select oute-task -r $REPO 8-rsv codex " <<<"$(cmd 8-rsv)"
check "reserva: a linha aberta: mostra a reserva"        [ "$OUT" == "aberta: #8 → pane w1:p2 · worktree repo-8-rsv · agente codex · modelo gpt-6.1-sol (fase build, label) · reserva: indisponivel" ]
MAX=5 sw spawn 9-exp "instrução" --agent claude
check "reserva: --agent claude explícito não cai na reserva" [ "$RC" -eq 0 -a "$(sel 9-exp agent) $(sel 9-exp reserve)" == "claude " -a "$(sp_agent swarm-test 9-exp)" == claude ]
check "reserva: --agent claude, só aviso e sem 'reserva:' na saída" bash -c 'grep -qF "explícita" <<<"$1" && ! grep -qF "reserva:" <<<"$2"' _ "$ERR" "$OUT"
unset FAKE_CLAUDE_AUTH_RC
# 11c. rodada com --agent (workers=codex): escolha explícita da rodada; o modelo é o do Codex da fase
CASE=seletor-rodada; round "$CASE"; echo workers=codex >> "$STATE/meta"
labels 8 aidlc:spec; labels 9 aidlc:ops
sw spawn 8-rod "instrução"
check "rodada codex: Codex da linha da fase, origem manual" [ "$RC" -eq 0 -a "$(sel 8-rod agent) $(sel 8-rod model) $(sel 8-rod effort) $(sel 8-rod origin) $(sel 8-rod phase)" == "codex gpt-6-astra high manual spec" ]
check "rodada codex: spawned e oute-task com codex"      bash -c '[ "$1" == codex ] && grep -qF -- "oute-task -r $2 8-rod codex " "$3"' _ "$(sp_agent swarm-test 8-rod)" "$REPO" "$FAKE/herdr.log"
sw spawn 9-ovr "instrução" --agent claude
check "spawn --agent claude sobrepõe a rodada: Sonnet da fase ops" [ "$(sel 9-ovr agent) $(sel 9-ovr model) $(sel 9-ovr origin)" == "claude claude-sonnet-5-5 manual" ]
# 11e. Jev (#257): issue sem label de fase, a instrução do spawn é o texto da tarefa
CASE=seletor-jev; round "$CASE"; ts_start "$TMP/$CASE/ts"
labels 8 aidlc:build; labels 10 bug; labels 13 agentes
ts_set ok spec 0.88
MAX=5 sw spawn 10-jev "escreva a issue com os critérios de aceite"
check "jev: código 0, sem aviso"                         [ "$RC" -eq 0 -a -z "$ERR" ]
check "jev: Opus da fase classificada, origem jev, com a confiança" [ "$(sel 10-jev phase) $(sel 10-jev origin) $(sel 10-jev model) $(sel 10-jev confidence)" == "spec jev claude-opus-5-5 0.88" ]
check "jev: saída com a fase e a origem"                 [ "$OUT" == "aberta: #10 → pane w1:p2 · worktree repo-10-jev · agente claude · modelo claude-opus-5-5 (fase spec, jev)" ]
check "jev: só a instrução vai à TypeSafe (sem as regras do worker)" jqe '.body.state == "escreva a issue com os critérios de aceite"' <<<"$(ts_last)"
check "jev: a chave não vai na linha de comando da sessão" bash -c '! grep -qF "$1" "$2"' _ "$TS_KEY" "$FAKE/herdr.log"
ts_set ok spec 0.3
MAX=5 sw spawn 13-baixa "escreva a issue com os critérios de aceite"
check "jev com confiança baixa: Sonnet, origem padrao, confiança guardada" [ "$RC" -eq 0 -a "$(sel 13-baixa model) $(sel 13-baixa origin) $(sel 13-baixa confidence)" == "claude-sonnet-5-5 padrao 0.3" ]
check "jev com confiança baixa: aviso"                   grep -qF 'o Jev ficou com confiança baixa (0,30 em spec' <<<"$ERR"
ts_reset
MAX=5 sw spawn 8-label "escreva a issue com os critérios de aceite"
check "issue com label de fase: o Jev não é chamado"     [ "$(sel 8-label origin) $(ts_calls)" == "label 0" ]
ts_stop; ts_off
# 11d. seletor falhando ou ausente: o spawn abre como antes (o agente pedido, sem escolha), com aviso
CASE=seletor-falha; round "$CASE"
BAD="$TMP/$CASE/bad"; mkdir -p "$BAD"; printf '#!/usr/bin/env bash\necho estourou >&2; exit 1\n' > "$BAD/oute-select"; chmod +x "$BAD/oute-select"
swb() {   # sw com outro PATH na frente ($1)
  local p="$1"; shift
  OUT="$(env PATH="$p:$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 \
         OUTE_SWARM_ID=swarm-test OUTE_SWARM_REPO="$REPO" OUTE_SWARM_MAX=5 "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
swb "$BAD" spawn 8-cai "instrução" --agent codex
check "seletor falhando: abre o agente pedido, código 0" [ "$RC" -eq 0 -a "$(sp_agent swarm-test 8-cai)" == codex -a ! -e "$STATE/8-cai.select" ]
check "seletor falhando: aviso"                          grep -qxF "oute-swarm: aviso: o seletor de modelo não respondeu; 8-cai abre com o modelo padrão do agente" <<<"$ERR"
check "seletor falhando: oute-task sem OUTE_SELECT_FILE" grep -qF -- "OUTE_SWARM_ROUND=swarm-test oute-task -r $REPO 8-cai codex " <<<"$(cmd 8-cai)"
check "seletor falhando: saída como antes"               [ "$OUT" == "aberta: #8 → pane w1:p2 · worktree repo-8-cai · agente codex" ]
OUTE_SELECT_TABLE="$TMP/sem-tabela.toml" MAX=5 sw spawn 9-semtab "instrução"
check "sem tabela: abre claude sem modelo, com aviso"    bash -c '[ "$1" -eq 0 ] && [ "$2" == "aberta: #9 → pane w1:p3 · worktree repo-9-semtab · agente claude" ] && grep -qF "tabela de fase ausente ou inválida" <<<"$3"' _ "$RC" "$OUT" "$ERR"
# PATH sem oute-select nenhum: só os falsos do teste (menos ele) e o sistema
NOSEL="$TMP/$CASE/nosel"; mkdir -p "$NOSEL"; for f in "$BIN"/*; do [[ "$(basename "$f")" == oute-select ]] || ln -s "$f" "$NOSEL/"; done
nosel() {
  OUT="$(env PATH="$NOSEL:/usr/bin:/bin" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 \
         OUTE_SWARM_ID=swarm-test OUTE_SWARM_REPO="$REPO" OUTE_SWARM_MAX=5 "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
}
nosel spawn 10-nosel "instrução"
check "sem oute-select: abre claude como antes, sem aviso" [ "$RC" -eq 0 -a -z "$ERR" -a "$OUT" == "aberta: #10 → pane w1:p4 · worktree repo-10-nosel · agente claude" ]
before="$(cat "$STATE/spawned")"
nosel spawn 11-nosel "instrução" --model claude-opus-5-5
check "sem oute-select + --model: recusa, nada registrado" bash -c '[ "$1" -ne 0 ] && grep -qF -- "--model precisa do oute-select" <<<"$2" && [ "$3" == "$4" ]' _ "$RC" "$ERR" "$(cat "$STATE/spawned")" "$before"
check_end
