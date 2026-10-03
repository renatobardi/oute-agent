#!/usr/bin/env bash
# Testes do `oute-quota` (#346): leitura da cota das assinaturas Claude e Codex, só GET por https, sem escrever nem
# renovar credencial. Endpoints falsos com TLS de teste (tests/lib/fake-quota.py, certificado gerado na hora pelo openssl);
# um `curl` no PATH só registra o argv e chama o de verdade. Tokens sentinela gerados na hora, nunca reais.
# Datas com horas de folga do que o comando confere (nunca no limite). Só comportamento externo.
# Uso: tests/oute-quota.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; SRV_PID=""
trap '[[ -z "$SRV_PID" ]] || kill "$SRV_PID" 2>/dev/null; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v openssl >/dev/null && command -v curl >/dev/null && command -v python3 >/dev/null \
  || die "precisa de jq, openssl, curl e python3"
QUOTA="$ROOT/docker/oute-quota"
[[ -x "$QUOTA" ]] || die "oute-quota ausente ou sem +x: $QUOTA"

# --- servidor falso com TLS
SD="$TMP/srv"; mkdir -p "$SD"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
  -keyout "$SD/key.pem" -out "$SD/cert.pem" >/dev/null 2>&1 || die "o openssl não gerou o certificado"
python3 "$ROOT/tests/lib/fake-quota.py" "$SD" & SRV_PID=$!
for _ in $(seq 1 50); do [[ -s "$SD/port" ]] && break; sleep 0.1; done
[[ -s "$SD/port" ]] || die "o servidor falso não subiu"
BASE="https://127.0.0.1:$(cat "$SD/port")"

# --- ambiente do comando (isolado do real)
H="$TMP/home"; CL="$H/.claude"; CX="$H/.codex"; mkdir -p "$CL" "$CX" "$TMP/bin"
REALCURL="$(command -v curl)"
cat > "$TMP/bin/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/argv.log"
exec "$REALCURL" "\$@"
CURL
chmod +x "$TMP/bin/curl"
export HOME="$H" XDG_CACHE_HOME="$TMP/cache" CLAUDE_CONFIG_DIR="$CL" CODEX_HOME="$CX" \
  OUTE_QUOTA_CLAUDE_URL="$BASE/claude/api/oauth/usage" OUTE_QUOTA_CODEX_URL="$BASE/codex/backend-api/wham/usage" \
  SSL_CERT_FILE="$SD/cert.pem" CURL_CA_BUNDLE="$SD/cert.pem" PATH="$TMP/bin:$PATH"
unset OUTE_QUOTA_MAX_PCT OUTE_QUOTA_TIMEOUT
CTOK="ctok$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
XTOK_RAW="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
ACCT="acct-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
CACHE="$XDG_CACHE_HOME/oute-quota"

now=$(date +%s)
R5C=$((now + 7200)); R7C=$((now + 172800)); R5X=$((now + 10800)); R7X=$((now + 400000))
iso() { date -u -d "@$1" +%FT%TZ; }
loc() { TZ="$2" date -d "@$1" +%Y-%m-%dT%H:%M:%S%:z; }   # hora do reset no fuso $2, com o deslocamento (#415)

