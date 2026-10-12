#!/usr/bin/env bash
# Testes da captura parcial do ai-memory (#725): o `oute-doctor` do container (sessões locais × capturadas por agente, com
# limite, e o `trusted_hash` dos hooks do Codex), as métricas do `oute-emit doctor` e o `oute doctor` do host.
# Bash puro + python3/jq, sem Docker nem rede. Costuras: o servidor do ai-memory é um falso local (só os dois GET que o
# comando faz), o coletor é o receptor OTLP de tests/lib/otlp.sh e o `docker` do host é um dublê que roda o comando local.
# Uso: tests/oute-doctor.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
# o scripts/oute lê o ambiente: credenciais reais nunca chegam a ele daqui
for v in $(compgen -e | grep -E '^(OCI_|GH_TOKEN$|GITHUB_TOKEN$|AGENT_STUDIO_|BW_|AI_MEMORY_|OUTE_DOCTOR_)' || true); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/otlp.sh"
. "$ROOT/tests/lib/check.sh"
mem_stop() { [[ -z "${MEM_PID:-}" ]] || { kill "$MEM_PID" 2>/dev/null; wait "$MEM_PID" 2>/dev/null; MEM_PID=""; }; return 0; }
trap 'mem_stop; rcv_stop; rm -rf "${TMP:?}"' EXIT
command -v jq >/dev/null && command -v python3 >/dev/null || die "precisa de jq e python3"
CHECK_OUT=20
DOCTOR="$ROOT/docker/oute-doctor"
SCHEME=http
unset OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT CLAUDECODE CODEX_THREAD_ID
export OTEL_RESOURCE_ATTRIBUTES="host.name=oute-teste,oute.instance=oute-agent"

# ---------------------------------------------------------------- o servidor falso do ai-memory
# $MEM/captured.json = {"<workspace>/<projeto>": {"<agente>": sessões}}; $MEM/mode = ok | 500 | lixo | espera;
# $MEM/token (se existe) = o Bearer exigido (sem ele ou com outro: 401). Cada pedido vai em $MEM/requests.jsonl.
MEM="$TMP/mem"; mkdir -p "$MEM"
cat > "$TMP/fake-memory.py" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
D = sys.argv[1]
def read(name, default=""):
    try:
        return open(os.path.join(D, name)).read().strip()
    except OSError:
        return default
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, code, body):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        u = urlparse(self.path)
        token, auth = read("token"), self.headers.get("Authorization", "")
        with open(os.path.join(D, "requests.jsonl"), "a") as fh:
            fh.write(json.dumps({"path": u.path, "query": u.query, "bearer": auth.startswith("Bearer ")}) + "\n")
        if token and auth != "Bearer " + token:
            return self.reply(401, {"error": "auth required"})
        mode = read("mode", "ok")
        if mode == "500":
            return self.reply(500, {"error": "boom"})
        if mode == "lixo":
            return self.reply(200, b"<html>nada</html>")
        if mode == "espera":
            time.sleep(5)
        data = json.loads(read("captured.json", "{}"))
        if u.path == "/admin/projects":
            return self.reply(200, {"projects": [{"workspace_name": k.split("/")[0], "project_name": k.split("/")[1]} for k in data]})
        if u.path == "/admin/sessions/by-agent":
            q = parse_qs(u.query)
            rows = data.get(f"{q['workspace'][0]}/{q['project'][0]}", {})
            return self.reply(200, {"by_agent": [{"agent": a, "sessions": n} for a, n in rows.items()]})
        self.reply(404, {"error": "rota"})
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port.tmp"), "w").write(str(srv.server_address[1]))
os.replace(os.path.join(D, "port.tmp"), os.path.join(D, "port"))
srv.serve_forever()
PY
python3 "$TMP/fake-memory.py" "$MEM" 2>"$MEM/stderr" & MEM_PID=$!   # o cliente que desiste no modo espera deixa um traceback: vai ao arquivo
for _ in $(seq 1 100); do [[ -s "$MEM/port" ]] && break; sleep 0.1; done
[[ -s "$MEM/port" ]] || die "o servidor falso do ai-memory não subiu"
MEM_URL="$SCHEME://127.0.0.1:$(cat "$MEM/port")"
captured() { local json="$1"; printf '%s' "$json" > "$MEM/captured.json"; return 0; }
mode() { local name="$1"; printf '%s' "$name" > "$MEM/mode"; return 0; }

