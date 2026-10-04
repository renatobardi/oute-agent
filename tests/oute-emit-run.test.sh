#!/usr/bin/env bash
# Testes do `oute-emit run` (#507): roda um comando (o agente headless do revisor da etapa) com o ambiente de telemetria do
# ~/.oute_env, que o shell do Bash tool do Claude Code não herda (#250). Só o que falta no ambiente, só as chaves do
# TELEMETRY_KEYS, nunca source, --attr no OTEL_RESOURCE_ATTRIBUTES; repassa entrada, saída e código de saída.
# Bash puro + python3, sem rede. Uso: tests/oute-emit-run.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v python3 >/dev/null || die "precisa de python3"
EMIT="$ROOT/docker/oute-emit"
H="$TMP/home"; mkdir -p "$H"
# o comando que o `run` executa: grava o ambiente, os argumentos e o stdin, e sai com $RC_CHILD
cat > "$TMP/child" <<'SH'
#!/usr/bin/env bash
env | sort > "$OUT_DIR/env"; printf '%s\n' "$@" > "$OUT_DIR/args"; cat > "$OUT_DIR/stdin"
echo "saida do filho"; echo "erro do filho" >&2
exit "${RC_CHILD:-0}"
SH
chmod +x "$TMP/child"
export OUT_DIR="$TMP/out"; mkdir -p "$OUT_DIR"
# envfile <home> [VAR=valor…]: ~/.oute_env como o entrypoint grava (declare -px, o mesmo filtro), só com as variáveis dadas e
# uma GH_, uma OUTE_ e uma OTEL_SERVICE_NAME (fora do conjunto); e uma linha de shell solta, que só um source executaria
envfile() {
  local h="$1"; shift
  env -i OUTE_X='valor com "aspas" e $(touch '"$h"'/pwned)' GH_X=segredo OTEL_SERVICE_NAME=outro "$@" bash -c 'declare -px' \
    | grep -E '^declare -x (GH_|OUTE_|OTEL_|CLAUDE_CODE_)' > "$h/.oute_env"
  printf 'touch "%s/pwned"\n' "$h" >> "$h/.oute_env"
  return 0
}
# clean: o ambiente do Bash tool (sem as OTEL_* e sem as chaves do conjunto)
clean() { env -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_EXPORTER_OTLP_LOGS_ENDPOINT -u OTEL_RESOURCE_ATTRIBUTES -u OTEL_EXPORTER_OTLP_PROTOCOL \
  -u OTEL_LOGS_EXPORTER -u OTEL_METRICS_EXPORTER -u OTEL_TRACES_EXPORTER -u OTEL_LOG_USER_PROMPTS -u OTEL_LOG_TOOL_DETAILS -u OTEL_LOG_TOOL_CONTENT \
  -u OTEL_LOG_ASSISTANT_RESPONSES -u CLAUDE_CODE_ENABLE_TELEMETRY -u CLAUDE_CODE_ENHANCED_TELEMETRY_BETA "$@"; return $?; }
