#!/usr/bin/env bash
# Testes do replay do bucket no agent-studio (#159, ADR-08 §7): `oute studio replay` (scripts/oute, do host) e
# `python -m agent_studio.replay` (dentro do serviço). O bucket é uma pasta ($TMP/bucket) servida por um `rclone`
# falso (lsf/copyto); o `docker` falso só roda o `agent_studio.replay` real, com o ambiente que o container teria
# (credencial de ingestão, porta), contra o agent-studio e o SurrealDB de verdade (venv e binário fixados, sem Docker).
# Casos: DuckDB vazio = N linhas; segunda vez = 0 novas (idempotente); SurrealDB esvaziado com o DuckDB intacto =
# pedidos, rodadas e sessões voltam; lote > 64 MB partido por resource; faixa pela partição com 1 h de folga, --host,
# --signal, --legacy; objeto ilegível (Archive) pulado com rc ≠ 0; 400 e 503 no replay; a credencial nunca em argv;
# o acerto do histórico sem repositório (#617) pelo replay.
# Uso: tests/agent-studio-replay.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
stub_stop() { [[ -z "${STUB_PID:-}" ]] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""; }; }
trap 'studio_stop; surreal_stop; stub_stop; rm -rf "$TMP"' EXIT
studio_init
. "$ROOT/tests/lib/surreal.sh"
surreal_bin
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não subiu"; }
PKG="$ROOT/docker/agent-studio"

# ---------------------------------------------------------------- o bucket de exemplo
# Partições (UTC) de oute-server: 2026-10-01 hora 12 (a de dentro), 2026-10-01 hora 13 (dentro, a de metrics), 2026-10-03
# hora 12 (fora), e as de folga: 2026-10-01 hora 10 e 2026-10-01 hora 14 entram na folga de 1 h da faixa 11:30–13:30.
# oute-mac tem a sua; o legado não tem host=.
B="$TMP/bucket/otel"
PYTHONPATH="$ROOT/tests/lib" python3 - "$B" <<'PY'
import gzip, json, os, sys
from otlp_json import canal_decided, canal_proposed, event, kv, queue_metrics, rl, rs, span
b = sys.argv[1]
T = 1790856000  # 2026-10-01T12:00:00Z

def put(sig, host, day_hour, name, obj, legacy=False):
    day, hour = day_hour
    d = f"{b}/{sig}/" + ("" if legacy else f"host={host}/instance=oute-agent/") + f"year=2026/month=10/day={day:02d}/hour={hour:02d}"
    os.makedirs(d, exist_ok=True)
    with gzip.open(f"{d}/{name}.json.gz", "wt") as f:
        json.dump(obj, f)

server = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "claude"}
mac = {"host.name": "oute-mac", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "codex"}
P1, P2 = "20261001-120000-reiniciar-nginx", "20261001-121000-listar-backups"
RND, S1 = "swarm-1001-1200", "11111111-1111-4111-8111-111111111111"
# hora 12: pedidos, uma rodada e uma sessão (o que o SurrealDB deriva)
put("logs", "oute-server", (1, 12), "logs_a", {"resourceLogs": [
    rl(server, [
        canal_proposed(T + 10, P1, "ev-p1", "Reiniciar nginx", "root", "systemctl reload nginx\n"),
        canal_proposed(T + 20, P2, "ev-p2", "Listar backups", "user", "ls /backup\n"),
        event(T + 30, "oute.swarm.round.opened", "ev-r1", {"oute.swarm.round": RND, "oute.swarm.repo": "oute-agent",
                                                           "oute.swarm.max": 3, "oute.swarm.label": "replay"}),
        event(T + 40, "oute.task.opened", "ev-t1", {"oute.task.id": S1, "oute.task.repo": "oute-agent",
                                                     "oute.task.slug": "159-replay", "oute.task.agent": "claude",
                                                     "oute.swarm.round": RND}),
    ]),
    rl({**server, "oute.agent": "human"}, [canal_decided(T + 60, P1, "ev-d1", "executado", None, **{"oute.canal.rc": 0})]),
]})
# a hora 13: um log só, e as métricas e os spans (outros sinais)
put("logs", "oute-server", (1, 13), "logs_b", {"resourceLogs": [rl(server, [event(T + 3700, "oute.exemplo", "ev-x1", {})])]})
put("logs", "oute-server", (3, 12), "logs_c", {"resourceLogs": [rl(server, [event(T + 2 * 86400, "oute.exemplo", "ev-fora", {})])]})
put("logs", "oute-server", (1, 10), "logs_d", {"resourceLogs": [rl(server, [event(T - 7200, "oute.exemplo", "ev-folga-antes", {})])]})
put("logs", "oute-server", (1, 14), "logs_e", {"resourceLogs": [rl(server, [event(T + 7300, "oute.exemplo", "ev-folga-depois", {})])]})
put("logs", "oute-server", (1, 8), "logs_f", {"resourceLogs": [rl(server, [event(T - 14400, "oute.exemplo", "ev-longe", {})])]})
put("logs", "oute-mac", (1, 12), "logs_g", {"resourceLogs": [rl(mac, [event(T + 90, "oute.exemplo", "ev-mac", {})])]})
put("logs", None, (1, 12), "logs_h", {"resourceLogs": [rl({"service.name": "oute"}, [event(T + 95, "oute.exemplo", "ev-legado", {})])]}, legacy=True)
put("metrics", "oute-server", (1, 12), "metrics_a", queue_metrics("oute-server", T + 100, 40))
put("traces", "oute-server", (1, 12), "traces_a", {"resourceSpans": [rs({**server, "oute.subscription": "zai"}, [span("claude_code.llm_request", T + 5, 2, {"model": "claude-sonnet-5"})])]})
# um .gz sem partição de hora no caminho (não dá para saber se está na faixa: ignorado, com aviso)
open(f"{b}/logs/host=oute-server/instance=oute-agent/solto.json.gz", "w").write("x")
# um objeto que não é gzip, uma pasta de outro tipo de arquivo (ignorada) e o da Archive (listado, mas ilegível)
os.makedirs(f"{b}/logs/host=oute-server/instance=oute-agent/year=2026/month=10/day=01/hour=12", exist_ok=True)
with open(f"{b}/logs/host=oute-server/instance=oute-agent/year=2026/month=10/day=01/hour=12/logs_nao-gzip.json.gz", "w") as f:
    f.write("isto não é gzip")
