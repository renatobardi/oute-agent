#!/usr/bin/env bash
# Testes dos eventos operacionais do canal e do backfill (#124). Bash puro + python3/jq, sem Docker nem rede.
# Costura 1: receptor OTLP/HTTP falso (tests/lib/otlp-receiver.py) no OTEL_EXPORTER_OTLP_ENDPOINT.
# Costura 2: `docker` falso no PATH para o `oute approve` (repassa o exec ao oute-emit local; "imagem antiga" =
# comando não encontrado). A rodada do swarm fica em tests/oute-swarm.test.sh. Só comportamento externo:
# stdout, código de saída e o que chega ao receptor. Uso: tests/oute-emit.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"
trap 'rcv_stop; rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FAIL precisa de jq e python3"; exit 1; }

BIN="$TMP/bin"; mkdir -p "$BIN"
ln -s "$ROOT/docker/oute-emit" "$BIN/oute-emit"
export PATH="$BIN:$PATH" OTEL_RESOURCE_ATTRIBUTES="host.name=oute-mac,oute.instance=oute-agent,deployment.environment=oute-mac"
unset CLAUDECODE CODEX_THREAD_ID PI_CODING_AGENT OUTE_PROPOSE_AGENT OUTE_INBOX OUTE_OUTBOX OTEL_EXPORTER_OTLP_LOGS_ENDPOINT

posts() { ls "$RCV_DIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
# propose <home> <título> [args]: roda o oute-propose com o script de $SCRIPT; stdout em $OUT, código em $RC
propose() { local h="$1"; shift; OUT="$(HOME="$h" "$ROOT/docker/oute-propose" "$@" <<<"$SCRIPT" 2>/dev/null)"; RC=$?; }

# ---------------------------------------------------------------- 1. oute-propose → oute.canal.proposed
H="$TMP/prop"; mkdir -p "$H"; rcv_start "$TMP/r1"
SCRIPT=$'set -euo pipefail\necho "oi do agente"'
OUTE_PROPOSE_AGENT=codex propose "$H" "Ver disco" --root
id="$OUT"
check "propose: código 0 e só o id no stdout"          [ "$RC" -eq 0 -a -f "$H/outbox/$id.sh" ]
e="$(ev '.name == "oute.canal.proposed"')"
check "propose: um evento oute.canal.proposed"         [ "$(grep -c . <<<"$e")" -eq 1 ]
check "propose: id, título, como, tamanho"             jqe --arg id "$id" '.attrs["oute.canal.id"] == $id and .attrs["oute.canal.title"] == "Ver disco"
                                                         and .attrs["oute.canal.as"] == "root" and (.attrs["oute.canal.size"] | tonumber) == 38' <<<"$e"
check "propose: corpo = script"                        jqe '.body == "set -euo pipefail\necho \"oi do agente\"\n"' <<<"$e"
check "propose: oute.agent do OUTE_PROPOSE_AGENT"      jqe '.attrs["oute.agent"] == "codex" and .res["oute.agent"] == "codex"' <<<"$e"
check "propose: origem e service.name=oute"            jqe '.res["host.name"] == "oute-mac" and .res["oute.instance"] == "oute-agent" and .res["service.name"] == "oute"' <<<"$e"
check "propose: hora do registro = criado"             jqe --arg c "$(sed -n 's/^# criado: //p' "$H/outbox/$id.sh")" \
                                                         '(.time | tonumber / 1e9 | todate) == $c' <<<"$e"
sleep 1
CLAUDECODE=1 propose "$H" "pelo ambiente"
check "propose: agente pelo ambiente (claude)"         [ "$(n '.attrs["oute.canal.title"] == "pelo ambiente" and .attrs["oute.agent"] == "claude"')" -eq 1 ]
check "propose: cabeçalho com o agente do ambiente"    grep -qx '# agente: claude' "$H/outbox/$OUT.sh"
sleep 1
CODEX_THREAD_ID=t1 propose "$H" "pelo codex"
check "propose: agente pelo ambiente (codex)"          [ "$(n '.attrs["oute.canal.title"] == "pelo codex" and .attrs["oute.agent"] == "codex"')" -eq 1 ]
sleep 1
PI_CODING_AGENT=true propose "$H" "ambiente do pi"
check "propose: Pi fora do stack, sem agente (unknown)" [ "$(n '.attrs["oute.canal.title"] == "ambiente do pi" and .attrs["oute.agent"] == "unknown"')" -eq 1 ]
sleep 1
propose "$H" "sem agente"
check "propose: sem agente = unknown no evento"        [ "$(n '.attrs["oute.canal.title"] == "sem agente" and .attrs["oute.agent"] == "unknown"')" -eq 1 ]
check "propose: cabeçalho continua 'desconhecido'"     grep -qx '# agente: desconhecido' "$H/outbox/$OUT.sh"
rcv_stop

# ---------------------------------------------------------------- 2. coletor fora do ar ou lento
H="$TMP/down"; mkdir -p "$H"
SCRIPT='echo x'
t0=$(date +%s)
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(closed_port)" propose "$H" "fora do ar"
check "fora do ar: código 0, id no stdout, pedido criado" [ "$RC" -eq 0 -a -f "$H/outbox/$OUT.sh" -a "$(grep -c . <<<"$OUT")" -eq 1 ]
check "fora do ar: rápido"                             [ $(( $(date +%s) - t0 )) -le 3 ]
RCV_SLEEP=6 rcv_start "$TMP/r2"
sleep 1; t0=$(date +%s)
propose "$H" "lento"
check "lento: código 0, id no stdout"                  [ "$RC" -eq 0 -a -f "$H/outbox/$OUT.sh" -a "$(grep -c . <<<"$OUT")" -eq 1 ]
check "lento: não passa do timeout (~2 s)"             [ $(( $(date +%s) - t0 )) -le 4 ]
rcv_stop
OUT="$(HOME="$H" OTEL_EXPORTER_OTLP_ENDPOINT= oute-emit canal "$OUT" 2>&1)"; RC=$?
check "sem endpoint: rc 0, nada na tela"               [ "$RC" -eq 0 -a -z "$OUT" ]
OUT="$(HOME="$H" oute-emit canal ../../etc/passwd 2>&1; oute-emit nada 2>&1; oute-emit swarm x 2>&1)"; RC=$?
check "uso inválido: rc 0, nada na tela"               [ "$RC" -eq 0 -a -z "$OUT" ]

# ---------------------------------------------------------------- 3. oute approve → oute.canal.decided (docker falso)
if ! has_pty; then
  echo "skip approve: sem script(1) do util-linux (o read do approve lê do /dev/tty)"
else
CH="$TMP/ctr"; OH="$TMP/ohome"; mkdir -p "$CH/outbox" "$CH/inbox" "$OH"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
# docker falso: o "container" é HOME=$CTR_HOME nesta máquina; F_OLD=1 = imagem sem oute-emit
case "$1" in
  ps) echo abc123 ;;
  exec) shift; [[ "$1" == -i ]] && shift; shift
        if [[ "$1" == oute-emit && -n "${F_OLD:-}" ]]; then
          echo 'OCI runtime exec failed: exec failed: unable to start container process: exec: "oute-emit": executable file not found in $PATH: unknown' >&2
          exit 127
        fi
        HOME="$CTR_HOME" exec "$@" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/docker"
