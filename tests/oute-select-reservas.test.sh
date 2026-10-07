#!/usr/bin/env bash
# Testes da assinatura padrão e das reservas do seletor (#598, ADR-02): o `oute-select` com a tabela do repo e com uma tabela
# de TRÊS assinaturas (a terceira, `fict`, é fictícia: prova que a regra não é só para claude e codex). O `claude`/`codex`/`fict`
# e o `oute-quota` são falsos (tests/lib/fake-agent.sh, tests/lib/fake-oute-quota.sh); nada de rede. Só comportamento externo:
# JSON no stdout, aviso no stderr, código de saída.
# A seção 1 é a prova de que, com a padrão abaixo do teto, nada muda: saída e aviso iguais, byte a byte, aos do seletor de antes
# da #598 (os valores esperados foram gerados pelo `docker/oute-select` da `main` antes da mudança). $OUTE_SELECT_BIN troca o
# seletor testado (para rodar os casos contra outro código).
# Uso: tests/oute-select-reservas.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v python3 >/dev/null || die "precisa de jq e python3"
SEL="${OUTE_SELECT_BIN:-$ROOT/docker/oute-select}"; REPO_TABLE="$ROOT/tests/lib/select-table-sem-zai.toml"; ZAI_TABLE="$ROOT/config/select/models.toml"
[[ -x "$SEL" ]] || die "oute-select ausente ou sem +x: $SEL"

BIN="$TMP/bin"; FAKE="$TMP/fake"; mkdir -p "$BIN" "$FAKE" "$TMP/repo"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "issue view") exec bash "$TESTLIB/fake-gh-issue.sh" "$@" ;;
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
GH
cp "$ROOT/tests/lib/fake-agent.sh" "$BIN/claude"; cp "$ROOT/tests/lib/fake-agent.sh" "$BIN/codex"
cp "$ROOT/tests/lib/fake-oute-quota.sh" "$BIN/oute-quota"
# o agente da terceira assinatura: `fict status` sai com $FAKE_FICT_RC (padrão 0) e registra a chamada
cat > "$BIN/fict" <<'FICT'
#!/usr/bin/env bash
echo "fict $*" >> "$FAKE/auth.log"
exit "${FAKE_FICT_RC:-0}"
FICT
chmod +x "$BIN/gh" "$BIN/fict"
export PATH="$BIN:$PATH" FAKE TZ=UTC TESTLIB="$ROOT/tests/lib" OUTE_SELECT_TABLE="$REPO_TABLE"
unset OUTE_SELECT_GH_TIMEOUT FAKE_GH_HANG FAKE_CLAUDE_AUTH_RC FAKE_CODEX_LOGIN_RC FAKE_FICT_RC FAKE_AUTH_HANG OUTE_SELECT_AGENT_TIMEOUT \
      FAKE_QUOTA_RC FAKE_QUOTA_SLEEP OUTE_SELECT_QUOTA_TIMEOUT OUTE_TYPESAFE_API_KEY FAKE_AVAIL_RC_ZAI

# tabela de três assinaturas: a do repo mais a `fict` (coluna em toda linha); $1 = modo das reservas
table3() {
  local mode="$1"
  cat > "$TMP/t3-$mode.toml" <<TOML
[[subscription]]
name = "claude"
default = true
status = ["claude", "auth", "status"]
[[subscription]]
name = "codex"
status = ["codex", "login", "status"]
effort = true
prefixes = ["gpt-", "codex"]
[[subscription]]
name = "fict"
status = ["fict", "status"]
prefixes = ["fict-"]
[select]
reserve_mode = "$mode"
[default]
claude = "claude-sonnet-5-5"
codex = "gpt-6.1-sol"
fict = "fict-medio"
effort = "high"
[[line]]
phases = ["build", "plan"]
claude = "claude-sonnet-5-5"
codex = "gpt-6.1-sol"
fict = "fict-medio"
effort = "high"
[[line]]
phases = ["spec"]
claude = "claude-opus-5-5"
codex = "gpt-6-astra"
fict = "fict-grande"
effort = "high"
TOML
  return 0
}
table3 mais-livre; table3 ordem

