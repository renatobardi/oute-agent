#!/usr/bin/env bash
# Testes do oute-swarm, tema: modo dark, fatias (a) e (b) (#841, #842, ADR-10; (b): --phase arch, autorização e dark.md): `--dark` grava dark=1 no meta e põe "modo dark, ADR-10" no prompt;
# recusa o oute-agent (código 7) e pré-requisito faltando (código 8, um item por linha; cota de 7 dias e permissão de push).
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

# -------- código 7: o oute-agent não é alvo
CASE=c7; round "$CASE"
REPO="$TMP/$CASE/oute-agent"; dark_repo "$REPO"; dq 10 10 10; dgh true
opn --dark
check "oute-agent: código 7"                     [ "$RC" -eq 7 ]
check "oute-agent: diz o motivo (ADR-10, self-restart)" bash -c 'grep -qF "ADR-10" <<<"$1" && grep -qF "self-restart" <<<"$1" && grep -qF "código 7" <<<"$1"' _ "$ERR"
check "oute-agent: nenhuma rodada nova nem oute-task" so_teste

# -------- código 8, um item: cota do claude na trava
CASE=c8a; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 96 10 10; dgh true
opn --dark
check "1 item faltando: código 8"                [ "$RC" -eq 8 ]
check "1 item: lista a assinatura, o uso e a trava" bash -c 'grep -qF -- "- cota: a assinatura claude está em 96% da janela de 7 dias, na trava de 95%" <<<"$1"' _ "$ERR"
check "1 item: só uma linha de item"             [ "$(grep -c '^  - ' <<<"$ERR")" -eq 1 ]
check "1 item: nada aberto"                      so_teste

# -------- código 8, dois itens: cota do codex e GH_TOKEN sem push
CASE=c8b; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 97 10; dgh false
opn --dark
check "2 itens faltando: código 8"               [ "$RC" -eq 8 ]
check "2 itens: uma linha por item"              [ "$(grep -c '^  - ' <<<"$ERR")" -eq 2 ]
check "2 itens: a cota do codex"                 bash -c 'grep -qF -- "- cota: a assinatura codex está em 97%" <<<"$1"' _ "$ERR"
check "2 itens: o GH_TOKEN sem push no dono/repo" bash -c 'grep -qF -- "- GH_TOKEN: sem permissão de merge (permissions.push) em renatobardi/projeto" <<<"$1"' _ "$ERR"
check "2 itens: o gh api pediu o repo do remoto"  grep -qxF "repos/renatobardi/projeto" "$FAKE/gh-api.log"
check "2 itens: nada aberto"                     so_teste

# -------- cota não lida e gh sem acesso também faltam
CASE=c8c; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; rm -f "${FAKE:?}/quota.json"; echo '{"schema":1,"max_pct":98,"agents":{"claude":{"status":"error","windows":{}}}}' > "$FAKE/quota.json"; dgh erro
opn --dark
check "cota não lida e gh com erro: código 8"    [ "$RC" -eq 8 ]
check "cota não lida: item da assinatura sem leitura" bash -c 'grep -qF -- "- cota: não li a janela de 7 dias da assinatura claude" <<<"$1"' _ "$ERR"
check "gh com erro: item do GH_TOKEN"            bash -c 'grep -qF -- "- GH_TOKEN: sem permissão de merge" <<<"$1"' _ "$ERR"

# -------- remoto sem dono/repo
CASE=c8d; round "$CASE"
REPO="$TMP/$CASE/projeto"; gitrepo "$REPO"; dq 10 10 10; dgh true
opn --dark
check "sem remoto origin: código 8"              [ "$RC" -eq 8 ]
check "sem remoto origin: o item do GH_TOKEN"    bash -c 'grep -qF -- "- GH_TOKEN: não achei o dono/repo do remoto origin" <<<"$1"' _ "$ERR"

# -------- tudo presente: abre, com dark=1 no meta e o texto no prompt
CASE=ok; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 10 10 94; dgh true
opn --dark
check "tudo presente: código 0"                  [ "$RC" -eq 0 ]
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

# -------- sem --dark: nada muda
CASE=sem; round "$CASE"
REPO="$TMP/$CASE/projeto"; dark_repo "$REPO"; dq 99 99 99; dgh false
opn
check "sem --dark: abre mesmo com cota e push faltando" [ "$RC" -eq 0 ]
R="$(nova)"
check "sem --dark: sem dark= no meta"            bash -c '! grep -q "^dark=" "$1"' _ "$H/.oute/swarm/$R/meta"
check "sem --dark: o prompt não cita o modo dark" bash -c '! grep -qF "modo dark" "$1"' _ "$FAKE/oute-task.last"
check "sem --dark: oute-task com --phase plan"   [ "$(tr '\n' ' ' < "$FAKE/oute-task.args")" == "--phase plan -r $REPO $R claude " ]
check "sem --dark: sem autorizacao gravada"      [ ! -e "$H/.oute/swarm/$R/autorizacao" ]
check "sem --dark: sem dark.md na pasta da rodada" [ ! -e "$H/.oute/swarm/$R/prompt/dark.md" ]
check "sem --dark: nenhuma etapa citada leva a dark.md" bash -c '! grep -qF "dark.md" "$1"' _ "$FAKE/oute-task.all"

guarda_check
guarda_stop
check_end
