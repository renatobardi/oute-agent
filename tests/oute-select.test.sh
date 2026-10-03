#!/usr/bin/env bash
# Testes do seletor de modelo por sessão (#219 e #257, ADR-02, fatias 1 e 2): o `oute-select` com a tabela do repo
# (config/select/models.toml), um `gh` falso (tests/lib/fake-gh-issue.sh) e uma TypeSafe falsa (tests/lib/typesafe.sh)
# (com TLS: o seletor só fala https, #313) no lugar do Jev. Bash puro + python3/jq/openssl, sem rede: a chave e o endereço da TypeSafe de verdade saem do ambiente.
# Só comportamento externo: o JSON no stdout, o aviso no stderr e o código de saída.
# O que o oute-task e o oute-swarm fazem com a escolha está em tests/oute-task.test.sh e tests/oute-swarm.test.sh.
# Uso: tests/oute-select.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'ts_stop; kill "${CLARO_PID:-}" 2>/dev/null; rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/typesafe.sh"
command -v jq >/dev/null && command -v python3 >/dev/null && command -v openssl >/dev/null || die "precisa de jq, python3 e openssl"
SEL="$ROOT/docker/oute-select"; TABLE="$ROOT/config/select/models.toml"
[[ -x "$SEL" ]] || die "oute-select ausente ou sem +x: $SEL"

BIN="$TMP/bin"; NOGH="$TMP/nogh"; FAKE="$TMP/fake"; mkdir -p "$BIN" "$NOGH" "$FAKE" "$TMP/repo"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "issue view") exec bash "$TESTLIB/fake-gh-issue.sh" "$@" ;;
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
GH
chmod +x "$BIN/gh"
# PATH sem gh nenhum: só o que o oute-select precisa para rodar
for c in env python3; do ln -s "$(command -v "$c")" "$NOGH/$c"; done
export PATH="$BIN:$PATH" FAKE TESTLIB="$ROOT/tests/lib" OUTE_SELECT_TABLE="$TABLE"
unset OUTE_SELECT_GH_TIMEOUT FAKE_GH_HANG
ts_off   # seções 1 a 9: sem chave, o Jev nunca é chamado

# sel <args…>: oute-select --json no repo de teste; JSON em $OUT, stderr em $ERR, código em $RC
sel() { OUT="$("$SEL" --json --repo "$TMP/repo" "$@" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"; }
labels() { local n="$1"; shift; printf '%s\n' "$@" > "$FAKE/labels-$n"; }   # <n> <label…>
# is <fase> <origem> <agente> <modelo> <esforço>: o JSON devolvido, campo a campo, com código 0
is() { [ "$RC" -eq 0 ] && jqe --arg p "$1" --arg o "$2" --arg a "$3" --arg m "$4" --arg e "$5" \
         '.phase == $p and .origin == $o and .agent == $a and .model == $m and .effort == $e' <<<"$OUT"; }
calls() { cat "$FAKE/gh-issue.log" 2>/dev/null | grep -c . || true; }
SONNET=claude-sonnet-5-5; OPUS=claude-opus-5-5; HAIKU=claude-haiku-4-5-20251001

# ---------------------------------------------------------------- 1. label de fase
labels 10 aidlc:build agentes ready
sel --issue 10
check "label: aidlc:build abre no Sonnet, origem label" is build label claude "$SONNET" ""
check "label: os sete campos, e só eles"                jqe 'keys == ["agent", "confidence", "effort", "model", "origin", "phase", "reason"]' <<<"$OUT"
check "label: sem confiança (o Jev não foi chamado)"    jqe '.confidence == ""' <<<"$OUT"
check "label: motivo diz o label e a issue"             jqe '.reason == "label aidlc:build da issue #10"' <<<"$OUT"
check "label: sem aviso"                                [ -z "$ERR" ]
check "label: o gh roda no repo dado, uma vez"          [ "$(cat "$FAKE/gh-issue.log")" == "repo 10" ]
labels 11 aidlc:spec; sel --issue 11
check "label: aidlc:spec abre no Opus"                  is spec label claude "$OPUS" ""
labels 12 aidlc:ops; sel --issue 12
check "label: aidlc:ops abre no Haiku"                  is ops label claude "$HAIKU" ""
sel --task 10-seletor-modelo
check "--task: o número da issue sai do slug"           is build label claude "$SONNET" ""
# toda fase do ADR-07 (e a faixa ctx) tem linha na tabela do repo, com o modelo do ADR-02
for p in strat:$OPUS intent:$OPUS arch:$OPUS spec:$OPUS build:$SONNET qa:$SONNET design:$SONNET plan:$SONNET \
         ship:$SONNET iter:$SONNET ops:$HAIKU ctx:$HAIKU learn:$HAIKU; do
  labels 13 "aidlc:${p%%:*}"; sel --issue 13
  check "tabela: ${p%%:*} → ${p#*:}"                    is "${p%%:*}" label claude "${p#*:}" ""