# run <args…>: roda `oute-emit run` com o filho; stdout em $OUT, stderr em $ERR, código em $RC. $RUN_ENV = variáveis a mais
run() {
  rm -f "$OUT_DIR"/*
  OUT="$(printf 'entrada do pai' | HOME="$H" clean ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$EMIT" run "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
  return 0
}
envval() { local k="$1"; sed -n "s/^$k=//p" "$OUT_DIR/env"; return $?; }
RUN_ENV=()
HTTP="ht""tp"; EP="$HTTP://collector.invalid:4318"; LEP="$HTTP://logs.invalid:4318/v1/logs"; export HTTP EP LEP

envfile "$H" OTEL_EXPORTER_OTLP_ENDPOINT=$EP OTEL_RESOURCE_ATTRIBUTES="host.name=oute-server,oute.instance=oute-agent" \
  OTEL_EXPORTER_OTLP_PROTOCOL=http/json OTEL_LOGS_EXPORTER=otlp OTEL_METRICS_EXPORTER=otlp OTEL_TRACES_EXPORTER=otlp OTEL_LOG_USER_PROMPTS=1 \
  CLAUDE_CODE_ENABLE_TELEMETRY=1 CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
run --attr oute.swarm.round=swarm-1004-1306 --attr oute.swarm.step=fechamento -- "$TMP/child" um "dois três" --flag
check "run: o código de saída do filho é o do comando (0)" [ "$RC" -eq 0 ]
check "run: stdout e stderr do filho passam"            bash -c '[ "$1" = "saida do filho" ] && [ "$2" = "erro do filho" ]' _ "$OUT" "$ERR"
check "run: o stdin chega ao filho"                     [ "$(cat "$OUT_DIR/stdin")" = "entrada do pai" ]
check "run: os argumentos chegam como estão (espaço e opção)" [ "$(cat "$OUT_DIR/args")" = $'um\ndois três\n--flag' ]
check "run: o ambiente do arquivo chega ao filho (endpoint, protocolo, exporters, ligar a telemetria)" bash -c '
  v() { sed -n "s/^$1=//p" "$OUT_DIR/env"; }
  [ "$(v OTEL_EXPORTER_OTLP_ENDPOINT)" = $EP ] && [ "$(v OTEL_EXPORTER_OTLP_PROTOCOL)" = http/json ] \
  && [ "$(v OTEL_LOGS_EXPORTER)" = otlp ] && [ "$(v OTEL_METRICS_EXPORTER)" = otlp ] && [ "$(v OTEL_TRACES_EXPORTER)" = otlp ] \
  && [ "$(v OTEL_LOG_USER_PROMPTS)" = 1 ] && [ "$(v CLAUDE_CODE_ENABLE_TELEMETRY)" = 1 ] && [ "$(v CLAUDE_CODE_ENHANCED_TELEMETRY_BETA)" = 1 ]' _
check "run: --attr acrescenta à origem do arquivo, na ordem" [ "$(envval OTEL_RESOURCE_ATTRIBUTES)" = "host.name=oute-server,oute.instance=oute-agent,oute.swarm.round=swarm-1004-1306,oute.swarm.step=fechamento" ]
check "run: chave fora do conjunto do arquivo não passa (GH_, OUTE_, OTEL_SERVICE_NAME)" bash -c '! grep -qE "^(GH_X|OUTE_X|OTEL_SERVICE_NAME)=" "$OUT_DIR/env"' _
check "run: nenhuma linha do arquivo executada (nunca source)" [ ! -e "$H/pwned" ]
# o ambiente vence, chave por chave
RUN_ENV=(OTEL_EXPORTER_OTLP_PROTOCOL=grpc OTEL_RESOURCE_ATTRIBUTES="host.name=do-ambiente")
run --attr a.b=c -- "$TMP/child"
check "run: variável com valor no ambiente vence a do arquivo (protocolo)" [ "$(envval OTEL_EXPORTER_OTLP_PROTOCOL)" = grpc ]
check "run: a origem do ambiente vence e leva o --attr"  [ "$(envval OTEL_RESOURCE_ATTRIBUTES)" = "host.name=do-ambiente,a.b=c" ]
check "run: o que o ambiente não tem vem do arquivo"      [ "$(envval OTEL_LOGS_EXPORTER)" = otlp ]
# endpoint de logs no ambiente: o endpoint base do arquivo não entra (o par vale junto)
RUN_ENV=(OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=$LEP)
run -- "$TMP/child"
check "run: endpoint de logs no ambiente = o base do arquivo não entra" bash -c '! grep -q "^OTEL_EXPORTER_OTLP_ENDPOINT=" "$OUT_DIR/env" && grep -q "^OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=$HTTP://logs.invalid" "$OUT_DIR/env"' _
RUN_ENV=()
# sem --attr e sem origem em lugar nenhum: nada de OTEL_RESOURCE_ATTRIBUTES
rm -f "$H/.oute_env"
run -- "$TMP/child"
check "run: sem arquivo e sem --attr: roda o filho, sem origem inventada" bash -c '[ "$1" -eq 0 ] && ! grep -q "^OTEL_RESOURCE_ATTRIBUTES=" "$OUT_DIR/env"' _ "$RC"
run --attr oute.swarm.round=r1 -- "$TMP/child"
check "run: sem arquivo, só o --attr vira a origem"      [ "$(envval OTEL_RESOURCE_ATTRIBUTES)" = oute.swarm.round=r1 ]
# código de saída do filho
RUN_ENV=(RC_CHILD=7); run -- "$TMP/child"
check "run: o código de saída do filho passa (7)"        [ "$RC" -eq 7 ]
RUN_ENV=()
# linha do arquivo fora do formato = chave ausente
for bad in "aspas simples|declare -x OTEL_LOGS_EXPORTER='otlp'" "sem aspas|declare -x OTEL_LOGS_EXPORTER=otlp" "\$'…'|declare -x OTEL_LOGS_EXPORTER=\$'otlp'" \
           "comando depois|declare -x OTEL_LOGS_EXPORTER=\"otlp\" ; touch $H/pwned"; do
  : > "$H/.oute_env"; printf '%s\n' "${bad#*|}" >> "$H/.oute_env"
  run -- "$TMP/child"
  check "run: linha fora do formato do declare -px ($(printf '%s' "${bad%%|*}")): a chave não passa e nada é executado" bash -c '[ "$1" -eq 0 ] && ! grep -q "^OTEL_LOGS_EXPORTER=" "$OUT_DIR/env" && [ ! -e "$2/pwned" ]' _ "$RC" "$H"
done
# chave repetida = ausente
printf 'declare -x OTEL_LOGS_EXPORTER="otlp"\ndeclare -x OTEL_LOGS_EXPORTER="outro"\n' > "$H/.oute_env"
run -- "$TMP/child"
check "run: chave repetida no arquivo: ausente"         bash -c '! grep -q "^OTEL_LOGS_EXPORTER=" "$OUT_DIR/env"' _
# arquivo grande demais ou fora de UTF-8: nada dele, o filho roda
printf 'declare -x OTEL_LOGS_EXPORTER="otlp"\n' > "$H/.oute_env"; head -c 1100000 /dev/zero | tr '\0' '#' >> "$H/.oute_env"
run -- "$TMP/child"
check "run: arquivo acima de 1 MiB: nada dele, o filho roda" bash -c '[ "$1" -eq 0 ] && ! grep -q "^OTEL_LOGS_EXPORTER=" "$OUT_DIR/env"' _ "$RC"
printf 'declare -x OTEL_LOGS_EXPORTER="otlp"\n\xff\xfe\n' > "$H/.oute_env"
run -- "$TMP/child"
check "run: arquivo fora de UTF-8: nada dele, o filho roda" bash -c '[ "$1" -eq 0 ] && ! grep -q "^OTEL_LOGS_EXPORTER=" "$OUT_DIR/env"' _ "$RC"
# uso inválido: código 2, o comando não roda
rm -f "$H/.oute_env"
for args in "--attr x=1" "--attr x=1 $TMP/child" "-- " "" "--attr" "--attr x -- $TMP/child" "--attr a=b;c -- $TMP/child" "--attr a=b%20c -- $TMP/child" "--attr =x -- $TMP/child" "--attr a= -- $TMP/child"; do
  # shellcheck disable=SC2086
  run $args
  check "run: uso inválido ($args): código 2 e o filho não roda" bash -c '[ "$1" -eq 2 ] && [ -n "$2" ] && [ ! -e "$3/env" ]' _ "$RC" "$ERR" "$OUT_DIR"
done
run -- "$TMP/nao-existe"
check "run: comando que não existe: 127, só o nome na mensagem" bash -c '[ "$1" -eq 127 ] && grep -qF "não rodei" <<<"$2"' _ "$RC" "$ERR"
check "run: nunca escreve no stdout em erro"             [ -z "$OUT" ]
check "docs: o uso do oute-emit lista o run"             bash -c '"$1" --help 2>&1 | grep -qF "oute-emit run [--attr k=v]"' _ "$EMIT"
check_end
