#!/usr/bin/env bash
# Guia do `oute help` × prompt do `oute approve` (#231). Bash puro, sem Docker: só lê os dois arquivos.
# O guia (docker/comandos.md) já descreveu as teclas ao contrário do código (N = recusa, r = relê). Aqui a
# linha do guia é conferida contra o prompt e os ramos do `case` do scripts/oute, que são a fonte.
# Uso: tests/comandos-approve.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTE="${OUTE:-$ROOT/scripts/oute}"
GUIDE="${GUIDE:-$ROOT/docker/comandos.md}"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ---------------------------------------------------------------- a fonte: scripts/oute
# corpo do approve_one, do prompt até o fim do case
body="$(awk '/^approve_one\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$OUTE")"
check "código: prompt [s]im / [N]ão agora / [r]ecusar" grep -qF 'executar? [s]im / [N]ão agora / [r]ecusar: ' <<<"$body"
check "código: s executa"                             grep -qE '^ +s\|S\|sim\)$' <<<"$body"
check "código: r recusa"                              grep -qE '^ +r\|R\)$' <<<"$body"
check "código: o resto (N, Enter) fica pendente"      grep -qE '^ +\*\) echo "fica pendente\." ;;$' <<<"$body"

# ---------------------------------------------------------------- o guia
line="$(grep -E '^  oute approve +revisa ' "$GUIDE")"
check "guia: uma linha do oute approve"   [ "$(grep -c . <<<"$line")" -eq 1 ]
check "guia: s = executa"                 grep -qE '[(, ]s = executa' <<<"$line"
check "guia: N = deixa pendente"          grep -qE '[(, ]N( ou Enter)? = deixa pendente' <<<"$line"
check "guia: r = recusa"                  grep -qE '[(, ]r = recusa' <<<"$line"
check "guia: N não recusa"                bash -c '! grep -qE "N[^,)]*= recusa" <<<"$1"' _ "$line"
check "guia: não existe relê no approve"  bash -c '! grep -qi "rel[eê]" <<<"$1"' _ "$line"

printf '\n%d ok, %d falha(s)\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
