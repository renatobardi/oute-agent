#!/usr/bin/env bash
# Testes do oute-swarm, tema: agente das sessões da rodada: --agent na abertura (#212).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-agente.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/swarm-otlp.sh"
trap 'rcv_stop; rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- #212: agente das sessões da rodada (--agent na abertura)
# 10. abertura com --agent: meta, prompt, aviso, log e oute.swarm.round.opened
CASE=agente-abre; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
opn --max 2 --agent codex
nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
check "--agent: código 0 e rodada nova"                  [ "$RC" -eq 0 -a -n "$nr" ]
check "--agent: meta com workers=codex e agent=codex (#213)" [ "$(grep -cxE 'workers=codex|agent=codex' "$M")" -eq 2 ]
check "--agent: prompt com o agente da rodada"           grep -qF 'Agente das sessões: `codex` (escolhido pelo Bardi na abertura, `--agent codex`).' "$FAKE/oute-task.all"
check "--agent: prompt manda não passar --agent nem --model" grep -qF -- '- **Agente e modelo:** não passe `--agent` nem `--model` no `spawn`' "$FAKE/oute-task.all"
check "--agent: triagem com o agente de cada sessão"     grep -qF 'área tocada, agente da sessão,' "$FAKE/oute-task.all"
check "--agent: sem placeholder no prompt"               [ -z "$(grep -o '{{[A-Z_]*}}' "$FAKE/oute-task.all")" ]
check "--agent: aviso com o agente"                      grep -qxF "dispatcher $nr · repo repo · max 2 · agente codex" <<<"$ERR"
check "--agent: linha do log com o agente"               grep -q " abertura $nr (repo repo, max 2, agente codex)$" "$H/.oute/swarm/$nr/log"
check "--agent: round.opened com oute.swarm.round.agent" [ "$(n '.name == "oute.swarm.round.opened" and .attrs["oute.swarm.round.agent"] == "codex" and .attrs["oute.agent"] == "codex"')" -eq 1 ]
rcv_stop
# 10b. abertura sem --agent: meta sem workers=, prompt com "seletor", evento sem o atributo
CASE=agente-sem; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
opn --max 2
nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
check "sem --agent: código 0 e rodada nova"              [ "$RC" -eq 0 -a -n "$nr" ]
check "sem --agent: meta sem workers="                   [ -z "$(grep '^workers' "$M")" -a "$(grep -cx 'agent=claude' "$M")" -eq 1 ]
check "sem --agent: prompt com seletor"                  grep -qF 'Agente das sessões: seletor (a rodada abriu sem `--agent`' "$FAKE/oute-task.all"
check "sem --agent: aviso e log como antes"              [ "$(grep -cxF "dispatcher $nr · repo repo · max 2" <<<"$ERR")" -eq 1 -a "$(grep -c " abertura $nr (repo repo, max 2)$" "$H/.oute/swarm/$nr/log")" -eq 1 ]
check "sem --agent: round.opened sem round.agent"        [ "$(n '.name == "oute.swarm.round.opened"')" -eq 1 -a "$(n '.name == "oute.swarm.round.opened" and (.attrs | has("oute.swarm.round.agent"))')" -eq 0 ]
sw spawn 8-bar "instrução"
check "sem --agent: spawn usa claude"                    [ "$RC" -eq 0 -a "$(sp_agent swarm-test 8-bar)" == claude ]
check "sem --agent: oute-task com claude"                ran 8-bar claude
rcv_stop
# 10b2. abertura com --prefer (#621): meta com prefer=, sem workers=; formato inválido recusa sem rodada
CASE=agente-prefer; round "$CASE"
opn --max 2 --prefer codex
nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
check "--prefer: código 0, meta com prefer=codex e sem workers=" [ "$RC" -eq 0 -a -n "$nr" -a "$(grep -cx 'prefer=codex' "$M")" -eq 1 -a -z "$(grep '^workers' "$M")" ]
opn --max 2 --prefer 'X;y'
check "--prefer inválido: recusado com a mensagem" bash -c '[ "$1" -ne 0 ] && grep -qF -- "--prefer inválido: X;y" <<<"$2"' _ "$RC" "$ERR"
# 10b3. abertura com --subscription (#678): meta com subscription=; o dispatcher segue no claude; formato inválido recusa sem rodada
CASE=agente-subscription; round "$CASE"
opn --max 2 --subscription zai
nr="$(nova)"; M="$H/.oute/swarm/$nr/meta"
check "--subscription: código 0, meta com subscription=zai" [ "$RC" -eq 0 -a -n "$nr" -a "$(grep -cx 'subscription=zai' "$M")" -eq 1 ]
check "--subscription: o dispatcher abre no claude, fase plan, sem a assinatura" bash -c 'grep -qx -- "--phase" "$1" && grep -qx -- "plan" "$1" && ! grep -qF -- "--subscription" "$1"' _ "$FAKE/oute-task.args"
opn --max 2 --subscription 'X;y'
check "--subscription inválido: recusado com a mensagem" bash -c '[ "$1" -ne 0 ] && grep -qF -- "--subscription inválido: X;y" <<<"$2"' _ "$RC" "$ERR"
# 10c. --agent inválido: erro claro, sem rodada nem oute-task
CASE=agente-invalido; round "$CASE"
opn --agent foo
check "inválido: código != 0"                            [ "$RC" -ne 0 ]
check "inválido: mensagem clara"                         grep -qF 'agente inválido: foo; use claude ou codex' <<<"$ERR"
check "inválido: nenhuma rodada criada"                  so_teste
opn --max 2 --agent pi
check "Pi na abertura: recusado, sem rodada"             [ "$RC" -ne 0 -a "$(grep -c 'Pi saiu do stack (#217)' <<<"$ERR")" -eq 1 ]
check "Pi na abertura: nenhuma rodada criada"            so_teste
# 10d. spawn numa rodada com workers=codex: padrão do meta, sobreposição e kaizen
CASE=agente-spawn; round "$CASE"; echo workers=codex >> "$STATE/meta"
sw spawn 8-def "instrução"
check "padrão do meta: código 0"                         [ "$RC" -eq 0 ]
check "padrão do meta: spawned com codex"                [ "$(sp_agent swarm-test 8-def)" == codex ]
check "padrão do meta: oute-task com codex"              ran 8-def codex
check "padrão do meta: saída e log com codex"            [ "${OUT##* · agente }" == "codex · modelo gpt-6.1-sol (fase build, manual)" -a "$(grep -c ' spawn 8-def codex$' "$STATE/log")" -eq 1 ]
sw spawn 9-ovr "instrução" --agent claude
check "--agent sobrepõe: claude no spawned e no oute-task" [ "$RC" -eq 0 -a "$(sp_agent swarm-test 9-ovr)" == claude ]
check "--agent sobrepõe: oute-task com claude"           ran 9-ovr claude
sw spawn 10-kz "instrução" --kaizen
check "kaizen: segue o padrão da rodada"                 [ "$RC" -eq 0 -a "$(awk '$1 == "10-kz" {print $3, $7}' "$STATE/spawned")" == "codex kaizen" ]
check "kaizen: oute-task com codex"                      ran 10-kz codex
# 10e. dispatcher reiniciado sem OUTE_SWARM_ID: o padrão vem do meta da rodada assumida
WT="$TMP/$CASE/wt"; coord "$WT" sessao/swarm-test
swc "$WT" spawn 11-rei "instrução" --kaizen
check "reinício: assume a rodada e usa codex"            [ "$RC" -eq 0 -a "$(sp_agent swarm-test 11-rei)" == codex ]
check "reinício: aviso de rodada assumida"               grep -qF "$ASSUME" <<<"$ERR"
# 10f. spawn avulso não herda o agente de rodada nenhuma
swc "$REPO" spawn 12-av "instrução"
check "avulso: claude, mesmo com rodada workers=codex"   [ "$RC" -eq 0 -a "$(sp_agent avulso 12-av)" == claude ]
# 10g. workers= inválido no meta: erro claro, nada aberto; --agent explícito não depende dele
sed -i.bak 's/^workers=.*/workers=pi/' "$STATE/meta"; before="$(cat "$STATE/spawned")"; tabs="$(grep -c 'tab create' "$FAKE/herdr.log")"
sw spawn 13-x "instrução" --kaizen
check "meta inválido: código != 0"                       [ "$RC" -ne 0 ]
check "meta inválido: mensagem com a origem"             grep -qF 'Pi saiu do stack (#217), use claude ou codex (workers= do meta da rodada swarm-test)' <<<"$ERR"
check "meta inválido: nada registrado nem aberto"        [ "$(cat "$STATE/spawned")" == "$before" -a "$(grep -c 'tab create' "$FAKE/herdr.log")" -eq "$tabs" ]
sw spawn 13-y "instrução" --kaizen --agent claude
check "meta inválido + --agent: abre com o explícito"    [ "$RC" -eq 0 -a "$(sp_agent swarm-test 13-y)" == claude ]
check_end