done

# ---------------------------------------------------------------- 2. exceção por label (antes da fase)
labels 20 aidlc:spec kaizen
sel --issue 20
check "kaizen: Haiku, mesmo com aidlc:spec"             is spec label claude "$HAIKU" ""
check "kaizen: motivo diz a exceção"                    jqe '.reason == "label kaizen da issue #20"' <<<"$OUT"
labels 21 docs aidlc:build
sel --issue 21
check "docs: Haiku, mesmo com aidlc:build"              is build label claude "$HAIKU" ""
labels 22 kaizen
sel --issue 22
check "kaizen sem fase: Haiku, fase vazia, sem aviso"   bash -c '[ -z "$1" ] && jq -e ".phase == \"\" and .origin == \"label\" and .model == \"$2\"" <<<"$3" >/dev/null' _ "$ERR" "$HAIKU" "$OUT"

# ---------------------------------------------------------------- 3. sem label: Sonnet, com aviso, sem bloquear
labels 30 bug agentes
sel --issue 30
check "sem label: Sonnet, origem padrao, código 0"      is "" padrao claude "$SONNET" ""
check "sem label: aviso em stderr"                      [ "$ERR" == "oute-select: aviso: issue #30 sem label aidlc:<fase>; abrindo no padrão ($SONNET)" ]
: > "$FAKE/labels-31"; sel --issue 31
check "issue sem label nenhum: Sonnet, com aviso"       bash -c '[ -n "$1" ]' _ "$ERR"
check "issue sem label nenhum: origem padrao"           is "" padrao claude "$SONNET" ""
labels 32 aidlc:foo; sel --issue 32
check "fase fora da tabela: Sonnet, origem padrao"      is "" padrao claude "$SONNET" ""
check "fase fora da tabela: aviso com o label"          grep -qF 'fase fora da tabela (aidlc:foo)' <<<"$ERR"
labels 33 aidlc:spec aidlc:build; sel --issue 33
check "duas fases: vale a primeira, com aviso"          is spec label claude "$OPUS" ""
check "duas fases: aviso diz qual valeu"                grep -qF 'mais de um label de fase (spec, build); vale spec' <<<"$ERR"
sel --task sessao-1003-0050
check "sessão sem issue: Sonnet, origem padrao"         is "" padrao claude "$SONNET" ""
check "sessão sem issue: aviso"                         grep -qF 'sessão sem issue; abrindo no padrão' <<<"$ERR"
sel
check "sem --issue nem --task: o mesmo"                 is "" padrao claude "$SONNET" ""

# ---------------------------------------------------------------- 4. gh fora do ar: Sonnet, com aviso, sem bloquear
touch "$FAKE/gh.down"
sel --issue 10
check "gh fora: Sonnet, origem padrao, código 0"        is "" padrao claude "$SONNET" ""
check "gh fora: aviso em stderr"                        [ "$ERR" == "oute-select: aviso: o gh não respondeu para a issue #10; abrindo no padrão ($SONNET)" ]
rm "$FAKE/gh.down"
sel --issue 99
check "issue que não existe: Sonnet, com aviso"         bash -c '[ -n "$1" ]' _ "$ERR"
check "issue que não existe: origem padrao"             is "" padrao claude "$SONNET" ""
touch "$FAKE/gh.hang"; t0=$(date +%s)
OUTE_SELECT_GH_TIMEOUT=1 sel --issue 10
check "gh que não responde: Sonnet depois do tempo limite" is "" padrao claude "$SONNET" ""
check "gh que não responde: não espera o gh"            [ $(( $(date +%s) - t0 )) -le 4 ]
rm "$FAKE/gh.hang"
OUT="$(PATH="$NOGH" "$SEL" --json --repo "$TMP/repo" --issue 10 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
check "sem gh no PATH: Sonnet, origem padrao, código 0" is "" padrao claude "$SONNET" ""
check "sem gh no PATH: aviso"                           grep -qF 'o gh não respondeu' <<<"$ERR"
cp "$BIN/gh" "$BIN/gh.bak"; printf '#!/usr/bin/env bash\necho "isto não é JSON"\n' > "$BIN/gh"
sel --issue 10
check "gh com resposta que não é JSON: Sonnet"          is "" padrao claude "$SONNET" ""
mv "$BIN/gh.bak" "$BIN/gh"

