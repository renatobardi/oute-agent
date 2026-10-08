#!/usr/bin/env bash
# Testes de `oute studio rebuild-state` (#345, ADR-08 §7): `scripts/oute` (host) e `python -m agent_studio.rebuild_state`
# (one-off dentro da imagem). O agent-studio e o SurrealDB são de verdade (venv e binário fixados, sem Docker); o `docker`
# falso faz `stop` (derruba o serviço: o DuckDB só abre depois), `run` (o one-off real, com o ambiente que o compose
# daria) e `up` (só registra). Casos: o estado remontado de um SurrealDB vazio é igual ao que a ingestão gerou (as cinco
# tabelas, campo a campo), com blocos de 1 linha também; idempotente; não apaga o que já está lá; ordem stop → run → up;
# SurrealDB fora = rc 1 e o serviço sobe de novo; serviço que não sobe = rc 1; uso e pré-condições sem tocar no serviço;
# a credencial nunca em argv.
# Uso: tests/agent-studio-rebuild-state.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; surreal_stop; rm -rf "${TMP:?}"' EXIT
studio_init
. "$ROOT/tests/lib/surreal.sh"
surreal_bin
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não subiu"; }
PKG="$ROOT/docker/agent-studio"
SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml"
      AGENT_STUDIO_PHASE_JOB=0)   # sem a rotina da fase (#749): ela espelharia a fase no SurrealDB esvaziado e mudaria a contagem de "antes"
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
DB="$TMP/s/db.duckdb"

# ---------------------------------------------------------------- 1. a ingestão gera o estado
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys
from otlp_json import canal_decided, canal_proposed, event, rl, rs, span
tmp, T = sys.argv[1], 1790856000
server = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "claude"}
RND, S1, S2, SESS = "swarm-1001-1200", "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "conv-0001"
P1, P2, P3 = "20261001-120000-reiniciar-nginx", "20261001-121000-listar-backups", "20261001-122000-chegou-fora-de-ordem"
# lote 1: pedidos (um decidido, um pendente, um decidido ANTES do proposed), rodada, worker, sessões, título com ":"
b1 = {"resourceLogs": [
    rl(server, [
        canal_proposed(T + 10, P1, "ev-p1", "ship: verificar deploy", "root", "systemctl reload nginx\n"),
        canal_proposed(T + 20, P2, "ev-p2", "Listar backups", "user", "ls /backup\n"),
        event(T + 30, "oute.swarm.round.opened", "ev-r1", {"oute.swarm.round": RND, "oute.swarm.repo": "oute-agent",
                                                           "oute.swarm.max": 3, "oute.swarm.label": "rebuild"}),
        event(T + 35, "oute.swarm.session.spawned", "ev-w1", {"oute.swarm.round": RND, "oute.swarm.session": "345-rebuild",
                                                               "oute.swarm.issue": 345, "oute.swarm.session.agent": "claude",
                                                               "oute.swarm.repo": "oute-agent"}),
        event(T + 40, "oute.task.opened", "ev-t1", {"oute.task.id": S1, "oute.task.repo": "oute-agent",
                                                     "oute.task.slug": "345-rebuild", "oute.task.agent": "claude",
                                                     "oute.swarm.round": RND, "oute.swarm.session": "345-rebuild"}),
        event(T + 41, "oute.task.opened", "ev-t2", {"oute.task.id": S2, "oute.task.repo": "oute-agent",
                                                     "oute.task.slug": "avulsa", "oute.task.agent": "codex"}),
        event(T + 50, "oute.task.removed", "ev-t2r", {"oute.task.id": S2, "oute.task.reason": "merged"}),
        event(T + 55, "oute.exemplo", "ev-x", {}),
    ]),
    rl({**server, "oute.agent": "human"}, [
        canal_decided(T + 60, P1, "ev-d1", "executado", None, **{"oute.canal.rc": 0}),
        canal_decided(T + 61, P3, "ev-d3", "recusado"),
    ]),
]}
# lote 2: o proposed do P3 chega depois do decided; o worker e a rodada fecham
b2 = {"resourceLogs": [rl(server, [
    canal_proposed(T + 5, P3, "ev-p3", "Fora de ordem", "root", "true\n"),
    event(T + 70, "oute.swarm.session.closed", "ev-w1c", {"oute.swarm.round": RND, "oute.swarm.session": "345-rebuild"}),
    event(T + 80, "oute.swarm.round.closed", "ev-r1c", {"oute.swarm.round": RND}),
])]}
# spans e um log da conversa (session.id + oute.task.id nos resources): vira `conversa` ligada à sessão
conv = {**server, "session.id": SESS, "oute.task.id": S1, "oute.subscription": "zai"}  # #679: a assinatura da conversa
spans = {"resourceSpans": [rs(conv, [span("claude_code.llm_request", T + 45, 2, {"model": "claude-sonnet-5"})])]}
b3 = {"resourceLogs": [rl(conv, [event(T + 46, "claude_code.api_request", "ev-api", {})])]}
for name, obj in (("b1", b1), ("b2", b2), ("spans", spans), ("b3", b3)):
    json.dump(obj, open(f"{tmp}/{name}.json", "w"))