# ---------------------------------------------------------------- o home dos agentes
# uid <n>: um id de sessão fixo por número (nada sorteado: o teste confere o nome inteiro)
uid() { local n="$1"; printf '00000000-0000-4000-8000-%012d' "$n"; return 0; }
# claude_sessions <home> <projeto> <de> <até>; codex_sessions <home> <de> <até>
claude_sessions() {
  local home="$1" proj="$2" from="$3" to="$4" i
  mkdir -p "$home/.claude/projects/$proj"
  for i in $(seq "$from" "$to"); do echo '{}' > "$home/.claude/projects/$proj/$(uid "$i").jsonl"; done
  return 0
}
codex_sessions() {
  local home="$1" from="$2" to="$3" i
  mkdir -p "$home/.codex/sessions/2026/09/25"
  for i in $(seq "$from" "$to"); do echo '{}' > "$home/.codex/sessions/2026/09/25/rollout-2026-09-25T21-25-39-$(uid "$i").jsonl"; done
  return 0
}
# codex_hooks <home>: hooks.json com um hook que não é do ai-memory e três do ai-memory, todos com trusted_hash
codex_hooks() {
  local home="$1"
  mkdir -p "$home/.codex"
  cat > "$home/.codex/hooks.json" <<'JSON'
{"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash outro.sh"}]},
                   {"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/ai-memory hook --event session-start"}]}],
  "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/ai-memory hook --event session-end"}]}],
  "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/ai-memory hook --event prompt"}]}]}}
JSON
  local f="$home/.codex/hooks.json" k
  { echo 'sandbox_mode = "danger-full-access"'; echo; echo '[hooks.state]'
    for k in session_start:1:0 session_end:0:0 user_prompt_submit:0:0; do
      printf '[hooks.state."%s:%s"]\ntrusted_hash = "sha256:%s"\n\n' "$f" "$k" "$(printf '%s' "$k" | sha256sum | cut -c1-64)"
    done; } > "$home/.codex/config.toml"
  return 0
}
# doc <home> [args…]: roda o oute-doctor naquele home contra o servidor falso; saída em $OUT, código em $RC
doc() { local home="$1"; shift; OUT="$(HOME="$home" AI_MEMORY_SERVER_URL="$MEM_URL" OUTE_DOCTOR_HTTP_TIMEOUT=2 "$DOCTOR" "$@" 2>&1)"; RC=$?; return 0; }
# ag <agente> <filtro jq>: o filtro sobre a linha do agente no --json de $OUT
ag() { local agent="$1" filter="$2"; jq -e --arg a "$agent" ".agents[] | select(.agent == \$a) | $filter" <<<"$OUT" >/dev/null; return $?; }
hist() { local home="$1"; grep -c . "$home/.oute/doctor/history.jsonl" 2>/dev/null || true; return 0; }
ago() { local days="$1"; echo $(( $(date +%s) - days * 86400 )); return 0; }

