#!/usr/bin/env bash
# Testes do oute-swarm, tema: modo dark, fatias (a), (b) e (d) (#841, #842, #844, ADR-10; (b): --phase arch, autorização e dark.md): `--dark` grava dark=1 no meta e põe "modo dark, ADR-10" no prompt;
# recusa o oute-agent (código 7) e pré-requisito faltando (código 8, um item por linha; cota de 7 dias e permissão de push).
# Fatia (d): --budget no meta, spawn com o custo da rodada lido do agent-studio falso (código 9, [budget]; leitura que falha abre),
# dark_parada=deploy, e `oute-swarm stop` (idempotente).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh e tests/lib/oute-swarm-dark.sh).
# Uso: tests/oute-swarm-dark.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/otlp.sh"
guarda_start "$TMP/guarda"
rcv_stop   # sem receptor neste arquivo: porta fechada, nenhum evento alcança o coletor (#815)
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/oute-swarm-dark.sh"

# a tabela do repo: claude, zai e codex, todas com weekly_guard_pct = 95
export OUTE_SELECT_TABLE="$ROOT/config/select/models.toml"
export OUTE_SWARM_CONFIG="$ROOT/config/swarm.toml"   # o padrão do repo (dark_budget_usd, #844)

# -------- código 7: o oute-agent não é alvo
CASE=c7; round "$CASE"
REPO="$TMP/$CASE/oute-agent"; dark_repo "$REPO"; dq 10 10 10; dgh true; dalive; dcontract "$REPO"
opn --dark
check "oute-agent: código 7"                     [ "$RC" -eq 7 ]
check "oute-agent: diz o motivo (ADR-10, self-restart)" bash -c 'grep -qF "ADR-10" <<<"$1" && grep -qF "self-restart" <<<"$1" && grep -qF "código 7" <<<"$1"' _ "$ERR"
check "oute-agent: nenhuma rodada nova nem oute-task" so_teste

# -------- código 8, um item: cota do claude na trava
CASE=c8a; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 96 10 10; dgh true; dalive; dcontract "$REPO"
opn --dark
check "1 item faltando: código 8"                [ "$RC" -eq 8 ]
check "1 item: lista a assinatura, o uso e a trava" bash -c 'grep -qF -- "- cota: a assinatura claude está em 96% da janela de 7 dias, na trava de 95%" <<<"$1"' _ "$ERR"
check "1 item: só uma linha de item"             [ "$(grep -c '^  - ' <<<"$ERR")" -eq 1 ]
check "1 item: nada aberto"                      so_teste

# -------- código 8, dois itens: cota do codex e GH_TOKEN sem push
CASE=c8b; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 97 10; dgh false; dalive; dcontract "$REPO"
opn --dark
check "2 itens faltando: código 8"               [ "$RC" -eq 8 ]
check "2 itens: uma linha por item"              [ "$(grep -c '^  - ' <<<"$ERR")" -eq 2 ]
check "2 itens: a cota do codex"                 bash -c 'grep -qF -- "- cota: a assinatura codex está em 97%" <<<"$1"' _ "$ERR"
check "2 itens: o GH_TOKEN sem push no dono/repo" bash -c 'grep -qF -- "- GH_TOKEN: sem permissão de merge (permissions.push) em renatobardi/projeto" <<<"$1"' _ "$ERR"
check "2 itens: o gh api pediu o repo do remoto"  grep -qxF "repos/renatobardi/projeto" "$FAKE/gh-api.log"
check "2 itens: nada aberto"                     so_teste

# -------- cota não lida e gh sem acesso também faltam
CASE=c8c; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; rm -f "${FAKE:?}/quota.json"; echo '{"schema":1,"max_pct":98,"agents":{"claude":{"status":"error","windows":{}}}}' > "$FAKE/quota.json"; dgh erro; dalive; dcontract "$REPO"
opn --dark
check "cota não lida e gh com erro: código 8"    [ "$RC" -eq 8 ]
check "cota não lida: item da assinatura sem leitura" bash -c 'grep -qF -- "- cota: não li a janela de 7 dias da assinatura claude" <<<"$1"' _ "$ERR"
check "gh com erro: item do GH_TOKEN"            bash -c 'grep -qF -- "- GH_TOKEN: sem permissão de merge" <<<"$1"' _ "$ERR"

