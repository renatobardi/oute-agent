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
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FAIL precisa de jq e python3"; exit 1; }

BIN="$TMP/bin"; mkdir -p "$BIN"
ln -s "$ROOT/docker/oute-emit" "$BIN/oute-emit"
export PATH="$BIN:$PATH" OTEL_RESOURCE_ATTRIBUTES="host.name=oute-mac,oute.instance=oute-agent,deployment.environment=oute-mac"
unset CLAUDECODE CODEX_THREAD_ID PI_CODING_AGENT OUTE_PROPOSE_AGENT OUTE_INBOX OUTE_OUTBOX

# ev <jq-select>: registros recebidos que casam o filtro; n <jq-select>: quantos
ev() { events "$RCV_DIR" | jq -c "select($1)"; }
n() { ev "$1" | grep -c . || true; }
jqe() { jq -e "$@" >/dev/null; }
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
PI_CODING_AGENT=true propose "$H" "pelo pi"
check "propose: agente pelo ambiente (pi)"             [ "$(n '.attrs["oute.canal.title"] == "pelo pi" and .attrs["oute.agent"] == "pi"')" -eq 1 ]
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
if ! command -v script >/dev/null || ! script -qec true /dev/null </dev/null >/dev/null 2>&1; then
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
pedido() { printf '# oute-propose\n# titulo: %s\n# como: user\n# agente: pi\n# criado: 2026-09-27T10:00:00Z\n\n%s\n' "$1" "$2" > "$CH/outbox/$1.sh"; }
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
printf '# oute-propose\n# titulo: pendente\n# como: user\n# agente: pi\n# criado: 2026-09-27T11:00:00Z\n\necho p\n' > "$BH/outbox/20260927-110000-pend.sh"
printf '# oute-propose\n# titulo: novo\n# como: user\n# agente: pi\n# criado: 2026-09-27T12:30:00Z\n\necho n\n' > "$BH/outbox/20260927-123000-novo.sh"

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
pedido5() { printf '# oute-propose\n# titulo: %s\n# como: user\n# agente: pi\n# criado: %s\n\necho %s\n' "$2" "$3" "$2" > "$IH/outbox/$1.sh"; }
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

printf '\n%d ok, %d falha(s)\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