# ---------------------------------------------------------------- 5. escolha explícita (manual) vence o label
sel --issue 20 --model claude-fable-5-1
check "--model: vence a exceção e a fase"               is spec manual claude claude-fable-5-1 ""
check "--model: motivo com o que a issue daria"         jqe '.reason == "--model claude-fable-5-1 (label kaizen da issue #20)"' <<<"$OUT"
sel --issue 10 --agent codex
check "--agent codex: modelo e esforço do Codex da fase" is build manual codex gpt-6.1-sol high
sel --issue 11 --agent codex
check "--agent codex em spec: linha do Opus"            is spec manual codex gpt-6-astra high
sel --issue 20 --agent codex
check "--agent codex em kaizen: linha do Haiku"         is spec manual codex gpt-6-luna medium
sel --issue 11 --agent claude
check "--agent claude: manual, com o modelo da fase"    is spec manual claude "$OPUS" ""
sel --issue 10 --model gpt-6-astra
check "--model do Codex sem --agent: abre no Codex"     is build manual codex gpt-6-astra high
sel --issue 10 --model gpt-9-novo
check "--model fora da tabela: agente pelo prefixo"     is build manual codex gpt-9-novo high
sel --issue 10 --agent codex --model "$SONNET"
check "--agent e --model: valem os dois"                is build manual codex "$SONNET" high
sel --issue 10 --model 'claude-opus-5-5[1m]'
check "--model com [1m]: aceito"                        is build manual claude 'claude-opus-5-5[1m]' ""
sel --issue 30 --model "$OPUS"
check "--model em issue sem label: sem aviso do padrão" [ "$RC" -eq 0 -a -z "$ERR" ]
sel --issue 30 --agent codex
check "--agent codex em issue sem label: padrão do Codex" is "" manual codex gpt-6.1-sol high
check "--agent codex em issue sem label: aviso"         grep -qF 'abrindo no padrão (gpt-6.1-sol)' <<<"$ERR"

# ---------------------------------------------------------------- 6. fase fixa (dispatcher): não lê a issue
rm -f "$FAKE/gh-issue.log"
sel --phase plan
check "--phase plan: Sonnet, origem padrao"             is plan padrao claude "$SONNET" ""
check "--phase plan: sem aviso e sem chamar o gh"       [ -z "$ERR" -a "$(calls)" -eq 0 ]
check "--phase plan: motivo"                            jqe '.reason == "fase plan fixa"' <<<"$OUT"
sel --phase arch
check "--phase arch: Opus"                              is arch padrao claude "$OPUS" ""
sel --phase nada
check "--phase fora da tabela: Sonnet, com aviso"       is "" padrao claude "$SONNET" ""
check "--phase fora da tabela: aviso"                   grep -qF 'fase fixa fora da tabela (nada)' <<<"$ERR"

# ---------------------------------------------------------------- 7. tabela ausente ou inválida: abre sem modelo
OUTE_SELECT_TABLE="$TMP/nao-existe.toml" sel --issue 10
check "sem tabela: código 0, claude sem modelo"         is "" padrao claude "" ""
check "sem tabela: aviso"                               grep -qF 'tabela de fase ausente ou inválida' <<<"$ERR"
OUTE_SELECT_TABLE="$TMP/nao-existe.toml" sel --issue 10 --agent codex --model gpt-6-luna
check "sem tabela: a escolha explícita vale"            is "" manual codex gpt-6-luna ""
echo 'default = [' > "$TMP/quebrada.toml"
OUTE_SELECT_TABLE="$TMP/quebrada.toml" sel --issue 10
check "tabela que não é TOML: abre sem modelo, com aviso" bash -c '[ "$1" -eq 0 ] && jq -e ".model == \"\"" <<<"$2" >/dev/null && grep -qF "tabela de fase ausente ou inválida" <<<"$3"' _ "$RC" "$OUT" "$ERR"
printf '[default]\nclaude = "a b"\ncodex = "x"\neffort = "high"\n' > "$TMP/invalida.toml"
OUTE_SELECT_TABLE="$TMP/invalida.toml" sel --issue 10
check "tabela com id inválido: abre sem modelo, com aviso" bash -c '[ "$1" -eq 0 ] && jq -e ".model == \"\"" <<<"$2" >/dev/null && grep -qF "[default] sem claude, codex ou effort" <<<"$3"' _ "$RC" "$OUT" "$ERR"

