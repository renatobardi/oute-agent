#!/usr/bin/env bash
# Testes do scripts/models-check (#220, ADR-02): a tabela do seletor conferida contra fontes de exemplo, um "binário"
# do claude, um models_cache.json do Codex e um `gh label list` falso. Bash puro + python3/jq, sem rede e sem
# nenhuma chamada a modelo: o claude e o codex do PATH do teste só registram se alguém os executar.
# Só comportamento externo: as linhas do stdout, o aviso no stderr e o código de saída.
# Uso: tests/models-check.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v jq >/dev/null && command -v python3 >/dev/null || die "precisa de jq e python3"
python3 -c 'import tomllib' 2>/dev/null || die "precisa de python3 >= 3.11 (tomllib)"
MC="$ROOT/scripts/models-check"; TABLE="$ROOT/config/select/models.toml"
[[ -x "$MC" ]] || die "models-check ausente ou sem +x: $MC"

BIN="$TMP/bin"; FAKE="$TMP/fake"; SHIMS="$TMP/shims"; RES="$TMP/reserva"; EMPTY="$TMP/vazio"
mkdir -p "$BIN" "$FAKE" "$SHIMS" "$RES" "$EMPTY" "$TMP/codex"
SONNET=claude-sonnet-5-5; OPUS=claude-opus-5-5; HAIKU=claude-haiku-4-5-20251001

# "binário" do claude: os ids como texto dentro de um script que só registra a execução (ninguém pode executá-lo)
claude_bin() {   # <arquivo> <id…>
  local f="$1"; shift
  { printf '#!/usr/bin/env bash\necho "claude $*" >> "%s/called"; exit 1\n' "$FAKE"; printf 'x="%s";\n' "$@"; } > "$f"
  chmod +x "$f"
}
# cache do Codex: <dias de idade> <slug:esforço,esforço…>…
codex_cache() {
  local days="$1"; shift
  printf '%s\n' "$@" | jq -Rn --arg at "$(date -u -d "-$days days" +%Y-%m-%dT%H:%M:%S.123456789Z)" '
    {fetched_at: $at, client_version: "0.0.0", models: [inputs | split(":") |
      {slug: .[0], visibility: "list", supported_reasoning_levels: [.[1] | split(",")[] | {effort: .}]}]}' \
    > "$TMP/codex/models_cache.json"
}
good_cache() { codex_cache "${1:-1}" gpt-6.1-sol:low,medium,high gpt-6-astra:low,high gpt-6-luna:low,medium gpt-6-sol:low; }
# tabela de exemplo: a do repo, com as trocas dadas (sed)
table() { sed "$@" "$TABLE" > "$TMP/table.toml"; }

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/gh.log"
[[ ! -e "$FAKE/gh.down" ]] || { echo "gh falso: fora do ar" >&2; exit 1; }
case "$1 ${2:-}" in
  "label list") jq -Rn '[inputs | select(. != "") | {name: .}]' < "$FAKE/labels" ;;
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
GH
printf '#!/usr/bin/env bash\necho "codex $*" >> "%s/called"; exit 1\n' "$FAKE" > "$BIN/codex"
chmod +x "$BIN/gh" "$BIN/codex"
printf '%s\n' kaizen docs aidlc:build ready > "$FAKE/labels"
claude_bin "$TMP/claude-real" "$OPUS" "$SONNET" "$HAIKU"
good_cache
export PATH="$BIN:$PATH" FAKE CODEX_HOME="$TMP/codex" OUTE_MODELS_CLAUDE_BIN="$TMP/claude-real"
export OUTE_AGENTS_FALLBACK="$EMPTY"

# mc <args…>: models-check com as fontes de exemplo; stdout em $OUT, stderr em $ERR, código em $RC
mc() { OUT="$("$MC" "$@" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(<"$TMP/err")"; }
has() { grep -qxF -- "$1" <<<"$OUT"; }      # linha inteira no stdout
hasnt() { ! grep -qF -- "$1" <<<"$OUT"; }
count() { grep -c "^$1 " <<<"$OUT" || true; }

