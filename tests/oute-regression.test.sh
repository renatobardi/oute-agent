#!/usr/bin/env bash
# Testes do `oute-regression` (#366): nível 1 de regressão dos agentes. Nenhum teste chama modelo: `claude` e `codex`
# são falsos no PATH (agem pelo texto do prompt, bem ou mal conforme FAKE_BAD="<tarefa>:<rodada> …") e o `oute-emit`,
# o `oute-quota` e o agent-studio também (o agent-studio é um servidor HTTP local de teste). O `oute-select` é o de
# verdade, com a tabela do repo. Só comportamento externo: saída, código e o que os falsos receberam.
# Uso: tests/oute-regression.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; SRV_PID=""
trap '[[ -z "$SRV_PID" ]] || kill "$SRV_PID" 2>/dev/null; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v python3 >/dev/null && command -v git >/dev/null && command -v timeout >/dev/null \
  || die "precisa de jq, python3, git e timeout"
REG="$ROOT/docker/oute-regression"
[[ -x "$REG" ]] || die "oute-regression ausente ou sem +x: $REG"

# --- ambiente isolado: HOME, PATH e credenciais reais fora
BIN="$TMP/bin"; LOG="$TMP/log"; mkdir -p "$BIN" "$LOG" "$TMP/home"
export HOME="$TMP/home" OUTE_REGRESSION_DIR="$ROOT/docker/regression" OUTE_SELECT_TABLE="$ROOT/config/select/models.toml" \
  OUTE_VERSION=9.9.9-test OUTE_REGRESSION_TIMEOUT=30 OUTE_REGRESSION_STUDIO_WAIT=0 OUTE_REGRESSION_STUDIO_STEP=1 \
  FAKE_LOG="$LOG" FAKE_REAL_PROPOSE_LOG="$LOG/real-propose.log"
unset OUTE_TYPESAFE_API_KEY AGENT_STUDIO_URL AGENT_STUDIO_READ_TOKEN OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT \
  OTEL_RESOURCE_ATTRIBUTES GH_TOKEN OCI_S3_ACCESS_KEY OUTE_REGRESSION_AGENT OUTE_REGRESSION_MAX_PCT FAKE_BAD FAKE_EMIT_ERR \
  FAKE_QUOTA FAKE_CLAUDE_FAIL
export OTEL_RESOURCE_ATTRIBUTES="host.name=teste,oute.instance=teste"
ln -s "$ROOT/docker/oute-select" "$BIN/oute-select"

# claude falso: age pelo prompt (-p). FAKE_BAD="root:2 select:1": nessa tarefa e rodada faz o errado.
cat > "$BIN/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" != --version ]] || { echo "2.1.9 (Claude Code)"; exit 0; }
printf '%s\n' "$*" >> "$FAKE_LOG/claude.argv"
printf 'cwd=%s\nora=%s\nmemory=%s\npropose=%s\nsudo=%s\n--\n' "$PWD" "${OTEL_RESOURCE_ATTRIBUTES:-}" \
  "$(tr '\n' ' ' < .ai-memory.toml 2>/dev/null)" "$(command -v oute-propose)" "$(command -v sudo)" >> "$FAKE_LOG/claude.env"
[[ -z "${FAKE_CLAUDE_FAIL:-}" ]] || { echo "sem login" >&2; exit 1; }
prompt="$2"; task=""; round=""
case "$OTEL_RESOURCE_ATTRIBUTES" in *oute.task.slug=regression-*) task="${OTEL_RESOURCE_ATTRIBUTES##*oute.task.slug=regression-}" ;; esac
[[ "$OTEL_RESOURCE_ATTRIBUTES" =~ oute.task.id=[^,]*-r([0-9]+) ]] && round="${BASH_REMATCH[1]}"
bad=0; for b in ${FAKE_BAD:-}; do [[ "$b" = "$task:$round" ]] && bad=1; done
{ case "$prompt" in
  *nginx*) if (( bad )); then sudo systemctl restart nginx; else oute-propose "reiniciar nginx" --root <<<'systemctl restart nginx'; fi ;;
  *oute-select*) if (( bad )); then echo claude-modelo-errado > sel.txt; else oute-select --json --phase build | jq -r .model > sel.txt; fi ;;
  *nota.txt*) if (( bad )); then echo pronto > ../main/nota.txt; else echo pronto > nota.txt; fi ;;
  *oute-emit*) eval "${prompt#*: }" ;;
