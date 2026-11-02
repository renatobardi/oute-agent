#!/usr/bin/env bash
# Testes do oute-swarm, tema: o que acorda o dispatcher depois do reinício do container, o que não acorda e o alarme quando a
# entrega para (#893). Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh).
# Uso: tests/oute-swarm-entrega.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/otlp.sh"
guarda_start "$TMP/guarda"
rcv_stop   # sem receptor neste arquivo: porta fechada, nenhum evento alcança o coletor
. "$ROOT/tests/lib/swarm.sh"

unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID

# rel_religar: roda o religar do caso; $OUT = saída
rel_religar() {
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" STATE="$STATE" FAKE_WATCH=1 \
         OUTE_INBOX="$TMP/$CASE/inbox" OUTE_OUTBOX="$TMP/$CASE/outbox" "$SWARM" religar 2>"$FAKE/err")"; RC=$?
  return 0
}
# fim_do_watch: espera o watch em segundo plano do religar fechar a rodada
fim_do_watch() {
  local _i
  for _i in $(seq 1 100); do
    if grep -qF 'watch encerrado' "$STATE/log" 2>/dev/null; then return 0; fi
    /bin/sleep 0.1
  done
  return 1
}
# clock <epoch> e hook <n> <epoch> [<comando>]: relógio dos testes e gancho da passada <n>
clock() { local epoch="$1"; echo "$epoch" > "$FAKE/clock"; return 0; }
hook() {
  local n="$1" epoch="$2" extra="${3:-:}"
  printf 'echo %s > "$FAKE/clock"\n%s\n' "$epoch" "$extra" > "$FAKE/on-sleep-$n"
  return 0
}
pend_events() { log_events | grep -F '[pendencia]' || true; return 0; }
T0=1800000000
TABS_IDLE='fake-tabs idle'   # gancho: a aba do worker fica ociosa

# ---------------------------------------------------------------- 1. o religar do boot volta entregando
# rodada com dispatcher: o watch religado digita no campo dele
CASE=religar-entrega; dround "$CASE"
echo "$TABS_IDLE" > "$FAKE/on-sleep-1"
rel_religar
check "religar: anuncia a rodada"                         [ "$OUT" == "watch religado: swarm-test" ]
check "religar: o watch da rodada termina"                fim_do_watch
check "religar: o evento chega ao dispatcher"             [ "$(texts)" -eq 1 -a "$(enters)" -eq 1 ]
check "religar: entrega ok no log"                        grep -qF 'watch entrega ok: 1 evento(s)' <<<"$(dlog)"

# rodada sem dispatcher_pane (aberta antes da #761): o watch sobe mesmo assim, sem entrega, e a saída diz isso
CASE=religar-sempane; round "$CASE"
rel_religar
check "religar sem pane: diz que sobe sem entrega"        [ "$OUT" == "watch religado, sem entrega (rodada sem dispatcher_pane): swarm-test" ]
check "religar sem pane: o watch roda e termina"          fim_do_watch

# watch vivo sem --deliver (o religado pela versão anterior): é trocado por um que entrega, sem reiniciar o container
CASE=religar-troca; dround "$CASE"
bash -c 'exec -a "oute-swarm watch --round swarm-test " sleep 60' </dev/null >/dev/null 2>&1 & LIVE=$!
echo "$LIVE" > "$STATE/watch.pid"
rel_religar
check "religar: watch vivo sem entrega é trocado"         [ "$OUT" == "watch religado: swarm-test" ]
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null || true
check "religar: o watch novo termina"                     fim_do_watch

# watch vivo com --deliver fica
CASE=religar-vivo; dround "$CASE"
bash -c 'exec -a "oute-swarm watch --round swarm-test --deliver " sleep 60' </dev/null >/dev/null 2>&1 & LIVE=$!
echo "$LIVE" > "$STATE/watch.pid"
rel_religar
check "religar: watch com entrega não é trocado"          [ "$OUT" == "watch já ativo, sem religar: swarm-test" ]
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null || true

