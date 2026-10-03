#!/usr/bin/env bash
# Testes do tests/lib/otelcol.sh (#246), pelo lado que os tests/otelcol-*.test.sh não exercitam quando passam: a conta
# de perdidos e duplicados (otelcol_tally), o que falta para rodar (die), o S3 falso e o collector que não sobem, o
# começo do config do teste e o log no fim. Cada cenário roda num bash à parte (run), com a lib carregada.
# Não baixa nem roda o collector. Precisa de python3, jq, curl e tar. Uso: tests/otelcol-lib.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1

# run <trecho> [VAR=valor…]: o trecho num bash novo, com check.sh, otlp.sh e otelcol.sh carregados; define OUT e RC
run() {
  local code="$1"; shift
  OUT="$(env "$@" bash -c "set -uo pipefail; ROOT='$ROOT'; TMP='$TMP'
    . '$ROOT/tests/lib/check.sh'; . '$ROOT/tests/lib/otlp.sh'; . '$ROOT/tests/lib/otelcol.sh'; $code" 2>&1)"; RC=$?
}

# ---------------------------------------------------------------- 1. o que falta para rodar
BIN="$TMP/bin"; mkdir -p "$BIN"
for c in bash python3 jq curl dirname grep; do ln -s "$(command -v "$c")" "$BIN/$c"; done   # sem o tar
run 'echo "não chega aqui"' PATH="$BIN"
check "sem tar: sai com 1"                             test "$RC" = 1
check "sem tar: diz o que falta e para"                test "$OUT" = "FAIL precisa de tar"

# ---------------------------------------------------------------- 2. otelcol_tally: aceitos, recebidos, perdidos, duplicados
printf 'a\nb\nc\n\n' > "$TMP/aceitos.txt"
run "printf 'a\nb\nc\n' | otelcol_tally '$TMP/aceitos.txt'"
check "tally: tudo entregue uma vez"                   test "$OUT" = "3 3 0 0"
run "printf 'a\nb\nb\nb\nfora\nfora\n' | otelcol_tally '$TMP/aceitos.txt'"
check "tally: perdido e duplicado só entre os aceitos" test "$OUT" = "3 2 1 2"
run "otelcol_tally '$TMP/aceitos.txt' </dev/null"
check "tally: nada chegou = tudo perdido"              test "$OUT" = "3 0 3 0"
run "counts() { printf 'a\nb\n' | otelcol_tally '$TMP/aceitos.txt'; }; wait_all x 1; echo \"rc=\$?\""
check "wait_all: com item perdido, devolve != 0 no prazo" has_line "rc=1"
run "counts() { printf 'a\nb\nc\n' | otelcol_tally '$TMP/aceitos.txt'; }; wait_all x 1; echo \"rc=\$?\""
check "wait_all: tudo entregue, devolve 0"             has_line "rc=0"

# ---------------------------------------------------------------- 3. ambiente e config do teste
run 'OCI_S3_ENDPOINT=de-fora; otelcol_env; echo "$OUTE_HOST $OUTE_INSTANCE $LANGFUSE_HOST"; echo "s3=$OCI_S3_ENDPOINT"'
check "otelcol_env: origem de teste e Langfuse inválido" has_line "oute-test oute-agent https://langfuse.invalid"
check "otelcol_env: S3 em 127.0.0.1, nunca o do ambiente" has '^s3=[a-z]*://127\.0\.0\.1:[0-9][0-9]*$'
run 'HTTP=1 GRPC=2 HC=3; otelcol_test_yaml'
check "otelcol_test_yaml: health check, fila e receiver locais" bash -c 'grep -qxF "  health_check: {endpoint: 127.0.0.1:3}" <<<"$1" &&
  grep -qxF "  file_storage/queue: {directory: $2/queue}" <<<"$1" && grep -qF "http: {endpoint: 127.0.0.1:1}" <<<"$1"' _ "$OUT" "$TMP"
check "otelcol_test_yaml: sem s3, nenhum exporter"     hasnt '^exporters:'
run 'HTTP=1 GRPC=2 HC=3; otelcol_test_yaml s3'
check "otelcol_test_yaml s3: os três exporters do bucket com flush de 5 s" test "$(grep -c '^  awss3/.*flush_timeout: 5s' <<<"$OUT")" = 3
check "otelcol_test_yaml s3: exporters por último (o teste acrescenta os dele)" bash -c '[[ "$(tail -4 <<<"$1" | head -1)" == "exporters:" ]]' _ "$OUT"

# ---------------------------------------------------------------- 4. S3 falso e collector que não sobem
# python3 que cai na hora, só para o S3 falso (pasta própria: o $BIN tem o link para o python3 de verdade)
mkdir -p "$TMP/semS3"; printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/semS3/python3"; chmod +x "$TMP/semS3/python3"
run "PATH='$TMP/semS3':\$PATH; otelcol_s3_start '$TMP/s3' down; echo 'não chega aqui'"
check "S3 falso não sobe: sai com 1 e diz"             bash -c '[[ "$1" -eq 1 ]] && grep -qxF "FAIL S3 falso não subiu" <<<"$2" && ! grep -q "não chega" <<<"$2"' _ "$RC" "$OUT"
check "S3 falso: o modo fica gravado"                  test "$(cat "$TMP/s3/mode")" = down
: > "$TMP/collector.log"
run 'OTELCOL=false; HC="$(closed_port)"; otelcol_start --config=x; echo "rc=$? cpid=${CPID:+ok}"'
check "collector não sobe: devolve 1, com o CPID"      has_line "rc=1 cpid=ok"
check "collector não sobe: avisa"                      has_line "# collector não subiu"
printf 'linha do log\n' > "$TMP/collector.log"
run 'fail=1; otelcol_log'
check "otelcol_log: com falha, mostra o fim do log"    test "$OUT" = "# log do collector:"$'\n'"linha do log"
run 'fail=0; otelcol_log; echo "rc=$?"'
check "otelcol_log: sem falha, nada"                   test "$OUT" = "rc=0"

check_end