# ---------------------------------------------------------------- 8. argumento inválido: código 2, sem JSON
sel --issue 10 --agent pi
check "Pi: código 2, mensagem, sem JSON"                [ "$RC" -eq 2 -a -z "$OUT" -a "$ERR" == "oute-select: Pi saiu do stack (#217), use claude ou codex" ]
sel --issue 10 --agent gemini
check "agente inválido: código 2"                       [ "$RC" -eq 2 -a -z "$OUT" ]
sel --issue 10 --model 'x; rm -rf /'
check "modelo inválido: código 2"                       [ "$RC" -eq 2 -a -z "$OUT" ]
sel --issue abc
check "--issue inválido: código 2"                      [ "$RC" -eq 2 -a -z "$OUT" ]
sel --nada
check "opção desconhecida: código 2, com o uso"         bash -c '[ "$1" -eq 2 ] && grep -q "^uso: oute-select" <<<"$2"' _ "$RC" "$ERR"
sel --model
check "opção sem valor: código 2"                       [ "$RC" -eq 2 ]

# ---------------------------------------------------------------- 9. saída para ler e ajuda
OUT="$("$SEL" --repo "$TMP/repo" --issue 10 --agent codex 2>/dev/null)"
check "sem --json: uma linha para ler"                  [ "$OUT" == "fase build · origem manual · agente codex · modelo gpt-6.1-sol · esforço high · motivo: --agent codex (label aidlc:build da issue #10)" ]
check "--help: uso, código 0"                           bash -c '"$1" --help | grep -q "^oute-select — seletor de modelo"' _ "$SEL"

# ---------------------------------------------------------------- 10. tabela no agent: mount só leitura e imagem
check "compose: config/select montado só leitura no agent" grep -qxF '      - ./config/select:/opt/oute/select:ro' "$ROOT/docker/compose.yaml"
check "imagem: oute-select copiado e executável"        bash -c 'grep -qxF "COPY docker/oute-select /usr/local/bin/" "$1" && grep -q "chmod +x .*" "$1" && grep -qF "/usr/local/bin/oute-select" "$1"' _ "$ROOT/docker/Dockerfile"
check "tabela padrão do oute-select = o mount"          grep -qF '"/opt/oute/select/models.toml"' "$SEL"

# ---------------------------------------------------------------- 11. Jev direto na TypeSafe (#257)
# sem label de fase e com texto da tarefa: a TypeSafe falsa classifica a fase e a tabela dá o modelo
ts_start "$TMP/ts"; ALL="$TMP/saidas"; : > "$ALL"
# jsel <texto> <args…>: sel com o texto da tarefa num arquivo; tudo que sai (stdout e stderr) fica também em $ALL
jsel() { printf '%s' "$1" > "$TMP/texto"; shift; sel --text-file "$TMP/texto" "$@"; printf '%s\n%s\n' "$OUT" "$ERR" >> "$ALL"; }
conf() { jq -r .confidence <<<"$OUT"; }
TXT="Escreva o ADR do novo serviço de filas e compare as opções de arquitetura"

