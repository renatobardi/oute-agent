#!/usr/bin/env bash
# Testes do oute-swarm, tema: carga do container no spawn (#623): aviso em stderr quando a média de 1 min do
# /proc/loadavg passa de 2 × nproc, sem bloquear a sessão.
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-carga.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"

# nproc falso: $FAKE_NPROC núcleos (padrão 4); `falha` = sai com 1, sem número
cat > "$BIN/nproc" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_NPROC:-4}" != falha ]] || exit 1
echo "${FAKE_NPROC:-4}"
SH
chmod +x "$BIN/nproc"
LOAD="$TMP/loadavg"
# spawn_load <n>-<slug> <conteúdo do loadavg>: o spawn com o arquivo de carga dado
spawn_load() {
  local task="$1" content="$2"
  printf '%s\n' "$content" > "$LOAD"
  OUTE_SWARM_LOADAVG="$LOAD" MAX=20 sw spawn "$task" "instrução"
  return 0
}
# quiet_open <slug>: o último spawn saiu com 0, sem nada em stderr, e a sessão está no spawned
quiet_open() {
  local slug="$1"
  [[ "$RC" -eq 0 && -z "$ERR" ]] || return 1
  grep -q "^$slug " "$STATE/spawned"
  return $?
}

CASE=carga; round "$CASE"
# 4 núcleos: o limite é 8
spawn_load 8-alta "8.01 7.50 6.00 9/2014 94187"
check "carga alta: aviso em stderr, com a carga e o limite" test "$ERR" = "oute-swarm: aviso: carga do container em 8.01, acima de 8 (2 × 4 núcleos); 8-alta abre mesmo assim"
check "carga alta: não bloqueia (código 0, sessão aberta)" bash -c '[ "$1" -eq 0 ] && grep -q "^8-alta " "$2" && grep -q -- "--label #8 alta " "$3"' _ "$RC" "$STATE/spawned" "$FAKE/herdr.log"
spawn_load 9-igual "8.00 7.50 6.00 9/2014 94187"
check "carga igual a 2 × nproc: sem aviso"                 test "$RC$ERR" = 0
spawn_load 10-baixa "1.50 1.20 1.00 2/2014 94187"
check "carga baixa: sem aviso"                             test "$RC$ERR" = 0
FAKE_NPROC=1 spawn_load 11-um "2.5 1.20 1.00 2/2014 94187"
check "1 núcleo: o limite é 2"                             test "$ERR" = "oute-swarm: aviso: carga do container em 2.5, acima de 2 (2 × 1 núcleos); 11-um abre mesmo assim"
spawn_load 12-inteiro "17 1.20 1.00 2/2014 94187"
check "carga sem casa decimal: avisa"                      grep -qF 'carga do container em 17, acima de 8' <<<"$ERR"

# sem dado de carga: o spawn abre calado
spawn_load 13-lixo "muita 1.20 1.00"
check "loadavg que não é número: sem aviso, sessão aberta" quiet_open 13-lixo
OUTE_SWARM_LOADAVG="$TMP/nao-existe" MAX=20 sw spawn 14-sem "instrução"
check "sem o arquivo de carga (o Mac): sem aviso, sessão aberta" quiet_open 14-sem
FAKE_NPROC=falha spawn_load 15-nproc "99.00 1.20 1.00 2/2014 94187"
check "sem nproc: sem aviso, sessão aberta"                quiet_open 15-nproc

# o aviso é de quem abre: spawn recusado não avisa
printf '%s\n' "99.00 1.20 1.00 2/2014 94187" > "$LOAD"
OUTE_SWARM_LOADAVG="$LOAD" MAX=1 sw spawn 16-cheia "instrução"
check "spawn recusado pelo limite: sem aviso de carga"     bash -c '[ "$1" -ne 0 ] && ! grep -qF "carga do container" <<<"$2"' _ "$RC" "$ERR"
# sem a variável, o arquivo é o /proc/loadavg; o apoio dos temas aponta para um que não existe
check "padrão do spawn: lê o /proc/loadavg"                grep -qF 'file="${OUTE_SWARM_LOADAVG:-/proc/loadavg}"' "$SWARM"
check "apoio dos temas: a carga de quem roda o teste não entra" test "$OUTE_SWARM_LOADAVG" = "$TMP/sem-loadavg" -a ! -e "$TMP/sem-loadavg"

check_end