# sel <args…>: oute-select --json no repo de teste; JSON em $OUT, stderr em $ERR, código em $RC
sel() { OUT="$("$SEL" --json --repo "$TMP/repo" "$@" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"; return 0; }
labels() { local n="$1"; shift; printf '%s\n' "$@" > "$FAKE/labels-$n"; return 0; }
# q <agente=5h,7d|agente=unknown>…: grava o `oute-quota --json` (o que não é citado fica em 0%); datas fixas, só resets_in_s conta
q() {
  local args=() a
  for a in "$@"; do args+=(--arg "${a%%=*}" "${a#*=}"); done
  jq -nc "${args[@]}" '
    def w($p; $s; $at): {used_pct: $p, resets_at: $at, resets_in_s: $s};
    def ag($v): if $v == "unknown" then {status: "unknown", reason: "rede", stale: false, age_s: null, windows: {}}
      else ($v | split(",") | map(tonumber)) as $x
        | {status: "ok", reason: null, stale: false, age_s: 0, windows: {"5h": w($x[0]; ($x[2] // 9000); "2030-01-01T15:00:00Z"), "7d": w($x[1]; 300000; "2030-01-05T09:30:00Z")}} end;
    $ARGS.named as $n
    | {schema: 1, max_pct: 98, reset_grace_s: 1200,
       agents: (["claude", "codex", "fict", "zai"] | map({key: ., value: ag($n[.] // "0,0")}) | from_entries)}' > "$FAKE/quota.json"
  return 0
}
ag() { jq -r .agent <<<"$OUT"; return $?; }
rsv() { jq -r '.reserve + ">" + (.reserve_from // "-")' <<<"$OUT"; return $?; }
warnhas() { local texto="$1"; grep -qF -- "$texto" <<<"$ERR"; return $?; }
labels 1 aidlc:build; labels 2 aidlc:spec

# ---------------------------------------------------------------- 1. padrão abaixo do teto: nada muda (tabela do repo)
# cada caso: "<descrição>|<cota>|<argumentos>" -> o que o seletor de antes da #598 devolvia: código|stdout|stderr
golden() { # <cota…> -- <argumentos…>: "código|stdout|stderr" do que o seletor testado devolve
  local qa=() arg
  while [[ "${1:-}" != -- ]]; do arg="$1"; qa+=("$arg"); shift; done; shift
  if [[ ${#qa[@]} -gt 0 ]]; then q "${qa[@]}"; else rm -f "$FAKE/quota.json"; fi
  sel "$@"; printf '%s|%s|%s' "$RC" "$OUT" "$ERR"; return 0
}
want() { # <descrição> <esperado> <obtido>
  local desc="$1" esperado="$2" obtido="$3"
  check "$desc" bash -c '[ "$1" == "$2" ]' _ "$obtido" "$esperado"; return 0
}
J='{"phase": "build", "origin": "label", "subscription": "claude", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "", "reason": "label aidlc:build da issue #1", "confidence": "", "reserve": ""}'
want "padrão abaixo do teto, reservas folgadas: Claude, saída igual à de antes" "0|$J|" "$(golden claude=40,30 codex=10,10 -- --issue 1)"
want "padrão abaixo do teto, reserva com mais folga (0%): Claude mesmo assim" "0|$J|" "$(golden claude=90,90 codex=0,0 -- --issue 1)"
want "padrão abaixo do teto, reserva no teto: Claude, sem aviso" "0|$J|" "$(golden claude=40,30 codex=100,100 -- --issue 1)"
want "padrão em 97% (#558), reserva a 0%: Claude" "0|$J|" "$(golden claude=97,97 codex=0,0 -- --issue 1)"
want "padrão abaixo do teto, reserva desconhecida: Claude, sem aviso" "0|$J|" "$(golden claude=40,30 codex=unknown -- --issue 1)"
J2='{"phase": "spec", "origin": "label", "subscription": "claude", "agent": "claude", "model": "claude-opus-5-5", "effort": "", "reason": "label aidlc:spec da issue #2", "confidence": "", "reserve": ""}'
want "fase spec, padrão abaixo do teto: Opus, saída igual à de antes" "0|$J2|" "$(golden claude=10,10 codex=0,0 -- --issue 2)"
want "5h em 99% com reset em 10 min (exceção): Claude, só o aviso de antes" "0|$J|oute-select: aviso: Claude com a janela de 5h em 99%, mas reseta em menos de 20 min (01/01 15:00 UTC); abrindo no Claude" \
  "$(golden claude=99,40,600 codex=0,0 -- --issue 1)"
want "cota do Claude desconhecida: Claude, o aviso de antes" "0|$J|oute-select: aviso: a cota do Claude está desconhecida (unknown); abrindo no Claude" \
  "$(golden claude=unknown codex=0,0 -- --issue 1)"
want "oute-quota sem JSON: Claude, o aviso de antes" "0|$J|oute-select: aviso: não li a cota (\`oute-quota --json\` falhou ou não respondeu em tempo); abrindo no Claude" \
  "$(echo 'isto não é json' > "$FAKE/quota.json"; sel --issue 1; printf '%s|%s|%s' "$RC" "$OUT" "$ERR")"
JM='{"phase": "build", "origin": "manual", "subscription": "codex", "agent": "codex", "model": "gpt-6.1-sol", "effort": "high", "reason": "--agent codex (label aidlc:build da issue #1)", "confidence": "", "reserve": ""}'
want "--agent codex com o Codex no teto: Codex, sem aviso (explícito)" "0|$JM|" "$(golden claude=10,10 codex=100,100 -- --issue 1 --agent codex)"
JP='{"phase": "plan", "origin": "padrao", "subscription": "claude", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "", "reason": "fase plan fixa", "confidence": "", "reserve": ""}'
want "--phase plan, Claude no teto: Claude, sem aviso (explícito)" "0|$JP|" "$(golden claude=99,99 codex=0,0 -- --phase plan)"
JS='{"phase": "", "origin": "padrao", "subscription": "claude", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "", "reason": "sessão sem issue", "confidence": "", "reserve": ""}'
want "sessão sem issue, padrão abaixo do teto: Claude, aviso de antes" "0|$JS|oute-select: aviso: sessão sem issue; abrindo no padrão (claude-sonnet-5-5)" "$(golden claude=10,10 codex=0,0 -- --task sem-issue)"
q claude=40,30 codex=0,0; OUT="$("$SEL" --repo "$TMP/repo" --issue 1 2>/dev/null </dev/null)"
want "linha para ler, padrão abaixo do teto: a de antes, com a assinatura" "fase build · origem label · assinatura claude · agente claude · modelo claude-sonnet-5-5 · motivo: label aidlc:build da issue #1" "$OUT"
# a mesma conta, agora com a tabela de três assinaturas: a terceira, a 0% de cota, não tira a sessão da padrão
for m in mais-livre ordem; do
  export OUTE_SELECT_TABLE="$TMP/t3-$m.toml"
  J3='{"phase": "build", "origin": "label", "subscription": "claude", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "", "reason": "label aidlc:build da issue #1", "confidence": "", "reserve": ""}'
  want "três assinaturas, modo $m, padrão abaixo do teto: Claude" "0|$J3|" "$(golden claude=90,90 codex=50,50 fict=0,0 -- --issue 1)"
done
export OUTE_SELECT_TABLE="$REPO_TABLE"

# ---------------------------------------------------------------- 2. padrão no teto, modo A (mais-livre), três assinaturas
export OUTE_SELECT_TABLE="$TMP/t3-mais-livre.toml"
q claude=99,40 codex=70,10 fict=40,10; sel --issue 1
check "A: padrão no teto: a reserva de mais cota livre (fict, 60% livre) ganha" [ "$(ag)" == fict ]
check "A: reserve cota, de claude"                      [ "$(rsv)" == "cota>claude" ]
check "A: modelo da coluna da assinatura (fict-medio), sem esforço" jqe '.model == "fict-medio" and .effort == ""' <<<"$OUT"
check "A: aviso diz a janela do teto e a reserva"       bash -c 'grep -qF "cota do Claude esgotada (5h em 99%" <<<"$1" && grep -qF "abrindo no Fict (reserva por cota)" <<<"$1"' _ "$ERR"
q claude=99,40 codex=20,10 fict=40,10; sel --issue 1
check "A: com o Codex mais livre (80% × 60%), o Codex ganha" [ "$(ag)" == codex ]
check "A: Codex leva o esforço da linha"                jqe '.effort == "high" and .model == "gpt-6.1-sol"' <<<"$OUT"
q claude=99,40 codex=20,95 fict=40,10; sel --issue 1
check "A: cota livre é a da janela mais apertada (Codex 7d em 95%, 5% livre): fict" [ "$(ag)" == fict ]
q claude=99,40 codex=70,10 fict=70,10; sel --issue 1
check "A: empate de cota livre: a primeira da tabela (Codex)" [ "$(ag)" == codex ]
check "A: o JSON ganha reserve_from só com reserva"     jqe 'keys == ["agent", "confidence", "effort", "model", "origin", "phase", "reason", "reserve", "reserve_from", "subscription"]' <<<"$OUT"
OUT="$("$SEL" --repo "$TMP/repo" --issue 1 2>/dev/null </dev/null)"
check "A: linha para ler diz a reserva e de onde"       bash -c 'grep -qF "agente codex" <<<"$1" && grep -qF "reserva cota (de claude)" <<<"$1"' _ "$OUT"

# ---------------------------------------------------------------- 3. padrão no teto, modo B (ordem)
export OUTE_SELECT_TABLE="$TMP/t3-ordem.toml"
q claude=99,40 codex=70,10 fict=10,10; sel --issue 1
check "B: a 2ª da ordem (Codex, 30% livre) ganha da 3ª com mais folga (90%)" [ "$(ag)" == codex ]
check "B: reserve cota, de claude"                      [ "$(rsv)" == "cota>claude" ]
q claude=99,40 codex=98,10 fict=70,10; sel --issue 1
check "B: a 2ª no teto: pula para a 3ª"                 [ "$(ag)" == fict ]
q claude=99,40 codex=100,10 fict=unknown; sel --issue 1
check "B: 2ª no teto e 3ª desconhecida: a desconhecida, com o aviso de cota não lida" bash -c '[ "$1" == fict ] && grep -qF "cota não lida" <<<"$2"' _ "$(ag)" "$ERR"

# ---------------------------------------------------------------- 4. todas no teto: nunca recusa, a de mais cota livre
for m in mais-livre ordem; do
  export OUTE_SELECT_TABLE="$TMP/t3-$m.toml"
  q claude=99,40 codex=100,10 fict=98,10; sel --issue 1
  check "todas no teto ($m): código 0 e a de mais cota livre (fict, 2%), com aviso" bash -c '[ "$1" -eq 0 ] && [ "$2" == fict ]' _ "$RC" "$(ag)"
  check "todas no teto ($m): aviso lista as outras no teto" bash -c 'grep -qF "do Codex também" <<<"$1" && grep -qF "a de mais cota livre" <<<"$1"' _ "$ERR"
  check "todas no teto ($m): reserve cota, de claude"  [ "$(rsv)" == "cota>claude" ]
  q claude=98,40 codex=100,10 fict=99,10; sel --issue 1
  check "todas no teto ($m): a padrão com mais cota livre fica, sem reserva" bash -c '[ "$1" == claude ] && [ "$2" == ">-" ]' _ "$(ag)" "$(rsv)"
  check "todas no teto ($m): o aviso diz que as outras também"  bash -c 'grep -qF "do Fict também" <<<"$1"' _ "$ERR"
done

# ---------------------------------------------------------------- 5. reserva pedida (--prefer) e cheia: pode voltar para a padrão
export OUTE_SELECT_TABLE="$TMP/t3-mais-livre.toml"
q claude=40,30 codex=10,10 fict=10,10; sel --issue 1 --prefer codex
check "--prefer codex abaixo do teto: abre no Codex, sem reserva" bash -c '[ "$1" == codex ] && [ "$2" == ">-" ]' _ "$(ag)" "$(rsv)"
check "--prefer não é escolha explícita: origem label" jqe '.origin == "label"' <<<"$OUT"
q claude=40,30 codex=99,10 fict=10,10; sel --issue 1 --prefer codex
check "--prefer codex no teto: volta para a padrão (Claude), reserve cota de codex" bash -c '[ "$1" == claude ] && [ "$2" == "cota>codex" ]' _ "$(ag)" "$(rsv)"
q claude=99,99 codex=99,10 fict=10,10; sel --issue 1 --prefer codex
check "--prefer codex no teto e a padrão também: a reserva abaixo do teto (fict)" bash -c '[ "$1" == fict ] && [ "$2" == "cota>codex" ]' _ "$(ag)" "$(rsv)"
q claude=99,99 codex=99,10 fict=98,10; sel --issue 1 --prefer codex
check "--prefer codex, todas no teto: a de mais cota livre (Codex, 1% × 2% do fict)" bash -c '[ "$1" == fict ]' _ "$(ag)"
q claude=99,99 codex=99,10 fict=100,10; sel --issue 1 --prefer codex
check "--prefer codex, todas no teto e a pedida com mais folga: fica nela, sem reserva" bash -c '[ "$1" == codex ] && [ "$2" == ">-" ]' _ "$(ag)" "$(rsv)"
sel --issue 1 --prefer nada
check "--prefer com assinatura que não existe: código 2"  [ "$RC" -eq 2 -a -z "$OUT" ]

# ---------------------------------------------------------------- 6. escolha explícita: só avisa, não troca
q claude=40,30 codex=100,100 fict=0,0; : > "$FAKE/quota.args"
sel --issue 1 --agent codex
check "--agent codex com o Codex no teto: fica no Codex, manual, sem reserva" bash -c '[ "$1" == codex ] && [ "$2" == ">-" ] && jq -e ".origin == \"manual\"" <<<"$3" >/dev/null' _ "$(ag)" "$(rsv)" "$OUT"
sel --issue 1 --agent fict
check "--agent fict (a terceira): abre nela, com o modelo da coluna" bash -c '[ "$1" == fict ] && jq -e ".model == \"fict-medio\"" <<<"$2" >/dev/null' _ "$(ag)" "$OUT"
sel --issue 1 --model fict-grande
check "--model da coluna da terceira assinatura: abre nela" [ "$(ag)" == fict ]
sel --issue 1 --model fict-novo
check "--model fora da tabela com o prefixo da terceira: abre nela" [ "$(ag)" == fict ]
check "explícito: a cota nem foi lida"                  [ ! -s "$FAKE/quota.args" ]
export FAKE_CLAUDE_AUTH_RC=1
sel --issue 1 --agent claude
check "--agent claude com o Claude indisponível: fica, avisa" bash -c '[ "$1" == claude ] && grep -qF "explícita" <<<"$2"' _ "$(ag)" "$ERR"
unset FAKE_CLAUDE_AUTH_RC

# ---------------------------------------------------------------- 7. cota desconhecida: por último entre as reservas, com aviso
export OUTE_SELECT_TABLE="$TMP/t3-mais-livre.toml"
q claude=99,40 codex=unknown fict=95,10; sel --issue 1
check "padrão no teto, Codex desconhecido, fict abaixo do teto (5% livre): fict (a lida vem antes)" [ "$(ag)" == fict ]
q claude=99,40 codex=unknown fict=unknown; sel --issue 1
check "padrão no teto, as duas reservas desconhecidas: a primeira da tabela (Codex), aviso de cota não lida" bash -c '[ "$1" == codex ] && grep -qF "cota não lida" <<<"$2"' _ "$(ag)" "$ERR"
q claude=99,40 codex=unknown fict=100,10; sel --issue 1
check "padrão e fict no teto, Codex desconhecido: o Codex (a desconhecida antes de todas no teto)" [ "$(ag)" == codex ]
q claude=unknown codex=0,0 fict=0,0; sel --issue 1
check "cota da padrão desconhecida: fica nela, só avisa" bash -c '[ "$1" == claude ] && grep -qF "desconhecida" <<<"$2"' _ "$(ag)" "$ERR"
rm -f "$FAKE/quota.json"; q claude=99,40 codex=0,0   # sem a chave fict no JSON do quota: fict desconhecida
jq 'del(.agents.fict)' "$FAKE/quota.json" > "$FAKE/q2" && mv "$FAKE/q2" "$FAKE/quota.json"; q2=1
sel --issue 1
check "assinatura que o oute-quota não lê: desconhecida, fica depois do Codex lido" [ "$(ag)" == codex ]

# ---------------------------------------------------------------- 8. padrão indisponível
q claude=0,0 codex=80,10 fict=40,10
export FAKE_CLAUDE_AUTH_RC=1; : > "$FAKE/auth.log"
sel --issue 1
check "indisponível, modo A: a reserva de mais cota livre (fict), reserve indisponivel" bash -c '[ "$1" == fict ] && [ "$2" == "indisponivel>claude" ]' _ "$(ag)" "$(rsv)"
export OUTE_SELECT_TABLE="$TMP/t3-ordem.toml"
sel --issue 1
check "indisponível, modo B: a 2ª da ordem (Codex)"     bash -c '[ "$1" == codex ] && [ "$2" == "indisponivel>claude" ]' _ "$(ag)" "$(rsv)"
export FAKE_FICT_RC=1 OUTE_SELECT_TABLE="$TMP/t3-mais-livre.toml"
sel --issue 1
check "indisponível e a fict também fora: o Codex"      [ "$(ag)" == codex ]
export FAKE_CODEX_LOGIN_RC=1
sel --issue 1
check "as três fora: código 0, abre na padrão, aviso das três" bash -c '[ "$1" -eq 0 ] && [ "$2" == claude ] && grep -qF "Claude, Codex e Fict indisponíveis" <<<"$3"' _ "$RC" "$(ag)" "$ERR"
unset FAKE_CODEX_LOGIN_RC FAKE_FICT_RC FAKE_CLAUDE_AUTH_RC
# padrão fora e a cota ilegível com duas reservas: a ordem da tabela (Codex), com aviso de que a cota não foi lida
echo 'isto não é json' > "$FAKE/quota.json"; export FAKE_CLAUDE_AUTH_RC=1
sel --issue 1
check "padrão fora, cota ilegível, duas reservas: a 1ª da tabela, aviso" bash -c '[ "$1" == codex ] && [ "$2" == "indisponivel>claude" ] && grep -qF "não li a cota" <<<"$3"' _ "$(ag)" "$(rsv)" "$ERR"
unset FAKE_CLAUDE_AUTH_RC
# a padrão no teto e a única reserva com mais folga fora do ar: não é candidata
q claude=99,40 codex=0,0 fict=0,0; export FAKE_CODEX_LOGIN_RC=1
sel --issue 1
check "padrão no teto, Codex fora: a fict (disponível)"  [ "$(ag)" == fict ]
unset FAKE_CODEX_LOGIN_RC

# ---------------------------------------------------------------- 9. tabela inválida: abre sem modelo, com aviso
bad_table() { # <descrição> <trecho que a mensagem tem> <arquivo>
  local desc="$1" trecho="$2" arquivo="$3"
  q claude=0,0; OUTE_SELECT_TABLE="$arquivo" sel --issue 1
  check "$desc" bash -c '[ "$1" -eq 0 ] && jq -e ".model == \"\" and .agent == \"claude\"" <<<"$2" >/dev/null && grep -qF "$4" <<<"$3"' _ "$RC" "$OUT" "$ERR" "$trecho"
  return 0
}
sed 's/reserve_mode = "ordem"/reserve_mode = "sorteio"/' "$TMP/t3-ordem.toml" > "$TMP/modo.toml"
bad_table "modo desconhecido: tabela inválida" "reserve_mode desconhecido" "$TMP/modo.toml"
sed 's/^default = true//' "$TMP/t3-ordem.toml" > "$TMP/semdefault.toml"
bad_table "nenhuma padrão: tabela inválida" "só uma, com default" "$TMP/semdefault.toml"
sed 's/^name = "fict"/name = "claude"/' "$TMP/t3-ordem.toml" > "$TMP/repetida.toml"
bad_table "assinatura repetida: tabela inválida" "nome repetido" "$TMP/repetida.toml"
sed 's/^fict = "fict-grande"//' "$TMP/t3-ordem.toml" > "$TMP/semcoluna.toml"
bad_table "linha sem a coluna de uma assinatura: tabela inválida" "[[line]] sem phases" "$TMP/semcoluna.toml"
sel --issue 1 --agent gemini
check "agente fora da lista: código 2, a lista vem da tabela" bash -c '[ "$1" -eq 2 ] && grep -qF "use claude ou codex" <<<"$2"' _ "$RC" "$ERR"
export OUTE_SELECT_TABLE="$TMP/t3-ordem.toml"
sel --issue 1 --agent gemini
check "três assinaturas: a lista do erro tem as três"  bash -c '[ "$1" -eq 2 ] && grep -qF "use claude ou codex ou fict" <<<"$2"' _ "$RC" "$ERR"
# sem o reserve_mode o valor inicial é mais-livre
sed '/^\[select\]/,/^reserve_mode/d' "$TMP/t3-ordem.toml" > "$TMP/semmodo.toml"; export OUTE_SELECT_TABLE="$TMP/semmodo.toml"
q claude=99,40 codex=70,10 fict=10,10; sel --issue 1
check "sem [select]: modo mais-livre (fict, 90% livre)"  [ "$(ag)" == fict ]

# ---------------------------------------------------------------- 7. a assinatura `zai` e a cadeia por linha (#677, tabela do repo)
export OUTE_SELECT_TABLE="$ZAI_TABLE"
sb() { jq -r '.subscription + "/" + .agent + "/" + .model' <<<"$OUT"; return $?; }
label_phase() { local n="$1"; shift; labels "$n" "$@"; sel --issue "$n"; return 0; }
# execução: a zai abre, com o agente claude e o modelo glm-5.3 (cota folgada, disponível)
q claude=10,10 codex=10,10 zai=10,10
for f in build ship ops ctx; do
  label_phase 50 "aidlc:$f"
  check "execução ($f): zai, agente claude, glm-5.3, sem reserva" bash -c '[ "$1" == "zai/claude/glm-5.3" ] && [ "$2" == ">-" ]' _ "$(sb)" "$(rsv)"
done
for e in kaizen docs; do
  label_phase 51 "$e"
  check "exceção $e: zai, agente claude, glm-5.3" [ "$(sb)" == "zai/claude/glm-5.3" ]
done
label_phase 52 kaizen aidlc:build
check "kaizen com fase de código vale a fase (build): zai" [ "$(sb)" == "zai/claude/glm-5.3" ]
# raciocínio: claude e o modelo de hoje
for f in strat:claude-opus-5-5 intent:claude-opus-5-5 arch:claude-opus-5-5 spec:claude-opus-5-5 design:claude-sonnet-5-5 \
         plan:claude-sonnet-5-5 qa:claude-sonnet-5-5 iter:claude-sonnet-5-5 learn:claude-sonnet-5-5; do
  label_phase 53 "aidlc:${f%%:*}"
  check "raciocínio (${f%%:*}): claude, ${f#*:}" [ "$(sb)" == "claude/claude/${f#*:}" ]
done
label_phase 54 spike aidlc:build
check "exceção spike: claude, claude-sonnet-5-5"        [ "$(sb)" == "claude/claude/claude-sonnet-5-5" ]
sel --phase build
check "--phase build: zai (a fase fixa também tem cadeia)" [ "$(sb)" == "zai/claude/glm-5.3" ]
check "o status da zai é o --available do oute-quota"   grep -qxF -- "--available zai" "$FAKE/quota.args"
# a zai indisponível: abre no claude
export FAKE_AVAIL_RC_ZAI=1
label_phase 50 aidlc:build
check "execução, zai indisponível: claude, sonnet"      [ "$(sb)" == "claude/claude/claude-sonnet-5-5" ]
check "execução, zai indisponível: reserve indisponivel, de zai" [ "$(rsv)" == "indisponivel>zai" ]
check "execução, zai indisponível: aviso nomeia o comando" warnhas 'o Zai está indisponível (`oute-quota --available zai` falhou); abrindo no Claude (reserva)'
q claude=99,10 codex=10,10 zai=10,10; sel --issue 50
check "zai fora e claude no teto: codex da linha"       bash -c '[ "$1" == "codex" ] && [ "$2" == "indisponivel>zai" ]' _ "$(ag)" "$(rsv)"
unset FAKE_AVAIL_RC_ZAI
# a zai no teto: abre no claude (cadeia por ordem, não pela cota livre: codex a 0% não passa na frente)
q claude=60,10 codex=0,0 zai=98,10; sel --issue 50
check "execução, zai em 98%: claude, mesmo com o codex mais livre" bash -c '[ "$1" == "claude/claude/claude-sonnet-5-5" ] && [ "$2" == "cota>zai" ]' _ "$(sb)" "$(rsv)"
check "execução, zai em 98%: aviso diz a cota da zai"   warnhas 'cota do Zai esgotada (5h em 98%'
q claude=97,10 codex=50,10 zai=99,10; sel --issue 50
check "execução, claude em 97% abaixo do teto: ainda claude" [ "$(ag)/$(rsv)" == "claude/cota>zai" ]
q claude=99,10 codex=50,10 zai=99,10; sel --issue 50
check "execução, zai e claude no teto: codex, gpt-6.1-sol, high" bash -c '[ "$1" == "codex/codex/gpt-6.1-sol" ] && [ "$2" == "cota>zai" ] && jq -e ".effort == \"high\"" <<<"$3" >/dev/null' _ "$(sb)" "$(rsv)" "$OUT"
q claude=99,10 codex=99,10 zai=99,10; sel --issue 50
check "os três no teto, empate: fica na zai (a de partida), código 0, com aviso" bash -c '[ "$1" -eq 0 ] && [ "$2" == "zai/claude/glm-5.3" ] && grep -qF "abrindo no Zai" <<<"$3"' _ "$RC" "$(sb)" "$ERR"
q claude=99,10 codex=98,10 zai=99,10; sel --issue 50
check "os três no teto: a de mais cota livre (codex, 2%), com aviso" bash -c '[ "$1" == "codex" ] && grep -qF "a de mais cota livre" <<<"$2"' _ "$(ag)" "$ERR"
# raciocínio com o claude no teto: zai, e não o codex (que está mais livre)
labels 11 aidlc:spec; q claude=99,10 codex=0,0 zai=50,10; sel --issue 11
check "raciocínio, claude no teto: zai, glm-5.3, e não o codex" bash -c '[ "$1" == "zai/claude/glm-5.3" ] && [ "$2" == "cota>claude" ]' _ "$(sb)" "$(rsv)"
q claude=99,10 codex=0,0 zai=99,10; sel --issue 11
check "raciocínio, claude e zai no teto: codex"         [ "$(ag)/$(rsv)" == "codex/cota>claude" ]
export FAKE_AVAIL_RC_ZAI=1; q claude=99,10 codex=50,10 zai=0,0; sel --issue 11
check "raciocínio, claude no teto e zai indisponível: codex" [ "$(ag)/$(rsv)" == "codex/cota>claude" ]
unset FAKE_AVAIL_RC_ZAI
# --subscription: escolha explícita; avisa e abre na zai
export FAKE_AVAIL_RC_ZAI=1; q claude=10,10 codex=10,10 zai=10,10
sel --issue 11 --subscription zai
check "--subscription zai indisponível: abre na zai, código 0" bash -c '[ "$1" -eq 0 ] && [ "$2" == "zai/claude/glm-5.3" ] && [ "$3" == ">-" ]' _ "$RC" "$(sb)" "$(rsv)"
check "--subscription zai indisponível: avisa"          warnhas 'o Zai está indisponível (`oute-quota --available zai` falhou), mas a escolha foi explícita'
check "--subscription: origem manual e o motivo diz a opção" jqe '.origin == "manual" and (.reason | startswith("--subscription zai ("))' <<<"$OUT"
unset FAKE_AVAIL_RC_ZAI
q claude=10,10 codex=10,10 zai=99,10; sel --issue 50 --subscription zai
check "--subscription zai no teto: abre na zai, sem reserva" bash -c '[ "$1" == "zai/claude/glm-5.3" ] && [ "$2" == ">-" ]' _ "$(sb)" "$(rsv)"
check "--subscription zai no teto: avisa da cota"       warnhas 'cota do Zai esgotada (5h em 99%'
q claude=10,10 codex=10,10 zai=10,10; sel --issue 50 --subscription zai
check "--subscription zai folgada: sem aviso"           [ -z "$ERR" ]
sel --issue 50 --subscription claude
check "--subscription claude numa fase de execução: claude, sonnet" [ "$(sb)" == "claude/claude/claude-sonnet-5-5" ]
sel --issue 50 --subscription codex
check "--subscription codex: codex, com esforço"        bash -c '[ "$1" == "codex/codex/gpt-6.1-sol" ] && jq -e ".effort == \"high\"" <<<"$2" >/dev/null' _ "$(sb)" "$OUT"
sel --issue 50 --subscription gemini
check "--subscription fora da tabela: código 2 e a lista" bash -c '[ "$1" -eq 2 ] && grep -qF "use claude ou zai ou codex" <<<"$2"' _ "$RC" "$ERR"
sel --issue 50 --agent claude --subscription zai
check "--agent claude com --subscription zai: vale a zai" [ "$(sb)" == "zai/claude/glm-5.3" ]
sel --issue 50 --agent codex --subscription zai
check "--agent codex com --subscription zai: código 2, não combinam" bash -c '[ "$1" -eq 2 ] && grep -qF "não combinam" <<<"$2"' _ "$RC" "$ERR"
# --prefer zai: abre na zai numa fase de raciocínio; no teto, volta ao claude
q claude=10,10 codex=10,10 zai=10,10; sel --issue 11 --prefer zai
check "--prefer zai em spec: zai, glm-5.3, sem reserva" bash -c '[ "$1" == "zai/claude/glm-5.3" ] && [ "$2" == ">-" ]' _ "$(sb)" "$(rsv)"
q claude=10,10 codex=0,0 zai=99,10; sel --issue 11 --prefer zai
check "--prefer zai em spec, zai no teto: volta ao claude (Opus), não ao codex" bash -c '[ "$1" == "claude/claude/claude-opus-5-5" ] && [ "$2" == "cota>zai" ]' _ "$(sb)" "$(rsv)"
export FAKE_AVAIL_RC_ZAI=1; sel --issue 11 --prefer zai
check "--prefer zai em spec, zai indisponível: volta ao claude" [ "$(ag)/$(rsv)" == "claude/indisponivel>zai" ]
unset FAKE_AVAIL_RC_ZAI
# --agent segue aceitando claude e codex, com a saída de hoje
q claude=10,10 codex=10,10 zai=10,10
sel --issue 50 --agent claude
check "--agent claude em build: claude, sonnet, manual"  bash -c '[ "$1" == "claude/claude/claude-sonnet-5-5" ] && jq -e ".origin == \"manual\" and .reserve == \"\"" <<<"$2" >/dev/null' _ "$(sb)" "$OUT"
sel --issue 50 --agent codex
check "--agent codex em build: codex, gpt-6.1-sol, high" bash -c '[ "$1" == "codex/codex/gpt-6.1-sol" ] && jq -e ".effort == \"high\"" <<<"$2" >/dev/null' _ "$(sb)" "$OUT"
sel --issue 50 --agent zai
check "--agent zai: código 2 (zai é assinatura, não agente)" bash -c '[ "$1" -eq 2 ] && grep -qF "use claude ou codex" <<<"$2"' _ "$RC" "$ERR"
sel --model glm-5.3
check "--model glm-5.3 sem --agent: a assinatura é a zai"  [ "$(sb)" == "zai/claude/glm-5.3" ]
# sessão sem fase (linha padrão, sem chain): a padrão da tabela, como antes
sel --task sem-issue
check "sem fase: claude, sonnet, sem reserva (linha sem chain)" bash -c '[ "$1" == "claude/claude/claude-sonnet-5-5" ] && [ "$2" == ">-" ]' _ "$(sb)" "$(rsv)"
# linha sem chain segue o reserve_mode da tabela (mais-livre aqui): padrão no teto, a reserva de mais cota livre
q claude=99,10 codex=60,10 zai=20,10; sel --task sem-issue
check "linha sem chain, mais-livre: a de mais cota livre (zai, 80%)" [ "$(sb)/$(rsv)" == "zai/claude/glm-5.3/cota>claude" ]
# chain inválida: tabela inválida, abre com o modelo do agente e avisa
for ruim in '["claude", "claude"]' '["claude", "nada"]' '[]' '"zai"'; do
  sed "0,/^chain = .*/s//chain = $ruim/" "$ZAI_TABLE" > "$TMP/chain-ruim.toml"
  OUTE_SELECT_TABLE="$TMP/chain-ruim.toml" sel --issue 50
  check "chain $ruim: tabela inválida, aviso, código 0, sem modelo" bash -c '[ "$1" -eq 0 ] && grep -qF "chain inválida" <<<"$2" && jq -e ".model == \"\"" <<<"$3" >/dev/null' _ "$RC" "$ERR" "$OUT"
done
# `agent` da assinatura que não existe como nome: a sessão abre no programa dela
sed 's/^agent = "claude"$/agent = "outro"/' "$ZAI_TABLE" > "$TMP/agente-outro.toml"
OUTE_SELECT_TABLE="$TMP/agente-outro.toml" sel --issue 50
check "assinatura com agent = outro: o JSON diz o agente" jqe '.subscription == "zai" and .agent == "outro"' <<<"$OUT"
export OUTE_SELECT_TABLE="$REPO_TABLE"
rm -f "${FAKE:?}/quota.json"

check_end