PY
check "ingestão: lote 1 de logs" test "$(post logs "$TMP/b1.json")" = 200
check "ingestão: lote 2 de logs (o proposed atrasado)" test "$(post logs "$TMP/b2.json")" = 200
check "ingestão: spans" test "$(post traces "$TMP/spans.json")" = 200
check "ingestão: log da conversa" test "$(post logs "$TMP/b3.json")" = 200
TABLES=(rodada worker sessao pedido conversa)
# snapshot <arquivo>: as cinco tabelas, registro a registro, ordenadas pelo id
# a fase da conversa (#749) é derivada depois da ingestão (rotina e leitura do Uso), não pela ingestão: fica fora da comparação
# do estado, e os campos dela têm o caso próprio abaixo
snap() { local t omit; : > "$1"; for t in "${TABLES[@]}"; do omit=""; [[ "$t" != conversa ]] || omit="OMIT phase, phase_origin, phase_confidence"; echo "== $t" >> "$1"; surreal_q "SELECT * $omit FROM $t ORDER BY id" >> "$1"; done; }
snap "$TMP/ingestao.json"
sstate() { surreal_q "SELECT count() FROM $1 GROUP ALL" | jq -r 'try (.[0].count) // 0'; }
check "a ingestão gerou 1 rodada, 1 worker, 2 sessões, 3 pedidos e 1 conversa" \
  test "$(for t in "${TABLES[@]}"; do sstate "$t"; done | tr '\n' ' ')" = "1 1 2 3 1 "
check "o proposed atrasado não desfez o decided (estado decidido)" \
  test "$(surreal_q 'SELECT state FROM pedido:`20261001-122000-chegou-fora-de-ordem`' | jq -r '.[0].state')" = decidido
check "o texto com ':' ficou inteiro (#337)" \
  test "$(surreal_q 'SELECT title FROM pedido:`20261001-120000-reiniciar-nginx`' | jq -r '.[0].title')" = "ship: verificar deploy"
check "a conversa ficou ligada à sessão" \
  test "$(surreal_q 'SELECT sessao FROM conversa:`conv-0001`' | jq -r '.[0].sessao' | grep -c 11111111-1111-4111-8111-111111111111)" = 1
check "a conversa trouxe a assinatura (#679)" \
  test "$(surreal_q 'SELECT subscription FROM conversa:`conv-0001`' | jq -r '.[0].subscription')" = zai
studio_stop   # o DuckDB só abre para leitura com o serviço parado

# ---------------------------------------------------------------- 2. one-off direto, contra um SurrealDB vazio
REB=(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.rebuild_state)
wipe_surreal() { surreal_stop; rm -rf "${TMP:?}/sdb/data"; surreal_start "$TMP/sdb" || die "SurrealDB não voltou"; }
wipe_surreal
check "SurrealDB esvaziado: sem pedidos" test "$(sstate pedido)" = 0
OUT="$("${REB[@]}" 2>"$TMP/err")"; RC=$?
check "rebuild-state: rc 0" test "$RC" = 0
check "antes: tudo zerado" has_line "antes: rodadas=0 workers=0 sessoes=0 pedidos=0 conversas=0 etapas=0 acoes=0"
check "lidas: 14 logs e 1 span" has_line "lidas: logs=14 spans=1 marcas=0"
check "depois: a contagem da ingestão" has_line "depois: rodadas=1 workers=1 sessoes=2 pedidos=3 conversas=1 etapas=0 acoes=0"
snap "$TMP/remontado.json"
check "o estado remontado é igual ao da ingestão (as cinco tabelas, todos os campos)" cmp -s "$TMP/ingestao.json" "$TMP/remontado.json"
check "o rebuild-state remontou a assinatura da conversa (#679)" \
  test "$(surreal_q 'SELECT subscription FROM conversa:`conv-0001`' | jq -r '.[0].subscription')" = zai