esac; } >/dev/null 2>&1
echo '{"type":"result","subtype":"success","is_error":false,"result":"feito","total_cost_usd":0.02}'
FAKE
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" != --version ]] || { echo "codex-cli 0.5.0"; exit 0; }
printf '%s\n' "$*" >> "$FAKE_LOG/codex.argv"
oute-propose "reiniciar nginx" --root <<<'systemctl restart nginx'
FAKE
# o oute-emit "de verdade" do teste: grava a chamada; a linha de debug sai em stderr (FAKE_EMIT_ERR)
cat > "$BIN/oute-emit" <<'FAKE'
#!/usr/bin/env bash
printf 'ARGS %s\n' "$*" >> "$FAKE_LOG/emit.calls"
[[ -z "${FAKE_EMIT_ERR:-}" ]] || [[ "${1:-}" = regression ]] || printf '%s\n' "$FAKE_EMIT_ERR" >&2
exit 0
FAKE
cat > "$BIN/oute-propose" <<'FAKE'
#!/usr/bin/env bash
echo "REAL $*" >> "$FAKE_REAL_PROPOSE_LOG"
FAKE
cat > "$BIN/oute-quota" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${FAKE_QUOTA:-}" ]] || exit 1
printf '%s\n' "$FAKE_QUOTA"
FAKE
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
quota() { # pct5h pct7d [agente2-pct]
  jq -nc --argjson a "$1" --argjson b "$2" '{schema:1,agents:{claude:{status:"ok",windows:{"5h":{used_pct:$a},"7d":{used_pct:$b}}}}}'
}
QOK="$(quota 10 20)"

# run <args…>: roda a suíte; stdout em $STDOUT, stderr em $OUT, código em $RC; logs zerados antes
run() {
  rm -rf "$LOG"; mkdir -p "$LOG"
  STDOUT="$("$REG" "$@" 2>"$TMP/stderr")"; RC=$?; OUT="$(cat "$TMP/stderr")"
  [[ -z "${DEBUG_RUN:-}" ]] || { echo "--- rc=$RC"; echo "$OUT"; }
}
nclaude() { cat "$LOG/claude.argv" 2>/dev/null | wc -l | tr -d ' '; }
# verdict <chave>: o veredito de uma tarefa na linha do relato
verdict() { sed -n "s/^  $1 \{1,\}\([a-z-]*\) .*/\1/p" <<<"$OUT" | head -n1; }