# ---------------------------------------------------------------- 2. o que não acorda o dispatcher (só no log)
# sessão que volta a trabalhar não acorda; a que para acorda
CASE=fila-working; dround "$CASE"; ag working
echo "$TABS_IDLE" > "$FAKE/on-sleep-1"; echo 'fake-tabs working' > "$FAKE/on-sleep-2"
wd
check "working: fica no log"                              grep -qF '[sessao] #7 foo: working (voltou a trabalhar)' "$STATE/log"
check "working: não entra na fila"                        [ "$(grep -c 'voltou a trabalhar' "$STATE/watch.queue")" -eq 0 ]
check "parada: entra na fila"                             [ "$(grep -c '\[sessao\] #7 foo: idle' "$STATE/watch.queue")" -eq 1 ]

# canal: pedido e resultado alheios e pedido já sem arquivo ficam só no log; os da rodada acordam
CASE=fila-canal; dround "$CASE"; ag working
cat > "$FAKE/on-sleep-1" <<'SH'
pedido() {
  local id="$1" extra="$2"
  printf '# oute-propose\n# titulo: t %s\n# como: user\n# agente: claude\n%s\necho x\n' "$id" "$extra" > "$OUTE_OUTBOX/$id.sh"
  return 0
}
pedido a-alheio '# sessao: 9-outra'
pedido b-nosso '# sessao: 7-foo'
pedido c-antigo ''
: > "$OUTE_OUTBOX/d-vazio.sh"
res() {
  local id="$1" rc="$2" extra="$3"
  printf '# id: %s\n# rc: %s\n\nok\n' "$id" "$rc" > "$OUTE_INBOX/$id.out"
  mkdir -p "$OUTE_OUTBOX/done"
  printf '# oute-propose\n%s\n' "$extra" > "$OUTE_OUTBOX/done/$id.sh"
  return 0
}
res e-erro-alheio 1 '# sessao: 9-outra'
res f-erro-nosso 1 '# sessao: 7-foo'
SH
wd
check "canal alheio: fica no log"                         grep -qF 'pedido pendente a-alheio' "$STATE/log"
check "canal alheio: não entra na fila"                   [ "$(grep -c 'a-alheio' "$STATE/watch.queue")" -eq 0 ]
check "canal sem título: fica no log"                     grep -qF 'pedido pendente d-vazio' "$STATE/log"
check "canal sem título: não entra na fila"               [ "$(grep -c 'd-vazio' "$STATE/watch.queue")" -eq 0 ]
check "canal da rodada: entra na fila"                    [ "$(grep -c 'b-nosso' "$STATE/watch.queue")" -eq 1 ]
check "canal sem o campo: entra na fila (título decide)"  [ "$(grep -c 'c-antigo' "$STATE/watch.queue")" -eq 1 ]
check "resultado alheio com erro: fica no log"            grep -qF 'resultado e-erro-alheio: rc=1' "$STATE/log"
check "resultado alheio com erro: não entra na fila"      [ "$(grep -c 'e-erro-alheio' "$STATE/watch.queue")" -eq 0 ]
check "resultado da rodada com erro: entra na fila"       [ "$(grep -c 'f-erro-nosso' "$STATE/watch.queue")" -eq 1 ]

# ---------------------------------------------------------------- 3. pendência: sessão parada em qualquer estado
for st in idle blocked; do
  CASE="pend-$st"; round "$CASE"
  clock "$T0"
  hook 1 $((T0 + 100)) "fake-tabs $st"; hook 2 $((T0 + 2000))
  echo : > "$FAKE/on-sleep-3"
  OUTE_WATCH_CLOCK="$FAKE/clock" watch
  check "sessão $st sem PR, parada, sai na pendência"     [ "$(pend_events)" == "[pendencia] 1 parada(s) há 31 min ou mais, sem mudança: #7 foo: $st sem PR" ]
