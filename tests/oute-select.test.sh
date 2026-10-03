#!/usr/bin/env bash
# Testes do seletor de modelo por sessão (#219, ADR-02, fatia 1): o `oute-select` com a tabela do repo
# (config/select/models.toml) e um `gh` falso (tests/lib/fake-gh-issue.sh). Bash puro + python3/jq, sem rede.
# Só comportamento externo: o JSON no stdout, o aviso no stderr e o código de saída.
# O que o oute-task e o oute-swarm fazem com a escolha está em tests/oute-task.test.sh e tests/oute-swarm.test.sh.
# Uso: tests/oute-select.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v python3 >/dev/null || die "precisa de jq e python3"
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
check "label: os seis campos, e só eles"                jqe 'keys == ["agent", "effort", "model", "origin", "phase", "reason"]' <<<"$OUT"
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

check_end
