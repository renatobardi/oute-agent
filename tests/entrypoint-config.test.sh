#!/usr/bin/env bash
# Nível 0 de regressão do entrypoint e do codex_config (#365, spike #52): sem LLM, sem Docker, sem rede, sem porta.
# A setup_agents e a setup_ssh do docker/entrypoint.sh são extraídas por sed (como a flush_spool em oute-emit.test.sh)
# e rodam de verdade, com `set -euo pipefail` como no entrypoint, num HOME temporário, com o codex_config.py, o
# addons-link e o agent-notes.md reais, e um ai-memory dublê (tests/lib/fake-ai-memory.sh) que escreve mcp_servers e
# hooks.state como o real. Mais asserts estáticos do docker/compose.yaml. Só comportamento externo: o que fica em
# $HOME, o código de saída e o stderr.
# Prova vermelha (corpo do PR): ENTRYPOINT_SRC e OUTE_LIB_DIR apontam para cópias alteradas do entrypoint e do codex_config.
# Uso: tests/entrypoint-config.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/fake-ai-memory.sh"
for c in jq python3 ssh-keygen; do command -v "$c" >/dev/null || die "precisa de $c"; done
# o codex_config.py precisa do tomlkit (na imagem, python3-tomlkit); sem ele no python3 do ambiente, venv em cache com
# a mesma versão (tests/lib/tomlkit-requirements.txt, só com hash)
TOML_PY=python3
if ! python3 -c 'import tomlkit' 2>/dev/null; then
  req="$ROOT/tests/lib/tomlkit-requirements.txt"
  d="${XDG_CACHE_HOME:-$HOME/.cache}/oute-tests/tomlkit-$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "$req")"
  if ! "$d/bin/python" -c 'import tomlkit' 2>/dev/null; then
    rm -rf "$d"; mkdir -p "$(dirname "$d")"
    { python3 -m venv "$d" && "$d/bin/pip" install -q --only-binary :all: --require-hashes -r "$req"; } >/dev/null 2>&1 \
      || die "sem tomlkit no python3 e não montei o venv (tests/lib/tomlkit-requirements.txt)"
  fi
  TOML_PY="$d/bin/python"
fi

ENTRYPOINT_SRC="${ENTRYPOINT_SRC:-$ROOT/docker/entrypoint.sh}"
LIB_DIR="${OUTE_LIB_DIR:-$ROOT/docker}"   # onde ficam codex_config.py, addons-link e agent-notes.md (na imagem: /usr/local/lib/oute)
COMPOSE="$ROOT/docker/compose.yaml"
unset OUTE_AGENTS OUTE_AGENT_YOLO OUTE_HOST OUTE_HOSTNAME OUTE_INSTANCE OUTE_NET_GATEWAY OUTE_ADDONS_DIR \
  AI_MEMORY_SERVER_URL AI_MEMORY_AUTH_TOKEN FAKE_AI_MEMORY_LOG

BIN="$TMP/bin"; fake_ai_memory_install "$BIN"
# as funções reais do entrypoint; o caminho da imagem troca pelo do checkout; sudo vira no-op (sem root no teste)
FN="$TMP/fn.sh"
{
  grep '^log() ' "$ENTRYPOINT_SRC"
  echo 'sudo() { :; }'
  sed -n '/^setup_agents() {/,/^}/p;/^setup_ssh() {/,/^}/p' "$ENTRYPOINT_SRC" | sed "s#python3 /usr/local/lib/oute/codex_config.py#$TOML_PY $LIB_DIR/codex_config.py#;s#/usr/local/lib/oute/#$LIB_DIR/#g"
} > "$FN"
check "entrypoint: setup_agents e setup_ssh extraídas"   bash -c 'grep -q "^setup_agents() {" "$1" && grep -q "^setup_ssh() {" "$1"' _ "$FN"

