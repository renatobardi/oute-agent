#!/usr/bin/env bash
# Testes do oute-swarm, tema: o resumo do ciclo (#509, ADR-08 "Página da rodada e do ciclo"): a etapa `ciclo`, publicada por
# uma sessão avulsa (sem rodada nem dispatcher) com `step dir`, `step review` e `step publish ciclo --cycle <dono/repo#n>`,
# o evento oute.swarm.step.published com `oute.swarm.cycle` e a pasta do ciclo que nunca vira "a rodada mais recente".
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh).
# Uso: tests/oute-swarm-ciclo.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/swarm-otlp.sh"
trap 'rcv_stop; rm -rf "$TMP"' EXIT

. "$ROOT/tests/lib/swarm-reviewer.sh"
CYCLE=renatobardi/oute-agent#509
CID=ciclo-renatobardi_oute-agent-509
# swa <args>: a sessão avulsa: sem OUTE_SWARM_ID, fora de worktree de dispatcher e sem herdr; stdout em $OUT, stderr em $ERR
swa() {
  OUT="$(cd "$TMP" && env -u OUTE_SWARM_ID PATH="$RBIN:$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" \
         "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
  return 0
}
ok_json() { printf '{"veredito":"aprovado","achados":[]}' > "$FAKE/rev/answer"; return 0; }
TXT=$'## Decisão\n1. fechar o ciclo\n\n## Ações\n- nenhuma\n\n## Detalhe\nO ciclo teve 4 rodadas (https://github.com/renatobardi/oute-agent/issues/509).\n'
STEPEV='.name == "oute.swarm.step.published"'
WR=claude-sonnet-5-5

# ---------------------------------------------------------------- 1. step dir
CASE=dir; round "$CASE"; mkdir -p "$FAKE/rev"; ok_json
CD="$H/.oute/swarm/$CID"
swa step dir ciclo --cycle "$CYCLE"
check "step dir: imprime a pasta do ciclo, que passa a existir, e nada de rodada" bash -c '[ "$1" -eq 0 ] && [ "$2" = "$3/etapas" ] && [ -d "$3/etapas" ] && [ ! -e "$3/meta" ] && [ ! -e "$3/spawned" ]' _ "$RC" "$OUT" "$CD"
swa step dir ciclo
check "step dir sem --cycle: recusa e diz o uso"            bash -c '[ "$1" -eq 1 ] && grep -qF "uso: oute-swarm step dir ciclo --cycle" <<<"$2"' _ "$RC" "$ERR"
swa step dir merge --cycle "$CYCLE"
check "step dir de outro tipo: recusa"                      bash -c '[ "$1" -eq 1 ] && grep -qF "uso: oute-swarm step dir ciclo" <<<"$2"' _ "$RC" "$ERR"
swa step dir ciclo --cycle 'lixo'
check "step dir com ciclo fora do formato: recusa"          bash -c '[ "$1" -eq 1 ] && grep -qF -- "--cycle inválido" <<<"$2"' _ "$RC" "$ERR"
swa step dir ciclo --cycle '../../x/y#1'
check "step dir com caminho no ciclo: recusa, nada criado fora da pasta do swarm" bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/../x" ] && [ ! -e "$2/x" ]' _ "$RC" "$H/.oute"
check "ajuda: step dir ciclo"                               bash -c '"$1" --help | grep -qF "oute-swarm step dir ciclo --cycle"' _ "$SWARM"