# ---------------------------------------------------------------- 1. primeira execução: total em disco × total no servidor
H="$TMP/h1"; mkdir -p "$H"
claude_sessions "$H" -workspace-a 1 4; claude_sessions "$H" -workspace-b 5 6
mkdir -p "$H/.claude/projects/-workspace-a/$(uid 1)/subagents"; echo '{}' > "$H/.claude/projects/-workspace-a/$(uid 1)/subagents/agent-$(uid 99).jsonl"
codex_sessions "$H" 1 1; codex_hooks "$H"
captured '{"default/a": {"claude-code": 4, "codex": 1}, "default/b": {"claude-code": 3}}'
doc "$H" --json --no-emit
check "1ª execução: rc 0 e JSON"                          bash -c '[ "$1" -eq 0 ] && jq -e . <<<"$2" >/dev/null' _ "$RC" "$OUT"
check "claude: 6 locais (subagente não conta) × 7 capturadas, somadas dos 2 projetos" ag claude '.local == 6 and .captured == 7 and .captured_total == 7'
check "claude: base total, 0% sem captura, ok"            ag claude '.basis == "total" and .missing == 0 and .missing_pct == 0 and .status == "ok"'
check "codex: 1 local, abaixo do mínimo: amostra, sem %"  ag codex '.local == 1 and .captured == 1 and .status == "amostra" and .missing_pct == null'
check "hooks do Codex: 3 do ai-memory, todos com trusted_hash" jqe '.codex_hooks | .status == "ok" and .hooks == 3 and .untrusted == 0 and .missing == []' <<<"$OUT"
check "sem aviso"                                         jqe '.warnings == false' <<<"$OUT"
check "grava os ids vistos do claude (6) e do codex (1)"  bash -c '[ "$(grep -c . "$1/.oute/doctor/seen-claude")" -eq 6 ] && [ "$(grep -c . "$1/.oute/doctor/seen-codex")" -eq 1 ]' _ "$H"
check "grava uma linha por agente no histórico"           test "$(hist "$H")" -eq 2
check "grava o último relatório"                          jqe '.agents | length == 2' "$H/.oute/doctor/last.json"
check "só GET nas duas rotas de leitura"                  bash -c 'jq -r .path "$1" | sort -u | tr "\n" " " | grep -qx "/admin/projects /admin/sessions/by-agent "' _ "$MEM/requests.jsonl"

# ---------------------------------------------------------------- 2. captura parcial: o que cresceu desde a linha anterior
claude_sessions "$H" -workspace-a 7 16     # 10 sessões locais novas
captured '{"default/a": {"claude-code": 6, "codex": 1}, "default/b": {"claude-code": 3}}'   # só 2 capturadas a mais
doc "$H" --json --no-emit --no-save
check "captura parcial: rc 1"                              test "$RC" -eq 1
check "claude: 10 locais novas × 2 capturadas novas = 80% sem captura, aviso" ag claude '.basis == "delta" and .local == 10 and .captured == 2 and .missing == 8 and .missing_pct == 80 and .status == "aviso"'
check "claude: diz desde quando compara"                   ag claude '.since != null and .since <= now'
check "aviso geral ligado"                                 jqe '.warnings == true' <<<"$OUT"
check "--no-save: histórico e ids vistos como estavam"     bash -c '[ "$1" -eq 2 ] && [ "$(grep -c . "$2/.oute/doctor/seen-claude")" -eq 6 ]' _ "$(hist "$H")" "$H"
doc "$H" --no-emit --no-save
check "texto: a linha do claude com as contagens e o %"    has '✗ claude 10 locais × 2 capturadas (desde .* UTC): 80% sem captura'
check "texto: o limite e o resultado"                      bash -c 'grep -q "limite 20% sem captura" <<<"$1" && grep -qx "Resultado: algum aviso acima." <<<"$1"' _ "$OUT"