# 11a. acerto
ts_set ok arch 0.91
jsel "$TXT" --task sessao-1003-0900
check "jev: sessão sem issue abre no Opus da fase arch, origem jev" is arch jev claude "$OPUS" ""
check "jev: confiança no JSON, como número"             jqe '.confidence == 0.91' <<<"$OUT"
check "jev: motivo com a fase e a confiança"            jqe '.reason == "Jev: fase arch, confiança 0,91 (sessão sem issue)"' <<<"$OUT"
check "jev: sem aviso"                                  [ -z "$ERR" ]
check "jev: uma chamada, no caminho do systemone"       bash -c '[ "$1" -eq 1 ] && jq -e ".path == \"/v1/systemone\"" <<<"$2" >/dev/null' _ "$(ts_calls)" "$(ts_last)"
check "jev: a chave vai só no Authorization"            jqe --arg k "Bearer $TS_KEY" '.auth == $k and (.body | tostring | contains($k[7:]) | not)' <<<"$(ts_last)"
check "jev: só o texto da tarefa, o modelo e a pergunta" jqe --arg t "$TXT" '.body | (keys == ["model", "questions", "state"]) and .state == $t and .model == "jev-1.13.0"
  and (.questions | keys == ["fase"]) and (.questions.fase | keys == ["criteria", "instructions", "type"]) and .questions.fase.type == "choice"' <<<"$(ts_last)"
check "jev: as opções são as fases da tabela"           jqe '.body.questions.fase.criteria | keys == ["arch", "build", "ctx", "design", "intent", "iter", "learn", "ops", "plan", "qa", "ship", "spec", "strat"]' <<<"$(ts_last)"
check "jev: nada do repo nem da issue no pedido"        bash -c '! grep -qF "$1" <<<"$2" && ! grep -qF "#30" <<<"$2"' _ "$TMP/repo" "$(ts_last)"
ts_set ok ops 0.8
jsel "veja por que o custo subiu ontem" --issue 30
check "jev: issue sem label de fase abre no Haiku da fase ops" is ops jev claude "$HAIKU" ""
check "jev: motivo diz a issue"                         jqe '.reason == "Jev: fase ops, confiança 0,80 (issue #30 sem label aidlc:<fase>)"' <<<"$OUT"
jsel "veja por que o custo subiu ontem" --issue 32
check "jev: fase fora da tabela no label também vai ao Jev" is ops jev claude "$HAIKU" ""
ts_set ok spec 0.6
jsel "$TXT"
check "jev: confiança 0,6 já vale"                      is spec jev claude "$OPUS" ""
ts_set ok spec 1
jsel "$TXT"
check "jev: confiança 1 (inteiro) vale"                 bash -c '[ "$1" == 1 ] || [ "$1" == 1.0 ]' _ "$(conf)"
ts_set ok arch 0.91
jsel "$TXT" --agent codex
check "jev + --agent codex: Codex da fase, origem manual" is arch manual codex gpt-6-astra high
check "jev + --agent codex: a confiança fica registrada" jqe '.confidence == 0.91 and (.reason | startswith("--agent codex (Jev: fase arch"))' <<<"$OUT"
OUT="$(printf '%s' "$TXT" | "$SEL" --json --repo "$TMP/repo" --text-file - 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"
check "jev: texto pelo stdin (--text-file -)"           is arch jev claude "$OPUS" ""
check "jev: o texto do stdin chegou inteiro"            jqe --arg t "$TXT" '.body.state == $t' <<<"$(ts_last)"
jsel "$(printf 'x%.0s' $(seq 1 20000)) fim"
check "jev: texto longo vai cortado"                    jqe '.body.state | length == 16000' <<<"$(ts_last)"
OUT="$("$SEL" --repo "$TMP/repo" --text-file "$TMP/texto" 2>/dev/null)"
check "jev: saída para ler com a confiança"             grep -qF 'fase arch · origem jev · agente claude · modelo claude-opus-5-5 · confiança 0,91 · motivo: Jev: fase arch' <<<"$OUT"

# 11b. confiança baixa: Sonnet, origem padrao, com a confiança registrada
ts_set ok arch 0.59
jsel "$TXT"
check "confiança baixa: Sonnet, origem padrao, sem fase" is "" padrao claude "$SONNET" ""
check "confiança baixa: a confiança fica no JSON"       jqe '.confidence == 0.59' <<<"$OUT"
check "confiança baixa: aviso"                          [ "$ERR" == "oute-select: aviso: sessão sem issue, e o Jev ficou com confiança baixa (0,59 em arch, mínimo 0,60); abrindo no padrão ($SONNET)" ]
jsel "$TXT" --agent codex
check "confiança baixa + --agent codex: padrão do Codex" is "" manual codex gpt-6.1-sol high