# -------- remoto sem dono/repo
CASE=c8d; round "$CASE"
REPO="$TMP/$CASE/projeto"; gitrepo "$REPO"; dq 10 10 10; dgh true; dalive; dcontract "$REPO"
opn --dark
check "sem remoto origin: código 8"              [ "$RC" -eq 8 ]
check "sem remoto origin: o item do GH_TOKEN"    bash -c 'grep -qF -- "- GH_TOKEN: não achei o dono/repo do remoto origin" <<<"$1"' _ "$ERR"

# -------- tudo presente: abre, com dark=1 no meta e o texto no prompt
CASE=ok; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 94; dgh true; dalive; dcontract "$REPO"
opn --dark
check "tudo presente: código 0"                  [ "$RC" -eq 0 ]
check "tudo presente: o aviso do HEAD local chega a quem abre (stderr)" bash -c 'grep -qF "conferi só o HEAD" <<<"$1"' _ "$ERR"
R="$(nova)"
check "tudo presente: dark=1 no meta"            grep -qxF "dark=1" "$H/.oute/swarm/$R/meta"
check "tudo presente: o prompt traz \"modo dark, ADR-10\"" grep -qF "modo dark, ADR-10" "$FAKE/oute-task.last"
check "tudo presente: sem {{DARK}} sobrando"     bash -c '! grep -qF "{{DARK}}" "$1"' _ "$FAKE/oute-task.last"
# fatia (b) (#842): o juiz abre em arch, a autorização fica gravada, o dark.md existe só aqui
check "dark: oute-task com --phase arch"         [ "$(tr '\n' ' ' < "$FAKE/oute-task.args")" == "--phase arch -r $REPO $R claude " ]
check "dark: autorizacao gravada na abertura"    grep -qxF "modo dark (ADR-10, #839), dada na abertura" "$H/.oute/swarm/$R/autorizacao"
check "dark: estado.md traz a autorização"       grep -qF "modo dark (ADR-10, #839), dada na abertura" "$H/.oute/swarm/$R/estado.md"
check "dark: dark.md renderizado, com o id da rodada" bash -c 'grep -qF "juiz da rodada \`$1\`" "$2" && ! grep -q "{{" "$2"' _ "$R" "$H/.oute/swarm/$R/prompt/dark.md"
check "dark: o prompt manda ler o dark.md da rodada" grep -qF "~/.oute/swarm/$R/prompt/dark.md" "$FAKE/oute-task.last"
check "dark: o dark.md não manda perguntar (sem ask no juiz)" bash -c 'grep -qF "Nunca \`oute-swarm ask\`" "$1"' _ "$H/.oute/swarm/$R/prompt/dark.md"

# -------- auto-aprovador: sem batida, com batida velha, e o contrato de deploy faltando ou inválido
CASE=c8e; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 10; dgh true; dcontract "$REPO"
opn --dark
check "sem laço no host: código 8"               [ "$RC" -eq 8 ]
check "sem laço: item do auto-aprovador"         bash -c 'grep -qF -- "- auto-aprovador: nenhum laço" <<<"$1"' _ "$ERR"
check "sem laço: só esse item"                   [ "$(grep -c '^  - ' <<<"$ERR")" -eq 1 ]

CASE=c8f; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 10; dgh true; dcontract "$REPO"; dalive 300
opn --dark
check "batida de 300 s atrás: código 8"          [ "$RC" -eq 8 ]
check "batida velha: item do auto-aprovador"     bash -c 'grep -qF -- "- auto-aprovador: nenhum laço" <<<"$1"' _ "$ERR"

CASE=c8g; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 10; dgh true; dalive; ln -sf "$ROOT/scripts/deploy-contract" "$BIN/oute-deploy-contract"
opn --dark
check "sem contrato no repo: código 8"           [ "$RC" -eq 8 ]
check "sem contrato: o item diz que falta o .oute/deploy.toml" bash -c 'grep -qF -- "- contrato: .oute/deploy.toml não existe no HEAD" <<<"$1"' _ "$ERR"
check "sem contrato: nada aberto"                so_teste

CASE=c8h; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 10; dgh true; dalive; dcontract "$REPO"
chmod 644 "$REPO/.oute/verify.sh"; git -C "$REPO" add -A; git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm modo
opn --dark
check "verify sem 100755: código 8"              [ "$RC" -eq 8 ]
check "verify sem 100755: item com o caminho e o modo" bash -c 'grep -F -- "(.oute/verify.sh)" <<<"$1" | grep -qF "100644 blob"' _ "$ERR"