# ---------------------------------------------------------------- 3. limite configurável e amostra mínima
doc "$H" --json --no-emit --no-save --max-missing-pct 90
check "limite 90 por argumento: 80% passa, rc 0"           bash -c '[ "$1" -eq 0 ]' _ "$RC"
check "limite 90: ok, com o limite no relatório"           bash -c 'jq -e ".max_missing_pct == 90 and (.agents[] | select(.agent == \"claude\") | .status == \"ok\" and .missing_pct == 80)" <<<"$1" >/dev/null' _ "$OUT"
OUT="$(HOME="$H" AI_MEMORY_SERVER_URL="$MEM_URL" OUTE_DOCTOR_MAX_MISSING_PCT=79 "$DOCTOR" --json --no-emit --no-save 2>&1)"; RC=$?
check "limite 79 pela variável: 80% avisa, rc 1"           bash -c '[ "$1" -eq 1 ] && jq -e ".max_missing_pct == 79" <<<"$2" >/dev/null' _ "$RC" "$OUT"
doc "$H" --json --no-emit --no-save --min-sessions 11
check "mínimo de 11 sessões: 10 locais não dão veredito"   ag claude '.status == "amostra" and .missing_pct == null and .local == 10'
check "mínimo de 11: sem veredito não é aviso (rc 0)"      test "$RC" -eq 0
doc "$H" --since-days 0; check "uso: --since-days 0 = rc 2" test "$RC" -eq 2
doc "$H" --nao-existe;   check "uso: opção desconhecida = rc 2" test "$RC" -eq 2
OUT="$(HOME="$H" OUTE_DOCTOR_MIN_SESSIONS=x "$DOCTOR" --no-emit --no-save 2>&1)"; RC=$?
check "uso: variável inválida = rc 2, sem traceback"       bash -c '[ "$1" -eq 2 ] && grep -q "OUTE_DOCTOR_\* inválida" <<<"$2" && ! grep -q Traceback <<<"$2"' _ "$RC" "$OUT"
doc "$H" --help; check "--help: rc 0 e o uso"              bash -c '[ "$1" -eq 0 ] && grep -q "oute-doctor \[--json\]" <<<"$2"' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 4. arquivo local apagado continua contado; a linha gravada vira a base
doc "$H" --json --no-emit      # grava: 16 vistos, 9 capturadas
check "gravou a 2ª linha de cada agente"                   test "$(hist "$H")" -eq 4
rm -f "${H:?}/.claude/projects/-workspace-a/00000000-0000-4000-8000-000000000007.jsonl"
rm -f "${H:?}/.claude/projects/-workspace-a/00000000-0000-4000-8000-000000000008.jsonl"
doc "$H" --json --no-emit --no-save
check "sessão local apagada do disco segue contada (10 novas)" ag claude '.local == 10 and .local_on_disk == 14 and .seen == 16 and .missing_pct == 80'
captured '{"default/a": {"claude-code": 14, "codex": 1}, "default/b": {"claude-code": 3}}'   # as 8 que faltavam chegaram
doc "$H" --json --no-emit --no-save
check "captura em dia de novo: 0% e ok, rc 0"              bash -c '[ "$1" -eq 0 ] && jq -e ".agents[] | select(.agent == \"claude\") | .missing_pct == 0 and .status == \"ok\"" <<<"$2" >/dev/null' _ "$RC" "$OUT"
captured '{"default/a": {"claude-code": 1}}'              # projeto apagado no servidor: o total caiu
doc "$H" --json --no-emit --no-save
check "total do servidor menor que a base: capturadas novas = 0, nunca negativo" ag claude '.captured == 0 and .missing == 10 and .missing_pct == 100'

# ---------------------------------------------------------------- 5. a janela escolhe a linha de base
H="$TMP/h5"; mkdir -p "$H/.oute/doctor"
claude_sessions "$H" -workspace-a 1 30
captured '{"default/a": {"claude-code": 124}}'
OLD="$(ago 20)"; MID="$(ago 2)"; ANCIENT="$(ago 200)"
{ printf '{"agent":"claude","captured":1,"seen":0,"t":%s}\n' "$ANCIENT"
  printf '{"agent":"codex","captured":0,"seen":0,"t":%s}\n' "$ANCIENT"
  printf '{"agent":"claude","captured":100,"seen":0,"t":%s}\n' "$OLD"
  echo 'linha estragada'
  printf '{"agent":"claude","captured":120,"seen":25,"t":%s}\n' "$MID"; } > "$H/.oute/doctor/history.jsonl"