# 11c. tempo esgotado: Sonnet, sem esperar a TypeSafe
ts_set hang; t0=$(date +%s)
OUTE_SELECT_JEV_TIMEOUT=1 jsel "$TXT"
check "timeout: Sonnet, origem padrao, código 0"        is "" padrao claude "$SONNET" ""
check "timeout: não espera a TypeSafe"                  [ $(( $(date +%s) - t0 )) -le 3 ]
check "timeout: aviso, sem confiança"                   bash -c '[ "$1" == "" ] && grep -qF "o Jev falhou (sem resposta em 1 s); abrindo no padrão" <<<"$2"' _ "$(conf)" "$ERR"
t0=$(date +%s)
OUTE_SELECT_JEV_TIMEOUT=30 jsel "$TXT"
check "timeout: o teto de 3 s não sobe pelo ambiente"   bash -c '[ "$1" -le 4 ] && grep -qF "sem resposta em 3 s" <<<"$2"' _ "$(( $(date +%s) - t0 ))" "$ERR"

# 11d. erro da TypeSafe: Sonnet, com aviso
ts_set 5xx
jsel "$TXT"
check "5xx: Sonnet, origem padrao, código 0"            is "" padrao claude "$SONNET" ""
check "5xx: aviso com o código, sem confiança"          bash -c '[ "$1" == "" ] && [ "$2" == "oute-select: aviso: sessão sem issue, e o Jev falhou (HTTP 503); abrindo no padrão ($3)" ]' _ "$(conf)" "$ERR" "$SONNET"
ts_set 401
jsel "$TXT" --issue 30
check "401 (chave recusada): Sonnet, com aviso"         bash -c '[ "$1" -eq 0 ] && jq -e ".origin == \"padrao\" and .model == \"$3\"" <<<"$2" >/dev/null && grep -qF "issue #30 sem label aidlc:<fase>, e o Jev falhou (HTTP 401)" <<<"$4"' _ "$RC" "$OUT" "$SONNET" "$ERR"
for m in lixo sem-answers fora; do
  ts_set "$m"; jsel "$TXT"
  check "resposta inválida ($m): Sonnet, origem padrao"  is "" padrao claude "$SONNET" ""
  check "resposta inválida ($m): aviso"                  grep -qF 'o Jev falhou (resposta inválida)' <<<"$ERR"
done
for c in '"0.9"' 1.5 -0.1 true null; do
  ts_set ok arch "$c"; jsel "$TXT"
  check "confiança que não é número de 0 a 1 ($c): Sonnet" bash -c '[ "$3" == "" ] && jq -e ".origin == \"padrao\"" <<<"$1" >/dev/null && grep -qF "resposta inválida" <<<"$2"' _ "$OUT" "$ERR" "$(conf)"
done
ts_reset; ts_set redirect; printf '/outro' > "$TS_DIR/redirect-to"
jsel "$TXT"
check "redirecionamento: não segue (a chave não vai a outro endereço)" bash -c '[ "$1" -eq 1 ] && grep -qF "o Jev falhou (HTTP 302)" <<<"$2"' _ "$(ts_calls)" "$ERR"
check "redirecionamento: Sonnet, origem padrao"         is "" padrao claude "$SONNET" ""
OUTE_SELECT_JEV_URL="https://127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')/v1/systemone" jsel "$TXT"
check "TypeSafe fora do ar: Sonnet, com aviso"          bash -c '[ "$1" -eq 0 ] && jq -e ".origin == \"padrao\"" <<<"$2" >/dev/null && grep -qF "o Jev falhou (falha de rede" <<<"$3"' _ "$RC" "$OUT" "$ERR"
SSL_CERT_FILE="$TMP/outro.pem" jsel "$TXT"
check "certificado que não confere: Sonnet, com aviso"  bash -c '[ "$1" -eq 0 ] && jq -e ".origin == \"padrao\"" <<<"$2" >/dev/null && grep -qF "o Jev falhou (falha de rede" <<<"$3"' _ "$RC" "$OUT" "$ERR"