# ---------------------------------------------------------------- 1. a tabela do repo, com fontes que têm tudo
mc
check "tabela do repo: código 0"                        [ "$RC" -eq 0 ]
check "tabela do repo: sem aviso"                       [ -z "$ERR" ]
check "tabela do repo: nenhum FALTA nem desconhecido"   bash -c '! grep -qE "^(FALTA|desconhecido) " <<<"$1"' _ "$OUT"
check "claude: uma linha ok por id"                     has "ok $OPUS (claude)"
check "claude: o Haiku com data"                        has "ok $HAIKU (claude)"
check "claude: id repetido na tabela sai uma vez"       [ "$(grep -cxF "ok $HAIKU (claude)" <<<"$OUT")" -eq 1 ]
check "codex: uma linha ok por id"                      has "ok gpt-6-astra (codex)"
check "codex: uma linha ok por esforço"                 has "ok gpt-6-luna esforço medium (codex)"
check "estrutura: as 12 fases e ctx têm linha"          [ "$(grep -c '^ok linha da fase [a-z]* (tabela)$' <<<"$OUT")" -eq 13 ]
check "estrutura: a faixa ctx"                          has "ok linha da fase ctx (tabela)"
check "estrutura: label de exceção existe"              has "ok label kaizen (repo)"
check "estrutura: o gh lista os labels uma vez"         [ "$(grep -c '^label list' "$FAKE/gh.log")" -eq 1 ]
mc --table "$TABLE"
check "--table: a mesma tabela, código 0"               [ "$RC" -eq 0 ]

# ---------------------------------------------------------------- 2. id inexistente
table -e 's/claude-opus-5-5/claude-opus-9-9/' -e 's/gpt-6-astra/gpt-9-nada/'
mc --table "$TMP/table.toml"
check "id inexistente: código 1"                        [ "$RC" -eq 1 ]
check "id inexistente no Claude: FALTA com o id"        has "FALTA claude-opus-9-9 (claude)"
check "id inexistente no Codex: FALTA com o id"         has "FALTA gpt-9-nada (codex)"
check "id inexistente no Codex: esforço dele não sai"   hasnt "gpt-9-nada esforço"
check "id inexistente: os outros seguem ok"             has "ok $SONNET (claude)"
check "id inexistente: só os dois faltam"               [ "$(count FALTA)" -eq 2 ]
# id que só existe como parte de um mais longo não vale (claude-sonnet-5 dentro de claude-sonnet-5-5)
table -e 's/claude-sonnet-5-5/claude-sonnet-5/' -e 's/gpt-6.1-sol/gpt-6.1/'
mc --table "$TMP/table.toml"
check "id que é prefixo de outro: FALTA no Claude"      has "FALTA claude-sonnet-5 (claude)"
check "id que é prefixo de outro: FALTA no Codex"       has "FALTA gpt-6.1 (codex)"
table -e 's/claude-opus-5-5/claude-opus-5-5[1m]/'
mc --table "$TMP/table.toml"
check "id com [1m]: confere o id sem o sufixo"          has "ok claude-opus-5-5[1m] (claude)"

# ---------------------------------------------------------------- 3. esforço não suportado
table -e 's/effort = "medium"/effort = "ultra"/'
mc --table "$TMP/table.toml"
check "esforço não suportado: código 1"                 [ "$RC" -eq 1 ]
check "esforço não suportado: FALTA com id e esforço"   has "FALTA gpt-6-luna esforço ultra (codex)"
check "esforço não suportado: o id em si está ok"       has "ok gpt-6-luna (codex)"
check "esforço não suportado: só ele falta"             [ "$(count FALTA)" -eq 1 ]

# ---------------------------------------------------------------- 4. estrutura
table -e 's/"build", "qa", /"build", /' -e 's/"ops", "ctx", /"ops", /'
mc --table "$TMP/table.toml"
check "fase sem linha: código 1"                        [ "$RC" -eq 1 ]
check "fase sem linha: FALTA com a fase"                has "FALTA linha da fase qa (tabela)"
check "faixa ctx sem linha: FALTA"                      has "FALTA linha da fase ctx (tabela)"
check "fase sem linha: as outras seguem ok"             has "ok linha da fase build (tabela)"
table -e 's/"ops", "ctx", /"ops", "ctx", "deploy", /'
mc --table "$TMP/table.toml"
check "fase fora do ADR-07: FALTA, código 1"            bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA fase deploy (ADR-07)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/label = "docs"/label = "nao-existe"/'
mc --table "$TMP/table.toml"
check "exceção com label que não existe: código 1"      [ "$RC" -eq 1 ]
check "exceção com label que não existe: FALTA"         has "FALTA label nao-existe (repo)"
check "exceção com label que existe: ok"                has "ok label kaizen (repo)"
touch "$FAKE/gh.down"; mc
check "gh fora do ar: labels desconhecidos, código 3"   bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido label kaizen (repo)" <<<"$2"' _ "$RC" "$OUT"
check "gh fora do ar: aviso"                            grep -qF 'aviso: o gh não listou os labels do repo' <<<"$ERR"
check "gh fora do ar: o resto segue conferido"          has "ok $OPUS (claude)"
rm "$FAKE/gh.down"
cp "$BIN/gh" "$TMP/gh.bak"; printf '#!/usr/bin/env bash\necho "isto não é JSON"\n' > "$BIN/gh"; mc
check "gh com resposta que não é JSON: desconhecido"    bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido label docs (repo)" <<<"$2"' _ "$RC" "$OUT"
cp "$TMP/gh.bak" "$BIN/gh"