# -------- sem --dark: nada muda
CASE=sem; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 99 99 99; dgh false; dalive; dcontract "$REPO"
opn
check "sem --dark: abre mesmo com cota e push faltando" [ "$RC" -eq 0 ]
R="$(nova)"
check "sem --dark: sem dark= no meta"            bash -c '! grep -q "^dark=" "$1"' _ "$H/.oute/swarm/$R/meta"
check "sem --dark: o prompt não cita o modo dark" bash -c '! grep -qF "modo dark" "$1"' _ "$FAKE/oute-task.last"
check "sem --dark: oute-task com --phase plan"   [ "$(tr '\n' ' ' < "$FAKE/oute-task.args")" == "--phase plan -r $REPO $R claude " ]
check "sem --dark: sem autorizacao gravada"      [ ! -e "$H/.oute/swarm/$R/autorizacao" ]
check "sem --dark: sem dark.md na pasta da rodada" [ ! -e "$H/.oute/swarm/$R/prompt/dark.md" ]
check "sem --dark: nenhuma etapa citada leva a dark.md" bash -c '! grep -qF "dark.md" "$1"' _ "$FAKE/oute-task.all"

# ======== fatia (d), #844: --budget, spawn com teto de custo, dark_parada e stop
# -------- abertura: --budget no meta, o padrão de config/swarm.toml, e as recusas
CASE=b1; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 10; dgh true; dalive; dcontract "$REPO"
opn --dark --budget 25.50
check "budget: abre (código 0)"                  [ "$RC" -eq 0 ]
R="$(nova)"
check "budget: budget=25.50 no meta"             grep -qxF "budget=25.50" "$H/.oute/swarm/$R/meta"

CASE=b2; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 10; dgh true; dalive; dcontract "$REPO"
opn --dark
check "sem --budget: abre"                       [ "$RC" -eq 0 ]
R="$(nova)"
check "sem --budget: o padrão de config/swarm.toml (1000) no meta" grep -qxF "budget=1000" "$H/.oute/swarm/$R/meta"
check "config/swarm.toml: dark_budget_usd = 1000 (decisão do Bardi, #844)" grep -qxF "dark_budget_usd = 1000" "$ROOT/config/swarm.toml"

CASE=b3; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 10; dgh true; dalive; dcontract "$REPO"
opn --budget 10
check "--budget sem --dark: recusa"              [ "$RC" -ne 0 ]
check "--budget sem --dark: diz o motivo"        bash -c 'grep -qF -- "--budget só vale com --dark" <<<"$1"' _ "$ERR"
check "--budget sem --dark: nada aberto"         so_teste
for bad in 0 abc -5 1.234 ""; do
  opn --dark --budget "$bad"
  check "--budget '$bad': recusa"                [ "$RC" -ne 0 ]
  check "--budget '$bad': nada aberto"           so_teste
done
OUTE_SWARM_CONFIG="$TMP/nao-existe.toml" opn --dark
check "sem --budget e sem config: recusa (sem teto, sem humano)" [ "$RC" -eq 1 ]
check "sem --budget e sem config: diz o que falta" bash -c 'grep -qF "dark_budget_usd" <<<"$1"' _ "$ERR"
check "sem --budget e sem config: nada aberto"   so_teste

# -------- spawn: budget ok, estourado (código 9) e leitura que falha (abre)
CASE=sp; round "$CASE"; demit; ddark 50; MAX=20   # vagas de sobra: o teste é do teto de custo, não do --max
dstudio_up "$TMP/$CASE/studio" || exit 1
trap 'dstudio_down; rm -rf "${TMP:?}"' EXIT
dcost swarm-test 49.99
sw spawn 1-ok "instrução"
check "budget ok (49,99 < 50): spawn abre"       [ "$RC" -eq 0 ]
check "budget ok: o pedido foi ao /v1/usage da rodada com o token" grep -qxF "/v1/usage?rodada=swarm-test auth=ok" "$DSTUDIO_DIR/requests.log"
check "budget ok: a sessão está no spawned"      grep -q '^1-ok ' "$STATE/spawned"
check "budget ok: sem linha [budget] no log"     bash -c '! grep -qF "[budget]" "$1"' _ "$STATE/log"
dcost swarm-test 50
sw spawn 2-estoura "instrução"
check "budget estourado (50 >= 50): código 9"    [ "$RC" -eq 9 ]
check "budget estourado: diz custo, teto e a sessão" bash -c 'grep -qF "gastou US\$ 50" <<<"$1" && grep -qF "budget de US\$ 50" <<<"$1" && grep -qF "2-estoura não abre (código 9)" <<<"$1"' _ "$ERR"
check "budget estourado: linha [budget] no log da rodada" bash -c 'grep -qF "[budget] spawn 2-estoura recusado: custo da rodada US\$ 50 >= budget US\$ 50" "$1"' _ "$STATE/log"
check "budget estourado: nenhuma aba nova nem entrada no spawned" bash -c '! grep -q "^2-estoura " "$1" && [ "$(grep -c "tab create" "$2")" -eq 1 ]' _ "$STATE/spawned" "$FAKE/herdr.log"
check "budget estourado: nada de .instr nem .prompt da sessão recusada" [ ! -e "$STATE/2-estoura.instr" ] 
dcost swarm-test 51.5
sw spawn 2-estoura "instrução"
check "acima do teto (51,5): código 9 também"    [ "$RC" -eq 9 ]