# 11d2. endereço que não é https:// (#313): o Jev não é chamado (o texto e a chave iriam em claro), Sonnet com aviso
# uma segunda falsa, sem certificado (fala sem TLS): se o seletor mandasse o pedido, ele chegaria e ficaria gravado
ts_reset; ts_set ok arch 0.91; scheme=http; mkdir -p "$TMP/claro"
python3 "$TESTLIB/fake-typesafe.py" "$TMP/claro" & CLARO_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/claro/port" ]] && break; sleep 0.1; done; PORT="$(cat "$TMP/claro/port")"
NOTLS="oute-select: aviso: sessão sem issue, e o endereço do Jev (\$OUTE_SELECT_JEV_URL) não é https://: o Jev não é chamado; abrindo no padrão ($SONNET)"
OUTE_SELECT_JEV_URL="$scheme://127.0.0.1:$PORT/v1/systemone" jsel "$TXT"
check "sem TLS: Sonnet, origem padrao, código 0"        is "" padrao claude "$SONNET" ""
check "sem TLS: aviso, sem o endereço"                  [ "$ERR" == "$NOTLS" ]
check "sem TLS: sem confiança"                          bash -c '[ "$1" == "" ]' _ "$(conf)"
OUTE_SELECT_JEV_URL="$scheme://127.0.0.1:$PORT/v1/systemone" jsel "$TXT" --issue 30
check "sem TLS em issue sem label: Sonnet, com aviso"   bash -c '[ "$1" -eq 0 ] && jq -e ".origin == \"padrao\" and .phase == \"\" and .model == \"$3\"" <<<"$2" >/dev/null && grep -qF "issue #30 sem label aidlc:<fase>, e o endereço do Jev" <<<"$4"' _ "$RC" "$OUT" "$SONNET" "$ERR"
OUTE_SELECT_JEV_URL="$scheme://127.0.0.1:$PORT/v1/systemone" jsel "$TXT" --agent codex
check "sem TLS + --agent codex: padrão do Codex"        is "" manual codex gpt-6.1-sol high
# o que não é exatamente https://<host>[:porta][/caminho] também não passa: outro esquema, maiúsculas, usuário, espaço, vazio
for u in "nada://x" "HTTPS://127.0.0.1:$PORT/v1/systemone" "https://u:p@127.0.0.1:$PORT/v1/systemone" \
         " https://127.0.0.1:$PORT/v1/systemone" "https://127.0.0.1:$PORT/v1/system one" "https://" "127.0.0.1:$PORT" ""; do
  OUTE_SELECT_JEV_URL="$u" jsel "$TXT"
  check "endereço recusado ($u): Sonnet, com o aviso do https" bash -c '[ "$1" -eq 0 ] && jq -e ".origin == \"padrao\"" <<<"$2" >/dev/null && [ "$3" == "$4" ]' _ "$RC" "$OUT" "$ERR" "$NOTLS"
done
check "endereço recusado: nenhuma chamada, nem à falsa sem TLS" [ "$(ts_calls)" -eq 0 -a ! -e "$TMP/claro/requests.jsonl" ]
kill "$CLARO_PID" 2>/dev/null; wait "$CLARO_PID" 2>/dev/null
check "endereço recusado: o valor não aparece no aviso" bash -c '! grep -qF "u:p@" "$1"' _ "$ALL"
OUT="$(env -u OUTE_SELECT_JEV_URL -u OUTE_TYPESAFE_API_KEY "$SEL" --json --repo "$TMP/repo" --text-file "$TMP/texto" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"
check "endereço padrão (sem a variável): passa pelo https e para na chave" grep -qF 'sem a chave da TypeSafe' <<<"$ERR"

# 11e. sem a chave: não chama o Jev, Sonnet com aviso
ts_reset; ts_set ok arch 0.91
OUTE_TYPESAFE_API_KEY="" jsel "$TXT"
check "sem chave (vazia): Sonnet, origem padrao"        is "" padrao claude "$SONNET" ""
check "sem chave: aviso"                                [ "$ERR" == "oute-select: aviso: sessão sem issue, e sem a chave da TypeSafe (\$OUTE_TYPESAFE_API_KEY) o Jev não classifica; abrindo no padrão ($SONNET)" ]
OUT="$(env -u OUTE_TYPESAFE_API_KEY "$SEL" --json --repo "$TMP/repo" --issue 30 --text-file "$TMP/texto" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"
check "sem chave (ausente): Sonnet, origem padrao, código 0" is "" padrao claude "$SONNET" ""
check "sem chave: nenhuma chamada à TypeSafe"           [ "$(ts_calls)" -eq 0 ]