doc "$H" --json --no-emit --no-save
check "janela de 7 dias: base = a linha de 2 dias (5 locais × 4 capturadas)" ag claude ".since == $MID and .local == 5 and .captured == 4 and .missing_pct == 20 and .status == \"ok\""
doc "$H" --json --no-emit --no-save --since-days 30
check "janela de 30 dias: base = a linha de 20 dias (30 × 24)" ag claude ".since == $OLD and .local == 30 and .captured == 24 and .missing_pct == 20"
doc "$H" --json --no-emit --no-save --since-days 1
check "nenhuma linha na janela de 1 dia: base = a última linha" ag claude ".since == $MID and .basis == \"delta\""
doc "$H" --json --no-emit --since-days 7
check "regravação: a linha estragada some e ficam as 2 do claude, a última do codex e as 2 novas" bash -c '[ "$(grep -c . "$1")" -eq 5 ] && ! grep -q estragada "$1"' _ "$H/.oute/doctor/history.jsonl"
check "linha de 200 dias: a do claude sai; a do codex fica, por ser a última dele antes desta" bash -c '[ "$(jq -c "select(.t == $2) | .agent" "$1")" = "\"codex\"" ]' _ "$H/.oute/doctor/history.jsonl" "$ANCIENT"
check "codex sem sessão local: amostra, sem aviso"         ag codex '.local == 0 and .status == "amostra" and .basis == "delta"'

# ---------------------------------------------------------------- 6. servidor sem resposta ou com resposta ruim: indeterminado
H="$TMP/h6"; mkdir -p "$H"; claude_sessions "$H" -workspace-a 1 8
captured '{"default/a": {"claude-code": 8}}'
for m in 500 lixo espera; do
  mode "$m"; doc "$H" --json --no-emit
  check "servidor em modo $m: indeterminado, rc 1, sem %"  bash -c '[ "$1" -eq 1 ] && jq -e ".warnings == true and (.agents | all(.status == \"indeterminado\" and .missing_pct == null and .note != null))" <<<"$2" >/dev/null' _ "$RC" "$OUT"
done
mode ok
check "indeterminado não grava linha no histórico"         test "$(hist "$H")" -eq 0
check "indeterminado ainda guarda os ids vistos"           test "$(grep -c . "$H/.oute/doctor/seen-claude")" -eq 8
OUT="$(HOME="$H" AI_MEMORY_SERVER_URL="$SCHEME://127.0.0.1:$(closed_port)" "$DOCTOR" --no-emit --no-save 2>&1)"; RC=$?
check "servidor fora: texto diz indeterminado, rc 1"       bash -c '[ "$1" -eq 1 ] && grep -q "? claude indeterminado: sem resposta do servidor" <<<"$2"' _ "$RC" "$OUT"
TOKEN="tok-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; printf '%s' "$TOKEN" > "$MEM/token"
doc "$H" --json --no-emit --no-save
check "servidor com token e cliente sem: 401, indeterminado" ag claude '.status == "indeterminado" and (.note | test("respondeu 401"))'
OUT="$(HOME="$H" AI_MEMORY_SERVER_URL="$MEM_URL" AI_MEMORY_AUTH_TOKEN="$TOKEN" "$DOCTOR" --json --no-emit --no-save 2>&1)"; RC=$?
check "com o token do ambiente: lê e dá o veredito"        bash -c '[ "$1" -eq 0 ] && jq -e ".agents[] | select(.agent == \"claude\") | .status == \"ok\" and .captured == 8" <<<"$2" >/dev/null' _ "$RC" "$OUT"
check "o token nunca aparece na saída"                     hasnt_str "$TOKEN"
OUT="$(HOME="$H" AI_MEMORY_SERVER_URL="$MEM_URL" AI_MEMORY_AUTH_TOKEN="errado-$TOKEN" "$DOCTOR" --no-emit --no-save 2>&1)"; RC=$?
check "token errado: indeterminado, sem o token na saída"  bash -c '[ "$1" -eq 1 ] && grep -q "respondeu 401" <<<"$2" && ! grep -qF "$3" <<<"$2"' _ "$RC" "$OUT" "$TOKEN"
rm -f "${MEM:?}/token"

