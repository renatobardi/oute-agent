#!/usr/bin/env bash
# Testes do oute-swarm, tema: trava semanal no spawn (#742, ADR-02 adendo): a assinatura escolhida com `weekly_guard_pct` e a janela
# de 7 dias no valor ou acima não abre sessão (código 5, linha `guard` no log); --force vence; cota não lida só avisa; sem o campo,
# nada muda. Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh; `oute-quota` falso com $FAKE/quota.json).
# Uso: tests/oute-swarm-trava.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"

# q7 <% da janela de 7 dias do claude> [status]: grava o JSON do `oute-quota --json` (5 h folgada, as outras assinaturas folgadas)
q7() {
  local used="$1" status="${2:-ok}"
  jq -n --argjson u "$used" --arg s "$status" '{schema: 1, max_pct: 98, reset_grace_s: 1200, agents: {
    claude: {status: $s, windows: {"5h": {used_pct: 10, resets_in_s: 9000}, "7d": {used_pct: $u, resets_in_s: 90000, resets_at: "2030-01-05T00:00:00Z"}}},
    codex: {status: "ok", windows: {"5h": {used_pct: 10, resets_in_s: 9000}, "7d": {used_pct: 10, resets_in_s: 90000}}}}}' > "$FAKE/quota.json"
  return $?
}
TABLE="$ROOT/config/select/models.toml"
SPEC="aidlc:spec"   # fase com a cadeia claude → zai → codex: o claude é a assinatura de partida

CASE=trava; round "$CASE"; labels 8 "$SPEC"; labels 9 "$SPEC"; labels 10 "$SPEC"; labels 11 "$SPEC"; labels 12 "$SPEC"; labels 13 "$SPEC"
check "a tabela do repo tem weekly_guard_pct = 85 na claude" bash -c 'python3 -I -c "import sys,tomllib; t=tomllib.load(open(sys.argv[1],\"rb\")); print({s[\"name\"]: s.get(\"weekly_guard_pct\") for s in t[\"subscription\"]})" "$1" | grep -qxF "{'"'"'claude'"'"': 85, '"'"'zai'"'"': None, '"'"'codex'"'"': None}"' _ "$TABLE"

# acima da trava: recusa com código 5, sem abrir aba nem registrar a sessão
q7 90
before="$(cat "$STATE/spawned")"; tabs="$(grep -c 'tab create' "$FAKE/herdr.log" 2>/dev/null || true)"
OUTE_SELECT_TABLE="$TABLE" MAX=5 sw spawn 8-alta "instrução"
check "7d=90 (trava 85): código 5"                      [ "$RC" -eq 5 ]
check "7d=90: diz a assinatura, os números e as opções"  bash -c 'for t in "trava semanal" "assinatura claude" "90% da janela de 7 dias" "trava de 85%" "reseta em cerca de 25 h" "#8 não abre (código 5)" "--force"; do grep -qF -- "$t" <<<"$1" || exit 1; done' _ "$ERR"
check "7d=90: nada aberto nem registrado"               [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log" 2>/dev/null || true)" == "$tabs" ]
check "7d=90: linha guard no log da rodada"             grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z guard 8-alta claude 7d=90% trava=85%$' "$STATE/log"
check "7d=90: stdout vazio (a sessão não abriu)"        [ -z "$OUT" ]

# no valor exato: trava (igual ou acima); logo abaixo: abre
q7 85
OUTE_SELECT_TABLE="$TABLE" MAX=5 sw spawn 9-igual "instrução"
check "7d=85 (igual à trava): código 5"                 [ "$RC" -eq 5 ]
q7 84
OUTE_SELECT_TABLE="$TABLE" MAX=5 sw spawn 10-abaixo "instrução"
check "7d=84 (abaixo): abre, sem aviso, no claude"      [ "$RC" -eq 0 -a -z "$ERR" -a "$(sp_agent swarm-test 10-abaixo)" == claude ]
check "7d=84: sem linha guard"                          bash -c '! grep -q " guard 10-abaixo " "$1"' _ "$STATE/log"

# --force vence (só o Bardi)
q7 95
OUTE_SELECT_TABLE="$TABLE" MAX=5 sw spawn 11-forca "instrução" --force
check "7d=95 com --force: abre, código 0"               [ "$RC" -eq 0 -a "$(sp_agent swarm-test 11-forca)" == claude ]
check "--force: sem linha guard"                        bash -c '! grep -q " guard 11-forca " "$1"' _ "$STATE/log"