# 11f. sem texto da tarefa: Sonnet, sem chamar o Jev, com o aviso de sempre
sel --task sessao-1003-0901
check "sem texto: Sonnet, origem padrao"                is "" padrao claude "$SONNET" ""
check "sem texto: o aviso da fatia 1"                   [ "$ERR" == "oute-select: aviso: sessão sem issue; abrindo no padrão ($SONNET)" ]
jsel "" --issue 30
check "texto vazio: Sonnet, origem padrao"              is "" padrao claude "$SONNET" ""
jsel $'  \n\t ' --issue 30
check "texto só com espaço: o aviso da fatia 1"         [ "$ERR" == "oute-select: aviso: issue #30 sem label aidlc:<fase>; abrindo no padrão ($SONNET)" ]
sel --issue 30 --text-file "$TMP/nao-existe"
check "arquivo de texto ilegível: Sonnet, com aviso"    bash -c '[ "$1" -eq 0 ] && jq -e ".origin == \"padrao\"" <<<"$2" >/dev/null && grep -qF "não li o texto da tarefa" <<<"$3"' _ "$RC" "$OUT" "$ERR"
# #313: o texto só vem do --text-file; valor de outra opção, mesmo com espaço e no fim da linha, nunca vira texto
mkdir -p "$TMP/repo com espaço no nome"
OUT="$("$SEL" --json --task sessao-1003-0902 --repo "$TMP/repo com espaço no nome" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(cat "$TMP/err")"
check "valor de opção com espaço no fim da linha: não é texto, Sonnet" is "" padrao claude "$SONNET" ""
check "valor de opção com espaço no fim da linha: o aviso de sessão sem texto" [ "$ERR" == "oute-select: aviso: sessão sem issue; abrindo no padrão ($SONNET)" ]
check "sem texto: nenhuma chamada à TypeSafe"           [ "$(ts_calls)" -eq 0 ]

# 11g. quando outra coisa decide, o Jev não é chamado, mesmo com texto e chave
jsel "$TXT" --issue 10
check "label de fase: vale o label"                     is build label claude "$SONNET" ""
jsel "$TXT" --issue 22
check "exceção por label sem fase: vale a exceção"      is "" label claude "$HAIKU" ""
jsel "$TXT" --phase plan
check "fase fixa (dispatcher): sem Jev"                 is plan padrao claude "$SONNET" ""
jsel "$TXT" --model "$OPUS"
check "--model: escolha explícita, sem Jev"             is "" manual claude "$OPUS" ""
touch "$FAKE/gh.down"; jsel "$TXT" --issue 10; rm "$FAKE/gh.down"
check "gh fora do ar: padrão, sem Jev"                  is "" padrao claude "$SONNET" ""
OUTE_SELECT_TABLE="$TMP/nao-existe.toml" jsel "$TXT"
check "sem tabela: abre sem modelo, sem Jev"            is "" padrao claude "" ""
check "outra coisa decide: nenhuma chamada à TypeSafe"  [ "$(ts_calls)" -eq 0 ]

# 11h. a chave nunca sai: nem no stdout, nem no stderr, nem nos argumentos do gh
check "a chave não aparece em nenhuma saída"            bash -c '[ -s "$2" ] && ! grep -qF "$1" "$2"' _ "$TS_KEY" "$ALL"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FAKE/gh.argv"\nexec bash "$TESTLIB/fake-gh-issue.sh" "$@"\n' > "$BIN/gh"
ts_set ok arch 0.91; jsel "$TXT" --issue 30
check "a chave não vai nos argumentos do gh"            bash -c '[ -s "$2" ] && ! grep -qF "$1" "$2"' _ "$TS_KEY" "$FAKE/gh.argv"
ts_stop

# 11i. a chave é opcional no host e chega ao login pela allowlist do entrypoint (prefixo OUTE_)
check "host e compose não exigem nem citam a chave (o oute up sobe sem ela)" bash -c '! grep -q "TYPESAFE" "$1/scripts/oute" "$1/docker/compose.yaml" "$1/docker/entrypoint.sh"' _ "$ROOT"
check "entrypoint: variável OUTE_* vai ao ambiente do login" bash -c 'grep -E "^ +declare -px \| grep -E .*\(GH_\|OUTE_\|" "$1" >/dev/null' _ "$ROOT/docker/entrypoint.sh"

check_end