# ---------------------------------------------------------------- 7. Codex: hook do ai-memory sem trusted_hash
H="$TMP/h7"; mkdir -p "$H"; codex_hooks "$H"; captured '{}'
hk() { local filter="$1"; jq -e ".codex_hooks | $filter" <<<"$OUT" >/dev/null; return $?; }
doc "$H" --json --no-emit --no-save
check "hooks completos: ok e rc 0"                         bash -c '[ "$1" -eq 0 ] && jq -e ".codex_hooks.status == \"ok\"" <<<"$2" >/dev/null' _ "$RC" "$OUT"
python3 - "$H/.codex/config.toml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s, n = re.subn(r'\[hooks\.state\."[^"]*:session_end:0:0"\]\ntrusted_hash = "[^"]*"\n', "", s)
assert n == 1
open(p, "w").write(s)
PY
doc "$H" --json --no-emit --no-save
check "sem a entrada do session_end: aviso, rc 1"          bash -c '[ "$1" -eq 1 ]' _ "$RC"
check "diz qual hook ficou sem trusted_hash"               hk '.status == "aviso" and .hooks == 3 and .untrusted == 1 and .missing == ["session_end:0:0"]'
doc "$H" --no-emit --no-save
check "texto: o hook sem trusted_hash e o efeito"          has '✗ codex  hooks: 1 de 3 hooks do ai-memory sem trusted_hash (session_end:0:0): o Codex não os roda'
sed -i 's/^trusted_hash = "sha256:.*"$/trusted_hash = ""/' "$H/.codex/config.toml"
doc "$H" --json --no-emit --no-save
check "trusted_hash vazio conta como ausente (os 2 restantes também)" hk '.untrusted == 3'
codex_hooks "$H"; sed -i '/^\[hooks\.state\."[^"]*session_start:1:0"\]$/,/^$/d' "$H/.codex/config.toml"
doc "$H" --json --no-emit --no-save
check "só o session_start do ai-memory sem entrada: 1 hook" hk '.missing == ["session_start:1:0"]'
codex_hooks "$H"; echo '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "bash outro.sh"}]}]}}' > "$H/.codex/hooks.json"
doc "$H" --json --no-emit --no-save
check "hooks.json sem hook do ai-memory: aviso"            bash -c '[ "$1" -eq 1 ] && jq -e ".codex_hooks | .status == \"aviso\" and .hooks == 0 and (.note | test(\"não tem hook do ai-memory\"))" <<<"$2" >/dev/null' _ "$RC" "$OUT"
rm -f "${H:?}/.codex/hooks.json"
doc "$H" --json --no-emit --no-save
check "sem hooks.json: aviso"                              hk '.status == "aviso" and (.note | test("sem ~/.codex/hooks.json"))'
codex_hooks "$H"; echo 'isto não é [toml' > "$H/.codex/config.toml"
doc "$H" --json --no-emit --no-save
check "config.toml que não se lê: indeterminado, rc 1"     bash -c '[ "$1" -eq 1 ] && jq -e ".codex_hooks | .status == \"indeterminado\" and .untrusted == null" <<<"$2" >/dev/null' _ "$RC" "$OUT"
codex_hooks "$H"; rm -f "${H:?}/.codex/config.toml"
doc "$H" --json --no-emit --no-save
check "sem config.toml: os 3 hooks sem trusted_hash"       hk '.status == "aviso" and .untrusted == 3'
echo 'lixo' > "$H/.codex/hooks.json"
doc "$H" --json --no-emit --no-save
check "hooks.json que não se lê: indeterminado"            hk '.status == "indeterminado"'
H="$TMP/h7b"; mkdir -p "$H"
doc "$H" --json --no-emit --no-save
check "sem ~/.codex: sem veredito e sem aviso (rc 0)"      bash -c '[ "$1" -eq 0 ] && jq -e ".codex_hooks | .status == null and .untrusted == null" <<<"$2" >/dev/null' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 8. métricas (oute-emit doctor)
BIN="$TMP/bin"; mkdir -p "$BIN"; ln -s "$ROOT/docker/oute-emit" "$BIN/oute-emit"
H="$TMP/h8"; mkdir -p "$H/.oute/doctor"; claude_sessions "$H" -workspace-a 1 10; codex_sessions "$H" 1 2; codex_hooks "$H"
sed -i '/^\[hooks\.state\."[^"]*session_end:0:0"\]$/,/^$/d' "$H/.codex/config.toml"
printf '{"agent":"claude","captured":50,"seen":0,"t":%s}\n' "$(ago 3)" > "$H/.oute/doctor/history.jsonl"
captured '{"default/a": {"claude-code": 54, "codex": 2}}'
rcv_start "$TMP/r8"
emitdoc() { OUT="$(HOME="$H" PATH="$BIN:$PATH" AI_MEMORY_SERVER_URL="$MEM_URL" "$DOCTOR" "$@" 2>&1)"; RC=$?; return 0; }
emitdoc --json
check "com aviso e emissão: rc 1"                          test "$RC" -eq 1
P="$(mp '.name | startswith("oute.memory.capture.")')"
check "claude: missing_pct 60, em %"                       jqe -s 'map(select(.name == "oute.memory.capture.missing_pct")) | length == 1 and .[0].value == 60 and .[0].unit == "%" and .[0].res["oute.agent"] == "claude"' <<<"$P"
check "claude: as duas contagens comparadas (10 e 4)"      jqe -s '(map(select(.name == "oute.memory.capture.local")) | map(.value) == [10]) and (map(select(.name == "oute.memory.capture.captured")) | map(.value) == [4])' <<<"$P"
check "claude: a base da comparação no ponto"              jqe -s 'map(select(.name == "oute.memory.capture.missing_pct")) | .[0].attrs["oute.memory.capture.basis"] == "delta"' <<<"$P"
check "codex (amostra): nenhum ponto de % nem de contagem" jqe -s 'map(select(.res["oute.agent"] == "codex" and .name != "oute.memory.capture.hooks_untrusted")) == []' <<<"$P"
check "codex: 1 hook sem trusted_hash"                     jqe -s 'map(select(.name == "oute.memory.capture.hooks_untrusted")) | length == 1 and .[0].value == 1 and .[0].res["oute.agent"] == "codex"' <<<"$P"
check "origem do host no recurso, pela rota de métricas"   jqe -s 'all(.res["host.name"] == "oute-teste" and .res["oute.instance"] == "oute-agent" and .res["service.name"] == "oute" and .path == "/v1/metrics")' <<<"$P"
check "hora do ponto = a da conferência"                   jqe -s --argjson at "$(jq .at <<<"$OUT")" 'all((.time | tonumber) == $at * 1000000000)' <<<"$P"
check "a emissão não muda a saída do oute-doctor (JSON só)" jqe '.agents | length == 2' <<<"$OUT"
rcv_stop; rcv_start "$TMP/r8b"
emitdoc --json --no-emit
check "--no-emit: nada chega ao coletor"                   test "$(mpoints "$RCV_DIR" | grep -c .)" -eq 0
emitdoc --json --no-save
check "--no-save: sem relatório novo, nada é emitido"      test "$(mpoints "$RCV_DIR" | grep -c .)" -eq 0
mode 500; emitdoc --json; mode ok
check "indeterminado: só o ponto dos hooks, sem % inventado" jqe -s 'map(.name) == ["oute.memory.capture.hooks_untrusted"]' <<<"$(mpoints "$RCV_DIR")"
rcv_stop
OUT="$(HOME="$TMP/h7b" PATH="$BIN:$PATH" OTEL_EXPORTER_OTLP_ENDPOINT="$SCHEME://127.0.0.1:$(closed_port)" oute-emit doctor 2>&1)"; RC=$?
check "oute-emit doctor sem relatório: rc 0 e silêncio"    bash -c '[ "$1" -eq 0 ] && [ -z "$2" ]' _ "$RC" "$OUT"
echo 'lixo' > "$H/.oute/doctor/last.json"
OUT="$(HOME="$H" PATH="$BIN:$PATH" OTEL_EXPORTER_OTLP_ENDPOINT="$SCHEME://127.0.0.1:$(closed_port)" oute-emit doctor 2>&1)"; RC=$?
check "oute-emit doctor com relatório estragado: rc 0 e silêncio" bash -c '[ "$1" -eq 0 ] && [ -z "$2" ]' _ "$RC" "$OUT"
OUT="$(HOME="$H" PATH="$BIN:$PATH" AI_MEMORY_SERVER_URL="$MEM_URL" OTEL_EXPORTER_OTLP_ENDPOINT="$SCHEME://127.0.0.1:$(closed_port)" "$DOCTOR" --json 2>&1)"; RC=$?
check "coletor fora: o veredito sai igual (rc 1 e JSON)"   bash -c '[ "$1" -eq 1 ] && jq -e ".agents | length == 2" <<<"$2" >/dev/null' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 9. `oute doctor` no host
HB="$TMP/hostbin"; mkdir -p "$HB"
cat > "$HB/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$F_DOCKER"
case "$1" in
  ps)   [[ -e "$F_UP" ]] && echo abc123; exit 0 ;;
  exec) shift; [[ "$1" == oute-agent ]] || exit 9; shift
        PATH="$F_CTR_BIN:$PATH" exec "$@" ;;
  *)    exit 9 ;;