open(f"{b}/logs/host=oute-server/instance=oute-agent/year=2026/month=10/day=01/hour=12/LEIAME.txt", "w").write("x")
PY
ARCH="otel/logs/host=oute-server/instance=oute-agent/year=2026/month=10/day=01/hour=12/logs_archive.json.gz"
BAD_GZ="otel/logs/host=oute-server/instance=oute-agent/year=2026/month=10/day=01/hour=12/logs_nao-gzip.json.gz"

# ---------------------------------------------------------------- rclone e docker falsos
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/rclone" <<'SH'
#!/usr/bin/env bash
# bucket falso: $F_BUCKET/<prefixo>/...; só os subcomandos que o replay usa. Cada chamada vai ao $F_LOG (argv).
printf 'rclone %s\n' "$*" >> "$F_LOG"
[[ "${RCLONE_CONFIG_OCI_ACCESS_KEY_ID:-}" == "$F_EXPECT_KEY" ]] || { echo "sem a credencial do bucket no ambiente" >&2; exit 1; }
args=(); for a in "$@"; do case "$a" in -*) ;; *) args+=("$a") ;; esac; done
n=${#args[@]}   # o valor de --retries sobra no meio; origem e destino são os dois últimos
case "${args[0]}" in
  lsf) [[ "${F_LSF_FAIL:-}" == 1 ]] && { echo "AccessDenied" >&2; exit 5; }
       p="${args[n-1]#oci:*/}"; [[ -d "$F_BUCKET/$p" ]] || exit 3
       ( cd "$F_BUCKET/$p" && find . -type f | sed 's|^\./||' | sort ) ;;
  copyto) src="${args[n-2]#oci:*/}"
          if grep -qxF "$src" "$F_ARCHIVE" 2>/dev/null; then echo "InvalidObjectState: Archive" >&2; exit 1; fi
          cp "$F_BUCKET/$src" "${args[n-1]}" ;;
  *) exit 9 ;;
esac
SH
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
# docker falso: `ps` (o container está de pé) e `exec -i oute-agent-studio <python> -m agent_studio.replay <sinal>`,
# que roda o replay real com o ambiente do container (a credencial vem daqui, nunca do argv).
printf 'docker %s\n' "$*" >> "$F_LOG"
case "$1" in
  ps) [[ "${F_DOWN:-}" == 1 ]] || echo abc123 ;;
  exec) shift; [[ "$1" == -i && "$2" == oute-agent-studio ]] || exit 9
        [[ "$3" == /opt/agent-studio/venv/bin/python ]] || exit 9
        shift 3
        env AGENT_STUDIO_INGEST_TOKEN="$STUDIO_TOKEN" AGENT_STUDIO_PORT="$F_PORT" PYTHONPATH="$F_PKG" \
          AGENT_STUDIO_REPLAY_WAIT=0 "$F_PY" "$@" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN"/*
OCI_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
export F_LOG="$TMP/calls.log" F_BUCKET="$TMP/bucket" F_ARCHIVE="$TMP/archive.txt" F_EXPECT_KEY="$OCI_KEY"
: > "$F_LOG"; : > "$F_ARCHIVE"