# cota desconhecida: só avisa e abre
q7 95 error
OUTE_SELECT_TABLE="$TABLE" MAX=5 sw spawn 12-semcota "instrução"
check "cota do claude não lida: abre, código 0"         [ "$RC" -eq 0 -a "$(sp_agent swarm-test 12-semcota)" == claude ]
check "cota não lida: aviso da trava não conferida"     grep -qF "não li a janela de 7 dias da assinatura claude" <<<"$ERR"
echo 'lixo' > "$FAKE/quota.json"; OUTE_SELECT_TABLE="$TABLE" MAX=5 sw spawn 13-quebrou "instrução"
check "oute-quota quebrado: abre, código 0, avisa"      bash -c '[ "$1" -eq 0 ] && grep -qF "não li a janela de 7 dias" <<<"$2"' _ "$RC" "$ERR"

# sem weekly_guard_pct na assinatura: nada muda (tabela de antes, sem o campo, e assinatura sem o campo na tabela atual)
CASE=trava-antes; round "$CASE"; labels 8 "$SPEC"; labels 9 "$SPEC"
q7 97   # abaixo do teto de 98% do seletor, que senão trocaria para a reserva
OUTE_SELECT_TABLE="$ROOT/tests/lib/select-table-sem-zai.toml" MAX=5 sw spawn 8-antes "instrução"
check "tabela de antes, 7d=97: abre no claude como antes, sem aviso" [ "$RC" -eq 0 -a -z "$ERR" -a "$(sp_agent swarm-test 8-antes)" == claude ]
check "o JSON do seletor não ganha campo novo (saída de antes)" [ "$(jq -c keys "$STATE/8-antes.select")" == '["agent","confidence","effort","model","origin","phase","reason","reserve","subscription"]' ]
check "tabela de antes: sem linha guard"                bash -c '! grep -q " guard " "$1"' _ "$STATE/log"
OUTE_SELECT_TABLE="$TABLE" MAX=5 sw spawn 9-cx "instrução" --agent codex
check "codex (sem weekly_guard_pct) com 7d=97: abre"    [ "$RC" -eq 0 -a "$(sp_agent swarm-test 9-cx)" == codex ]

# oute-select --weekly-guard: o contrato que o spawn e o oute-task usam
CASE=trava-select; round "$CASE"; q7 90
wg() { local sub="$1"; env PATH="$BIN:$PATH" FAKE="$FAKE" OUTE_SELECT_TABLE="$TABLE" "$ROOT/docker/oute-select" --weekly-guard "$sub"; return $?; }
check "--weekly-guard claude (90): over, com os números" bash -c '[ "$(jq -c "[.status,.guard_pct,.used_pct,.resets_in_s]" <<<"$1")" == "[\"over\",85,90,90000]" ]' _ "$(wg claude)"
check "--weekly-guard codex: none"                      bash -c '[ "$(jq -r .status <<<"$1")" == none ]' _ "$(wg codex)"
check "--weekly-guard assinatura fora da tabela: none"  bash -c '[ "$(jq -r .status <<<"$1")" == none ]' _ "$(wg zzz)"
q7 40; check "--weekly-guard claude (40): ok"           bash -c '[ "$(jq -r .status <<<"$1")" == ok ]' _ "$(wg claude)"
q7 40 error; check "--weekly-guard com cota não lida: unknown" bash -c '[ "$(jq -r .status <<<"$1")" == unknown ]' _ "$(wg claude)"
check "--weekly-guard sem valor: código 2"              bash -c 'env PATH="$1:$PATH" FAKE="$2" "$3" --weekly-guard >/dev/null 2>&1; [ $? -eq 2 ]' _ "$BIN" "$FAKE" "$ROOT/docker/oute-select"
# valor inválido na tabela: tabela recusada (aviso), a sessão abre com o padrão do agente e a trava não se aplica
BADT="$TMP/$CASE/bad.toml"; sed 's/^weekly_guard_pct = 85/weekly_guard_pct = 150/' "$TABLE" > "$BADT"
check "weekly_guard_pct fora de 1 a 100: tabela inválida, aviso" bash -c 'env PATH="$1:$PATH" FAKE="$2" OUTE_SELECT_TABLE="$3" "$4" --weekly-guard claude 2>&1 | grep -qF "weekly_guard_pct fora de 1 a 100"' _ "$BIN" "$FAKE" "$BADT" "$ROOT/docker/oute-select"
check_end