esac
SH
chmod +x "$HB/docker"
export F_DOCKER="$TMP/docker.calls" F_UP="$TMP/up" F_CTR_BIN="$TMP/ctrbin"
mkdir -p "$F_CTR_BIN"
printf '#!/usr/bin/env bash\necho "doctor: $*"\nexit "${F_DOCTOR_RC:-0}"\n' > "$F_CTR_BIN/oute-doctor"; chmod +x "$F_CTR_BIN/oute-doctor"
host() { OUT="$(PATH="$HB:$PATH" OUTE_HOME="$TMP/oute-home" OUTE_HOST=teste OUTE_INSTANCE=teste "$ROOT/scripts/oute" doctor "$@" 2>&1)"; RC=$?; return 0; }
host --json
check "container fora: diz e sai com 1, sem exec"          bash -c '[ "$1" -eq 1 ] && grep -q "o container oute-agent não está de pé" <<<"$2" && ! grep -q "^exec" "$3"' _ "$RC" "$OUT" "$F_DOCKER"
: > "$F_UP"
host --json --since-days 3
check "repassa os argumentos ao oute-doctor do container"  has_line 'doctor: --json --since-days 3'
check "sem aviso: rc 0"                                    test "$RC" -eq 0
F_DOCTOR_RC=1 host
check "com aviso: repassa o rc 1 e a saída"                bash -c '[ "$1" -eq 1 ] && grep -qx "doctor: " <<<"$2"' _ "$RC" "$OUT"
check "roda no container do agente"                        grep -qx 'exec oute-agent oute-doctor' "$F_DOCKER"
rm -f "${F_CTR_BIN:?}/oute-doctor"
host
check "imagem sem o oute-doctor: diz que precisa da release, rc 1" bash -c '[ "$1" -eq 1 ] && grep -q "a imagem em uso não tem o oute-doctor" <<<"$2"' _ "$RC" "$OUT"
check "o guia e o uso citam o comando"                     bash -c 'grep -q "^  oute doctor " "$1/docker/comandos.md" && grep -q "^  doctor \[opções\]" "$1/scripts/oute" && grep -q "^## CONTAINER — captura do ai-memory (oute-doctor, #725)" "$1/docker/comandos.md"' _ "$ROOT"
check "a imagem leva o comando, executável"                bash -c 'grep -q "^COPY docker/oute-doctor /usr/local/bin/" "$1/docker/Dockerfile" && grep -q "/usr/local/bin/oute-doctor" "$1/docker/Dockerfile" && [ -x "$1/docker/oute-doctor" ]' _ "$ROOT"

check_end