# oute <args…>: o scripts/oute real, num ambiente só do teste (nada de credencial do host)
oute() {
  OUT="$(env -i PATH="$BIN:$PATH" HOME="$TMP/home" OUTE_HOME="$TMP/home/.oute" LANG=C.UTF-8 TMPDIR="$TMP" \
    OCI_S3_ACCESS_KEY="$OCI_KEY" OCI_S3_SECRET_KEY=segredo-do-teste OCI_S3_ENDPOINT=endpoint-do-teste OCI_S3_REGION=regiao-do-teste \
    OUTE_HOST=oute-teste F_LOG="$F_LOG" F_BUCKET="$F_BUCKET" F_ARCHIVE="$F_ARCHIVE" F_EXPECT_KEY="$F_EXPECT_KEY" \
    F_PORT="${F_PORT_OVERRIDE:-${STUDIO_URL##*:}}" F_PKG="$PKG" F_PY="$STUDIO_PY" STUDIO_TOKEN="$STUDIO_TOKEN" F_DOWN="${F_DOWN:-}" F_LSF_FAIL="${F_LSF_FAIL:-}" \
    ${OUTE_ENV[@]+"${OUTE_ENV[@]}"} "$TMP/repo/scripts/oute" "$@" 2>&1)"; RC=$?
}
# o scripts/oute roda de uma cópia, num checkout sem .env: o OUTE_AGENT_STUDIO do .env de quem roda o teste não entra
mkdir -p "$TMP/home/.oute" "$TMP/repo/scripts" "$TMP/repo/docker"
cp "$ROOT/scripts/oute" "$TMP/repo/scripts/oute"; cp "$ROOT/VERSION" "$TMP/repo/VERSION"
OUTE_ENV=(OUTE_AGENT_STUDIO=1)

# ---------------------------------------------------------------- agent-studio + SurrealDB de verdade
SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml")
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
count() { studio_sql "$TMP/s/db.duckdb" "SELECT count(*) AS n FROM $1" | jq -r .n; }
counts() { echo "logs=$(count logs) spans=$(count spans) metrics=$(count metrics)"; }
# sem o namespace (SurrealDB recém-esvaziado) a resposta é um texto de erro: conta 0
sstate() { surreal_q "SELECT count() FROM $1 GROUP ALL" | jq -r 'try (.[0].count) // 0'; }
# o DuckDB só abre para leitura com o servidor parado: para contar, para o serviço e sobe de novo (mesmo arquivo)
restart_studio() { studio_stop; studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não voltou"; }; }
# count_now: define NOW_COUNTS (sem subshell: o studio_stop e o studio_start mexem no STUDIO_PID)
count_now() { studio_stop; NOW_COUNTS="$(counts)"; studio_start "$TMP/s" "${SENV[@]}" || die "agent-studio não voltou"; }

# ---------------------------------------------------------------- 1. replay completo: DuckDB vazio = N linhas
count_now
check "banco começa vazio" test "$NOW_COUNTS" = "logs=0 spans=0 metrics=0"
# logs de dentro: a (4 logs de oute-server + 1 decided = 5), b (1), d e e (folga, 1 cada), g? (oute-mac fora com --host)
oute studio replay --from 2026-10-01T11:30:00Z --to 2026-10-01T13:30:00Z --host oute-server
check "replay de oute-server: rc 1 pelo objeto que não é gzip, o resto entra" test "$RC" = 1
check "resumo de logs: 5 objetos de oute-server na faixa (a, b, d, e e o não-gzip), gravados 8, 1 falhou" \
  has_line "logs: objetos lidos=5 gravados=8 repetidos=0 falharam=1"
check "resumo de traces: 1 objeto, 1 gravado"  has_line "traces: objetos lidos=1 gravados=1 repetidos=0 falharam=0"
check "resumo de metrics: 1 objeto, 2 gravados" has_line "metrics: objetos lidos=1 gravados=2 repetidos=0 falharam=0"
check "objeto sem partição de hora no caminho: ignorado, com aviso" has_line "logs: 1 objeto(s) sem partição de hora no caminho, ignorados"
check "o objeto que não é gzip é dito, sem o conteúdo" bash -c 'grep -qF "logs: falhou no replay (rc 2): $1" <<<"$2" && ! grep -q "isto não é" <<<"$2"' _ "$BAD_GZ" "$OUT"
studio_stop; EV="$(studio_sql "$TMP/s/db.duckdb" "SELECT oute_event_id AS id FROM logs" | jq -r .id)"
studio_start "$TMP/s" "${SENV[@]}" || die "agent-studio não voltou"
check "folga de 1 h: as partições das 10h e das 14h entraram" bash -c 'grep -qx ev-folga-antes <<<"$1" && grep -qx ev-folga-depois <<<"$1"' _ "$EV"
check "fora da faixa e da folga: a das 8h, a de dois dias depois, oute-mac e o legado não entraram" \
  bash -c '! grep -qxE "ev-longe|ev-fora|ev-mac|ev-legado" <<<"$1"' _ "$EV"
count_now; N="$NOW_COUNTS"
check "DuckDB: 8 logs, 1 span e 2 métricas" test "$N" = "logs=8 spans=1 metrics=2"
studio_stop; SUBS="$(studio_sql "$TMP/s/db.duckdb" "SELECT oute_subscription AS s FROM spans" | jq -r .s)"
studio_start "$TMP/s" "${SENV[@]}" || die "agent-studio não voltou"
check "o replay remontou a assinatura do span (#679)" test "$SUBS" = zai
check "pedidos, rodada e sessão no SurrealDB" bash -c '[ "$1" = 2 ] && [ "$2" = 1 ] && [ "$3" = 1 ]' _ "$(sstate pedido)" "$(sstate rodada)" "$(sstate sessao)"
check "o pedido decidido vem decidido" test "$(surreal_q 'SELECT state FROM pedido:`20261001-120000-reiniciar-nginx`' | jq -r '.[0].state')" = decidido

# ---------------------------------------------------------------- 2. segunda vez: 0 novas
oute studio replay --from 2026-10-01T11:30:00Z --to 2026-10-01T13:30:00Z --host oute-server
check "segunda vez: nada gravado, tudo repetido" has_line "logs: objetos lidos=5 gravados=0 repetidos=8 falharam=1"
check "segunda vez: traces e metrics repetidos" bash -c 'grep -qxF "traces: objetos lidos=1 gravados=0 repetidos=1 falharam=0" <<<"$1" && grep -qxF "metrics: objetos lidos=1 gravados=0 repetidos=2 falharam=0" <<<"$1"' _ "$OUT"
count_now
check "segunda vez: o DuckDB não ganhou linha" test "$NOW_COUNTS" = "$N"

# ---------------------------------------------------------------- 3. SurrealDB esvaziado, DuckDB intacto
studio_stop; surreal_stop; rm -rf "${TMP:?}/sdb/data"
surreal_start "$TMP/sdb" || die "SurrealDB não voltou"
studio_start "$TMP/s" "${SENV[@]}" || die "agent-studio não voltou"
check "SurrealDB esvaziado: sem pedidos" test "$(sstate pedido)" = 0
oute studio replay --from 2026-10-01T11:30:00Z --to 2026-10-01T13:30:00Z --host oute-server --signal logs
check "replay com o DuckDB intacto: nada novo no DuckDB (8 repetidos)" has_line "logs: objetos lidos=5 gravados=0 repetidos=8 falharam=1"
check "pedidos, rodada e sessão voltaram" bash -c '[ "$1" = 2 ] && [ "$2" = 1 ] && [ "$3" = 1 ]' _ "$(sstate pedido)" "$(sstate rodada)" "$(sstate sessao)"
check "o decidido voltou decidido, com o rc" test "$(surreal_q 'SELECT state, rc FROM pedido:`20261001-120000-reiniciar-nginx`' | jq -c '.[0] | [.state, .rc]')" = '["decidido",0]'
check "o pendente voltou pendente" test "$(surreal_q 'SELECT state FROM pedido:`20261001-121000-listar-backups`' | jq -r '.[0].state')" = pendente
check "só logs: o replay não tocou em traces nem metrics" bash -c '! grep -q "^traces:\|^metrics:" <<<"$1"' _ "$OUT"

# ---------------------------------------------------------------- 4. filtros: host, legado, sinal, faixa
oute studio replay --from 2026-10-01 --to 2026-10-02 --signal logs
check "sem --host: o dia 1 inteiro, com oute-mac e a partição das 8h (legado não): 7 objetos, 2 novos" \
  has_line "logs: objetos lidos=7 gravados=2 repetidos=8 falharam=1"
count_now
check "o legado ficou de fora sem --legacy" test "$NOW_COUNTS" = "logs=10 spans=1 metrics=2"
oute studio replay --from 2026-10-01 --to 2026-10-02 --signal logs --legacy
check "--legacy: o objeto sem host= entra (1 gravado a mais)" has_line "logs: objetos lidos=8 gravados=1 repetidos=10 falharam=1"
oute studio replay --from 2026-10-03 --to 2026-10-04 --host oute-server --signal logs
check "faixa do dia 3: só a partição do dia 3" has_line "logs: objetos lidos=1 gravados=1 repetidos=0 falharam=0"
check "o replay do dia 3 não listou os outros sinais" bash -c '! grep -q "^traces:\|^metrics:" <<<"$1"' _ "$OUT"
oute studio replay --from 2026-10-01T12:00:00Z --to 2026-10-01T12:30:00Z --host oute-server --signal metrics
check "faixa curta dentro de uma hora: a partição dela entra (e as vizinhas, pela folga)" has_line "metrics: objetos lidos=1 gravados=0 repetidos=2 falharam=0"
oute studio replay --from 2026-09-01 --to 2026-09-02 --host oute-server --signal traces
check "faixa sem objetos: lidos=0, rc 0" bash -c '[ "$1" = 0 ] && grep -qxF "traces: objetos lidos=0 gravados=0 repetidos=0 falharam=0" <<<"$2"' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 5. objeto ilegível (Archive)
cp "$B/logs/host=oute-server/instance=oute-agent/year=2026/month=10/day=01/hour=12/logs_a.json.gz" "$F_BUCKET/$ARCH"
echo "$ARCH" > "$F_ARCHIVE"
oute studio replay --from 2026-10-01T12:00:00Z --to 2026-10-01T12:30:00Z --host oute-server --signal logs
check "Archive: listado e pulado, com o objeto dito" has_line "logs: objeto ilegível, pulado (Archive? restaure antes: ADR-08 §7): $ARCH"
check "Archive: rc ≠ 0 no fim" test "$RC" != 0
check "Archive: os outros objetos seguiram (a e b repetidos); 2 falhas: o Archive e o não-gzip" has_line "logs: objetos lidos=4 gravados=0 repetidos=6 falharam=2"

# ---------------------------------------------------------------- 5b. listagem: sem o prefixo do sinal e com erro do rclone
mv "$B/traces" "$TMP/traces-fora"
oute studio replay --from 2026-10-01 --to 2026-10-02 --signal traces
check "sinal sem nenhum objeto no bucket (rclone rc 3): lidos=0, rc 0" bash -c '[ "$1" = 0 ] && grep -qxF "traces: objetos lidos=0 gravados=0 repetidos=0 falharam=0" <<<"$2"' _ "$RC" "$OUT"
mv "$TMP/traces-fora" "$B/traces"
F_LSF_FAIL=1 oute studio replay --from 2026-10-01 --to 2026-10-02 --signal traces
check "rclone que não lista (rc 5): erro dito, rc 1, nada reenviado" bash -c '[ "$1" = 1 ] && grep -q "traces: não consegui listar oci:oute-observability/otel/traces (rclone rc 5)" <<<"$2" && ! grep -q "^traces: objetos" <<<"$2"' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 6. erros de uso e de ambiente
OUTE_ENV=(OUTE_X=); oute studio replay --from 2026-10-01 --to 2026-10-02
check "fora do host com o agent-studio: erro claro, rc 1, nada listado" bash -c '[ "$1" = 1 ] && grep -q "só roda no host com o agent-studio (OUTE_AGENT_STUDIO=1" <<<"$2"' _ "$RC" "$OUT"
OUTE_ENV=(OUTE_AGENT_STUDIO=1)
before="$(wc -l < "$F_LOG")"
oute studio replay --from 2026-10-02 --to 2026-10-01
check "--from depois de --to: rc 2" test "$RC" = 2
oute studio replay --from ontem --to 2026-10-01
check "--from inválido: rc 2 e diz o formato" bash -c '[ "$1" = 2 ] && grep -q "ISO 8601" <<<"$2"' _ "$RC" "$OUT"
oute studio replay --from 2026-10-01 --to 2026-13-01
check "--to com mês 13: rc 2" test "$RC" = 2
oute studio replay --from 2026-10-01
check "sem --to: rc 2" test "$RC" = 2
oute studio replay --from 2026-10-01 --to 2026-10-02 --signal xyz
check "--signal desconhecido: rc 2" test "$RC" = 2
oute studio replay --from 2026-10-01 --to 2026-10-02 --host '../x'
check "--host com barra: rc 2" test "$RC" = 2
oute studio replay --from 2026-10-01 --to 2026-10-02 --nada
check "opção desconhecida: rc 2" test "$RC" = 2
oute studio outra
check "oute studio sem replay: rc 2" test "$RC" = 2
check "nenhum erro de uso chegou ao rclone nem ao docker" test "$(wc -l < "$F_LOG")" = "$before"
F_DOWN=1 oute studio replay --from 2026-10-01 --to 2026-10-02
check "agent-studio fora do ar: erro claro, rc 1" bash -c '[ "$1" = 1 ] && grep -q "oute-agent-studio não está de pé" <<<"$2"' _ "$RC" "$OUT"
F_DOWN=""
OUTE_ENV=(OUTE_AGENT_STUDIO=1 OCI_S3_ACCESS_KEY=)
oute studio replay --from 2026-10-01 --to 2026-10-02
check "sem a credencial do bucket: erro claro, rc 1" bash -c '[ "$1" = 1 ] && grep -q "oci-storage ausente" <<<"$2"' _ "$RC" "$OUT"
OUTE_ENV=(OUTE_AGENT_STUDIO=1)

# ---------------------------------------------------------------- 7. a credencial nunca em argv nem em log
check "a credencial de ingestão não aparece em argv (rclone e docker)" bash -c '! grep -qF "$1" "$2"' _ "$STUDIO_TOKEN" "$F_LOG"
check "a credencial do bucket não aparece em argv" bash -c '! grep -qF "$1" "$2"' _ "$OCI_KEY" "$F_LOG"
check "nem na saída do comando" bash -c '! grep -qF "$1" <<<"$2"' _ "$STUDIO_TOKEN" "$OUT"
check "o replay passa o objeto pelo stdin (docker exec -i), com o python do venv" bash -c 'grep -qF "docker exec -i oute-agent-studio /opt/agent-studio/venv/bin/python -m agent_studio.replay logs" "$1"' _ "$F_LOG"
check "o rclone só lê (lsf e copyto)" bash -c '! grep "^rclone" "$1" | grep -vE "^rclone (lsf|copyto) "' _ "$F_LOG"
check "a pasta temporária do replay foi removida" bash -c '! ls "$1"/oute-replay.* >/dev/null 2>&1' _ "$TMP"

# ---------------------------------------------------------------- 8. lote > 64 MB partido por resource
studio_stop; studio_start "$TMP/s2" "${SENV[@]}" AGENT_STUDIO_SURREAL_URL= || die "agent-studio (2) não subiu"
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import gzip, json, sys
from otlp_json import event, kv, rl
tmp, T = sys.argv[1], 1790856000
big = "x" * (23 * 1024 * 1024)   # 3 resources de 23 MB = 69 MB > 64 MiB, cada um cabe sozinho
batch = {"resourceLogs": [rl({"host.name": f"oute-big-{i}", "oute.instance": "oute-agent", "service.name": "oute"},
                              [event(T + i, "oute.big", f"ev-big-{i}", {}, big + str(i))]) for i in range(3)]}
raw = json.dumps(batch, separators=(",", ":"), ensure_ascii=False).encode()
assert len(raw) > 64 * 1024 * 1024, len(raw)
open(f"{tmp}/big.json.gz", "wb").write(gzip.compress(raw, 1))
PY
BIGOUT="$(env AGENT_STUDIO_INGEST_TOKEN="$STUDIO_TOKEN" AGENT_STUDIO_PORT="${STUDIO_URL##*:}" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.replay logs < "$TMP/big.json.gz" 2>"$TMP/big.err")"; BIGRC=$?
check "lote de 69 MB: partido por resource, entra (rc 0, 3 gravados)" bash -c '[ "$1" = 0 ] && [ "$2" = "written=3 duplicate=0 failed=0" ]' _ "$BIGRC" "$BIGOUT"
BIGOUT="$(env AGENT_STUDIO_INGEST_TOKEN="$STUDIO_TOKEN" AGENT_STUDIO_PORT="${STUDIO_URL##*:}" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.replay logs < "$TMP/big.json.gz" 2>/dev/null)"
check "o lote grande de novo: 3 repetidos" test "$BIGOUT" = "written=0 duplicate=3 failed=0"
check "o lote grande inteiro, sem partir, a ingestão recusa com 413 (por isso o replay parte)" \
  test "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $STUDIO_TOKEN" -H 'Content-Type: application/json' -H 'Content-Encoding: gzip' --data-binary "@$TMP/big.json.gz" "$STUDIO_URL/v1/logs")" = 413

# ---------------------------------------------------------------- 9. replay.py direto: 400, 503, serviço fora, uso
export STUB_TOKEN="$STUDIO_TOKEN"
python3 - "$TMP/stub" <<'PY' &
import http.server, json, os, sys, threading
state = {"n503": 0, "mode": "ok", "calls": 0}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        state["calls"] += 1
        mode = open(sys.argv[1] + ".mode").read().strip()
        if mode != state.get("last"):  # cada modo conta as suas chamadas desde o início
            state.update(last=mode, calls=1, n503=0)
        if mode == "503x2" and state["n503"] < 2:
            state["n503"] += 1; self.send_response(503); self.send_header("Retry-After", "0"); self.end_headers(); return
        if mode == "503":
            self.send_response(503); self.send_header("Retry-After", "0"); self.end_headers(); return
        if mode == "400" or (mode == "400first" and state["calls"] == 1):
            self.send_response(400); self.end_headers(); self.wfile.write(b'{"message":"SEGREDO-NA-RESPOSTA"}'); return
        self.send_response(200); self.send_header("X-Agent-Studio-Written", "1"); self.send_header("X-Agent-Studio-Duplicate", "0"); self.end_headers(); self.wfile.write(b"{}")
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
STUB_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/stub.port" ]] && break; sleep 0.1; done
SP="$(cat "$TMP/stub.port")"
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import gzip, json, sys
from otlp_json import event, rl
tmp = sys.argv[1]
one = {"resourceLogs": [rl({"host.name": "h"}, [event(1790856000, "oute.x", "ev-x", {})])]}
open(f"{tmp}/one.json.gz", "wb").write(gzip.compress(json.dumps(one).encode()))
open(f"{tmp}/one.json", "w").write(json.dumps(one))
# dois resources: um parte em duas requisições quando o teto é baixo (só a lógica de partir)
two = {"resourceLogs": [rl({"host.name": "a"}, [event(1790856000, "oute.x", "ev-a", {})]),
                         rl({"host.name": "b"}, [event(1790856001, "oute.x", "ev-b", {})])]}
open(f"{tmp}/two.json", "w").write(json.dumps(two))
PY
rp() { # rp <modo> <arquivo> [env…]: roda o replay contra o servidor falso; define RPOUT, RPERR e RPRC
  echo "$1" > "$TMP/stub.mode"; local f="$2"; shift 2
  RPOUT="$(env AGENT_STUDIO_INGEST_TOKEN="$STUDIO_TOKEN" AGENT_STUDIO_PORT="$SP" PYTHONPATH="$PKG" AGENT_STUDIO_REPLAY_WAIT=0 "$@" \
    "$STUDIO_PY" -m agent_studio.replay logs < "$f" 2>"$TMP/rp.err")"; RPRC=$?; RPERR="$(cat "$TMP/rp.err")"
}
rp ok "$TMP/one.json.gz"
check "ingestão ok: rc 0 e a contagem do cabeçalho" bash -c '[ "$1" = 0 ] && [ "$2" = "written=1 duplicate=0 failed=0" ]' _ "$RPRC" "$RPOUT"
rp ok "$TMP/one.json"
check "JSON puro (sem gzip) também vale" test "$RPRC:$RPOUT" = "0:written=1 duplicate=0 failed=0"
rp 503x2 "$TMP/one.json.gz"
check "503 duas vezes e depois ok: espera, repete e entra (rc 0)" test "$RPRC:$RPOUT" = "0:written=1 duplicate=0 failed=0"
check "503: o replay avisou que repetia" bash -c 'grep -q "espero e repito" <<<"$1"' _ "$RPERR"
rp 503 "$TMP/one.json.gz" AGENT_STUDIO_REPLAY_TRIES=3
check "503 sem parar: desiste depois das tentativas, failed=1, rc 1" test "$RPRC:$RPOUT" = "1:written=0 duplicate=0 failed=1"
check "503 sem parar: diz quantas tentativas" bash -c 'grep -q "depois de 3 tentativas" <<<"$1"' _ "$RPERR"
rp 400 "$TMP/one.json.gz"
check "400: conta e sai ≠ 0 (failed=1)" test "$RPRC:$RPOUT" = "1:written=0 duplicate=0 failed=1"
check "400: nada da resposta do servidor vai ao stderr" bash -c '! grep -q SEGREDO <<<"$1" && grep -q "HTTP 400" <<<"$1"' _ "$RPERR"
rp 400first "$TMP/two.json" AGENT_STUDIO_REPLAY_MAX_BYTES=200
check "400 numa parte: segue com as outras (1 entrou, 1 falhou) e sai ≠ 0" test "$RPRC:$RPOUT" = "1:written=1 duplicate=0 failed=1"
rp ok "$TMP/one.json.gz" AGENT_STUDIO_PORT=1 AGENT_STUDIO_REPLAY_TRIES=2
check "serviço fora (porta fechada): failed=1, rc 1" test "$RPRC:$RPOUT" = "1:written=0 duplicate=0 failed=1"
rp ok "$TMP/one.json.gz" AGENT_STUDIO_INGEST_TOKEN=
check "sem credencial no ambiente: rc 2" test "$RPRC" = 2
rp ok /dev/null
check "stdin vazio: rc 2, objeto ilegível" bash -c '[ "$1" = 2 ] && grep -q "ilegível" <<<"$2"' _ "$RPRC" "$RPERR"
printf '[1,2]' > "$TMP/arr.json"; rp ok "$TMP/arr.json"
check "JSON que não é objeto: rc 2" test "$RPRC" = 2
# o resumo do `oute studio replay` quando a ingestão recusa (400): o objeto conta como falha e a saída é rc 1
echo 400 > "$TMP/stub.mode"
F_PORT_OVERRIDE="$SP" oute studio replay --from 2026-10-01T12:00:00Z --to 2026-10-01T12:30:00Z --host oute-server --signal metrics
check "ingestão que recusa (400): objeto conta como falha, dito pela chave, rc 1" bash -c '[ "$1" = 1 ] && grep -qxF "metrics: objetos lidos=1 gravados=0 repetidos=0 falharam=1" <<<"$2" && grep -q "^metrics: falhou no replay: otel/metrics/host=oute-server/.*metrics_a.json.gz$" <<<"$2"' _ "$RC" "$OUT"
echo ok > "$TMP/stub.mode"
check "uso: sem sinal = rc 2" bash -c 'env AGENT_STUDIO_INGEST_TOKEN=x PYTHONPATH="$1" "$2" -m agent_studio.replay </dev/null 2>/dev/null; [ $? = 2 ]' _ "$PKG" "$STUDIO_PY"
check "uso: sinal desconhecido = rc 2" bash -c 'env AGENT_STUDIO_INGEST_TOKEN=x PYTHONPATH="$1" "$2" -m agent_studio.replay nada </dev/null 2>/dev/null; [ $? = 2 ]' _ "$PKG" "$STUDIO_PY"

# a lógica de partir (sem rede): por resource, por scope e o que não cabe nem assim
PYTHONPATH="$PKG:$ROOT/tests/lib" "$STUDIO_PY" - >"$TMP/split.out" <<'PY'
import json
from agent_studio import replay
def check(d, c):
    print(("ok   " if c else "FAIL ") + d)
res = lambda n, size: {"resource": {"attributes": []}, "scopeLogs": [{"logRecords": [{"body": {"stringValue": "x" * size}}]}]}
b = {"resourceLogs": [res(i, 100) for i in range(5)]}
check("lote pequeno não é partido", len(replay.split(b, "logs")) == 1)
parts = replay.split(b, "logs", limit=len(json.dumps(b, separators=(",", ":"))) - 1)
check("lote acima do teto vira mais de uma parte", len(parts) > 1)
check("nenhum resource se perde nem se repete", sum(len(p["resourceLogs"]) for p in parts) == 5)
check("cada parte cabe no teto", all(replay._size(p) <= len(json.dumps(b, separators=(",", ":"))) - 1 for p in parts))
one = {"resourceLogs": [{"resource": {"attributes": []}, "scopeLogs": [{"logRecords": [{"body": {"stringValue": "x" * 50}}]} for _ in range(4)]}]}
parts = replay.split(one, "logs", limit=replay._size(one) // 2 + 60)
check("um resource que sozinho passa do teto parte por scope", len(parts) > 1 and all(len(p["resourceLogs"]) == 1 for p in parts))
check("nenhum scope se perde", sum(len(p["resourceLogs"][0]["scopeLogs"]) for p in parts) == 4)
solo = {"resourceLogs": [res(0, 1000)]}
check("o que não cabe nem por scope sai inteiro (a ingestão dirá 413)", len(replay.split(solo, "logs", limit=100)) == 1)
check("lote sem a lista do sinal não quebra", replay.split({"x": 1}, "logs", limit=1) == [{"x": 1}])
PY
check_py_lines "$TMP/split.out"

# ---------------------------------------------------------------- 10. a ingestão devolve as contagens
studio_stop; studio_start "$TMP/s3" "${SENV[@]}" AGENT_STUDIO_SURREAL_URL= || die "agent-studio (3) não subiu"
H1="$(curl -s -D - -o /dev/null -X POST -H "Authorization: Bearer $STUDIO_TOKEN" -H 'Content-Type: application/json' --data-binary "@$TMP/one.json" "$STUDIO_URL/v1/logs" | tr -d '\r')"
H2="$(curl -s -D - -o /dev/null -X POST -H "Authorization: Bearer $STUDIO_TOKEN" -H 'Content-Type: application/json' --data-binary "@$TMP/one.json" "$STUDIO_URL/v1/logs" | tr -d '\r')"
check "ingestão: a primeira vez devolve gravados=1, repetidos=0" bash -c 'grep -qi "^x-agent-studio-written: 1" <<<"$1" && grep -qi "^x-agent-studio-duplicate: 0" <<<"$1"' _ "$H1"
check "ingestão: a segunda devolve gravados=0, repetidos=1" bash -c 'grep -qi "^x-agent-studio-written: 0" <<<"$1" && grep -qi "^x-agent-studio-duplicate: 1" <<<"$1"' _ "$H2"

# ---------------------------------------------------------------- 11. o acerto do histórico sem repositório vale no replay (#617)
# A mesma entrada do tests/agent-studio-repo-corte.test.sh, agora pelo `agent_studio.replay` real contra a ingestão: fato sem
# repositório antes de 2026-10-06T00:00:00Z entra com `oute-agent`; depois do corte segue NULL; repositório próprio fica.
studio_stop; studio_start "$TMP/s4" "${SENV[@]}" AGENT_STUDIO_SURREAL_URL= || die "agent-studio (4) não subiu"
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import gzip, json, sys
from otlp_json import event, kv, rl, rs, span
tmp = sys.argv[1]
OLD, NEW = 1791201600, 1791374400   # 2026-10-05T12:00:00Z (antes do corte) e 2026-10-07T12:00:00Z (depois)
res = {"host.name": "h-corte", "service.name": "oute"}   # sem oute.task.repo
own = {**res, "oute.task.repo": "alfa"}


def put(name, obj):
    open(f"{tmp}/corte-{name}.json.gz", "wb").write(gzip.compress(json.dumps(obj).encode()))


def call(t, conv):
    return span("claude_code.llm_request", t, 2, {"model": "claude-sonnet-5", "session.id": conv})


def point(t, name):
    return {"name": name, "gauge": {"dataPoints": [{"timeUnixNano": str(t * 10**9), "asInt": "1", "attributes": []}]}}


put("traces", {"resourceSpans": [rs(res, [call(OLD, "velha"), call(NEW, "nova")]), rs(own, [call(OLD, "propria")])]})
put("logs", {"resourceLogs": [rl(res, [event(OLD, "oute.exemplo", "ev-velha", {}), event(NEW, "oute.exemplo", "ev-nova", {})]),
                              rl(own, [event(OLD, "oute.exemplo", "ev-propria", {})])]})
put("metrics", {"resourceMetrics": [{"resource": {"attributes": kv(res)}, "scopeMetrics": [{"metrics": [point(OLD, "m.velha"), point(NEW, "m.nova")]}]},
                                    {"resource": {"attributes": kv(own)}, "scopeMetrics": [{"metrics": [point(OLD, "m.propria")]}]}]})
PY
CORTE_OUT=""
for sig in traces logs metrics; do
  CORTE_OUT+="$sig: $(env AGENT_STUDIO_INGEST_TOKEN="$STUDIO_TOKEN" AGENT_STUDIO_PORT="${STUDIO_URL##*:}" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.replay "$sig" < "$TMP/corte-$sig.json.gz" 2>>"$TMP/corte.err")"$'\n'
done
check "replay do corte: os três sinais entram (3 gravados cada)" test "$CORTE_OUT" = $'traces: written=3 duplicate=0 failed=0\nlogs: written=3 duplicate=0 failed=0\nmetrics: written=3 duplicate=0 failed=0\n'
# as três tabelas numa leitura só: <tabela> <chave do exemplo> <oute_repo ou NULL> <o JSON do resource tem oute.task.repo?>
CORTE_JSON="json_extract_string(resource_attributes, '\$.\"oute.task.repo\"') IS NOT NULL"
CORTE_SQL="SELECT 'spans' AS tab, session_id AS k, coalesce(oute_repo, 'NULL') AS r, $CORTE_JSON AS j FROM spans
  UNION ALL SELECT 'logs', oute_event_id, coalesce(oute_repo, 'NULL'), $CORTE_JSON FROM logs
  UNION ALL SELECT 'metrics', metric_name, coalesce(oute_repo, 'NULL'), $CORTE_JSON FROM metrics"
studio_stop; CORTE="$(studio_sql "$TMP/s4/db.duckdb" "$CORTE_SQL" | jq -r '[.tab, .k, .r, (.j | tostring)] | join(" ")' | sort)"
CORTE_WANT="logs ev-nova NULL false
logs ev-propria alfa true
logs ev-velha oute-agent false
metrics m.nova NULL false
metrics m.propria alfa true
metrics m.velha oute-agent false
spans nova NULL false
spans propria alfa true
spans velha oute-agent false"
check "replay: antes do corte sem repositório = oute-agent; depois = NULL; repositório próprio fica; o JSON do resource não muda" test "$CORTE" = "$CORTE_WANT"
# a subida em cima do que o replay gravou, e o replay de novo: nada muda
studio_start "$TMP/s4" "${SENV[@]}" AGENT_STUDIO_SURREAL_URL= || die "agent-studio (4) não voltou"
CORTE_OUT="$(env AGENT_STUDIO_INGEST_TOKEN="$STUDIO_TOKEN" AGENT_STUDIO_PORT="${STUDIO_URL##*:}" PYTHONPATH="$PKG" "$STUDIO_PY" -m agent_studio.replay traces < "$TMP/corte-traces.json.gz" 2>>"$TMP/corte.err")"
check "replay do corte de novo: tudo repetido" test "$CORTE_OUT" = "written=0 duplicate=3 failed=0"
studio_stop
check "depois da subida e do replay repetido: as mesmas linhas, com o mesmo repositório" \
  test "$(studio_sql "$TMP/s4/db.duckdb" "$CORTE_SQL" | jq -r '[.tab, .k, .r, (.j | tostring)] | join(" ")' | sort)" = "$CORTE_WANT"

check_end