# ---------------------------------------------------------------- 5. cache do Codex ausente, velho ou ilegível
rm "$TMP/codex/models_cache.json"; mc
check "cache ausente: código 3"                         [ "$RC" -eq 3 ]
check "cache ausente: id desconhecido, não ok"          has "desconhecido gpt-6-astra (codex)"
check "cache ausente: esforço desconhecido"             has "desconhecido gpt-6-luna esforço medium (codex)"
check "cache ausente: nenhum ok do Codex"               hasnt "ok gpt-"
check "cache ausente: aviso com o caminho"              grep -qF "aviso: cache de modelos do Codex ausente ou ilegível ($TMP/codex/models_cache.json" <<<"$ERR"
check "cache ausente: o Claude segue conferido"         has "ok $OPUS (claude)"
good_cache 8; mc
check "cache com 8 dias: desconhecido, código 3"        bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido gpt-6.1-sol (codex)" <<<"$2"' _ "$RC" "$OUT"
check "cache com 8 dias: aviso com a idade"             grep -qF 'aviso: cache de modelos do Codex com 8 dias, mais de 7' <<<"$ERR"
good_cache 6; mc
check "cache com 6 dias: vale, código 0"                [ "$RC" -eq 0 ]
good_cache 1; jq 'del(.fetched_at)' "$TMP/codex/models_cache.json" > "$TMP/c.json"; cp "$TMP/c.json" "$TMP/codex/models_cache.json"
mc
check "cache sem fetched_at: vale a data do arquivo"    [ "$RC" -eq 0 ]
touch -d '-9 days' "$TMP/codex/models_cache.json"; mc
check "cache sem fetched_at e arquivo velho: desconhecido" bash -c '[ "$1" -eq 3 ] && grep -qF "com 9 dias" <<<"$2"' _ "$RC" "$ERR"
echo 'isto não é JSON' > "$TMP/codex/models_cache.json"; mc
check "cache que não é JSON: desconhecido, com aviso"   bash -c '[ "$1" -eq 3 ] && grep -qF "ausente ou ilegível" <<<"$2"' _ "$RC" "$ERR"
echo '{"fetched_at": "2026", "models": "nada"}' > "$TMP/codex/models_cache.json"; touch "$TMP/codex/models_cache.json"; mc
check "cache com models fora do formato: desconhecido"  bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido gpt-6-luna (codex)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/claude-opus-5-5/claude-opus-9-9/'
mc --table "$TMP/table.toml"
check "FALTA e desconhecido juntos: código 1"           bash -c '[ "$1" -eq 1 ] && grep -q "^desconhecido " <<<"$2"' _ "$RC" "$OUT"
good_cache