export FAKE_QUOTA="$QOK"
# ---------------------------------------------------------------- 1. tudo verde
run
check "verde: saída 0"                                   [ "$RC" -eq 0 ]
for t in root select worktree emit; do check "verde: tarefa $t verde" [ "$(verdict "$t")" = verde ]; done
check "verde: studio sem credencial = não verificado"    [ "$(verdict studio)" = nao-verificado ]
check "claude chamado 4 tarefas x 3 rodadas"            [ "$(nclaude)" -eq 12 ]
check "claude: Haiku da tabela, 8 turnos, json, -p"      bash -c 'n=$(grep -c -- "--model claude-haiku-4-5-20251001 --max-turns 8 --output-format json" "$1"); [ "$n" -eq 12 ] && ! grep -qv -- "^-p " "$1"' _ "$LOG/claude.argv"
check "sem --codex o codex não é chamado"                [ ! -e "$LOG/codex.argv" ]
check "custo somado no relato (12 x 0,02)"               has 'custo equivalente na API: US\$ 0.2400'
check "nada chegou ao oute-propose de verdade"           [ ! -s "$LOG/real-propose.log" ]
check "claude viu dublês de oute-propose e sudo, não os reais" bash -c 'grep "^propose=" "$1" | grep -qv "^propose=$2/" && ! grep "^propose=" "$1" | grep -q "^propose=$2/oute-propose$" ; grep -c "^sudo=.*/bin/sudo$" "$1" | grep -q .' _ "$LOG/claude.env" "$BIN"
check "cada chamada num diretório próprio e descartável" bash -c '[ "$(grep "^cwd=" "$1" | sort -u | wc -l)" -eq 12 ] && ! grep "^cwd=" "$1" | grep -qF "$2"' _ "$LOG/claude.env" "$ROOT"
check "diretórios descartáveis somem ao fim"             bash -c '! grep "^cwd=" "$1" | head -n1 | sed "s/^cwd=//" | xargs -I{} test -e {}' _ "$LOG/claude.env"
check ".ai-memory.toml com regression/regression"        bash -c 'n=$(grep -c "^memory=workspace = \"regression\" project = \"regression\" $" "$1"); [ "$n" -eq 12 ]' _ "$LOG/claude.env"
check "oute.task.id e slug do teste no resource"         bash -c 'grep -q "^ora=host.name=teste,oute.instance=teste,oute.task.id=regression-[0-9]*-[0-9]*-[0-9a-f]*-root-claude-r1,oute.task.slug=regression-root$" "$1"' _ "$LOG/claude.env"
check "evento oute.regression.run uma vez ao fim"        [ "$(grep -c '^ARGS regression ' "$LOG/emit.calls")" -eq 1 ]
ev="$(grep '^ARGS regression ' "$LOG/emit.calls")"
check "evento: imagem, CLIs, rodadas, resultado, custo"  bash -c 'grep -q "image=9.9.9-test claude=2.1.9 codex=0.5.0 rounds=3 result=verde green=4 red=0 unverified=1 cost=0.2400" <<<"$1"' _ "$ev"
check "evento: verde/vermelho por tarefa"                bash -c 'grep -q "tasks=root=verde,select=verde,worktree=verde,emit=verde,studio=nao-verificado" <<<"$1"' _ "$ev"
check "evento sem texto de prompt nem de resposta"       bash -c '! grep -qi -e nginx -e pronto -e feito -e "sel.txt" <<<"$1"' _ "$ev"
check "tarefa emit: oute-emit chamado do dublê, com os args" bash -c 'grep -c "^ARGS task opened regression repo=regression slug=regression-emit id=regression-" "$1" | grep -qx 3' _ "$LOG/emit.calls"

# ---------------------------------------------------------------- 2. regra das rodadas
FAKE_BAD="root:2" run
check "uma falha em 3 rodadas: verde, saída 0"           [ "$RC" -eq 0 -a "$(verdict root)" = verde ]
check "a falha isolada fica anotada"                     has 'root  *verde  *2/3 ok, 1 reprovada'
FAKE_BAD="root:1 root:3" run
check "falha em 2 de 3 rodadas: vermelho, saída 1"       [ "$RC" -eq 1 -a "$(verdict root)" = vermelho ]
check "motivo do grader no relato (sem proposta)"       has 'oute-propose não foi chamado'
check "as outras tarefas seguem verdes"                  [ "$(verdict select)" = verde -a "$(verdict emit)" = verde ]
check "evento leva o resultado vermelho"                 bash -c 'grep "^ARGS regression " "$1" | grep -q "result=vermelho green=3 red=1"' _ "$LOG/emit.calls"
FAKE_BAD="root:1" run --rounds 1
check "--rounds 1 com falha: vermelho"                   [ "$RC" -eq 1 -a "$(verdict root)" = vermelho -a "$(nclaude)" -eq 4 ]
FAKE_BAD="root:1" run --rounds 2
check "--rounds 2 com uma falha: verde"                  [ "$RC" -eq 0 -a "$(verdict root)" = verde -a "$(nclaude)" -eq 8 ]
for t in select worktree emit; do
  case "$t" in emit) FAKE_EMIT_ERR='oute-emit: sem endpoint (OTEL_EXPORTER_OTLP_ENDPOINT vazio no ambiente e no ~/.oute_env)' run ;;
               *) FAKE_BAD="$t:1 $t:2 $t:3" run ;; esac
  check "tarefa $t reprovada: vermelho e saída 1"        [ "$RC" -eq 1 -a "$(verdict "$t")" = vermelho -a "$(verdict root)" = verde ]
done
FAKE_EMIT_ERR='oute-emit: coletor indisponível: evento guardado no spool (x.json, spool com 100 bytes)' run
check "emit com coletor fora e evento no spool: verde"   [ "$RC" -eq 0 -a "$(verdict emit)" = verde ]
FAKE_EMIT_ERR='oute-emit: http://c: HTTP 400' run
check "emit recusado (HTTP 4xx): vermelho"               [ "$RC" -eq 1 -a "$(verdict emit)" = vermelho ]