for modo in erro lixo; do
  printf '%s\n' "$modo" > "$DSTUDIO_DIR/mode"
  sw spawn "3-$modo" "instrução"
  check "leitura '$modo': abre (cota desconhecida não trava)" [ "$RC" -eq 0 ]
  check "leitura '$modo': avisa que não conferiu o teto" bash -c 'grep -qF "não li o custo da rodada swarm-test" <<<"$1" && grep -qF "3-'"$modo"' abre" <<<"$1"' _ "$ERR"
  check "leitura '$modo': a sessão está no spawned" grep -q "^3-$modo " "$STATE/spawned"
done
printf 'lento\n' > "$DSTUDIO_DIR/mode"
t0=$SECONDS
sw spawn 4-lento "instrução"
check "leitura lenta (acima de 3 s): abre"       [ "$RC" -eq 0 ]
check "leitura lenta: avisa"                     bash -c 'grep -qF "não li o custo da rodada" <<<"$1"' _ "$ERR"
check "leitura lenta: espera o teto de 3 s, não os 6 s do servidor" [ $((SECONDS - t0)) -le 5 ]
printf 'ok\n' > "$DSTUDIO_DIR/mode"
dstudio_down
sw spawn 5-fora "instrução"
check "agent-studio fora do ar: abre com aviso"  bash -c '[ "$1" -eq 0 ] && grep -qF "não li o custo da rodada" <<<"$2"' _ "$RC" "$ERR"
AGENT_STUDIO_READ_TOKEN="" sw spawn 6-sem-token "instrução"
check "sem token de leitura: abre com aviso"     bash -c '[ "$1" -eq 0 ] && grep -qF "não li o custo da rodada" <<<"$2"' _ "$RC" "$ERR"

# -------- spawn fora do modo dark: nem consulta o agent-studio
CASE=nd; round "$CASE"; MAX=3
dstudio_up "$TMP/$CASE/studio" || exit 1
dcost swarm-test 99999
sw spawn 1-livre "instrução"
check "rodada sem dark: abre mesmo com custo enorme" [ "$RC" -eq 0 ]
check "rodada sem dark: o agent-studio nem foi consultado" [ ! -s "$DSTUDIO_DIR/requests.log" ]
dstudio_down

# -------- dark_parada=deploy e stop
CASE=st; round "$CASE"; demit; ddark 1000
dstudio_up "$TMP/$CASE/studio" || exit 1
dcost swarm-test 1
sw dark-parada deploy
check "dark-parada: código 0"                    [ "$RC" -eq 0 ]
sw dark-parada deploy
check "dark-parada duas vezes: uma linha no meta" [ "$(grep -c '^dark_parada=deploy$' "$STATE/meta")" -eq 1 ]
check "dark-parada: linha [parada] no log, uma vez" [ "$(grep -c '\[parada\] rodada parada' "$STATE/log")" -eq 1 ]
sw spawn 1-depois "instrução"
check "depois do dark_parada: spawn recusa com código 9" [ "$RC" -eq 9 ]
check "depois do dark_parada: linha [parada] de spawn" bash -c 'grep -qF "[parada] spawn 1-depois recusado" "$1"' _ "$STATE/log"
check "depois do dark_parada: nem consultou o custo" [ ! -s "$DSTUDIO_DIR/requests.log" ]
sw dark-parada rollback
check "dark-parada: só aceita deploy"            [ "$RC" -ne 0 ]
dstudio_down

CASE=np; round "$CASE"
sw dark-parada deploy
check "dark-parada em rodada sem dark: recusa"   [ "$RC" -ne 0 ]
check "dark-parada em rodada sem dark: meta intacto" bash -c '! grep -q dark_parada "$1"' _ "$STATE/meta"