check "o rebuild-state refez a fase da conversa (#749): uma fase do ADR-07, a origem e a confiança" \
  test "$(surreal_q 'SELECT phase, phase_origin, phase_confidence FROM conversa:`conv-0001`' | jq -r '.[0] | [.phase, .phase_origin, .phase_confidence] | join(",")')" = "build,acao,baixa"
check "rebuild-state: a linha fases: conta a conversa" has_line "fases: conversas=1"
check "stderr vazio no caso feliz" test ! -s "$TMP/err"

# ---------------------------------------------------------------- 3. idempotente, em blocos de 1 linha, sem apagar
OUT="$(AGENT_STUDIO_REBUILD_CHUNK=1 "${REB[@]}" 2>&1)"; RC=$?
check "de novo, blocos de 1 linha: rc 0 e a contagem de antes é a de depois" bash -c '[ "$1" = 0 ] && grep -qx "antes: rodadas=1 workers=1 sessoes=2 pedidos=3 conversas=1 etapas=0 acoes=0" <<<"$2"' _ "$RC" "$OUT"
snap "$TMP/de-novo.json"
check "de novo: nada mudou" cmp -s "$TMP/ingestao.json" "$TMP/de-novo.json"
surreal_q 'CREATE pedido:`so-no-surreal` SET state = "pendente"' >/dev/null
OUT="$("${REB[@]}" 2>&1)"; RC=$?
check "registro que só existe no SurrealDB não é apagado" bash -c '[ "$1" = 0 ] && grep -qx "depois: rodadas=1 workers=1 sessoes=2 pedidos=4 conversas=1 etapas=0 acoes=0" <<<"$2"' _ "$RC" "$OUT"
surreal_q 'DELETE pedido:`so-no-surreal`' >/dev/null
# estado já atualizado no SurrealDB por fora volta ao do DuckDB onde o fato manda
wipe_surreal
OUT="$(AGENT_STUDIO_REBUILD_CHUNK=1 "${REB[@]}" 2>&1)"
snap "$TMP/bloco1.json"
check "blocos de 1 linha num SurrealDB vazio: o mesmo estado da ingestão" cmp -s "$TMP/ingestao.json" "$TMP/bloco1.json"

# ---------------------------------------------------------------- 4. falhas do one-off
OUT="$(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.rebuild_state 2>&1)"; RC=$?
check "sem a senha do SurrealDB: rc 2, diz qual variável" bash -c '[ "$1" = 2 ] && grep -q AGENT_STUDIO_SURREAL_PASS <<<"$2"' _ "$RC" "$OUT"
OUT="$(env AGENT_STUDIO_DB="$TMP/nao-existe.duckdb" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.rebuild_state 2>&1)"; RC=$?
check "DuckDB que não abre: rc 1, sem tocar no SurrealDB" bash -c '[ "$1" = 1 ] && grep -q "não abri o DuckDB" <<<"$2" && ! grep -q "^antes" <<<"$2"' _ "$RC" "$OUT"
DEAD="${SURREAL_URL%:*}:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"  # mesmo esquema e host, porta sem ninguém
OUT="$(env AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$DEAD" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.rebuild_state 2>&1)"; RC=$?
check "SurrealDB fora: rc 1, só o tipo do erro, sem a senha" bash -c '[ "$1" = 1 ] && grep -q "falhou (SurrealError)" <<<"$2" && ! grep -qF "$3" <<<"$2"' _ "$RC" "$OUT" "$SURREAL_TEST_PASS"
OUT="$(env AGENT_STUDIO_REBUILD_CHUNK=abc AGENT_STUDIO_DB="$DB" AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.rebuild_state 2>&1)"; RC=$?
check "tamanho de bloco inválido: rc 1 (não abre nada)" test "$RC" = 1