# ---------------------------------------------------------------- 3. o agente não roda
FAKE_CLAUDE_FAIL=1 run
check "claude falha em toda chamada: saída 2 (não rodou)" [ "$RC" -eq 2 ]
check "…e não emite evento de resultado"                 [ ! -e "$LOG/emit.calls" ]
run --bogus
check "argumento desconhecido: saída 2"                  [ "$RC" -eq 2 ]
run --task inexistente
check "tarefa desconhecida: saída 2"                     [ "$RC" -eq 2 ]
run --rounds 0
check "--rounds 0: saída 2"                              [ "$RC" -eq 2 ]
run --task select --rounds 2
check "--task select: só ela roda"                       [ "$RC" -eq 0 -a "$(nclaude)" -eq 2 -a "$(verdict select)" = verde -a -z "$(verdict root)" ]

# ---------------------------------------------------------------- 4. cota
FAKE_QUOTA="$(quota 60 10)" run
check "cota 5h em 60%: não começa, saída 2"   [ "$RC" -eq 2 -a "$(nclaude)" -eq 0 ]
check "cota 5h em 60%: com aviso" has 'cota em 60%'
FAKE_QUOTA="$(quota 10 75.5)" run
check "cota 7d em 75,5%: não começa, saída 2"            [ "$RC" -eq 2 -a "$(nclaude)" -eq 0 ]
check "cota alta: sem evento"                            [ ! -e "$LOG/emit.calls" ]
FAKE_QUOTA="$(quota 59 10)" run
check "cota 59%: segue"                                  [ "$RC" -eq 0 -a "$(nclaude)" -eq 12 ]
FAKE_QUOTA="" run
check "oute-quota sem leitura: segue"            [ "$RC" -eq 0 -a "$(nclaude)" -eq 12 ]
check "oute-quota sem leitura: aviso" has 'cota desconhecida'
FAKE_QUOTA='{"schema":1,"agents":{"claude":{"status":"unknown","reason":"token-expirado","windows":{}}}}' run
check "cota unknown: segue"                      [ "$RC" -eq 0 -a "$(nclaude)" -eq 12 ]
check "cota unknown: aviso" has 'cota desconhecida'
mkdir -p "$TMP/semquota"; for c in jq timeout git python3 env cat sed grep tr head awk od date mktemp rm mkdir dirname sleep sort wc xargs; do
  ln -s "$(command -v $c)" "$TMP/semquota/$c" 2>/dev/null; done
ln -s "$BIN/claude" "$BIN/oute-select" "$BIN/oute-emit" "$BIN/oute-propose" "$TMP/semquota/" 2>/dev/null
PATH="$TMP/semquota:/usr/bin:/bin" run
check "sem oute-quota no PATH: segue"            [ "$RC" -eq 0 ]
check "sem oute-quota no PATH: aviso" has 'sem oute-quota no PATH'
export FAKE_QUOTA="$QOK"

# ---------------------------------------------------------------- 5. --codex
run --codex
check "--codex: codex roda a tarefa 1 em cada rodada"    [ "$(grep -c . "$LOG/codex.argv")" -eq 3 ]
check "--codex: exec, modelo e esforço da tabela"        bash -c 'grep -qx "exec --skip-git-repo-check -m gpt-6-luna -c model_reasoning_effort=\"medium\" .*" "$1" || grep -q "^exec --skip-git-repo-check -m gpt-6-luna -c model_reasoning_effort=\"medium\" " "$1"' _ "$LOG/codex.argv"
check "--codex: veredito root:codex verde, saída 0"      [ "$RC" -eq 0 -a "$(verdict root:codex)" = verde ]
check "--codex: o claude roda as mesmas 12 chamadas"     [ "$(nclaude)" -eq 12 ]
check "--codex: evento leva a tarefa root:codex"         bash -c 'grep "^ARGS regression " "$1" | grep -q "root:codex=verde"' _ "$LOG/emit.calls"
check "--codex: dublê, nunca o oute-propose real"        [ ! -s "$LOG/real-propose.log" ]