CASE=stop; round "$CASE"; demit; ddark 1000
mkdir -p "$H/.oute/approve/dark.swarm-test.lock" "$H/.oute/approve/dark.outra.lock"
echo 1234 > "$H/.oute/approve/dark.swarm-test.lock/pid"; echo 1234 > "$H/.oute/approve/dark.outra.lock/pid"
date +%s > "$H/.oute/approve/dark.swarm-test.alive"
touch "$FAKE/tab-close.fail"
sw stop swarm-test
check "stop com aba que não fecha: código 1"     [ "$RC" -eq 1 ]
check "stop com aba que não fecha: diz para rodar de novo" bash -c 'grep -qF "nem todas as abas" <<<"$1"' _ "$ERR"
check "stop com aba que não fecha: sem a marca fechada" [ ! -e "$STATE/fechada" ]
check "stop com aba que não fecha: laço já desligado (dark.stop)" [ -s "$STATE/dark.stop" ]
check "stop: o lock da rodada saiu"              [ ! -e "$H/.oute/approve/dark.swarm-test.lock" ]
check "stop: a batida da rodada saiu"            [ ! -e "$H/.oute/approve/dark.swarm-test.alive" ]
check "stop: o lock de OUTRA rodada fica"        [ -d "$H/.oute/approve/dark.outra.lock" ]
rm -f "$FAKE/tab-close.fail"
sw stop swarm-test
check "stop: código 0"                           [ "$RC" -eq 0 ]
check "stop: fecha a aba da sessão (herdr tab close)" grep -qxF "tab close w1:t1" "$FAKE/herdr.log"
check "stop: marca fechada no disco"             [ -s "$STATE/fechada" ]
check "stop: a sessão entra no closed"           grep -qxF "7-foo" "$STATE/closed"
check "stop: uma linha 'rodada fechada' no log"  [ "$(grep -c ' rodada fechada$' "$STATE/log")" -eq 1 ]
check "stop: emite o round.closed (oute-emit swarm <rodada> ... rodada fechada)" [ "$(grep -c '^swarm swarm-test .* rodada fechada$' "$FAKE/emit.log")" -eq 1 ]
closes="$(grep -c '^tab close ' "$FAKE/herdr.log")"; emits="$(wc -l < "$FAKE/emit.log")"
sw stop swarm-test
check "stop de novo: código 0 (idempotente)"     [ "$RC" -eq 0 ]
check "stop de novo: diz que já estava fechada"  bash -c 'grep -qF "já fechada" <<<"$1"' _ "$OUT"
check "stop de novo: não fecha aba nem emite outra vez" bash -c '[ "$(grep -c "^tab close " "$1")" -eq "$2" ] && [ "$(wc -l < "$3")" -eq "$4" ]' _ "$FAKE/herdr.log" "$closes" "$FAKE/emit.log" "$emits"
check "stop de novo: ainda uma linha 'rodada fechada'" [ "$(grep -c ' rodada fechada$' "$STATE/log")" -eq 1 ]
sw spawn 1-depois-do-stop "instrução"
check "spawn depois do stop: código 9"           [ "$RC" -eq 9 ]
check "spawn depois do stop: a marca fechada não é desfeita" [ -s "$STATE/fechada" ]
check "spawn depois do stop: linha [parada] com oute-swarm stop" bash -c 'grep -qF "[parada] spawn 1-depois-do-stop recusado: rodada parada por oute-swarm stop" "$1"' _ "$STATE/log"
sw stop swarm-nao-existe
check "stop de rodada que não existe: erro"      [ "$RC" -ne 0 ]
check "stop de rodada que não existe: diz qual"  bash -c 'grep -qF "rodada swarm-nao-existe não existe" <<<"$1"' _ "$ERR"
sw stop
check "stop sem rodada: uso"                     bash -c '[ "$1" -ne 0 ] && grep -qF "uso: oute-swarm stop <rodada>" <<<"$2"' _ "$RC" "$ERR"
sw stop "../fora"
check "stop com caminho no lugar do id: recusa"  bash -c '[ "$1" -ne 0 ] && grep -qF "uso: oute-swarm stop" <<<"$2"' _ "$RC" "$ERR"

CASE=stop0; round "$CASE"; demit; ddark 1000
rm -f "$STATE/spawned"
sw stop swarm-test
check "stop de rodada dark sem nenhuma sessão: código 0 e fechada" bash -c '[ "$1" -eq 0 ] && [ -s "$2/fechada" ]' _ "$RC" "$STATE"

guarda_check
guarda_stop
check_end