# ---------------------------------------------------------------- 5. o comando do host, com docker falso
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
# docker falso: `ps` (SurrealDB de pé, salvo F_NOSURREAL) e `compose … stop|run|up`. Cada chamada vai ao $F_LOG (argv).
printf 'docker %s\n' "$*" >> "$F_LOG"
case "$1" in
  ps) [[ "${F_NOSURREAL:-}" == 1 ]] || echo abc123 ;;
  compose)
    shift
    while [[ "$1" == --project-directory || "$1" == -f ]]; do shift 2; done
    sub="$1"; shift
    case "$sub" in
      stop) [[ "$1" == agent-studio ]] || exit 9
            [[ "${F_STOP_FAIL:-}" == 1 ]] && exit 1
            if [[ -s "$F_PIDFILE" ]]; then kill "$(cat "$F_PIDFILE")" 2>/dev/null; while kill -0 "$(cat "$F_PIDFILE")" 2>/dev/null; do sleep 0.1; done; : > "$F_PIDFILE"; fi ;;
      run)  [[ " $* " == *" --entrypoint /opt/agent-studio/venv/bin/python agent-studio -m agent_studio.rebuild_state "* ]] || exit 9
            # o ambiente do serviço: a senha chega pelo ambiente exportado pelo scripts/oute (a interpolação do compose)
            env AGENT_STUDIO_DB="$F_DB" AGENT_STUDIO_SURREAL_URL="$F_SURREAL_URL" PYTHONPATH="$F_PKG" "$F_PY" -m agent_studio.rebuild_state ;;
      up)   [[ "${F_UP_FAIL:-}" == 1 ]] && exit 1
            [[ " $* " == *" agent-studio "* ]] || exit 9 ;;
      *)    exit 9 ;;
    esac ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/docker"
export F_LOG="$TMP/calls.log" F_PIDFILE="$TMP/studio.pid"
mkdir -p "$TMP/home/.oute" "$TMP/repo/scripts" "$TMP/repo/docker"
cp "$ROOT/scripts/oute" "$TMP/repo/scripts/oute"; cp "$ROOT/VERSION" "$TMP/repo/VERSION"
umask 077
echo 'export OUTE_TESTE=1' > "$TMP/home/.oute/agent.env"
write_services() { printf 'export AGENT_STUDIO_INGEST_TOKEN=%s\nexport AGENT_STUDIO_SURREAL_PASS=%s\n' "$1" "$2" > "$TMP/home/.oute/services.env"; }
write_services "$STUDIO_TOKEN" "$SURREAL_TEST_PASS"
OUTE_ENV=(OUTE_AGENT_STUDIO=1)
oute() {
  OUT="$(env -i PATH="$BIN:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/home/.oute" LANG=C.UTF-8 TMPDIR="$TMP" OUTE_HOST=oute-teste \
    F_LOG="$F_LOG" F_PIDFILE="$F_PIDFILE" F_DB="$DB" F_SURREAL_URL="${F_SURREAL_URL:-$SURREAL_URL}" F_PKG="$PKG" F_PY="$STUDIO_PY" \
    F_NOSURREAL="${F_NOSURREAL:-}" F_STOP_FAIL="${F_STOP_FAIL:-}" F_UP_FAIL="${F_UP_FAIL:-}" \
    ${OUTE_ENV[@]+"${OUTE_ENV[@]}"} "$TMP/repo/scripts/oute" "$@" 2>&1)"; RC=$?
}
calls() { grep -c "^docker compose" "$F_LOG"; }
start_studio() { studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }; echo "$STUDIO_PID" > "$F_PIDFILE"; }