# pedido <id> <script>: pedido pendente no outbox do container
pedido() { printf '# oute-propose\n# titulo: %s\n# como: user\n# agente: codex\n# criado: 2026-09-27T10:00:00Z\n\n%s\n' "$1" "$2" > "$CH/outbox/$1.sh"; }
# approve <resposta>: oute approve com a resposta digitada no terminal (pty do script(1)); saída em $OUT
approve() {
  OUT="$(printf '%s\n' "$1" | env CTR_HOME="$CH" OUTE_HOME="$OH" OUTE_HOST=oute-mac \
         script -qec "$ROOT/scripts/oute approve" /dev/null 2>&1)"; RC=$?
}
rcv_start "$TMP/r3"
pedido 20260927-100000-exec 'echo "SEGREDO-DO-HOST-123"; exit 3'
approve s
e="$(ev '.name == "oute.canal.decided" and .attrs["oute.canal.id"] == "20260927-100000-exec"')"
check "approve s: código 0"                            [ "$RC" -eq 0 ]
check "approve s: .out com duração e tamanho"          grep -qE '^# duracao: [0-9]+ s$' "$CH/inbox/20260927-100000-exec.out"
check "approve s: um evento decided"                   [ "$(grep -c . <<<"$e")" -eq 1 ]
check "approve s: executado, rc, tamanho, aprovador"   jqe '.attrs["oute.canal.decision"] == "executado" and (.attrs["oute.canal.rc"] | tonumber) == 3
                                                         and (.attrs["oute.canal.output_bytes"] | tonumber) == 20 and (.attrs["oute.canal.duration_s"] | tonumber) >= 0
                                                         and (.attrs["oute.canal.approver"] | endswith("@oute-mac")) and (.attrs["oute.canal.sha256"] | length) == 12' <<<"$e"
check "approve s: oute.agent=human"                    jqe '.attrs["oute.agent"] == "human" and .res["oute.agent"] == "human"' <<<"$e"
check "approve s: sem corpo"                           jqe '.body == null' <<<"$e"
check "approve s: saída do host em nenhum POST"        [ -z "$(grep -l 'SEGREDO-DO-HOST' "$RCV_DIR"/*.json)" ]
pedido 20260927-100100-recusa 'echo nunca'
approve r
e="$(ev '.name == "oute.canal.decided" and .attrs["oute.canal.id"] == "20260927-100100-recusa"')"
check "approve r: evento recusado, rc 126, sem corpo"  jqe '.attrs["oute.canal.decision"] == "recusado" and (.attrs["oute.canal.rc"] | tonumber) == 126
                                                         and .attrs["oute.agent"] == "human" and .body == null' <<<"$e"
before="$(posts)"
pedido 20260927-100200-depois 'echo depois'
approve ''
check "approve N: fica pendente"                       grep -q 'fica pendente' <<<"$OUT"
check "approve N: nenhum evento"                       [ "$(posts)" -eq "$before" ]
F_OLD=1 approve s
check "imagem antiga: código 0"                        [ "$RC" -eq 0 ]
check "imagem antiga: resultado gravado"               [ -f "$CH/inbox/20260927-100200-depois.out" ]
check "imagem antiga: nada sujo na tela"               [ -z "$(grep -iE 'not found|OCI runtime|oute-emit' <<<"$OUT")" ]
check "imagem antiga: nenhum evento"                   [ "$(posts)" -eq "$before" ]
pedido 20260927-100300-fora 'echo fora'
t0=$(date +%s)
OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(closed_port)" approve s
check "coletor fora do ar: approve segue, código 0"    [ "$RC" -eq 0 -a -f "$CH/inbox/20260927-100300-fora.out" ]
check "coletor fora do ar: nada sujo na tela"          [ -z "$(grep -iE 'oute-emit|Traceback|refused' <<<"$OUT")" ]
rcv_stop
fi

# ---------------------------------------------------------------- 4. backfill
BH="$TMP/bf"; R="$BH/.oute/swarm/swarm-0926-1012"; mkdir -p "$R" "$BH/outbox/done" "$BH/outbox/rejected" "$BH/inbox" "$BH/.oute/emit"
echo 2026-09-27T12:00:00Z > "$BH/.oute/emit/since"
printf 'repo=/workspace/lab\nmax=2\nlabel=bug\nstarted=2026-09-26T13:12:00Z\n' > "$R/meta"
printf '7-foo w1:p1 codex 2026-09-26T13:20:00Z w1:t1\n8-bar w1:p2 claude 2026-09-26T13:21:00Z w1:t2 /workspace/oute-agent kaizen\n' > "$R/spawned"
printf 'prompt do 7\n' > "$R/7-foo.prompt"
cat > "$R/log" <<'L'
2026-09-26T13:30:00Z tell 7-foo ok
2026-09-26T13:31:00Z tell 7-foo recusado: sessão #7 foo ocupada (working); tente depois
2026-09-26T13:32:00Z tell 8-bar ok (--force, working)
2026-09-26T13:33:00Z tell-manual 7-foo (rebase, autorizado)
2026-09-26T13:40:00Z watch [pr] PR #12 aberto (issue #7) https://x/pull/12
2026-09-26T13:41:00Z watch [ci] PR #12 · test: fail
linha estranha sem hora
2026-09-27T13:00:00Z watch [sessao] #7 foo: idle (depois do corte)
L
printf '7-foo\n8-bar\n' > "$R/closed"
echo 2026-09-26T15:00:00Z > "$R/fechada"
printf '# oute-propose\n# titulo: antigo\n# como: root\n# agente: desconhecido\n# criado: 2026-09-26T01:50:53Z\n\necho velho\n' > "$BH/outbox/done/20260926-015053-antigo.sh"
printf '# id: 20260926-015053-antigo\n# rc: 0\n# como: root\n# aprovado: 2026-09-26T01:51:34Z por ubuntu@oute-server\n# sha256: 409eccc983f8\n\nSEGREDO-DA-SAIDA\n# rc: 99\n' > "$BH/inbox/20260926-015053-antigo.out"
printf '# oute-propose\n# titulo: recusado\n# como: user\n# agente: claude\n# criado: 2026-09-27T02:26:00Z\n\necho nao\n' > "$BH/outbox/rejected/20260927-022600-rec.sh"
printf '# id: 20260927-022600-rec\n# rc: 126\n# recusado: 2026-09-27T02:26:23Z por ubuntu@oute-server\n# sha256: aaaaaaaaaaaa\n\nrecusado pelo usuário; nada foi executado.\n' > "$BH/inbox/20260927-022600-rec.out"
printf '# oute-propose\n# titulo: pendente\n# como: user\n# agente: codex\n# criado: 2026-09-27T11:00:00Z\n\necho p\n' > "$BH/outbox/20260927-110000-pend.sh"
printf '# oute-propose\n# titulo: novo\n# como: user\n# agente: codex\n# criado: 2026-09-27T12:30:00Z\n\necho n\n' > "$BH/outbox/20260927-123000-novo.sh"

OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$(closed_port)" HOME="$BH" oute-emit backfill >"$TMP/bf.out" 2>"$TMP/bf.err"; RC=$?
check "backfill fora do ar: rc 0, sem stdout"          [ "$RC" -eq 0 -a ! -s "$TMP/bf.out" ]
check "backfill fora do ar: avisa e não marca feito"   [ ! -e "$BH/.oute/emit/backfill.done" ] && grep -q 'rode de novo' "$TMP/bf.err"
rcv_start "$TMP/r4"
HOME="$BH" oute-emit backfill >"$TMP/bf.out" 2>"$TMP/bf.err"; RC=$?
check "backfill: rc 0, sem stdout"                     [ "$RC" -eq 0 -a ! -s "$TMP/bf.out" ]
check "backfill: resumo com emitidos e pulados"        grep -q '14 de 14 evento(s) emitido(s) (1 rodada(s)); pulados: 2 linha(s) não reconhecida(s), 2 close(s) sem hora' "$TMP/bf.err"
check "backfill: todos com oute.backfill=true"         [ "$(n '.attrs["oute.backfill"] == true')" -eq 14 -a "$(n 'true')" -eq 14 ]
check "backfill: rodada aberta na hora original"       [ "$(n '.name == "oute.swarm.round.opened" and (.time | tonumber / 1e9 | todate) == "2026-09-26T13:12:00Z"
                                                              and .attrs["oute.swarm.repo"] == "lab" and (.attrs["oute.swarm.max"] | tonumber) == 2 and .attrs["oute.swarm.label"] == "bug"
                                                              and .attrs["oute.agent"] == "claude"')" -eq 1 ]
check "backfill: spawn com agente, repo, kaizen e prompt" [ "$(n '.name == "oute.swarm.session.spawned" and .attrs["oute.swarm.session"] == "7-foo" and .attrs["oute.swarm.session.agent"] == "codex"
                                                              and (.attrs["oute.swarm.issue"] | tonumber) == 7 and .attrs["oute.swarm.repo"] == "lab" and .attrs["oute.swarm.kaizen"] == false
                                                              and .body == "prompt do 7\n"')" -eq 1 -a \
                                                          "$(n '.name == "oute.swarm.session.spawned" and .attrs["oute.swarm.session"] == "8-bar" and .attrs["oute.swarm.kaizen"] == true
                                                              and .attrs["oute.swarm.repo"] == "oute-agent" and .body == null')" -eq 1 ]
check "backfill: tell ok/recusado/forçado, sem corpo"  [ "$(n '.name == "oute.swarm.tell" and .body == null')" -eq 3 -a \
                                                          "$(n '.name == "oute.swarm.tell" and .attrs["oute.swarm.tell.result"] == "recusado" and (.attrs["oute.swarm.tell.reason"] | startswith("sessão #7 foo ocupada"))')" -eq 1 -a \
                                                          "$(n '.name == "oute.swarm.tell" and .attrs["oute.swarm.tell.forced"] == true and .attrs["oute.swarm.session"] == "8-bar"')" -eq 1 ]
check "backfill: watch como observação"                [ "$(n '.name == "oute.swarm.watch.pr" and .attrs["oute.swarm.source"] == "watch" and .body == "[pr] PR #12 aberto (issue #7) https://x/pull/12"')" -eq 1 -a \
                                                          "$(n '.name == "oute.swarm.watch.ci"')" -eq 1 ]
check "backfill: rodada fechada"                       [ "$(n '.name == "oute.swarm.round.closed" and (.time | tonumber / 1e9 | todate) == "2026-09-26T15:00:00Z"')" -eq 1 ]
check "backfill: close antigo sem hora não sai"        [ "$(n '.name == "oute.swarm.session.closed"')" -eq 0 ]
check "backfill: depois do corte não sai"              [ "$(n '.name == "oute.swarm.watch.sessao"')" -eq 0 -a "$(n '.attrs["oute.canal.id"] == "20260927-123000-novo"')" -eq 0 ]
check "backfill: pedido proposto (done, rejected, pendente)" [ "$(n '.name == "oute.canal.proposed"')" -eq 3 -a \
                                                          "$(n '.name == "oute.canal.proposed" and .attrs["oute.canal.id"] == "20260926-015053-antigo" and .attrs["oute.agent"] == "unknown" and .body == "echo velho\n"')" -eq 1 ]
check "backfill: decididos, human, sem corpo"          [ "$(n '.name == "oute.canal.decided" and .attrs["oute.agent"] == "human" and .body == null')" -eq 2 -a \
                                                          "$(n '.name == "oute.canal.decided" and .attrs["oute.canal.decision"] == "executado" and (.attrs["oute.canal.rc"] | tonumber) == 0
                                                              and .attrs["oute.canal.approver"] == "ubuntu@oute-server" and (.time | tonumber / 1e9 | todate) == "2026-09-26T01:51:34Z"')" -eq 1 ]
check "backfill: saída dos .out em nenhum POST"        [ -z "$(grep -l 'SEGREDO-DA-SAIDA' "$RCV_DIR"/*.json)" ]
before="$(posts)"
HOME="$BH" oute-emit backfill >"$TMP/bf.out" 2>"$TMP/bf.err"; RC=$?
check "backfill de novo: rc 0, zero POSTs"             [ "$RC" -eq 0 -a "$(posts)" -eq "$before" ]
check "backfill de novo: avisa que já foi feito"       grep -q 'já feito' "$TMP/bf.err"
rcv_stop

# ---------------------------------------------------------------- 5. oute.event.id fixo por fato (#165)
# o mesmo fato leva o mesmo id ao vivo, numa repetição e no backfill; fatos distintos (inclusive linhas iguais no
# mesmo segundo) levam ids diferentes. Ao vivo: cada linha entra no log antes do oute-emit, como no slog do oute-swarm
IH="$TMP/eid"; RND=swarm-0928-0900; IR="$IH/.oute/swarm/$RND"; mkdir -p "$IR" "$IH/outbox" "$IH/inbox" "$IH/.oute/emit"
echo 2099-01-01T00:00:00Z > "$IH/.oute/emit/since"
printf 'repo=/workspace/lab\nmax=2\nagent=claude\nstarted=2026-09-28T09:00:00Z\n' > "$IR/meta"
printf '7-foo w1:p1 codex 2026-09-28T09:01:00Z w1:t1 /workspace/lab\n' > "$IR/spawned"
T=$'\t'
LINES=("2026-09-28T09:00:00Z abertura $RND (repo lab, max 2)" "2026-09-28T09:01:00Z spawn 7-foo codex"
       "2026-09-28T09:02:00Z tell 7-foo ok${T}rebase" "2026-09-28T09:02:00Z tell 7-foo ok${T}rebase"
       "2026-09-28T09:02:00Z tell 7-foo ok${T}outra" "2026-09-28T09:03:00Z watch [ci] PR #12 · test: fail"
       "2026-09-28T09:03:00Z watch [ci] PR #12 · test: fail" "2026-09-28T09:04:00Z close 7-foo" "2026-09-28T09:05:00Z rodada fechada")
# ids <dir> <jq-select>: "<nome> <id>" dos registros, ordenado
ids() { events "$1" | jq -r "select($2) | \"\(.name) \(.attrs[\"oute.event.id\"])\"" | sort; }
rcv_start "$TMP/r5"
for ln in "${LINES[@]}"; do printf '%s\n' "$ln" >> "$IR/log"; HOME="$IH" oute-emit swarm "$RND" "$ln"; done
pedido5() { printf '# oute-propose\n# titulo: %s\n# como: user\n# agente: codex\n# criado: %s\n\necho %s\n' "$2" "$3" "$2" > "$IH/outbox/$1.sh"; }
pedido5 20260928-090000-um um 2026-09-28T09:00:00Z
pedido5 20260928-090000-dois dois 2026-09-28T09:00:00Z
HOME="$IH" oute-emit canal 20260928-090000-um; HOME="$IH" oute-emit canal 20260928-090000-dois
mkdir -p "$IH/outbox/done" "$IH/outbox/rejected"
mv "$IH/outbox/20260928-090000-um.sh" "$IH/outbox/done/"; mv "$IH/outbox/20260928-090000-dois.sh" "$IH/outbox/rejected/"
printf '# id: 20260928-090000-um\n# rc: 0\n# aprovado: 2026-09-28T09:10:00Z por ubuntu@oute-server\n\nsaida\n' > "$IH/inbox/20260928-090000-um.out"
printf '# id: 20260928-090000-dois\n# rc: 126\n# recusado: 2026-09-28T09:10:00Z por ubuntu@oute-server\n\nrecusado\n' > "$IH/inbox/20260928-090000-dois.out"
HOME="$IH" oute-emit canal 20260928-090000-um; HOME="$IH" oute-emit canal 20260928-090000-dois
live="$(ids "$RCV_DIR" true)"
check "event.id: todo evento ao vivo leva o id (32 hex)" [ "$(events "$RCV_DIR" | jq -r '.attrs["oute.event.id"] // "x"' | grep -cvE '^[0-9a-f]{32}$')" -eq 0 -a "$(grep -c . <<<"$live")" -eq 13 ]
check "event.id: fatos distintos, ids distintos (13)"   [ "$(cut -d' ' -f2 <<<"$live" | sort -u | grep -c .)" -eq 13 ]
check "event.id: dois tell iguais no mesmo segundo"     [ "$(ids "$RCV_DIR" '.name == "oute.swarm.tell"' | cut -d' ' -f2 | sort -u | grep -c .)" -eq 3 ]
check "event.id: dois watch iguais no mesmo segundo"    [ "$(ids "$RCV_DIR" '.name == "oute.swarm.watch.ci"' | cut -d' ' -f2 | sort -u | grep -c .)" -eq 2 ]
check "event.id: dois pedidos no mesmo segundo, proposto × decidido" [ "$(ids "$RCV_DIR" '.attrs["oute.canal.id"] != null' | cut -d' ' -f2 | sort -u | grep -c .)" -eq 4 ]
rcv_stop
# repetição (timeout, restart): a mesma linha e o mesmo pedido de novo, noutro segundo
rcv_start "$TMP/r5b"; sleep 1
HOME="$IH" oute-emit swarm "$RND" "${LINES[4]}"; HOME="$IH" oute-emit swarm "$RND" "${LINES[3]}"; HOME="$IH" oute-emit canal 20260928-090000-dois
again="$(ids "$RCV_DIR" true)"
check "event.id: repetição de tell = mesmo id (sem hora de envio)" [ -n "$(grep -Fx "$(ids "$RCV_DIR" '.body == "outra"')" <<<"$live")" ]
check "event.id: repetição da última linha igual = id da última ocorrência" [ -n "$(grep -Fx "$(ids "$RCV_DIR" '.body == "rebase"')" <<<"$live")" ]
check "event.id: repetição de decidido = mesmo id"      [ -n "$(grep -Fx "$(ids "$RCV_DIR" '.name == "oute.canal.decided"')" <<<"$live")" ]
rcv_stop
# backfill do mesmo HOME (corte no futuro: tudo é anterior) = os mesmos ids do ao vivo
rcv_start "$TMP/r5c"
HOME="$IH" oute-emit backfill 2>/dev/null
check "event.id: backfill = ao vivo (swarm e canal)"    [ "$(ids "$RCV_DIR" true)" == "$live" ]
rcv_stop
# rodada antiga (meta/spawned/fechada sem linha no log): a linha reescrita pelo backfill leva o id da linha ao vivo
OH2="$TMP/eid-old"; OR="$OH2/.oute/swarm/$RND"; mkdir -p "$OR" "$OH2/.oute/emit"
echo 2099-01-01T00:00:00Z > "$OH2/.oute/emit/since"; cp "$IR/meta" "$IR/spawned" "$OR/"
echo 2026-09-28T09:05:00Z > "$OR/fechada"
rcv_start "$TMP/r5d"
HOME="$OH2" oute-emit backfill 2>/dev/null
check "event.id: rodada antiga reescrita = ids do ao vivo" [ "$(ids "$RCV_DIR" true)" == "$(grep -E '^oute\.swarm\.(round\.opened|session\.spawned|round\.closed) ' <<<"$live")" ]
rcv_stop

# ---------------------------------------------------------------- 6. spool (#166)
# coletor fora → o evento vai para ~/.oute/emit/spool/ (rc 0, sem stdout) → volta → a próxima chamada reenvia o
# gravado como está (id e hora do fato originais, nunca recalculados) antes do evento novo
SH="$TMP/spool"; RND=swarm-0928-1000; SR="$SH/.oute/swarm/$RND"; SP="$SH/.oute/emit/spool"; mkdir -p "$SR" "$SH/outbox"
printf 'repo=/workspace/lab\nmax=2\nagent=codex\nstarted=2026-09-28T10:00:00Z\n' > "$SR/meta"
DOWN="http://127.0.0.1:$(closed_port)"
nspool() { ls "$SP"/*.json 2>/dev/null | wc -l | tr -d ' '; }
# spooled <jq-select>: registros gravados no spool que casam o filtro (mesmo formato do events)
spooled() { events "$SP" | jq -c "select($1)"; }
ms() { date +%s%3N; }
TELL="2026-09-28T10:02:00Z tell 7-foo ok${T}mesma"
printf '%s\n' "$TELL" >> "$SR/log"
OUT="$(HOME="$SH" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit swarm "$RND" "$TELL" 2>&1)"; RC=$?
check "spool: coletor fora, rc 0 e nada na tela"        [ "$RC" -eq 0 -a -z "$OUT" ]
check "spool: um arquivo, sem temporário"               [ "$(nspool)" -eq 1 -a -z "$(ls -A "$SP" | grep -v '\.json$' | grep -v '^\.lock$')" ]
id1="$(spooled true | jq -r '.attrs["oute.event.id"]')"
check "spool: gravado com id, hora do fato e origem"    jqe '.attrs["oute.event.id"] != null and (.time | tonumber / 1e9 | todate) == "2026-09-28T10:02:00Z"
                                                         and .res["host.name"] == "oute-mac" and .res["oute.agent"] == "codex" and .body == "mesma"' <<<"$(spooled true)"
printf '%s\n' "$TELL" >> "$SR/log"   # a mesma linha de novo, no mesmo segundo: outro fato
printf '# oute-propose\n# titulo: t\n# como: user\n# agente: codex\n# criado: 2026-09-28T10:03:00Z\n\necho t\n' > "$SH/outbox/20260928-100300-t.sh"
HOME="$SH" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal 20260928-100300-t
check "spool: segunda falha, segundo arquivo"           [ "$(nspool)" -eq 2 ]
rcv_start "$TMP/r6"
OUT="$(HOME="$SH" oute-emit swarm "$RND" "$TELL" 2>&1)"; RC=$?
check "spool: coletor volta, rc 0, nada na tela"        [ "$RC" -eq 0 -a -z "$OUT" ]
check "spool: tudo chega e o spool esvazia"             [ "$(n true)" -eq 3 -a "$(nspool)" -eq 0 ]
check "spool: reenvio antes do evento novo (ordem)"     [ "$(events "$RCV_DIR" | jq -r '.attrs["oute.event.id"]' | head -1)" == "$id1" ]
check "spool: os dois tell iguais, ids distintos"       [ "$(ids "$RCV_DIR" '.name == "oute.swarm.tell"' | cut -d' ' -f2 | sort -u | grep -c .)" -eq 2 ]
check "spool: reenviado com o id gravado (nunca recalculado)" [ "$(n ".attrs[\"oute.event.id\"] == \"$id1\" and .body == \"mesma\"")" -eq 1 ]
check "spool: reenviado com hora do fato e agente originais" [ "$(n '.name == "oute.canal.proposed" and (.time | tonumber / 1e9 | todate) == "2026-09-28T10:03:00Z" and .attrs["oute.agent"] == "codex"')" -eq 1 ]
check "spool: todo evento leva spool.bytes e spool.dropped" [ "$(n '.attrs["oute.emit.spool.bytes"] != null and .attrs["oute.emit.spool.dropped"] != null')" -eq 3 ]
check "spool: evento novo com spool vazio (bytes 0)"    [ "$(n '.attrs["oute.event.id"] != "'"$id1"'" and .name == "oute.swarm.tell" and (.attrs["oute.emit.spool.bytes"] | tonumber) == 0')" -eq 1 ]
check "spool: guardado leva o spool de quando falhou"   [ "$(n '.name == "oute.canal.proposed" and (.attrs["oute.emit.spool.bytes"] | tonumber) > 0')" -eq 1 ]
rcv_stop

# spool cheio: descarta o evento novo, conta em spool.dropped, avisa em stderr só com OUTE_EMIT_DEBUG=1
FH="$TMP/full"; mkdir -p "$FH/outbox"
printf '# oute-propose\n# titulo: f\n# como: user\n# agente: codex\n# criado: 2026-09-28T11:00:00Z\n\necho f\n' > "$FH/outbox/20260928-110000-f.sh"
OUT="$(HOME="$FH" OUTE_EMIT_SPOOL_MAX=100 OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal 20260928-110000-f 2>&1)"; RC=$?
check "cheio: rc 0, nada na tela, nada gravado"         [ "$RC" -eq 0 -a -z "$OUT" -a -z "$(ls "$FH/.oute/emit/spool/" 2>/dev/null)" ]
check "cheio: dropped = 1"                              [ "$(cat "$FH/.oute/emit/spool.dropped")" -eq 1 ]
ERR="$(HOME="$FH" OUTE_EMIT_DEBUG=1 OUTE_EMIT_SPOOL_MAX=100 OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal 20260928-110000-f 2>&1 >/dev/null)"
check "cheio: dropped acumula; aviso com OUTE_EMIT_DEBUG=1" [ "$(cat "$FH/.oute/emit/spool.dropped")" -eq 2 ] && grep -q 'spool cheio' <<<"$ERR"
rcv_start "$TMP/r6b"
HOME="$FH" oute-emit canal 20260928-110000-f
check "cheio: próximo evento leva dropped = 2"          [ "$(n '(.attrs["oute.emit.spool.dropped"] | tonumber) == 2')" -eq 1 ]
rcv_stop
# o limite conta o spool inteiro: com 50 MB (padrão) ocupados, o evento novo não entra
FH2="$TMP/full2"; mkdir -p "$FH2/outbox" "$FH2/.oute/emit/spool"; cp "$FH/outbox/"*.sh "$FH2/outbox/"
python3 -c 'import sys; open(sys.argv[1], "w").write("{\"resourceLogs\": [], \"pad\": \"" + "x" * 52428700 + "\"}")' "$FH2/.oute/emit/spool/00000000000000000001-1.json"
HOME="$FH2" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal 20260928-110000-f
check "cheio: 50 MB por padrão"                         [ "$(ls "$FH2/.oute/emit/spool/"*.json | wc -l)" -eq 1 -a "$(cat "$FH2/.oute/emit/spool.dropped")" -eq 1 ]

# teto de 2 s: spool com envios pendentes + coletor lento; o reenvio e o evento novo cabem nos mesmos 2 s
LH="$TMP/slow"; mkdir -p "$LH/outbox"; cp "$FH/outbox/"*.sh "$LH/outbox/"
for _ in 1 2 3; do HOME="$LH" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal 20260928-110000-f; done
RCV_SLEEP=6 rcv_start "$TMP/r6c"
t0=$(ms); OUT="$(HOME="$LH" oute-emit canal 20260928-110000-f 2>&1)"; RC=$?; dt=$(( $(ms) - t0 ))
check "teto: coletor lento, rc 0 e nada na tela"        [ "$RC" -eq 0 -a -z "$OUT" ]
check "teto: reenvio + evento novo nos 2 s ($dt ms)"   [ "$dt" -le 2800 ]
check "teto: nada se perde (spool com os 4)"            [ "$(ls "$LH/.oute/emit/spool/"*.json | wc -l)" -eq 4 ]
rcv_stop
t0=$(ms); HOME="$LH" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit flush; dt=$(( $(ms) - t0 ))
check "teto: coletor fora, spool cheio de envios, rápido ($dt ms)" [ "$dt" -le 2500 ]

# concorrência: a trava é não bloqueante; quem não pega pula o reenvio e manda só o seu
rcv_start "$TMP/r6d"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(5)' \
  "$LH/.oute/emit/spool/.lock" "$TMP/locked" & LPID=$!
for _ in $(seq 1 50); do [[ -e "$TMP/locked" ]] && break; sleep 0.1; done
t0=$(ms); HOME="$LH" oute-emit canal 20260928-110000-f; dt=$(( $(ms) - t0 ))
check "trava ocupada: não espera ($dt ms) e manda só o novo" [ "$dt" -le 2500 -a "$(n true)" -eq 1 -a "$(ls "$LH/.oute/emit/spool/"*.json | wc -l)" -eq 4 ]
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
rcv_stop
spool_ids="$(events "$LH/.oute/emit/spool" | jq -r '.attrs["oute.event.id"]' | sort)"
RCV_SLEEP=0.3 rcv_start "$TMP/r6e"
pids=(); for _ in 1 2 3 4; do HOME="$LH" oute-emit flush & pids+=($!); done; wait "${pids[@]}"
check "simultâneas: cada arquivo reenviado uma vez só"  [ "$(events "$RCV_DIR" | jq -r '.attrs["oute.event.id"]' | sort)" == "$spool_ids" -a "$(posts)" -eq 1 ]
check "simultâneas: spool vazio"                        [ -z "$(ls "$LH/.oute/emit/spool/"*.json 2>/dev/null)" ]
# arquivo ilegível no spool não trava a fila: sai para spool.bad, o resto segue
echo '{quebrado' > "$LH/.oute/emit/spool/00000000000000000001-1.json"
HOME="$LH" oute-emit canal 20260928-110000-f
check "ilegível: vai para spool.bad, o evento novo sai" [ -f "$LH/.oute/emit/spool.bad/00000000000000000001-1.json" -a -z "$(ls "$LH/.oute/emit/spool/"*.json 2>/dev/null)" -a "$(posts)" -eq 2 ]
rcv_stop

# lote recusado com 4xx: reenvia um por um; só o arquivo recusado de novo vai para spool.bad
MH="$TMP/misto"; MS="$MH/.oute/emit/spool"; mkdir -p "$MH/outbox"
for t in bom1 RUIM bom2; do
  id="20260928-120000-$(tr A-Z a-z <<<"$t")"
  printf '# oute-propose\n# titulo: %s\n# como: user\n# agente: codex\n# criado: 2026-09-28T12:00:00Z\n\necho %s\n' "$t" "$t" > "$MH/outbox/$id.sh"
  HOME="$MH" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal "$id"
done
check "4xx em lote: três arquivos no spool"             [ "$(ls "$MS/"*.json | wc -l)" -eq 3 ]
RCV_REJECT=RUIM rcv_start "$TMP/r6f"
HOME="$MH" oute-emit flush
check "4xx em lote: os bons chegam, um por um"          [ "$(n true)" -eq 2 -a "$(n '.attrs["oute.canal.title"] == "bom1"')" -eq 1 -a "$(n '.attrs["oute.canal.title"] == "bom2"')" -eq 1 ]
check "4xx em lote: só o recusado vai para spool.bad"  [ -z "$(ls "$MS/"*.json 2>/dev/null)" -a "$(ls "$MH/.oute/emit/spool.bad/"*.json | wc -l)" -eq 1 ] \
                                                         && grep -q RUIM "$MH/.oute/emit/spool.bad/"*.json
rcv_stop

# laço de flush do entrypoint (a função flush_spool, extraída do entrypoint.sh): sleep falso conta as voltas
eval "$(sed -n '/^flush_spool() {/,/^}/p' "$ROOT/docker/entrypoint.sh")"
check "entrypoint: flush_spool extraída"                [ "$(type -t flush_spool)" == function ]
EH="$TMP/ep"; mkdir -p "$EH/outbox"; cp "$FH/outbox/"*.sh "$EH/outbox/"
# voltas <up-na-volta>: roda o laço com o coletor fora até a volta dada (0 = nunca); imprime quantos sleep
voltas() { (
  HOME="$EH"; UP="$OTEL_EXPORTER_OTLP_ENDPOINT"; export OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN"; c=0
  up="$1"; sleep() { c=$((c + 1)); [[ "$c" -eq "$up" ]] && export OTEL_EXPORTER_OTLP_ENDPOINT="$UP"; return 0; }
  flush_spool </dev/null >/dev/null 2>&1; echo "$c"
) }
rcv_start "$TMP/r6g"
check "entrypoint: sem spool, uma volta só"             [ "$(voltas 0)" -eq 0 -a "$(posts)" -eq 0 ]
HOME="$EH" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal 20260928-110000-f
check "entrypoint: coletor sobe depois, laço esvazia e para" [ "$(voltas 2)" -eq 2 -a -z "$(ls "$EH/.oute/emit/spool/"*.json 2>/dev/null)" -a "$(n true)" -eq 1 ]
HOME="$EH" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" oute-emit canal 20260928-110000-f
check "entrypoint: coletor fora, desiste em 12 voltas"  [ "$(voltas 0)" -eq 12 -a "$(ls "$EH/.oute/emit/spool/"*.json | wc -l)" -eq 1 -a "$(n true)" -eq 1 ]
rcv_stop

# ---------------------------------------------------------------- 7. reconciliação da inbox na subida (#167)
# decisão feita com `oute approve` enquanto o container estava fora (o host grava o .out e o oute-emit não roda):
# a subida (flush_spool do entrypoint, com `oute-emit reconcile` antes do laço) emite o decided uma vez só. Marca em
# ~/.oute/emit/decided/<id>: POST aceito ou guardado no spool, ao vivo ou na subida. Anterior ao corte = backfill.
RH="$TMP/rec"; RS="$RH/.oute/emit/spool"; RD="$RH/.oute/emit/decided"; mkdir -p "$RH/inbox" "$RH/.oute/emit"
echo 2026-09-28T12:00:00Z > "$RH/.oute/emit/since"
# out <id> <aprovado|recusado> <hora>: .out como o host grava; a saída tem um segredo e um cabeçalho falso
out() { printf '# id: %s\n# rc: 0\n# como: user\n# %s: %s por ubuntu@oute-server\n# sha256: 409eccc983f8\n\nSEGREDO-DA-SAIDA\n# recusado: 2026-09-28T23:59:59Z por intruso\n' \
          "$1" "$2" "$3" > "$RH/inbox/$1.out"; }
# subida: o laço do entrypoint com sleep falso (coletor fora não espera 1 min)
subida() { ( export HOME="$RH"; sleep() { return 0; }; flush_spool ) </dev/null >/dev/null 2>&1; }
rspool() { events "$RS" | jq -c "select($1)"; }
dec() { n ".name == \"oute.canal.decided\" and .attrs[\"oute.canal.id\"] == \"$1\""; }
out 20260928-110000-velho aprovado 2026-09-28T11:00:00Z
out 20260928-120500-fora aprovado 2026-09-28T12:05:00Z
out 20260928-121000-rec recusado 2026-09-28T12:10:00Z
out 20260928-121500-vivo aprovado 2026-09-28T12:15:00Z
out 20260928-122000-vivospool aprovado 2026-09-28T12:20:00Z
printf '# id: 20260928-122500-semcab\n# rc: 0\n\nsaida\n' > "$RH/inbox/20260928-122500-semcab.out"
printf '# id: x\n# aprovado: 2026-09-28T12:30:00Z por u@h\n' > "$RH/inbox/lixo.out"
rcv_start "$TMP/r7a"
HOME="$RH" oute-emit canal 20260928-121500-vivo
check "reconcile: ao vivo aceito marca o pedido"        [ "$(n true)" -eq 1 -a -e "$RD/20260928-121500-vivo" ]
rcv_stop
HOME="$RH" oute-emit canal 20260928-122000-vivospool
check "reconcile: ao vivo no spool também marca"        [ -e "$RD/20260928-122000-vivospool" -a "$(ls "$RS/"*.json | wc -l)" -eq 1 ]
# subida com o coletor fora: vai para o spool e marca
OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" subida
check "reconcile coletor fora: decided pendentes no spool" [ "$(rspool '.name == "oute.canal.decided"' | grep -c .)" -eq 3 ] \
                                                         && [ "$(events "$RS" | jq -r '.attrs["oute.canal.id"]' | sort | tr '\n' ' ')" == "20260928-120500-fora 20260928-121000-rec 20260928-122000-vivospool " ]
check "reconcile coletor fora: .out marcados"           [ -e "$RD/20260928-120500-fora" -a -e "$RD/20260928-121000-rec" ]
check "reconcile: antes do corte, sem cabeçalho e id inválido ficam sem marca" \
                                                        [ ! -e "$RD/20260928-110000-velho" -a ! -e "$RD/20260928-122500-semcab" -a ! -e "$RD/lixo" ]
check "reconcile: hora do fato e decisão do cabeçalho"  [ "$(rspool '.attrs["oute.canal.id"] == "20260928-121000-rec" and .attrs["oute.canal.decision"] == "recusado"
                                                              and (.time | tonumber / 1e9 | todate) == "2026-09-28T12:10:00Z" and .attrs["oute.agent"] == "human" and .body == null' | grep -c .)" -eq 1 ]
check "reconcile: nunca lê a saída (segredo, cabeçalho falso)" [ -z "$(grep -l 'SEGREDO-DA-SAIDA\|intruso' "$RS"/*.json)" ] \
                                                         && [ "$(rspool '.attrs["oute.canal.id"] == "20260928-120500-fora" and .attrs["oute.canal.decision"] == "executado"' | grep -c .)" -eq 1 ]
# subida com o coletor no ar: o spool chega, a reconciliação não repete nada
rcv_start "$TMP/r7b"
subida
check "reconcile: cada decided chega uma vez"           [ "$(dec 20260928-120500-fora)" -eq 1 -a "$(dec 20260928-121000-rec)" -eq 1 -a "$(dec 20260928-122000-vivospool)" -eq 1 -a "$(n true)" -eq 3 ]
check "reconcile: enviado ao vivo não é reemitido"      [ "$(dec 20260928-121500-vivo)" -eq 0 ]
check "reconcile: anterior ao corte fica com o backfill" [ "$(dec 20260928-110000-velho)" -eq 0 ]
check "reconcile: saída do host em nenhum POST"         [ -z "$(grep -l 'SEGREDO-DA-SAIDA' "$RCV_DIR"/*.json)" -a -z "$(ls "$RS/"*.json 2>/dev/null)" ]
rcv_stop
rcv_start "$TMP/r7c"
subida
check "reconcile: subida repetida não reemite"          [ "$(posts)" -eq 0 ]
# aprovação com o container fora → subida com o coletor no ar: chega uma vez, com o id do ao vivo
out 20260928-123000-novo aprovado 2026-09-28T12:30:00Z
subida
e="$(ev '.attrs["oute.canal.id"] == "20260928-123000-novo"')"
check "reconcile: aprovação com container fora chega na subida" [ "$(grep -c . <<<"$e")" -eq 1 -a "$(n true)" -eq 1 -a -e "$RD/20260928-123000-novo" ]
subida
check "reconcile: e só uma vez"                         [ "$(n true)" -eq 1 ]
rcv_stop
rcv_start "$TMP/r7d"
HOME="$RH" oute-emit canal 20260928-123000-novo
check "reconcile: mesmo oute.event.id do ao vivo"       [ "$(ev true | jq -r '.attrs["oute.event.id"]')" == "$(jq -r '.attrs["oute.event.id"]' <<<"$e")" ]
rcv_stop
# o backfill do mesmo HOME fica só com o anterior ao corte: não sobrepõe
rcv_start "$TMP/r7e"
HOME="$RH" oute-emit backfill 2>/dev/null
check "reconcile × backfill: backfill só com o anterior" [ "$(n '.name == "oute.canal.decided"')" -eq 1 -a "$(dec 20260928-110000-velho)" -eq 1 ]
rcv_stop
# não conta como enviado: sem endpoint, spool cheio (descartado); a próxima subida tenta de novo
out 20260928-124000-tarde aprovado 2026-09-28T12:40:00Z
OTEL_EXPORTER_OTLP_ENDPOINT= subida
check "reconcile sem endpoint: não marca"               [ ! -e "$RD/20260928-124000-tarde" ]
OUTE_EMIT_SPOOL_MAX=100 OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" subida
check "reconcile spool cheio: descarta e não marca"     [ ! -e "$RD/20260928-124000-tarde" -a -z "$(ls "$RS/"*.json 2>/dev/null)" ]
rcv_start "$TMP/r7f"
subida
check "reconcile: depois, chega na próxima subida"      [ "$(n true)" -eq 1 -a "$(dec 20260928-124000-tarde)" -eq 1 -a -e "$RD/20260928-124000-tarde" ]
rcv_stop
# sem corte (since): não reconcilia (não sabe o que é do backfill)
NH="$TMP/rec-nosince"; mkdir -p "$NH/inbox"; cp "$RH/inbox/20260928-120500-fora.out" "$NH/inbox/"
rcv_start "$TMP/r7g"
HOME="$NH" oute-emit reconcile
check "reconcile sem corte: nada sai, nada marca"       [ "$(posts)" -eq 0 -a ! -e "$NH/.oute/emit/decided" ]
rcv_stop

# ---------------------------------------------------------------- 8. sem OTEL_* no ambiente: ~/.oute_env (#250)
# o shell do Bash tool do Claude Code não herda as OTEL_*: o oute-emit lê endpoint e origem do ~/.oute_env que o
# entrypoint grava (declare -px). Só lido (nunca source), só as três chaves; variável com valor no ambiente vence
noenv() { env -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_EXPORTER_OTLP_LOGS_ENDPOINT -u OTEL_RESOURCE_ATTRIBUTES "$@"; }
FILE_ORIGIN="host.name=oute-server,oute.instance=oute-agent,deployment.environment=oute-server"
# envfile <home> [VAR=valor…]: ~/.oute_env como o entrypoint grava (declare -px, mesmo filtro), só com as variáveis
# dadas e uma OUTE_ e uma GH_ quaisquer; e uma linha de shell solta, que só um source executaria
envfile() {
  local h="$1"; shift
  env -i OUTE_X='valor com "aspas" e $(touch '"$h"'/pwned)' GH_X=1 "$@" bash -c 'declare -px' \
    | grep -E '^declare -x (GH_|OUTE_|AI_MEMORY|GOOGLE_APP|AWS_|RCLONE_CONFIG_|OTEL_|CLAUDE_CODE_)' > "$h/.oute_env"
  printf 'touch "%s/pwned"\n' "$h" >> "$h/.oute_env"
}
# n_in <dir> <jq-select>: registros de um receptor que não é o atual
n_in() { events "$1" | jq -c "select($2)" | grep -c . || true; }
EH8="$TMP/oute-env"; mkdir -p "$EH8"
rcv_start "$TMP/r8"; LIVE="$OTEL_EXPORTER_OTLP_ENDPOINT"
envfile "$EH8" OTEL_EXPORTER_OTLP_ENDPOINT="$LIVE" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN" OTEL_SERVICE_NAME=outro
SCRIPT='echo do claude'
OUT="$(HOME="$EH8" noenv CLAUDECODE=1 "$ROOT/docker/oute-propose" "sem otel" <<<"$SCRIPT" 2>/dev/null)"; RC=$?
e="$(ev '.name == "oute.canal.proposed" and .attrs["oute.canal.title"] == "sem otel"')"
check "oute_env: propose sem OTEL_*, rc 0 e só o id"   [ "$RC" -eq 0 -a -f "$EH8/outbox/$OUT.sh" -a "$(grep -c . <<<"$OUT")" -eq 1 ]
check "oute_env: proposed chega com o endpoint do arquivo" [ "$(grep -c . <<<"$e")" -eq 1 ]
check "oute_env: oute.agent=claude, origem do arquivo"  jqe '.attrs["oute.agent"] == "claude" and .res["oute.agent"] == "claude" and .res["host.name"] == "oute-server"
                                                         and .res["oute.instance"] == "oute-agent" and .res["service.name"] == "oute"' <<<"$e"
check "oute_env: nunca source (nada executado)"         [ ! -e "$EH8/pwned" ]
R8="$EH8/.oute/swarm/swarm-1002-0800"; mkdir -p "$R8"; printf 'repo=/workspace/lab\nmax=1\nagent=claude\n' > "$R8/meta"
L8="2026-10-02T08:00:00Z abertura swarm-1002-0800 (repo lab, max 1)"; printf '%s\n' "$L8" > "$R8/log"
OUT="$(HOME="$EH8" noenv oute-emit swarm swarm-1002-0800 "$L8" 2>&1)"; RC=$?
check "oute_env: swarm sem OTEL_*, rc 0, nada na tela"  [ "$RC" -eq 0 -a -z "$OUT" ]
check "oute_env: round.opened com oute.agent=claude e origem do arquivo" [ "$(n '.name == "oute.swarm.round.opened" and .attrs["oute.agent"] == "claude"
                                                         and .res["host.name"] == "oute-server" and .res["oute.instance"] == "oute-agent"')" -eq 1 ]
# precedência, uma a uma: endpoint do ambiente vence o do arquivo; origem vazia no ambiente = a do arquivo
rcv_stop; rcv_start "$TMP/r8b"
printf '# oute-propose\n# titulo: prec\n# como: user\n# agente: claude\n# criado: 2026-10-02T08:01:00Z\n\necho p\n' > "$EH8/outbox/20261002-080100-prec.sh"
HOME="$EH8" OTEL_RESOURCE_ATTRIBUTES= oute-emit canal 20261002-080100-prec
check "precedência: endpoint do ambiente vence"         [ "$(n true)" -eq 1 -a "$(n_in "$TMP/r8" '.attrs["oute.canal.id"] == "20261002-080100-prec"')" -eq 0 ]
check "precedência: origem vazia no ambiente = a do arquivo" [ "$(n '.res["host.name"] == "oute-server"')" -eq 1 ]
HOME="$EH8" oute-emit canal 20261002-080100-prec
check "precedência: origem do ambiente vence"           [ "$(n '.res["host.name"] == "oute-mac" and .res["oute.instance"] == "oute-agent"')" -eq 1 ]
HOME="$EH8" noenv OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT/v1/logs" oute-emit canal 20261002-080100-prec
check "precedência: endpoint de logs do ambiente vence o base do arquivo" [ "$(n true)" -eq 3 ]
# endpoint de logs só no arquivo; o endpoint é um par: base no ambiente = nada de endpoint do arquivo
envfile "$EH8" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT/v1/logs" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN"
HOME="$EH8" noenv oute-emit canal 20261002-080100-prec
check "oute_env: OTEL_EXPORTER_OTLP_LOGS_ENDPOINT do arquivo" [ "$(n true)" -eq 4 ]
before="$(n_in "$TMP/r8" true)"
envfile "$EH8" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="$LIVE/v1/logs" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN"
HOME="$EH8" oute-emit canal 20261002-080100-prec
check "precedência: base no ambiente, endpoint de logs do arquivo não entra" [ "$(n true)" -eq 5 -a "$(n_in "$TMP/r8" true)" -eq "$before" ]
rcv_stop
# spool e flush sem OTEL_*: o coletor do arquivo fora → spool; de volta → flush entrega o mesmo oute.event.id
SH8="$TMP/oute-env-spool"; mkdir -p "$SH8/outbox"; cp "$EH8/outbox/20261002-080100-prec.sh" "$SH8/outbox/"
envfile "$SH8" OTEL_EXPORTER_OTLP_ENDPOINT="$DOWN" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN"
OUT="$(HOME="$SH8" noenv oute-emit canal 20261002-080100-prec 2>&1)"; RC=$?
check "oute_env coletor fora: rc 0, nada na tela, no spool" [ "$RC" -eq 0 -a -z "$OUT" -a "$(ls "$SH8/.oute/emit/spool/"*.json 2>/dev/null | wc -l)" -eq 1 ]
sid="$(events "$SH8/.oute/emit/spool" | jq -r '.attrs["oute.event.id"]')"
check "oute_env coletor fora: spool com a origem do arquivo" [ "$(events "$SH8/.oute/emit/spool" | jq -r '.res["host.name"]')" == oute-server ]
rcv_start "$TMP/r8c"
envfile "$SH8" OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN"
OUT="$(HOME="$SH8" noenv oute-emit flush 2>&1)"; RC=$?
check "oute_env flush sem OTEL_*: entrega o mesmo id"   [ "$RC" -eq 0 -a -z "$OUT" -a "$(n true)" -eq 1 -a "$(ev true | jq -r '.attrs["oute.event.id"]')" == "$sid" ]
check "oute_env flush sem OTEL_*: spool vazio"          [ -z "$(ls "$SH8/.oute/emit/spool/"*.json 2>/dev/null)" ]
rcv_stop
# teto de 2 s com o endpoint do arquivo e o coletor lento
RCV_SLEEP=6 rcv_start "$TMP/r8d"
envfile "$SH8" OTEL_EXPORTER_OTLP_ENDPOINT="$OTEL_EXPORTER_OTLP_ENDPOINT" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN"
t0=$(ms); OUT="$(HOME="$SH8" noenv oute-emit canal 20261002-080100-prec 2>&1)"; RC=$?; dt=$(( $(ms) - t0 ))
check "oute_env coletor lento: rc 0, teto de 2 s ($dt ms)" [ "$RC" -eq 0 -a -z "$OUT" -a "$dt" -le 2800 ]
rcv_stop
# sem endpoint no ambiente nem no arquivo (ausente, sem a chave, fora do formato, ilegível): nada enviado, nada no
# spool, rc 0, sem stdout; a reconciliação não marca. O receptor fica no ar, e é ele que está nas linhas quebradas
rcv_start "$TMP/r8e"; UP8="$OTEL_EXPORTER_OTLP_ENDPOINT"
XH="$TMP/oute-env-sem"; mkdir -p "$XH/outbox" "$XH/inbox" "$XH/.oute/emit"; cp "$EH8/outbox/20261002-080100-prec.sh" "$XH/outbox/"
echo 2026-10-01T00:00:00Z > "$XH/.oute/emit/since"
printf '# id: 20261002-080200-dec\n# rc: 0\n# aprovado: 2026-10-02T08:02:00Z por ubuntu@oute-server\n\nsaida\n' > "$XH/inbox/20261002-080200-dec.out"
# sem_endpoint <caso>: o ~/.oute_env já montado; canal e reconcile sem OTEL_* não mandam nem guardam nada
sem_endpoint() {
  OUT="$(HOME="$XH" noenv oute-emit canal 20261002-080100-prec 2>&1; HOME="$XH" noenv oute-emit reconcile 2>&1; HOME="$XH" noenv oute-emit flush 2>&1)"; RC=$?
  check "sem endpoint ($1): rc 0, nada na tela, nada enviado, nada no spool, sem marca" \
    [ "$RC" -eq 0 -a -z "$OUT" -a "$(posts)" -eq 0 -a ! -e "$XH/.oute/emit/spool" -a ! -e "$XH/.oute/emit/decided" ]
}
rm -f "$XH/.oute_env"; sem_endpoint "arquivo ausente"
envfile "$XH" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN"; sem_endpoint "arquivo sem a chave"
envfile "$XH" OTEL_EXPORTER_OTLP_ENDPOINT=; sem_endpoint "chave vazia"
envfile "$XH"; sed -i '/^declare -x OTEL_/d' "$XH/.oute_env"; echo "declare -x OTEL_EXPORTER_OTLP_ENDPOINT" >> "$XH/.oute_env"; sem_endpoint "chave sem valor"
# <caso>|<linha>: a linha do endpoint fora do formato do declare -px (o resto do arquivo é válido)
for bad in "aspas simples|declare -x OTEL_EXPORTER_OTLP_ENDPOINT='$UP8'" "sem aspas|declare -x OTEL_EXPORTER_OTLP_ENDPOINT=$UP8" \
           "aspas abertas|declare -x OTEL_EXPORTER_OTLP_ENDPOINT=\"$UP8" "\$'…'|declare -x OTEL_EXPORTER_OTLP_ENDPOINT=\$'$UP8'" \
           "export|export OTEL_EXPORTER_OTLP_ENDPOINT=\"$UP8\"" "atribuição solta|OTEL_EXPORTER_OTLP_ENDPOINT=\"$UP8\"" \
           "comando depois|declare -x OTEL_EXPORTER_OTLP_ENDPOINT=\"$UP8\" ; touch $XH/pwned" \
           "\$(…) sem escape|declare -x OTEL_EXPORTER_OTLP_ENDPOINT=\"\$(echo $UP8)\""; do
  envfile "$XH" OTEL_RESOURCE_ATTRIBUTES="$FILE_ORIGIN"; printf '%s\n' "${bad#*|}" >> "$XH/.oute_env"; sem_endpoint "${bad%%|*}"
done
envfile "$XH" OTEL_EXPORTER_OTLP_ENDPOINT="$UP8"; envfile "$TMP" OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:1"
grep '^declare -x OTEL_' "$TMP/.oute_env" >> "$XH/.oute_env"; sem_endpoint "chave repetida"
envfile "$XH" OTEL_EXPORTER_OTLP_ENDPOINT="$UP8"; printf '\xff\xfe\n' >> "$XH/.oute_env"; sem_endpoint "fora de UTF-8"
envfile "$XH" OTEL_EXPORTER_OTLP_ENDPOINT="$UP8"; head -c 1100000 /dev/zero | tr '\0' '#' >> "$XH/.oute_env"; sem_endpoint "grande demais"
if [[ "$(id -u)" -ne 0 ]]; then
  envfile "$XH" OTEL_EXPORTER_OTLP_ENDPOINT="$UP8"; chmod 000 "$XH/.oute_env"; sem_endpoint "ilegível"; chmod 644 "$XH/.oute_env"
fi
check "oute_env: nenhuma linha do arquivo executada"   [ ! -e "$XH/pwned" ]
envfile "$XH" OTEL_EXPORTER_OTLP_ENDPOINT="$UP8"
HOME="$XH" noenv oute-emit reconcile
check "oute_env válido de novo: reconcile manda e marca" [ "$(n '.name == "oute.canal.decided"')" -eq 1 -a -e "$XH/.oute/emit/decided/20261002-080200-dec" ]
rcv_stop

check_end