# ---------------------------------------------------------------- 6. binário do Claude
OUTE_MODELS_CLAUDE_BIN="$TMP/nao-existe" mc
check "binário apontado não existe: desconhecido, código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido $3 (claude)" <<<"$2"' _ "$RC" "$OUT" "$OPUS"
check "binário apontado não existe: aviso"              grep -qF 'aviso: Claude não conferido' <<<"$ERR"
check "binário apontado não existe: o Codex segue conferido" has "ok gpt-6-astra (codex)"
: > "$TMP/claude-vazio"; OUTE_MODELS_CLAUDE_BIN="$TMP/claude-vazio" mc
check "binário vazio: desconhecido, com aviso"          bash -c '[ "$1" -eq 3 ] && grep -qF "Claude não conferido" <<<"$2"' _ "$RC" "$ERR"
# sem OUTE_MODELS_CLAUDE_BIN: o claude do PATH, pulando o shim (link para oute-agent-shim), senão a reserva
printf '#!/usr/bin/env bash\necho "shim $*" >> "%s/called"; exit 1\n' "$FAKE" > "$SHIMS/oute-agent-shim"
chmod +x "$SHIMS/oute-agent-shim"; ln -s oute-agent-shim "$SHIMS/claude"
mkdir -p "$TMP/home/bin" "$TMP/versions"; claude_bin "$TMP/versions/9.9.9" "$OPUS" "$SONNET"
ln -s "$TMP/versions/9.9.9" "$TMP/home/bin/claude"
unset OUTE_MODELS_CLAUDE_BIN; SAVED_PATH="$PATH"
PATH="$SHIMS:$TMP/home/bin:$SAVED_PATH" mc
check "claude do PATH: pula o shim e lê o binário real" bash -c '[ "$1" -eq 1 ] && grep -qxF "ok $3 (claude)" <<<"$2" && grep -qxF "FALTA $4 (claude)" <<<"$2"' _ "$RC" "$OUT" "$OPUS" "$HAIKU"
claude_bin "$RES/claude" "$OPUS" "$SONNET" "$HAIKU"
# PATH sem claude nenhum: só o shim, o gh falso (bash + jq) e o que o models-check precisa para rodar
for c in env bash python3 jq; do ln -s "$(command -v "$c")" "$EMPTY/$c"; done
PATH="$SHIMS:$BIN:$EMPTY" OUTE_AGENTS_FALLBACK="$RES" mc
check "sem claude no PATH: lê a reserva da imagem"      bash -c '[ "$1" -eq 0 ] && grep -qxF "ok $3 (claude)" <<<"$2"' _ "$RC" "$OUT" "$HAIKU"
PATH="$SHIMS:$BIN:$EMPTY" mc
check "sem claude nem reserva: desconhecido, código 3"  bash -c '[ "$1" -eq 3 ] && grep -qF "binário do claude não encontrado" <<<"$2"' _ "$RC" "$ERR"
export OUTE_MODELS_CLAUDE_BIN="$TMP/claude-real"
PATH="$EMPTY" mc
check "sem gh no PATH: labels desconhecidos, código 3"  bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido label kaizen (repo)" <<<"$2"' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 7. tabela ilegível e argumento inválido: código 2
mc --table "$TMP/nao-existe.toml"
check "tabela ausente: código 2, com o caminho"         bash -c '[ "$1" -eq 2 ] && grep -qF "tabela ilegível ($3" <<<"$2"' _ "$RC" "$ERR" "$TMP/nao-existe.toml"
check "tabela ausente: nada no stdout"                  [ -z "$OUT" ]
echo 'isto = não é [toml' > "$TMP/table.toml"; mc --table "$TMP/table.toml"
check "tabela que não é TOML: código 2"                 [ "$RC" -eq 2 ]
table -e '/^\[default\]/,/^$/d'; mc --table "$TMP/table.toml"
check "tabela sem [default]: código 2"                  bash -c '[ "$1" -eq 2 ] && grep -qF "sem [default]" <<<"$2"' _ "$RC" "$ERR"
table -e '0,/^effort = /{/^effort = /d}'; mc --table "$TMP/table.toml"
check "linha sem effort: código 2"                      bash -c '[ "$1" -eq 2 ] && grep -qF "[default] sem claude, codex ou effort" <<<"$2"' _ "$RC" "$ERR"
table -e '/^phases = \["ops"/d'; mc --table "$TMP/table.toml"
check "[[line]] sem phases: código 2"                   bash -c '[ "$1" -eq 2 ] && grep -qF "[[line]] 3 sem phases" <<<"$2"' _ "$RC" "$ERR"
table -e '/^label = "docs"/d'; mc --table "$TMP/table.toml"
check "[[exception]] sem label: código 2"               bash -c '[ "$1" -eq 2 ] && grep -qF "[[exception]] 2 sem label" <<<"$2"' _ "$RC" "$ERR"
mc --tabela x
check "opção desconhecida: código 2, com o uso"         bash -c '[ "$1" -eq 2 ] && grep -qF "uso: models-check" <<<"$2"' _ "$RC" "$ERR"
mc --table
check "--table sem valor: código 2"                     bash -c '[ "$1" -eq 2 ] && grep -qF -- "--table sem valor" <<<"$2"' _ "$RC" "$ERR"
mc --help
check "--help: o uso, código 0"                         bash -c '[ "$1" -eq 0 ] && grep -qF "scripts/models-check [--table <arquivo>]" <<<"$2"' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 8. nenhuma chamada a modelo
check "nenhum claude, codex ou shim foi executado"      [ ! -e "$FAKE/called" ]
check "o gh só listou labels"                           bash -c '! grep -qv "^label list " "$1"' _ "$FAKE/gh.log"

check_end
