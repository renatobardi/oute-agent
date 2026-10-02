#!/usr/bin/env bash
# Testes do verify-host.sh da skill oute-aidlc-ship-verify (#107). Bash puro, sem Docker nem OCI:
# `oute`, `docker` e `rclone` são falsos, controlados por variáveis F_*. Confere a saída (OK/AVISO/FALHA)
# e o código de saída. Uso: tests/ship-verify.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/addons/skills/oute-aidlc-ship-verify/scripts/verify-host.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1   # o bad mostra a saída inteira
has() { grep -q -- "$1" <<<"$OUT"; }
hasnt() { ! has "$1"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/oute" <<'SH'
#!/usr/bin/env bash
case "$1" in
  version) printf 'repo:    %s (abc1234)\nrunning: %s\norigem:  host=srv instance=oute-agent\n' "${F_REPO:-0.7.26}" "${F_RUN:-0.7.26}" ;;
  storage) [[ "$OUTE_BUCKET" == oute-observability && "$2" == lsf ]] || exit 9
           [[ "${F_LS_FAIL:-}" == 1 ]] && exit 1
           case "$3" in *"/${F_EMPTY:-none}/"*) ;; *) printf 'year=2026/a.json\nyear=2026/b.json\n' ;; esac ;;
  *) exit 9 ;;
esac
SH
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  inspect) c="${!#}"
           [[ " ${F_MISSING:-} " == *" $c "* ]] && exit 1
           if [[ "$c" == oute-volume-init ]]; then echo 'exited|0'; exit 0; fi
           st=running; [[ " ${F_DOWN:-} " == *" $c "* ]] && st=exited
           r=0; [[ " ${F_RESTART:-} " == *" $c "* ]] && r=3
           echo "$st||$r|2026-09-27T12:00:00Z|img:$c" ;;
  logs) [[ -n "${F_ERRLOG:-}" ]] && printf '2026-09-27T12:00:00Z\terror\texporterhelper\tExporting failed. Dropping data.\n'; exit 0 ;;
  *) exit 9 ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' > "$BIN/rclone"
chmod +x "$BIN"/*

# run [VAR=valor…]: roda o script com os falsos; guarda saída em $OUT e código em $RC
run() { OUT="$(env PATH="$BIN:/usr/bin:/bin" OUTE_BIN="$BIN/oute" EXPECTED=0.7.26 "$@" bash "$SCRIPT" 2>&1)"; RC=$?; }

[[ -f "$SCRIPT" ]] || { echo "FAIL script ausente: $SCRIPT"; exit 1; }
check "sintaxe (bash -n)" bash -n "$SCRIPT"

run
check "tudo certo: código 0"                  [ "$RC" -eq 0 ]
check "tudo certo: sem FALHA"                 hasnt 'FALHA'
check "tudo certo: resumo 0 falha"            has '== resumo: 0 falha(s), 0 aviso(s)'
check "tudo certo: telemetria por sinal"      has 'OK     logs: 2 objeto(s) novo(s) em otel/logs/host=srv/instance=oute-agent'

run F_RUN=0.7.25
check "imagem antiga: código 1"               [ "$RC" -eq 1 ]
check "imagem antiga: FALHA da imagem"        has "FALHA  imagem rodando '0.7.25', esperado 0.7.26"

run F_REPO=0.7.25
check "repo atrasado: FALHA do repo"          has "FALHA  repo em '0.7.25', esperado 0.7.26"

run F_DOWN=oute-jev-router
check "serviço parado: código 1"              [ "$RC" -eq 1 ]
check "serviço parado: FALHA do serviço"      has 'FALHA  oute-jev-router: exited'

run F_MISSING=oute-ai-memory
check "container ausente: FALHA"              has 'FALHA  oute-ai-memory: container não existe'

run F_RESTART=oute-agent
check "reinício: só AVISO, código 0"          [ "$RC" -eq 0 ]
check "reinício: AVISO com a contagem"        has 'AVISO  oute-agent: rodando, mas reiniciou 3 vez(es)'

run F_EMPTY=metrics
check "um sinal vazio: AVISO, código 0"       [ "$RC" -eq 0 ]
check "um sinal vazio: AVISO do sinal"        has 'AVISO  metrics: nenhum objeto novo'

run F_LS_FAIL=1
check "bucket inacessível: código 1"          [ "$RC" -eq 1 ]
check "bucket inacessível: FALHA geral"       has 'FALHA  nenhuma telemetria nova do host=srv instance=oute-agent'

run F_ERRLOG=1
check "erro no collector: AVISO"              has 'AVISO  otel-collector: 1 linha(s) de erro'

run EXPECTED=
check "sem EXPECTED: AVISO e compara com o repo" has 'AVISO  EXPECTED não informado'
check "sem EXPECTED: código 0"                [ "$RC" -eq 0 ]

# o texto vai pelo canal com a versão na frente (como a skill manda): a linha extra não quebra o script
OUT="$( { printf 'EXPECTED=%q\n' 0.7.26; cat "$SCRIPT"; } | env PATH="$BIN:/usr/bin:/bin" OUTE_BIN="$BIN/oute" bash 2>&1)"; RC=$?
check "via stdin com EXPECTED na frente: código 0" [ "$RC" -eq 0 ]

check_end