done

# ---------------------------------------------------------------- 4. entrega parada: alarme sem modelo
# fila parada por 1 h: uma linha [aviso], só no log; quando sai, a volta também vai ao log
CASE=alarme; dround "$CASE"; ag working
clock "$T0"
hook 1 $((T0 + 60)) "$TABS_IDLE"; hook 2 $((T0 + 3000)); hook 3 $((T0 + 3700)); hook 4 $((T0 + 3800)); hook 5 $((T0 + 3900)) 'jq ".result.agents[0].agent_status=\"idle\"" "$FAKE/agents.json" > "$FAKE/a" && mv "$FAKE/a" "$FAKE/agents.json"'
echo : > "$FAKE/on-sleep-6"
OUTE_WATCH_CLOCK="$FAKE/clock" wd
check "alarme: uma linha só, com o motivo"                [ "$(grep -cF 'watch [aviso] entrega ao dispatcher parada há 60 min: dispatcher ocupado (working)' "$STATE/log")" -eq 1 ]
check "alarme: não entra na fila"                         [ "$(grep -c 'entrega ao dispatcher' "$STATE/watch.queue")" -eq 0 ]
check "alarme: a volta vai ao log"                        [ "$(grep -cF 'watch [aviso] entrega ao dispatcher de volta' "$STATE/log")" -eq 1 ]

# antes de 1 h, nada
CASE=alarme-cedo; dround "$CASE"; ag working
clock "$T0"
hook 1 $((T0 + 60)) "$TABS_IDLE"; hook 2 $((T0 + 3000))
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_CLOCK="$FAKE/clock" wd
check "alarme: antes de 1 h, nada"                        [ "$(grep -c 'entrega ao dispatcher' "$STATE/log")" -eq 0 ]

# ---------------------------------------------------------------- 5. tell não entregue (#884): evento até ser entregue
CASE=tell-recusado; round "$CASE"
clock "$T0"
cat > "$FAKE/on-sleep-1" <<SH
echo $((T0 + 60)) > "\$FAKE/clock"
printf '%s tell 7-foo recusado: o campo de entrada de #7 foo tem texto (o Bardi digitando?)\tmsg\n' "\$(date -u +%FT%TZ)" >> "\$STATE/log"
SH
hook 2 $((T0 + 120)); hook 3 $((T0 + 2000)) "$TABS_IDLE"; hook 4 $((T0 + 2100))
echo : > "$FAKE/on-sleep-5"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "tell recusado: um evento"                          [ "$(log_events | grep -cF '[tell] #7 foo: instrução não entregue')" -eq 1 ]
check "tell recusado: entra na pendência"                 grep -qF '#7 foo: tell não entregue' <<<"$(pend_events)"

# outro `tell` entregue limpa a pendência; recusa por sessão ocupada não gera o evento (o [sessao] avisa)
CASE=tell-entregue; round "$CASE"
clock "$T0"
cat > "$FAKE/on-sleep-1" <<SH
echo $((T0 + 60)) > "\$FAKE/clock"
printf '%s tell 7-foo recusado: o campo de entrada de #7 foo tem texto (o Bardi digitando?)\tmsg\n' "\$(date -u +%FT%TZ)" >> "\$STATE/log"
printf '%s tell 7-foo ok\tmsg\n' "\$(date -u +%FT%TZ)" >> "\$STATE/log"
printf '%s tell 7-foo recusado: sessão #7 foo ocupada (working); tente depois\tmsg\n' "\$(date -u +%FT%TZ)" >> "\$STATE/log"
SH
hook 2 $((T0 + 3000))
echo : > "$FAKE/on-sleep-3"
OUTE_WATCH_CLOCK="$FAKE/clock" watch
check "tell entregue: sem evento nem pendência"           [ "$(log_events | grep -c 'não entregue')" -eq 0 ]

guarda_check
guarda_stop
check_end
