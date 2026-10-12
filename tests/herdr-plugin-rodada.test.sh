#!/usr/bin/env bash
# Testes do plugin herdr oute.rodada (#722, protótipo): docker/herdr-plugins/oute.rodada/oute-rodada-sync e o manifesto.
# Bash puro + jq, sem Docker, sem rede e sem servidor do herdr: herdr, curl e oute-emit são dublês no PATH que gravam os
# argumentos (e o stdin do curl); a cota é o tests/lib/fake-oute-quota.sh. Só comportamento externo: o que o script manda
# ao herdr, ao curl e ao oute-emit, e o código de saída. Uso: tests/herdr-plugin-rodada.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v flock >/dev/null || die "precisa de jq e flock"
PLUGIN="$ROOT/docker/herdr-plugins/oute.rodada"
SYNC="$PLUGIN/oute-rodada-sync"

FAKE="$TMP/fake"; BIN="$TMP/bin"; mkdir -p "$FAKE" "$BIN"
export FAKE
# herdr falso: uma linha por chamada em $FAKE/herdr.calls; FAKE_HERDR_RC faz a chamada falhar
cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/herdr.calls"
exit "${FAKE_HERDR_RC:-0}"
SH
# curl falso: o stdin (a configuração com o token) e os argumentos vão para arquivos; FAKE_CURL_RC falha a chamada
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/curl.args"
cat > "$FAKE/curl.stdin"
[[ "${FAKE_CURL_RC:-0}" == 0 ]] || exit "$FAKE_CURL_RC"
printf '%s' '{"bar":{"pending":2,"alerts":0},"cost_today":{"usd":53.257}}'
SH
cat > "$BIN/oute-emit" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/emit.calls"
SH
cp "$ROOT/tests/lib/fake-oute-quota.sh" "$BIN/oute-quota"
chmod +x "$BIN"/*

# rodada fixture: dispatcher em w3:p1, três sessões (uma fechada), um PR com CI pendente na 722
SW="$TMP/swarm"; R="$SW/swarm-teste"; mkdir -p "$R"
printf 'repo=/workspace/oute-agent\nmax=3\ndispatcher_pane=w3:p1\nname=Brave_Baker\n' > "$R/meta"
cat > "$R/spawned" <<'EOT'
713-typing-guard w3:p3 claude 2026-10-12T00:08:01Z w3:t3 /workspace/oute-agent - claude
722-sidebar-herdr w3:p4 claude 2026-10-12T00:08:02Z w3:t4 /workspace/oute-agent - claude
725-doctor-captura w3:p5 claude 2026-10-12T00:08:03Z w3:t5 /workspace/oute-agent - claude
EOT
echo 725-doctor-captura > "$R/closed"
printf 'agent|713-typing-guard\tidle\nagent|722-sidebar-herdr\tworking\nagent|725-doctor-captura\tdone\n' > "$R/watch.state"
printf 'pr|810|713\tOPEN\nci|810|build\tpass\nci|810|SonarCloud\tpending\npr|811|722\tOPEN\nci|811|build\tpending\n' >> "$R/watch.state"

# run <evento>: uma atualização com estado limpo do plugin; zera os registros dos dublês
run() {
  local event="${1:-pane.agent_status_changed}"
  rm -f "${FAKE:?}"/herdr.calls "${FAKE:?}"/curl.args "${FAKE:?}"/curl.stdin "${FAKE:?}"/emit.calls
  PATH="$BIN:$PATH" OUTE_SWARM_STATE_ROOT="${SWROOT:-$SW}" HERDR_PLUGIN_STATE_DIR="$TMP/state" HERDR_BIN_PATH="$BIN/herdr" \
    AGENT_STUDIO_URL="https://studio.invalido" AGENT_STUDIO_READ_TOKEN="${TOKEN-tok-de-teste}" \
    OUTE_RODADA_MIN_INTERVAL="${MIN:-0}" HERDR_PLUGIN_EVENT="$event" \
    bash "$SYNC" "${@:2}"
  RC=$?
  return 0
}
calls() { cat "$FAKE/herdr.calls" 2>/dev/null; return 0; }

# ---------------------------------------------------------------- 1. o caminho feliz
run
check "sai com 0"                                   test "$RC" -eq 0
OUT="$(calls)"
check "pane da 722: issue, sessão e PR com CI"      has_line "pane report-metadata w3:p4 --source oute.rodada --ttl-ms 300000 --token oute_issue=#722 --token oute_sessao=working --token oute_pr=#811 open · ci rodando"
check "pane da 713: PR 810 e CI com pendente"       has "pane report-metadata w3:p3 .*oute_sessao=idle --token oute_pr=#810 open · ci rodando"
check "sessão fechada não é reportada"              hasnt 'w3:p5'
check "workspace do dispatcher: rodada, cota, custo" has_line 'workspace report-metadata w3 --source oute.rodada --ttl-ms 300000 --token oute_rodada=Brave_Baker · 2 ab. --token oute_cota=cl 10/10 cx 10/10 --token oute_custo=$53 hoje · 2 pend'
check "token do studio vai pelo stdin, não no argv" bash -c "grep -q 'tok-de-teste' '$FAKE/curl.stdin' && ! grep -q 'tok-de-teste' '$FAKE/curl.args'"
check "curl só lê o /v1/tray"                       grep -q '/v1/tray' "$FAKE/curl.args"
OUT="$(cat "$FAKE/emit.calls" 2>/dev/null)"
check "telemetria: um oute-emit sidebar ok"         has '^sidebar trigger=pane.agent_status_changed result=ok panes=2 workspaces=1 rounds=1 ms=[0-9]* quota=ok studio=ok$'

# ---------------------------------------------------------------- 2. telemetria no máximo a cada OUTE_RODADA_EMIT_EVERY
run pane.closed
check "2ª atualização dentro de 5 min não emite"    test ! -s "$FAKE/emit.calls"
check "…mas atualiza o sidebar"                     test -s "$FAKE/herdr.calls"

# ---------------------------------------------------------------- 3. espaçamento mínimo e ação manual
rm -rf "${TMP:?}/state"; MIN=60 run
check "1ª chamada com intervalo longo roda"         test -s "$FAKE/herdr.calls"
MIN=60 run
check "2ª chamada dentro do intervalo não roda"     test ! -s "$FAKE/herdr.calls"
MIN=60 run action --force
check "--force ignora o intervalo"                  test -s "$FAKE/herdr.calls"
OUT="$(cat "$FAKE/emit.calls" 2>/dev/null)"
check "--force: o gatilho é action"                 hasnt_str 'trigger=pane'

# ---------------------------------------------------------------- 4. rodada fechada
touch "$R/fechada"; rm -rf "${TMP:?}/state"
run
check "rodada com a marca fechada: nada ao herdr"   test ! -s "$FAKE/herdr.calls"
check "…e sai com 0"                                test "$RC" -eq 0
rm -f "${R:?}/fechada"

# ---------------------------------------------------------------- 5. fontes que falham
rm -rf "${TMP:?}/state"; FAKE_CURL_RC=22 run
OUT="$(calls)"
check "studio fora: sem token de custo"             hasnt 'oute_custo'
check "studio fora: cota segue"                     has 'oute_cota=cl 10/10'
OUT="$(cat "$FAKE/emit.calls" 2>/dev/null)"
check "studio fora: resultado parcial e studio=erro" has 'result=parcial .* studio=erro$'
rm -rf "${TMP:?}/state"
printf '{"schema":1,"agents":{"claude":{"status":"unknown","reason":"token-expirado","windows":{}},"codex":{"status":"unknown","reason":"rede","windows":{}}}}' > "$FAKE/quota.json"
run
OUT="$(calls)"
check "cota unknown: token mostra ?"                has 'oute_cota=cl ? cx ?'
OUT="$(cat "$FAKE/emit.calls" 2>/dev/null)"
check "cota unknown: quota=unknown"                 has 'quota=unknown'
rm -f "${FAKE:?}/quota.json"
rm -rf "${TMP:?}/state"; FAKE_HERDR_RC=1 run
check "herdr recusa: sai com 0 mesmo assim"         test "$RC" -eq 0
OUT="$(cat "$FAKE/emit.calls" 2>/dev/null)"
check "herdr recusa: result=parcial"                has 'result=parcial'
rm -rf "${TMP:?}/state"; TOKEN="" run
check "sem token do studio: não chama o curl"       test ! -e "$FAKE/curl.args"
OUT="$(cat "$FAKE/emit.calls" 2>/dev/null)"
check "sem token do studio: studio=off"             has 'studio=off'

# ---------------------------------------------------------------- 5b. CI vermelho, CI verde e PR de outro repo
SW2="$TMP/swarm-ci"; R2="$SW2/swarm-ci"; mkdir -p "$R2"
printf 'repo=/workspace/oute-agent\ndispatcher_pane=w4:p1\nname=Teste_CI\n' > "$R2/meta"
cat > "$R2/spawned" <<'EOT'
730-ci-vermelho w4:p2 claude 2026-10-12T00:08:01Z w4:t2 /workspace/oute-agent - claude
731-ci-verde w4:p3 claude 2026-10-12T00:08:02Z w4:t3 /workspace/oute-agent - claude
732-outro-repo w4:p4 claude 2026-10-12T00:08:03Z w4:t4 /workspace/oute-agent - claude
EOT
: > "$R2/closed"
printf 'agent|730-ci-vermelho\tidle\nagent|731-ci-verde\tidle\nagent|732-outro-repo\tworking\n' > "$R2/watch.state"
printf 'pr|830|730\tOPEN\nci|830|build\tfail\nci|830|SonarCloud\tpending\n' >> "$R2/watch.state"
printf 'pr|831|731\tOPEN\nci|831|build\tpass\nci|831|SonarCloud\tpass\n' >> "$R2/watch.state"
printf 'pr|dono/repo#12|dono/repo#732\tOPEN\nci|dono/repo#12|build\tpass\n' >> "$R2/watch.state"
rm -rf "${TMP:?}/state"; SWROOT="$SW2" run
OUT="$(calls)"
check "CI com falha: ci vermelho (vence o pendente)" has 'report-metadata w4:p2 .*oute_pr=#830 open · ci vermelho'
check "CI todo pass: ci verde"                       has 'report-metadata w4:p3 .*oute_pr=#831 open · ci verde'
check "PR de outro repo (dono/repo#n): achado pela issue, com o prefixo" has 'report-metadata w4:p4 .*oute_issue=#732 .*oute_pr=dono/repo#12 open · ci verde'

# ---------------------------------------------------------------- 6. manifesto
check "manifesto: id oute.rodada"                   grep -q '^id = "oute.rodada"$' "$PLUGIN/herdr-plugin.toml"
check "script executável (100755)"                  test -x "$SYNC"
# o herdr real valida o manifesto no link; `env -i` sem HERDR_SOCKET_PATH: o registro vai para o HOME do teste e o
# servidor da sessão não é tocado
if command -v herdr >/dev/null 2>&1; then
  mkdir -p "$TMP/home"
  OUT="$(env -i HOME="$TMP/home" PATH="$PATH" LANG=C.UTF-8 herdr plugin link "$PLUGIN" 2>&1)"
  check "herdr valida o manifesto (plugin_linked)"  jqe '.result.type == "plugin_linked"' <<<"$OUT"
  check "…sem avisos de manifesto"                  jqe '(.result.plugin.warnings // []) | length == 0' <<<"$OUT"
  check "…com os 4 eventos e a ação declarados"     jqe '(.result.plugin.events | length) == 4 and (.result.plugin.actions | length) == 1' <<<"$OUT"
else
  ok "sem herdr no PATH (CI): validação do manifesto pulada"
fi

check_end