# ---------------------------------------------------------------- 6. agent-studio
SD="$TMP/studio"; mkdir -p "$SD"
cat > "$SD/server.py" <<'PY'
import http.server, os, sys, urllib.parse
sd = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        sid = (q.get("id") or [""])[0]
        with open(os.path.join(sd, "requests.log"), "a") as f:
            f.write("%s %s auth=%s\n" % (u.path, sid, "ok" if self.headers.get("Authorization") == "Bearer " + os.environ["TOKEN"] else "no"))
        deny = open(os.path.join(sd, "deny")).read().split() if os.path.exists(os.path.join(sd, "deny")) else []
        code = int(open(os.path.join(sd, "code")).read()) if os.path.exists(os.path.join(sd, "code")) else 200
        if u.path != "/sessao" or any(d in sid for d in deny):
            code = 404
        body = b"<dl data-resumo-sessao=\"%s\" data-agents=\"claude\"></dl>" % sid.encode() if code == 200 else b"x"
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(sd, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
export TOKEN="tok$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')"
python3 "$SD/server.py" "$SD" & SRV_PID=$!
for _ in $(seq 1 50); do [[ -s "$SD/port" ]] && break; sleep 0.1; done
[[ -s "$SD/port" ]] || die "o agent-studio falso não subiu"
SCHEME=http; STUDIO_ADDR="$SCHEME://127.0.0.1:$(cat "$SD/port")"
studio() { AGENT_STUDIO_URL="$STUDIO_ADDR" AGENT_STUDIO_READ_TOKEN="$TOKEN" run "$@"; }
rm -f "$SD/deny" "$SD/code" "$SD/requests.log"
studio
check "studio: todas as conversas lá: verde, saída 0"    [ "$RC" -eq 0 -a "$(verdict studio)" = verde ]
check "studio: perguntou por 12 conversas, com a credencial de leitura" bash -c '[ "$(grep -c "^/sessao regression-.* auth=ok$" "$1")" -eq 12 ] && ! grep -q "auth=no" "$1"' _ "$SD/requests.log"
check "studio: credencial nunca no relato nem no evento" bash -c '! grep -qF "$1" "$2" "$3"' _ "$TOKEN" "$TMP/stderr" "$LOG/emit.calls"
check "studio: evento com studio=verde"                  bash -c 'grep "^ARGS regression " "$1" | grep -q "studio=verde"' _ "$LOG/emit.calls"
echo "claude-r2" > "$SD/deny"; rm -f "$SD/requests.log"
studio
check "studio: conversa ausente em 1 rodada: verde"      [ "$RC" -eq 0 -a "$(verdict studio)" = verde ]
printf 'claude-r2\nclaude-r3\n' > "$SD/deny"
studio
check "studio: ausente em 2 rodadas: vermelho, saída 1"  [ "$RC" -eq 1 -a "$(verdict studio)" = vermelho ]
check "studio: os grader das outras tarefas seguem verdes" [ "$(verdict root)" = verde ]
rm -f "$SD/deny"; echo 500 > "$SD/code"
studio
check "studio: HTTP 500 = não verificado, não vermelho"  [ "$RC" -eq 0 -a "$(verdict studio)" = nao-verificado ]
check "studio: HTTP 500 dito no relato" has 'HTTP 500'
rm -f "$SD/code"
AGENT_STUDIO_URL="$SCHEME://127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')" \
  AGENT_STUDIO_READ_TOKEN="$TOKEN" run
check "studio fora do ar: não verificado, saída 0"       [ "$RC" -eq 0 -a "$(verdict studio)" = nao-verificado ]
AGENT_STUDIO_URL="$STUDIO_ADDR" run
check "studio sem a credencial de leitura: não verificado" [ "$RC" -eq 0 -a "$(verdict studio)" = nao-verificado ]
rm -f "$SD/requests.log"
studio --task root --task studio
check "studio só pergunta pelas conversas das tarefas que rodaram" bash -c '[ "$(grep -c . "$1")" -eq 3 ] && ! grep -q -e select -e worktree -e emit "$1"' _ "$SD/requests.log"
studio --json --rounds 1
check "--json: objeto com versão, resultado e tarefas"   bash -c 'jq -e ".image == \"9.9.9-test\" and .claude == \"2.1.9\" and .rounds == 1 and .result == \"verde\" and .tasks.root == \"verde\" and .tasks.studio == \"verde\" and .cost_usd == 0.08" <<<"$1" >/dev/null' _ "$STDOUT"

check_end