# ---------------------------------------------------------------- 2. review e publish, sem rodada nem dispatcher
CASE=feliz; round "$CASE"; rcv_start "$TMP/$CASE/rcv"; mkdir -p "$FAKE/rev"; ok_json
CD="$H/.oute/swarm/$CID"; mkdir -p "$CD/etapas"; printf '%s' "$TXT" > "$CD/etapas/ciclo.r1.md"
SHA1="$(sha256sum "$CD/etapas/ciclo.r1.md" | cut -d' ' -f1)"
swa step review ciclo --cycle "$CYCLE" --writer $WR
check "review do ciclo: aprovado, sem rodada nem OUTE_SWARM_ID" bash -c '[ "$1" -eq 0 ] && grep -qF "etapa ciclo r1: aprovado (revisor claude-opus-5-5," <<<"$2"' _ "$RC" "$OUT"
check "review do ciclo: o veredito mora na pasta do ciclo, para o sha256 do texto" bash -c '[ "$(jq -r .sha256 "$1")" = "$2" ] && [ "$(jq -r .verdict "$1")" = aprovado ]' _ "$CD/etapas/ciclo.r1.review.json" "$SHA1"
check "review do ciclo: o consumo do revisor leva a pasta do ciclo na origem" bash -c 'grep -q "^OTEL_RESOURCE_ATTRIBUTES=.*oute.swarm.round=$2,oute.swarm.step=ciclo" "$1"' _ "$FAKE/rev/env.1" "$CID"
check "review do ciclo: sem meta de rodada, o consumo sai sem oute.task.repo (#599)" bash -c 'grep -qE "^OTEL_RESOURCE_ATTRIBUTES=.*,oute\.swarm\.step=ciclo$" "$1"' _ "$FAKE/rev/env.1"
swa step publish ciclo
check "publish do ciclo sem --cycle: recusa"                bash -c '[ "$1" -eq 1 ] && grep -qF "etapa ciclo pede --cycle" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$ERR" "$CD/log"
swa step publish ciclo --cycle "$CYCLE" --pr 3
check "publish do ciclo com --pr: recusa"                   bash -c '[ "$1" -eq 1 ] && grep -qF -- "--pr só vale na etapa merge" <<<"$2"' _ "$RC" "$ERR"
swa step publish ciclo --cycle "$CYCLE" --lixo
check "publish do ciclo com opção desconhecida: recusa"     bash -c '[ "$1" -eq 1 ] && grep -qF "opção desconhecida: --lixo" <<<"$2" && [ ! -e "$3" ]' _ "$RC" "$ERR" "$CD/log"
swa step publish ciclo --cycle "$CYCLE"
check "publish do ciclo: aprovado"                          bash -c '[ "$1" -eq 0 ] && grep -qxF "etapa ciclo r1 publicada (aprovado)" <<<"$2"' _ "$RC" "$OUT"
check "publish do ciclo: a linha vai para o log da pasta do ciclo, com o ciclo no fim" grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z etapa ciclo - 1 aprovado $SHA1 claude-sonnet-5-5 claude-opus-5-5 ausente $CYCLE\$" "$CD/log"
E="$(ev "$STEPEV")"
check "evento: a pasta do ciclo é a rodada, o tipo é ciclo, o ciclo e o texto vêm no evento" jqe --arg c "$CYCLE" --arg id "$CID" --arg sha "$SHA1" '.attrs["oute.swarm.round"] == $id and .attrs["oute.swarm.step.kind"] == "ciclo" and .attrs["oute.swarm.cycle"] == $c and .attrs["oute.swarm.step.sha256"] == $sha and .attrs["oute.swarm.step.review"] == "aprovado" and (.attrs | has("oute.swarm.step.key") | not) and (.body | startswith("## Decisão"))' <<<"$E"
swa step publish ciclo --cycle "$CYCLE"
check "publish de novo da mesma revisão: recusa"            bash -c '[ "$1" -eq 1 ] && grep -qF "já foi publicada" <<<"$2"' _ "$RC" "$ERR"
swa step publish ciclo --cycle "renatobardi/outro#7" --rev 1
check "outro ciclo é outra pasta: sem arquivo, recusa"      bash -c '[ "$1" -eq 1 ] && grep -qF "arquivo da etapa não existe" <<<"$2"' _ "$RC" "$ERR"
mkdir -p "$STATE/etapas"; printf '%s' "$TXT" > "$STATE/etapas/fechamento.r1.md"
swa step review fechamento --cycle "$CYCLE" --writer $WR
check "--cycle no review de outro tipo: recusa"             bash -c '[ "$1" -eq 1 ] && grep -qF -- "--cycle no step review só vale na etapa ciclo" <<<"$2"' _ "$RC" "$ERR"
# o oute-emit não emite etapa ciclo sem o ciclo, nem ciclo fora do formato
n0="$(n "$STEPEV")"
for l in "2026-10-04T10:00:00Z etapa ciclo - 1 aprovado $SHA1 claude-sonnet-5-5 claude-opus-5-5 ausente -" \
         "2026-10-04T10:00:00Z etapa ciclo - 1 aprovado $SHA1 claude-sonnet-5-5 claude-opus-5-5 ausente sem-barra#1"; do
  env PATH="$BIN:$PATH" HOME="$H" "$ROOT/docker/oute-emit" swarm "$CID" "$l" >/dev/null 2>&1
done
check "emit: etapa ciclo sem o ciclo ou com ciclo fora do formato não vira evento" [ "$(n "$STEPEV")" -eq "$n0" ]
rcv_stop

# ---------------------------------------------------------------- 3. a pasta do ciclo nunca é a "rodada mais recente"
CASE=recente; round "$CASE"; mkdir -p "$FAKE/rev"; ok_json
mkdir -p "$STATE/etapas"; printf '%s' "$TXT" > "$STATE/etapas/fechamento.r1.md"
swa step dir ciclo --cycle "$CYCLE"
touch -d '+1 hour' "$H/.oute/swarm/$CID"
swa step review fechamento --writer $WR
check "a pasta do ciclo é mais nova, mas a rodada mais recente segue sendo a rodada (review sem OUTE_SWARM_ID)" bash -c '[ "$1" -eq 0 ] && [ -f "$2/etapas/fechamento.r1.review.json" ] && [ ! -e "$3/etapas/fechamento.r1.review.json" ]' _ "$RC" "$STATE" "$H/.oute/swarm/$CID"
swa ask "o ciclo fechou?"
check "ask sem OUTE_SWARM_ID cai na rodada, não na pasta do ciclo" bash -c '[ "$1" -eq 0 ] && grep -q " pergunta " "$2/log" && [ ! -e "$3/log" ]' _ "$RC" "$STATE" "$H/.oute/swarm/$CID"
swa list
check "list: a pasta do ciclo não aparece como rodada"      bash -c '[ "$1" -eq 0 ] && ! grep -qF "ciclo-" <<<"$2"' _ "$RC" "$OUT"
check_end