# run <home> <função> [VAR=valor…]: a função num bash novo com -euo pipefail, como no entrypoint; stderr em $OUT, código em $RC
run() {
  local h="$1" f="$2"; shift 2; mkdir -p "$h"
  OUT="$(env HOME="$h" PATH="$BIN:$PATH" OUTE_ADDONS_DIR="$ROOT/addons" FAKE_AI_MEMORY_LOG="$h/ai-memory.log" "$@" \
    bash -c 'set -euo pipefail; . "$1"; "$2"' _ "$FN" "$f" 2>&1 >/dev/null </dev/null)"; RC=$?
}
tget() { python3 -c 'import sys,tomllib
d=tomllib.load(open(sys.argv[1],"rb"))
for k in sys.argv[2:]: d=d[k]
print(d)' "$@"; }
count() { grep -cF -- "$1" "$2" || true; }   # ocorrências (linhas) do texto fixo; 0 sem falhar

# ---------------------------------------------------------------- 1. home vazio
H="$TMP/h1"; run "$H" setup_agents FAKE_AI_MEMORY_BAK=0   # o dublê sem .bak: home novo de verdade
CHECK_OUT=15
check "home vazio: setup_agents sai 0 (sem .bak o ls não derruba o boot, #3)"  test "$RC" -eq 0
unset CHECK_OUT
C="$H/.codex/config.toml"; S="$H/.claude/settings.json"
check "home vazio: sandbox_mode = danger-full-access"   test "$(tget "$C" sandbox_mode)" = danger-full-access
check "home vazio: approval_policy = never (yolo)"      test "$(tget "$C" approval_policy)" = never
check "home vazio: [otel] com o environment do host"    test "$(tget "$C" otel environment)" = oute
check "home vazio: settings.json com bypassPermissions" jqe '.permissions.defaultMode == "bypassPermissions" and .skipDangerousModePermissionPrompt == true' "$S"
check "home vazio: autoMemoryEnabled = false"           jqe '.autoMemoryEnabled == false' "$S"
check "home vazio: mcp_servers do ai-memory preservado" test "$(tget "$C" mcp_servers ai-memory command)" = ai-memory
check "home vazio: hooks do Claude (ai-memory) preservados no settings.json" jqe '.hooks.SessionStart | length == 1' "$S"
check "home vazio: nenhum .bak criado e nenhum sobrando" bash -c '! ls "$1"/.codex/*.bak-* >/dev/null 2>&1' _ "$H"
check "ai-memory: install-mcp e install-hooks para claude-code e codex" bash -c '
  l="$1"; for c in install-mcp install-hooks; do for a in claude-code codex; do grep -q "^$c .*--\(client\|agent\) $a " "$l" || exit 1; done; done' _ "$H/ai-memory.log"
check "ai-memory: --session-aware só no claude-code"    bash -c '
  [ "$(grep -c -- "--session-aware" "$1")" -eq 1 ] && grep -- "--session-aware" "$1" | grep -q -- "--client claude-code"' _ "$H/ai-memory.log"
check "ai-memory: --project-strategy repo-root nos hooks" bash -c '[ "$(grep "^install-hooks" "$1" | grep -c -- "--project-strategy repo-root")" -eq 2 ]' _ "$H/ai-memory.log"
check "addons: links das skills em ~/.claude/skills e ~/.agents/skills" bash -c '
  s="$(ls "$1"/addons/skills | head -1)"; [ -L "$2/.claude/skills/$s" ] && [ -L "$2/.agents/skills/$s" ]' _ "$ROOT" "$H"
check "eventos: marca since gravada"                    test -s "$H/.oute/emit/since"
cp "$C" "$TMP/c1.toml"; cp "$S" "$TMP/s1.json"; cp "$H/.codex/hooks.json" "$TMP/hk1.json"

# ---------------------------------------------------------------- 2. segunda execução: idempotência e o que o ai-memory escreveu
run "$H" setup_agents
check "2ª execução: sai 0"                              test "$RC" -eq 0
check "2ª execução: mcp_servers do ai-memory continua"  test "$(tget "$C" mcp_servers ai-memory command)" = ai-memory
check "2ª execução: [hooks.state] com trusted_hash continua" test "$(tget "$C" hooks state /home/oute/.codex/hooks.json:pre_tool_use:0:0 trusted_hash)" = sha256:0123abcd
check "2ª execução: config.toml idêntico ao da 1ª"      cmp -s "$TMP/c1.toml" "$C"
check "2ª execução: settings.json idêntico ao da 1ª"    cmp -s "$TMP/s1.json" "$S"
check "2ª execução: hooks.json do Codex intacto"        cmp -s "$TMP/hk1.json" "$H/.codex/hooks.json"
check "2ª execução: um só [otel] e um só sandbox_mode"  bash -c '[ "$(grep -c "^\[otel\]" "$1")" -eq 1 ] && [ "$(grep -c "^sandbox_mode" "$1")" -eq 1 ]' _ "$C"
check "2ª execução: sem .bak novo (nada mudou)"         bash -c '! ls "$1"/.codex/*.bak-* >/dev/null 2>&1' _ "$H"

# o que é do usuário no config.toml fica (merge estrutural), e a migração tira os blocos com marcadores das versões <= 0.5.7
H="$TMP/h1b"; mkdir -p "$H/.codex"
cat > "$H/.codex/config.toml" <<'TOML'
model = "gpt-5"
# >>> oute otel (gerado)
[otel]
environment = "antigo"
# <<< oute otel
[projects."/workspace/x"]
trust_level = "trusted"
TOML
run "$H" setup_agents OUTE_HOST=oute-mac
check "config do usuário: sai 0"                        test "$RC" -eq 0
check "config do usuário: chave solta e tabela do usuário preservadas" bash -c '
  tomllib() { python3 -c "import sys,tomllib; d=tomllib.load(open(sys.argv[1],\"rb\")); print(d[\"model\"], d[\"projects\"][\"/workspace/x\"][\"trust_level\"])" "$1"; }
  [ "$(tomllib "$1")" = "gpt-5 trusted" ]' _ "$H/.codex/config.toml"
check "config do usuário: [otel] com o host novo e sem marcador antigo" bash -c '
  [ "$(python3 -c "import sys,tomllib; print(tomllib.load(open(sys.argv[1],\"rb\"))[\"otel\"][\"environment\"])" "$1")" = oute-mac ] && ! grep -q ">>> oute" "$1"' _ "$H/.codex/config.toml"
check "config do usuário: mcp_servers do dublê junto com o do usuário" test "$(tget "$H/.codex/config.toml" mcp_servers ai-memory command)" = ai-memory

# ---------------------------------------------------------------- 2b. trava de pkill/killall (#538)
GK="$LIB_DIR/oute-guard-kill"
H="$TMP/h2b"; mkdir -p "$H/.claude"
echo '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"/x/do-usuario"}]}]}}' > "$H/.claude/settings.json"
run "$H" setup_agents; run "$H" setup_agents
S="$H/.claude/settings.json"
check "kill: 2 execuções saem 0"                        test "$RC" -eq 0
check "kill: hook do guard no PreToolUse (Bash), uma vez só" jqe --arg c "$GK" '[.hooks.PreToolUse[] | select(any(.hooks[]; .command == $c))] | length == 1 and .[0].matcher == "Bash"' "$S"
check "kill: hook do usuário no PreToolUse preservado"  jqe 'any(.hooks.PreToolUse[]; any(.hooks[]; .command == "/x/do-usuario"))' "$S"
check "kill: regras do Codex gravadas, iguais às da imagem" cmp -s "$LIB_DIR/codex-kill.rules" "$H/.codex/rules/oute-guard-kill.rules"
check "kill: nenhum .tmp sobrando em ~/.codex/rules"    bash -c '! ls "$1"/.codex/rules/*.tmp >/dev/null 2>&1' _ "$H"
if command -v codex >/dev/null 2>&1; then
  check "kill: o Codex recusa pkill -f e killall pelas regras gravadas" bash -c '
    codex execpolicy check --rules "$1" -- pkill -f x | grep -q forbidden && codex execpolicy check --rules "$1" -- killall x | grep -q forbidden \
      && ! codex execpolicy check --rules "$1" -- kill 123 | grep -q forbidden' _ "$H/.codex/rules/oute-guard-kill.rules"
fi
echo 'regra velha' > "$H/.codex/rules/oute-guard-kill.rules"; run "$H" setup_agents
check "kill: regras alteradas voltam ao texto da imagem" cmp -s "$LIB_DIR/codex-kill.rules" "$H/.codex/rules/oute-guard-kill.rules"
# falha ao copiar as regras (arquivo da imagem ausente): só AVISO, o setup segue (saída 0), sem regra nem .tmp, hook mantido
FN_OK="$FN"; FN="$TMP/fn-sem-regras.sh"; sed "s#codex-kill\.rules#ausente-kill.rules#" "$FN_OK" > "$FN"
H="$TMP/h2c"; run "$H" setup_agents FAKE_AI_MEMORY_BAK=0
check "kill sem regras: setup_agents sai 0 (só AVISO)"   test "$RC" -eq 0
check "kill sem regras: AVISO no stderr"                 bash -c 'echo "$1" | grep -qF "AVISO: falha ao gravar as regras do Codex"' _ "$OUT"
check "kill sem regras: nenhum arquivo de regras nem .tmp" bash -c '! ls "$1"/.codex/rules/oute-guard-kill.rules* >/dev/null 2>&1' _ "$H"
check "kill sem regras: o hook do Claude segue gravado"  jqe --arg c "$GK" '[.hooks.PreToolUse[] | select(any(.hooks[]; .command == $c))] | length == 1' "$H/.claude/settings.json"
FN="$FN_OK"; H="$TMP/h2b"
run "$H" setup_agents OUTE_AGENT_YOLO=0
check "kill: yolo=0 mantém o hook"                     jqe --arg c "$GK" '[.hooks.PreToolUse[] | select(any(.hooks[]; .command == $c))] | length == 1' "$S"

# ---------------------------------------------------------------- 3. OUTE_AGENT_YOLO=0
# O codex_config.py grava sandbox_mode = danger-full-access sempre (bwrap sem userns no container, #5, ADR-01):
# só approval_policy e o yolo do Claude dependem do OUTE_AGENT_YOLO.
H="$TMP/h3"; run "$H" setup_agents                      # com yolo (padrão), para o 0 ter o que tirar
check "yolo=1 (padrão): defaultMode e approval_policy presentes" bash -c 'jq -e ".permissions.defaultMode and .skipDangerousModePermissionPrompt" "$1/.claude/settings.json" >/dev/null && grep -q "^approval_policy" "$1/.codex/config.toml"' _ "$H"
run "$H" setup_agents OUTE_AGENT_YOLO=0
check "yolo=0: sai 0"                                   test "$RC" -eq 0
check "yolo=0: tira defaultMode e skipDangerousModePermissionPrompt" jqe '(.permissions.defaultMode // null) == null and (has("skipDangerousModePermissionPrompt") | not)' "$H/.claude/settings.json"
check "yolo=0: autoMemoryEnabled continua false"        jqe '.autoMemoryEnabled == false' "$H/.claude/settings.json"
check "yolo=0: hooks do Claude continuam"               jqe '.hooks.SessionStart | length == 1' "$H/.claude/settings.json"
check "yolo=0: tira approval_policy do Codex"           bash -c '! grep -q "^approval_policy" "$1/.codex/config.toml"' _ "$H"
check "yolo=0: sandbox_mode segue danger-full-access (container é a fronteira)" test "$(tget "$H/.codex/config.toml" sandbox_mode)" = danger-full-access
check "yolo=0: mcp_servers e trusted_hash continuam"    bash -c 'python3 -c "
import sys,tomllib; d=tomllib.load(open(sys.argv[1],\"rb\")); d[\"mcp_servers\"][\"ai-memory\"]; d[\"hooks\"][\"state\"]" "$1/.codex/config.toml"' _ "$H"
H="$TMP/h3b"; run "$H" setup_agents OUTE_AGENT_YOLO=0
check "yolo=0 em home vazio: settings.json sem yolo"    jqe '(.permissions.defaultMode // null) == null and (has("skipDangerousModePermissionPrompt") | not)' "$H/.claude/settings.json"

# ---------------------------------------------------------------- 4. blocos gerenciados (notas dos agentes)
H="$TMP/h4"; mkdir -p "$H/.claude" "$H/.codex"
printf 'texto do usuário no Claude\n' > "$H/.claude/CLAUDE.md"
printf '# meu AGENTS\n\nregra minha\n' > "$H/.codex/AGENTS.md"
run "$H" setup_agents; run "$H" setup_agents
check "notas: 2 execuções saem 0"                       test "$RC" -eq 0
for f in "$H/.claude/CLAUDE.md" "$H/.codex/AGENTS.md"; do
  n="${f#"$H/"}"
  check "notas $n: bloco ops-handoff uma única vez"     bash -c '[ "$(grep -c "^<!-- oute:managed:ops-handoff -->$" "$1")" -eq 1 ] && [ "$(grep -c "^<!-- /oute:managed:ops-handoff -->$" "$1")" -eq 1 ]' _ "$f"
  check "notas $n: conteúdo do bloco = agent-notes.md"  bash -c 'python3 - "$1" "$2" <<PY
import re,sys
t=open(sys.argv[1]).read(); m=re.search(r"<!-- oute:managed:ops-handoff -->\n(.*?)\n<!-- /oute:managed:ops-handoff -->",t,re.S)
sys.exit(0 if m and m.group(1)==open(sys.argv[2]).read().strip() else 1)
PY' _ "$f" "$LIB_DIR/agent-notes.md"
done
check "notas: regra de pedido que remove/recria/para lista dependentes e para sem alterar" grep -qF 'the script itself lists what depends on it and **stops without changing anything**' "$LIB_DIR/agent-notes.md"
check "notas: regra de pedido obsoleto: recusar antes e título do substituto"  grep -qF "replacement's title says it **replaces** the old one" "$LIB_DIR/agent-notes.md"
check "notas: texto do usuário fora do bloco preservado (Claude)" grep -qxF 'texto do usuário no Claude' "$H/.claude/CLAUDE.md"
check "notas: texto do usuário fora do bloco preservado (Codex)"  grep -qxF 'regra minha' "$H/.codex/AGENTS.md"
check "notas: usuário antes do bloco, não dentro dele"  bash -c 'a="$(grep -n "^regra minha$" "$1" | cut -d: -f1)"; b="$(grep -n "oute:managed:ops-handoff -->$" "$1" | head -1 | cut -d: -f1)"; [ "$a" -lt "$b" ]' _ "$H/.codex/AGENTS.md"
# bloco desatualizado é reescrito no lugar, sem duplicar
python3 - "$H/.claude/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(t.replace("<!-- /oute:managed:ops-handoff -->", "texto velho\n<!-- /oute:managed:ops-handoff -->"))
PY
run "$H" setup_agents
check "notas: bloco desatualizado volta ao texto atual, uma vez" bash -c '! grep -q "^texto velho$" "$1" && [ "$(grep -c "oute:managed:ops-handoff -->" "$1")" -eq 2 ]' _ "$H/.claude/CLAUDE.md"

# ---------------------------------------------------------------- 5. poda dos .bak (fica o mais antigo e os 2 mais recentes)
H="$TMP/h5"; mkdir -p "$H/.codex"   # o dublê sem .bak: só os do teste contam
for base in config.toml hooks.json; do
  for i in 1 2 3 4 5; do : > "$H/.codex/$base.bak-$i"; touch -d "2026-01-0$i 12:00:00" "$H/.codex/$base.bak-$i"; done
done
run "$H" setup_agents FAKE_AI_MEMORY_BAK=0
check "poda: sai 0"                                     test "$RC" -eq 0
for base in config.toml hooks.json; do
  check "poda $base: ficam o .bak mais antigo e os 2 mais recentes" test "$(cd "$H/.codex" && ls "$base".bak-* | sort | tr '\n' ' ')" = "$base.bak-1 $base.bak-4 $base.bak-5 "
done
for i in 1 2 3 4; do : > "$H/.codex/outro.bak-$i"; done   # só .bak do config.toml e do hooks.json são podados
run "$H" setup_agents FAKE_AI_MEMORY_BAK=0
check "poda: 2ª execução é estável e não toca em outros .bak" test "$(ls "$H"/.codex/outro.bak-* | wc -l)" -eq 4
check "poda: 2ª execução mantém os mesmos 3 do config.toml" test "$(cd "$H/.codex" && ls config.toml.bak-* | wc -l)" -eq 3
H="$TMP/h5b"; mkdir -p "$H/.codex"; : > "$H/.codex/config.toml.bak-1"; : > "$H/.codex/config.toml.bak-2"
run "$H" setup_agents FAKE_AI_MEMORY_BAK=0
check "poda: com 2 .bak nenhum é apagado"               test "$(ls "$H"/.codex/config.toml.bak-* | wc -l)" -eq 2

# ---------------------------------------------------------------- 6. setup_ssh
H="$TMP/h6"; mkdir -p "$H/.ssh"
printf 'Host velho\n  User fulano\n' > "$H/.ssh/config"
run "$H" setup_ssh OUTE_INSTANCE=oute-agent
check "ssh: sai 0"                                      test "$RC" -eq 0
SC="$H/.ssh/config"
check "ssh: Include na primeira linha do ~/.ssh/config" test "$(head -1 "$SC")" = 'Include ~/.ssh/config.d/*.conf'
check "ssh: config do usuário preservado depois do Include" grep -qx 'Host velho' "$SC"
check "ssh: oute-host.conf com IdentitiesOnly e User oute-ops" bash -c 'grep -qx "  IdentitiesOnly yes" "$1" && grep -qx "  User oute-ops" "$1" && grep -qx "Host oute-server oute-host" "$1"' _ "$H/.ssh/config.d/oute-host.conf"
check "ssh: gateway padrão 172.19.0.1"                  grep -qx '  HostName 172.19.0.1' "$H/.ssh/config.d/oute-host.conf"
check "ssh: chave do container e host key criadas"      bash -c '[ -f "$1/.ssh/oute-ops_ed25519" ] && [ -f "$1/.ssh/oute-ops_ed25519.pub" ] && [ -f "$1/.oute/ssh/ssh_host_ed25519_key" ]' _ "$H"
check "ssh: permissões 600 no config e no oute-host.conf" test "$(stat -c %a "$SC" "$H/.ssh/config.d/oute-host.conf" | sort -u)" = 600
cp "$SC" "$TMP/ssh1"; cp "$H/.ssh/config.d/oute-host.conf" "$TMP/ssh1.conf"; cp "$H/.ssh/oute-ops_ed25519.pub" "$TMP/ssh1.pub"
run "$H" setup_ssh OUTE_INSTANCE=oute-agent
check "ssh 2ª execução: sai 0 e config idêntico"        bash -c '[ "$2" -eq 0 ] && cmp -s "$1" "$3/.ssh/config"' _ "$TMP/ssh1" "$RC" "$H"
check "ssh 2ª execução: um só Include"                  test "$(count 'Include ~/.ssh/config.d/*.conf' "$SC")" -eq 1
check "ssh 2ª execução: oute-host.conf e chave iguais"  bash -c 'cmp -s "$1" "$3/.ssh/config.d/oute-host.conf" && cmp -s "$2" "$3/.ssh/oute-ops_ed25519.pub"' _ "$TMP/ssh1.conf" "$TMP/ssh1.pub" "$H"
run "$H" setup_ssh OUTE_NET_GATEWAY=10.9.8.1
check "ssh: OUTE_NET_GATEWAY muda o HostName"           grep -qx '  HostName 10.9.8.1' "$H/.ssh/config.d/oute-host.conf"
H="$TMP/h6b"; mkdir -p "$H/.ssh"; run "$H" setup_ssh   # o setup_integrations é quem cria ~/.ssh
check "ssh: sem ~/.ssh/config prévio, cria com o Include" test "$(head -1 "$H/.ssh/config")" = 'Include ~/.ssh/config.d/*.conf'
if [[ ! -f /etc/oute/authorized_keys ]]; then   # só onde o teste não tem o arquivo do host
  check "ssh: sem authorized_keys do host, avisa e não falha" bash -c '[ "$1" -eq 0 ] && grep -q "authorized_keys ausente" <<<"$2"' _ "$RC" "$OUT"
fi

# ---------------------------------------------------------------- 7. asserts estáticos do compose
AG="$TMP/agent-block.yaml"; awk '/^  agent:/{f=1;next} f&&/^  [a-z]/{exit} f' "$COMPOSE" > "$AG"
check "compose: bloco do serviço agent achado"          test -s "$AG"
check "compose: sshd em 127.0.0.1 por padrão (OUTE_SSH_BIND)" grep -qF '"${OUTE_SSH_BIND:-127.0.0.1}:${OUTE_SSH_PORT:-2222}:2222"' "$AG"
check "compose: o agent publica uma porta só, a do sshd" bash -c '[ "$(awk "/^    ports:/{f=1;next} f&&/^      - /{n++;next} f&&!/^      #/{exit} END{print n+0}" "$1")" -eq 1 ]' _ "$AG"
check "compose: nenhuma porta publicada em 0.0.0.0"     bash -c '! grep -E "^ +- \"?0\.0\.0\.0:" "$1"' _ "$COMPOSE"
check "compose: nenhuma BW_*"                           bash -c '! grep -q "BW_" "$1"' _ "$COMPOSE"
check "compose: agent_env é o único secret do agent"    test "$(awk '/^    secrets:/{f=1;next} f&&/^      - /{print $2;next} f&&!/^      #/{exit}' "$AG")" = agent_env
check "compose: agent_env é o único secret do arquivo"  test "$(awk '/^secrets:/{f=1;next} f&&/^[a-z]/{exit} f&&/^  [a-z_]+:/{gsub(/[ :]/,"");print}' "$COMPOSE")" = agent_env
for v in AGENT_STUDIO_INGEST_TOKEN AGENT_STUDIO_TOKEN AGENT_STUDIO_SURREAL_PASS SURREAL_USER SURREAL_PASS; do
  check "compose: segredo de serviço $v fora do agent (#256)" bash -c '! grep -qE "^ +$2:" "$1"' _ "$AG" "$v"
done
check "compose: o agent só tem o AGENT_STUDIO_URL de leitura (sem token no environment)" bash -c '[ "$(grep -c "AGENT_STUDIO_" "$1")" -eq 1 ] && grep -q "AGENT_STUDIO_URL:" "$1"' _ "$AG"

check_end