b64u() { python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).decode().rstrip("="))'; }
jwt() { # exp
  printf '{"alg":"none"}' | b64u | tr -d '\n'; printf '.'
  printf '{"exp":%s,"jti":"%s"}' "$1" "$XTOK_RAW" | b64u | tr -d '\n'; printf '.assinatura\n'
}
claude_cred() { # offset do expiresAt, em segundos (negativo = expirado)
  jq -n --arg t "$CTOK" --argjson e $(( (now + $1) * 1000 )) '{claudeAiOauth:{accessToken:$t, refreshToken:"refresh-\($t)", expiresAt:$e}}' > "$CL/.credentials.json"
}
codex_cred() { # offset do exp do JWT
  XJWT="$(jwt $((now + $1)))"
  jq -n --arg t "$XJWT" --arg a "$ACCT" '{tokens:{access_token:$t, refresh_token:"refresh-codex", account_id:$a}}' > "$CX/auth.json"
}
bodies() { # o que os endpoints devolvem quando ok
  printf '{"five_hour":{"utilization":15.0,"resets_at":"%s.123456+00:00"},"seven_day":{"utilization":34.0,"resets_at":"%s.000000+00:00"},"limits":[]}' \
    "$(date -u -d "@$R5C" +%FT%T)" "$(date -u -d "@$R7C" +%FT%T)" > "$SD/claude.body"
  printf '{"rate_limit":{"primary_window":{"used_percent":7,"reset_at":%s},"secondary_window":{"used_percent":21.5,"reset_at":%s}}}' \
    "$R5X" "$R7X" > "$SD/codex.body"
}
mode() { printf '%s' "$2" > "$SD/$1.mode"; }
reset_world() { # estado de partida de cada caso: credenciais vigentes, endpoints ok, sem cache, sem pedidos
  rm -rf "${CACHE:?}" "${SD:?}/claude.mode" "${SD:?}/codex.mode" "${SD:?}/requests.jsonl" "${SD:?}/retry-after" "${SD:?}/hang" "${TMP:?}/argv.log"
  claude_cred 14400; codex_cred 14400; bodies
}
write_cache() { # agente idade_s resets_at_s
  mkdir -p "$CACHE"
  jq -n --argjson r $((now - $2)) --argjson e "$3" '{read_at:$r, windows:{"5h":{used_pct:41,resets_at_s:$e},"7d":{used_pct:52,resets_at_s:$e}}}' > "$CACHE/$1.json"
}
reqs() { { cat "$SD/requests.jsonl" 2>/dev/null || true; } | grep -c . || true; }
reqs_of() { { grep "\"agent\": \"$1\"" "$SD/requests.jsonl" 2>/dev/null || true; } | grep -c . || true; }
run() { OUT="$("$QUOTA" "$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }
oj() { jq -e "$1" <<<"$OUT" >/dev/null 2>&1; }
rc_and_oj() { [[ "$RC" -eq "$1" ]] && oj "$2"; }
cred_state() { stat -c '%y' "$CL/.credentials.json" "$CX/auth.json" 2>/dev/null; sha256sum "$CL/.credentials.json" "$CX/auth.json" 2>/dev/null; }
tree_hash() { (cd "$H" && find . -type f -not -path './.cache/*' | sort | xargs sha256sum 2>/dev/null); }
no_secret() { ! grep -qF -e "$CTOK" -e "$XJWT" -e "$XTOK_RAW" -e "$ACCT" "$@"; }