# 5a. caminho feliz: serviço de pé, SurrealDB vazio -> para, remonta, sobe
wipe_surreal
start_studio
: > "$F_LOG"
oute studio rebuild-state
STUDIO_PID=""   # o `stop` falso derrubou o serviço
check "rebuild-state pelo host: rc 0" test "$RC" = 0
check "a saída traz antes, lidas e depois do one-off" bash -c 'grep -qx "antes: rodadas=0 workers=0 sessoes=0 pedidos=0 conversas=0 etapas=0 acoes=0" <<<"$1" && grep -qx "lidas: logs=14 spans=1 marcas=0" <<<"$1" && grep -qx "depois: rodadas=1 workers=1 sessoes=2 pedidos=3 conversas=1 etapas=0 acoes=0" <<<"$1"' _ "$OUT"
snap "$TMP/host.json"
check "o estado remontado pelo comando é igual ao da ingestão" cmp -s "$TMP/ingestao.json" "$TMP/host.json"
check "a ordem é stop, run, up" test "$(grep '^docker compose' "$F_LOG" | sed -E 's/.* (stop|run|up) .*/\1/' | tr '\n' ' ')" = "stop run up "
check "o run é descartável e sem dependências (--rm --no-deps), sem build no up" bash -c 'grep -q " run --rm --no-deps " "$1" && grep -q " up -d --no-build --no-deps agent-studio" "$1"' _ "$F_LOG"
check "nenhuma senha nem token em argv" bash -c '! grep -qF -e "$1" -e "$2" "$3" && ! grep -qF -e "$1" -e "$2" <<<"$4"' _ "$SURREAL_TEST_PASS" "$STUDIO_TOKEN" "$F_LOG" "$OUT"

# 5b. o one-off falha (SurrealDB inalcançável): rc 1 e o serviço sobe de novo mesmo assim
start_studio; : > "$F_LOG"
F_SURREAL_URL="$DEAD" oute studio rebuild-state
STUDIO_PID=""
check "one-off falhou: rc 1, diz que rodar de novo termina" bash -c '[ "$1" = 1 ] && grep -q "rebuild-state falhou (rc 1)" <<<"$2"' _ "$RC" "$OUT"
check "mesmo com a falha o serviço sobe de novo (stop, run, up)" test "$(grep '^docker compose' "$F_LOG" | sed -E 's/.* (stop|run|up) .*/\1/' | tr '\n' ' ')" = "stop run up "

# 5c. o serviço não volta: rc 1 e o aviso
start_studio; : > "$F_LOG"
F_UP_FAIL=1 oute studio rebuild-state
STUDIO_PID=""
check "serviço que não sobe de novo: rc 1 e manda rodar oute up" bash -c '[ "$1" = 1 ] && grep -q "não subiu de novo: rode oute up" <<<"$2"' _ "$RC" "$OUT"

# 5d. pré-condições: nada é parado
: > "$F_LOG"
OUTE_ENV=(); oute studio rebuild-state
check "sem OUTE_AGENT_STUDIO=1: erro claro, rc 1, docker intocado" bash -c '[ "$1" = 1 ] && grep -q "OUTE_AGENT_STUDIO=1" <<<"$2" && [ ! -s "$3" ]' _ "$RC" "$OUT" "$F_LOG"
OUTE_ENV=(OUTE_AGENT_STUDIO=1)
F_NOSURREAL=1 oute studio rebuild-state
check "SurrealDB fora do ar: erro claro, rc 1, o agent-studio não foi parado" bash -c '[ "$1" = 1 ] && grep -q "oute-surrealdb não está de pé" <<<"$2" && ! grep -q "^docker compose" "$3"' _ "$RC" "$OUT" "$F_LOG"
write_services "$STUDIO_TOKEN" ""
oute studio rebuild-state
check "senha do SurrealDB ausente no services.env: erro claro, rc 1, nada parado" bash -c '[ "$1" = 1 ] && grep -q "agent-studio não está configurado" <<<"$2" && ! grep -q "^docker compose" "$3"' _ "$RC" "$OUT" "$F_LOG"
write_services "$STUDIO_TOKEN" "$SURREAL_TEST_PASS"
F_STOP_FAIL=1 oute studio rebuild-state
check "não consegue parar: erro claro, rc 1, sem run nem up" bash -c '[ "$1" = 1 ] && grep -q "não consegui parar o agent-studio" <<<"$2" && ! grep -qE "^docker compose .* (run|up) " "$3"' _ "$RC" "$OUT" "$F_LOG"
oute studio rebuild-state --nada
check "argumento a mais: rc 2, docker intocado" bash -c '[ "$1" = 2 ] && grep -q "^uso: oute studio rebuild-state" <<<"$2"' _ "$RC" "$OUT"
oute studio outra
check "subcomando desconhecido: rc 2 e o uso lista os dois" bash -c '[ "$1" = 2 ] && grep -q "rebuild-state" <<<"$2" && grep -q "studio replay" <<<"$2"' _ "$RC" "$OUT"

check_end