# ============ 200 nos dois ============
reset_world; BEFORE="$(cred_state)"; TREE="$(tree_hash)"
run --json
check "200: saída 0" test "$RC" -eq 0
check "200: JSON no contrato (schema, max_pct, reset_grace_s, read_at)" oj '.schema == 1 and .max_pct == 90 and .reset_grace_s == 1200 and (.read_at|test("^[0-9]{4}-.*Z$"))'
check "200: claude ok, 5h 15% e 7d 34% com o reset em UTC" oj ".agents.claude | .status == \"ok\" and .reason == null and .stale == false and .age_s == 0 and .windows[\"5h\"].used_pct == 15 and .windows[\"5h\"].resets_at == \"$(iso $R5C)\" and .windows[\"7d\"].used_pct == 34 and .windows[\"7d\"].resets_at == \"$(iso $R7C)\""
check "200: resets_in_s coerente (reset − agora)" oj '.agents.claude.windows["5h"].resets_in_s | . > 7000 and . <= 7200'
check "200: codex ok, 5h 7% e 7d 21.5% (reset_at em epoch)" oj ".agents.codex | .status == \"ok\" and .windows[\"5h\"].used_pct == 7 and .windows[\"5h\"].resets_at == \"$(iso $R5X)\" and .windows[\"7d\"].used_pct == 21.5 and .windows[\"7d\"].resets_at == \"$(iso $R7X)\""
check "200: um pedido por agente, os dois GET" bash -c '[ "$(jq -s "map(select(.method == \"GET\")) | length" "$1")" = 2 ] && [ "$(jq -s length "$1")" = 2 ]' _ "$SD/requests.jsonl"
check "200: Claude com Bearer e anthropic-beta" bash -c 'jq -e "select(.agent == \"claude\") | .auth == \"Bearer $1\" and .beta == \"oauth-2025-04-20\"" "$2" >/dev/null' _ "$CTOK" "$SD/requests.jsonl"
check "200: Codex com Bearer (o JWT) e ChatGPT-Account-Id" bash -c 'jq -e "select(.agent == \"codex\") | .auth == \"Bearer $1\" and .account == \"$2\"" "$3" >/dev/null' _ "$XJWT" "$ACCT" "$SD/requests.jsonl"
check "200: nenhum token nem account id no argv do curl, que usa -K -" bash -c '! grep -qF -e "$1" -e "$2" -e "$3" "$4" && grep -q -e "-K -" "$4"' _ "$CTOK" "$XJWT" "$ACCT" "$TMP/argv.log"
check "200: só https, um endereço por agente" bash -c '! grep -q "http:" "$1" && [ "$(grep -c "https://127.0.0.1" "$1")" = 2 ]' _ "$TMP/argv.log"
printf '%s\n%s\n' "$OUT" "$ERR" > "$TMP/saida.txt"
check "200: token nunca na saída nem no erro" no_secret "$TMP/saida.txt"
check "200: cache sem token (nem refresh), só % e reset" bash -c 'grep -rqF refresh "$1" && exit 1; jq -e ".windows[\"5h\"].used_pct == 15" "$1/claude.json" >/dev/null' _ "$CACHE"
check "200: cache sem nenhum token" no_secret "$CACHE"/*.json
check "credencial: mtime e hash dos dois arquivos iguais" test "$BEFORE" = "$(cred_state)"
check "credencial: nenhum arquivo novo ou alterado no home" test "$TREE" = "$(tree_hash)"

# ============ tabela ============
reset_world
TZ=UTC run   # o TZ do container (America/Sao_Paulo na imagem) não pode mudar este caso: fixo em UTC (+00:00)
check "tabela: saída 0" test "$RC" -eq 0
check "tabela: cabeçalho" has "^agente  *janela  *usada  *reset"
check "tabela: linha do claude 5h com % e reset" has "^claude  *5h  *15.0%  *$(loc $R5C UTC)"
check "tabela: linha do codex 7d" has "^codex  *7d  *21.5%  *$(loc $R7X UTC)"
# fuso do container (#415): o reset sai na hora local com o deslocamento; o --json segue em UTC
TZ=America/Sao_Paulo run
check "tabela em America/Sao_Paulo: reset do claude 5h em -03:00" has "^claude  *5h  *15.0%  *$(loc $R5C America/Sao_Paulo)  *\$"
check "tabela em America/Sao_Paulo: reset do codex 7d em -03:00" has "^codex  *7d  *21.5%  *$(loc $R7X America/Sao_Paulo)"
check "tabela em America/Sao_Paulo: o deslocamento é -03:00" has "5h  *15.0%  *[0-9T:-]*-03:00"
check "tabela em America/Sao_Paulo: sem a hora em UTC (Z)" hasnt "T[0-9:]*Z"
TZ=Asia/Kolkata run
check "tabela em Asia/Kolkata: deslocamento com meia hora (+05:30)" has "^claude  *5h  *15.0%  *$(loc $R5C Asia/Kolkata)"
TZ=America/Sao_Paulo run --json
check "--json em America/Sao_Paulo segue em UTC (Z)" oj ".agents.claude.windows[\"5h\"].resets_at == \"$(iso $R5C)\" and .agents.codex.windows[\"7d\"].resets_at == \"$(iso $R7X)\""

# ============ --agent e uso ============
reset_world
run --json --agent codex
check "--agent codex: só o codex na saída" oj '(.agents|keys) == ["codex"] and .agents.codex.status == "ok"'
check "--agent codex: um único pedido, ao Codex" bash -c '[ "$1" = 1 ] && [ "$2" = 1 ]' _ "$(reqs)" "$(reqs_of codex)"
run --agent outro;  check "--agent inválido: saída 2" test "$RC" -eq 2
run --agent;        check "--agent sem valor: saída 2" test "$RC" -eq 2
run --bobagem;      check "argumento desconhecido: saída 2" test "$RC" -eq 2
NOTLS="ht""tp://127.0.0.1:1/x"
OUTE_QUOTA_CLAUDE_URL="$NOTLS" run --json
check "endereço sem TLS recusado: saída 2" test "$RC" -eq 2
OUTE_QUOTA_MAX_PCT=abc run --json
check "OUTE_QUOTA_MAX_PCT inválido: saída 2" test "$RC" -eq 2
OUTE_QUOTA_MAX_PCT=80 run --json
check "OUTE_QUOTA_MAX_PCT=80 é ecoado no --json" oj '.max_pct == 80'

# ============ cache ============
reset_world; run --json; N1="$(reqs)"
run --json
check "cache curto: segunda chamada não vai à rede" test "$(reqs)" = "$N1"
check "cache curto: continua ok, sem stale, mesmos valores" oj '.agents.claude.status == "ok" and .agents.claude.stale == false and .agents.claude.windows["5h"].used_pct == 15 and .agents.codex.status == "ok"'
reset_world; write_cache claude 600 $R5C
run --json --agent claude
check "cache velho (10 min) com endpoint ok: leitura nova, stale false, valores novos" oj '.agents.claude.status == "ok" and .agents.claude.stale == false and .agents.claude.age_s == 0 and .agents.claude.windows["5h"].used_pct == 15'
check "cache velho com endpoint ok: foi à rede" test "$(reqs)" = 1
reset_world; write_cache claude 600 $R5C; mode claude 429
run --json --agent claude
check "cache velho (10 min) + 429: devolve o cache com stale true e age_s" oj '.agents.claude.status == "ok" and .agents.claude.stale == true and .agents.claude.age_s >= 600 and .agents.claude.age_s < 700 and .agents.claude.windows["5h"].used_pct == 41'
check "cache velho + 429: saída 0" test "$RC" -eq 0
reset_world; write_cache claude 600 $R5C; mode claude 429
run --agent claude
check "cache velho + 429 na tabela: obs de cache" has "cache de [0-9]*s"
reset_world; write_cache claude 7200 $R5C; mode claude 429
run --json --agent claude
check "cache de 2 h (além de 30 min) + 429: unknown http-429, sem usar o cache" oj '.agents.claude.status == "unknown" and .agents.claude.reason == "http-429" and .agents.claude.windows == {}'
reset_world; write_cache claude 600 $((now - 3600)); mode claude 429
run --json --agent claude
check "cache com janela já resetada + 429: descartado, unknown" oj '.agents.claude.status == "unknown" and .agents.claude.reason == "http-429"'
reset_world; write_cache claude 600 $R5C; mode claude 5xx
run --json --agent claude
check "cache velho + HTTP 503: unknown http-503 (o cache só cobre 429, rede e timeout)" oj '.agents.claude.status == "unknown" and .agents.claude.reason == "http-503"'

# ============ 429 com retry-after ============
reset_world; mode claude 429; printf 294 > "$SD/retry-after"
run --json --agent claude
check "429 sem cache: unknown http-429 com retry_after_s 294" oj '.agents.claude.status == "unknown" and .agents.claude.reason == "http-429" and .agents.claude.retry_after_s == 294'
check "429 sem cache: saída 1 (o único agente lido ficou unknown)" test "$RC" -eq 1
N1="$(reqs)"
run --json --agent claude
check "429: nova chamada dentro do retry-after não vai à rede" test "$(reqs)" = "$N1"
check "429: nova chamada ainda dá http-429, com retry_after_s entre 1 e 294" oj '.agents.claude.reason == "http-429" and .agents.claude.retry_after_s > 0 and .agents.claude.retry_after_s <= 294'
run --agent claude
check "429 na tabela: motivo e retry-after" has "http-429 (retry-after"
reset_world; mode claude 429; mode codex 429
run --json
check "429 nos dois: saída 1 e JSON válido" rc_and_oj 1 '.schema == 1 and .agents.claude.status == "unknown" and .agents.codex.status == "unknown"'

# ============ token expirado ============
reset_world; claude_cred -7200; codex_cred -7200; BEFORE="$(cred_state)"
run --json
check "token expirado nos dois: unknown token-expirado" oj '.agents.claude.status == "unknown" and .agents.claude.reason == "token-expirado" and .agents.codex.reason == "token-expirado"'
check "token expirado nos dois: saída 1" test "$RC" -eq 1
check "token expirado: nenhum pedido (nem refresh) à rede" test "$(reqs)" = 0
check "token expirado: mtime e hash das credenciais iguais (sem renovar)" test "$BEFORE" = "$(cred_state)"
reset_world; write_cache claude 600 $R5C; claude_cred -7200
run --json --agent claude
check "token expirado com cache de 10 min: unknown, não devolve o cache como ok" oj '.agents.claude.status == "unknown" and .agents.claude.reason == "token-expirado"'
reset_world; claude_cred -7200
run --json
check "só o claude expirado: codex ok, saída 0" rc_and_oj 0 '.agents.claude.status == "unknown" and .agents.codex.status == "ok"'

# ============ sem credencial ============
reset_world; rm -f "$CL/.credentials.json" "$CX/auth.json"
run --json
check "sem credencial: unknown sem-credencial nos dois" oj '.agents.claude.reason == "sem-credencial" and .agents.codex.reason == "sem-credencial"'
check "sem credencial: saída 1 e nada na rede" bash -c '[ "$1" = 1 ] && [ "$2" = 0 ]' _ "$RC" "$(reqs)"
check "sem credencial: não cria credencial" bash -c '[ ! -e "$1" ] && [ ! -e "$2" ]' _ "$CL/.credentials.json" "$CX/auth.json"
reset_world; echo '{"claudeAiOauth":{}}' > "$CL/.credentials.json"; echo 'não é json' > "$CX/auth.json"
run --json
check "credencial sem token ou ilegível: sem-credencial" oj '.agents.claude.reason == "sem-credencial" and .agents.codex.reason == "sem-credencial"'
reset_world; rm -f "$CX/auth.json"
run --json
check "só o codex sem credencial: claude ok, saída 0" rc_and_oj 0 '.agents.claude.status == "ok" and .agents.codex.reason == "sem-credencial"'

# ============ formato, HTTP e rede ============
reset_world; mode claude formato; mode codex lixo
run --json
check "formato inesperado (JSON sem janelas) e corpo que não é JSON: unknown formato" oj '.agents.claude.reason == "formato" and .agents.codex.reason == "formato"'
check "formato: saída 1" test "$RC" -eq 1
reset_world; printf '{"five_hour":{"utilization":"muito","resets_at":"2026-01-01T00:00:00Z"},"seven_day":null}' > "$SD/claude.body"
run --json --agent claude
check "janela com tipo errado: unknown formato" oj '.agents.claude.reason == "formato"'
reset_world; mode claude 5xx
run --json
check "HTTP 503 no claude: unknown http-503, codex ok, saída 0" rc_and_oj 0 '.agents.claude.reason == "http-503" and .agents.codex.status == "ok"'
reset_world; OUTE_QUOTA_CLAUDE_URL="https://127.0.0.1:1/x" run --json --agent claude
check "rede fora (conexão recusada): unknown rede" oj '.agents.claude.reason == "rede"'
reset_world; OUTE_QUOTA_CLAUDE_URL="https://127.0.0.1:1/x" run --json
check "rede fora só num agente: o outro continua ok, saída 0" rc_and_oj 0 '.agents.codex.status == "ok" and .agents.claude.reason == "rede"'
reset_world; mode claude hang; mode codex hang; printf 4 > "$SD/hang"
T0=$SECONDS; OUTE_QUOTA_TIMEOUT=1 run --json; T1=$((SECONDS - T0))
check "timeout: unknown timeout nos dois" oj '.agents.claude.reason == "timeout" and .agents.codex.reason == "timeout"'
check "timeout: os dois em paralelo (≤ 3 s com teto de 1 s por agente)" test "$T1" -le 3
check "timeout: saída 1" test "$RC" -eq 1
reset_world; write_cache claude 600 $R5C; mode claude hang; printf 4 > "$SD/hang"
OUTE_QUOTA_TIMEOUT=1 run --json --agent claude
check "timeout com cache de 10 min: cache stale" oj '.agents.claude.status == "ok" and .agents.claude.stale == true'
reset_world; write_cache claude 600 $R5C
OUTE_QUOTA_CLAUDE_URL="https://127.0.0.1:1/x" run --json --agent claude
check "rede fora com cache de 10 min: cache stale" oj '.agents.claude.status == "ok" and .agents.claude.stale == true'

# ============ só leitura ============
reset_world
for m in 429 5xx lixo formato; do mode claude $m; mode codex $m; "$QUOTA" --json >/dev/null 2>&1; done
rm -rf "${CACHE:?}"; claude_cred -7200; "$QUOTA" --json >/dev/null 2>&1
check "só GET: nenhum pedido de outro método nesses cenários" bash -c '! jq -e "select(.method != \"GET\")" "$1" >/dev/null 2>&1' _ "$SD/requests.jsonl"
reset_world; BEFORE="$(cred_state)"
bash -x "$QUOTA" --json >"$TMP/xt.out" 2>&1
check "bash -x não vaza token" no_secret "$TMP/xt.out"
check "bash -x: credenciais intactas" test "$BEFORE" = "$(cred_state)"

check_end
