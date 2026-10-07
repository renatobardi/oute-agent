#!/usr/bin/env bash
# Testes do scripts/models-check (#220, ADR-02): uma tabela de exemplo do próprio teste conferida contra fontes de
# exemplo, um "binário" do claude, um models_cache.json do Codex e um `gh label list` falso. A tabela do repo só entra
# para provar que é ela que o script lê sem --table, sem afirmar nada do conteúdo dela (#304): mudar a
# config/select/models.toml não quebra este teste. Bash puro + python3/jq, sem rede e sem
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
# A idade leva 1 hora de folga: o fetched_at tem a fração de segundo fixa (os 9 dígitos que o Codex grava), e com
# "-N dias" exatos a idade dava N-1 dias quando o models-check rodava numa fração menor que ela (#304).
codex_cache() {
  local days="$1"; shift
  printf '%s\n' "$@" | jq -Rn --arg at "$(date -u -d "-$days days -1 hour" +%Y-%m-%dT%H:%M:%S.123456789Z)" '
    {fetched_at: $at, client_version: "0.0.0", models: [inputs | split(":") |
      {slug: .[0], visibility: "list", supported_reasoning_levels: [.[1] | split(",")[] | {effort: .}]}]}' \
    > "$TMP/codex/models_cache.json"
}
good_cache() { codex_cache "${1:-1}" gpt-6.1-sol:low,medium,high gpt-6-astra:low,high gpt-6-luna:low,medium gpt-6-sol:low; }
# tabela de exemplo do teste (não a do repo): um [default], três [[line]] e duas [[exception]]
EX="$TMP/exemplo.toml"
cat > "$EX" <<'TOML'
[[subscription]]
name = "claude"
default = true

[[subscription]]
name = "codex"

[select]
reserve_mode = "mais-livre"

[default]
claude = "claude-sonnet-5-5"
codex = "gpt-6.1-sol"
effort = "high"

[[line]]
phases = ["strat", "intent", "arch", "spec"]
claude = "claude-opus-5-5"
codex = "gpt-6-astra"
effort = "high"

[[line]]
phases = ["build", "qa", "design", "plan", "ship", "iter"]
claude = "claude-sonnet-5-5"
codex = "gpt-6.1-sol"
effort = "high"

[[line]]
phases = ["ops", "ctx", "learn"]
claude = "claude-haiku-4-5-20251001"
codex = "gpt-6-luna"
effort = "medium"

[[exception]]
label = "kaizen"
unless_phases = ["build", "qa"]
claude = "claude-haiku-4-5-20251001"
codex = "gpt-6-luna"
effort = "medium"

[[exception]]
label = "docs"
claude = "claude-haiku-4-5-20251001"
codex = "gpt-6-luna"
effort = "medium"

[[reviewer]]
writers = ["claude-sonnet-5-5", "gpt-6.1-sol"]
agent = "claude"
model = "claude-opus-5-5"
effort = "high"

[[reviewer]]
writers = ["claude-opus-5-5", "gpt-6-astra"]
agent = "claude"
model = "claude-sonnet-5-5"
effort = "high"
TOML
# a tabela de exemplo com as trocas dadas (sed)
table() { sed "$@" "$EX" > "$TMP/table.toml"; }

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
# a API da Z.ai (#677): o fake-quota.py com TLS (rota /zai/api/anthropic/v1/models); a chave de verdade nunca vai ao teste
unset OUTE_ZAI_API_KEY OUTE_MODELS_ZAI_URL
SD="$TMP/srv"; mkdir -p "$SD"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
  -keyout "$SD/key.pem" -out "$SD/cert.pem" >/dev/null 2>&1 || die "o openssl não gerou o certificado"
python3 "$ROOT/tests/lib/fake-quota.py" "$SD" & SRV_PID=$!
trap 'kill "${SRV_PID:-}" 2>/dev/null; rm -rf "${TMP:?}"' EXIT
for _ in $(seq 1 50); do [[ -s "$SD/port" ]] && break; sleep 0.1; done
[[ -s "$SD/port" ]] || die "o servidor falso não subiu"
scheme=https; ZAI_URL="$scheme://127.0.0.1:$(cat "$SD/port")/zai/api/anthropic/v1/models"

# mc <args…>: models-check com as fontes de exemplo; stdout em $OUT, stderr em $ERR, código em $RC
mc() { OUT="$("$MC" "$@" 2>"$TMP/err" </dev/null)"; RC=$?; ERR="$(<"$TMP/err")"; }
ex() { mc --table "$EX"; }                  # com a tabela de exemplo, sem trocas
count() { grep -c "^$1 " <<<"$OUT" || true; }

# ---------------------------------------------------------------- 1. a tabela de exemplo, com fontes que têm tudo
ex
check "tabela de exemplo: código 0"                     [ "$RC" -eq 0 ]
check "tabela de exemplo: sem aviso"                    [ -z "$ERR" ]
check "tabela de exemplo: nenhum FALTA nem desconhecido" bash -c '! grep -qE "^(FALTA|desconhecido) " <<<"$1"' _ "$OUT"
check "claude: uma linha ok por id"                     has_line "ok $OPUS (claude)"
check "claude: o Haiku com data"                        has_line "ok $HAIKU (claude)"
check "claude: id repetido na tabela sai uma vez"       [ "$(grep -cxF "ok $HAIKU (claude)" <<<"$OUT")" -eq 1 ]
check "codex: uma linha ok por id"                      has_line "ok gpt-6-astra (codex)"
check "codex: uma linha ok por esforço"                 has_line "ok gpt-6-luna esforço medium (codex)"
check "estrutura: as 12 fases e ctx têm linha"          [ "$(grep -c '^ok linha da fase [a-z]* (tabela)$' <<<"$OUT")" -eq 13 ]
check "estrutura: a faixa ctx"                          has_line "ok linha da fase ctx (tabela)"
check "estrutura: label de exceção existe"              has_line "ok label kaizen (repo)"
check "estrutura: unless_phases do kaizen com fase do ADR-07"  has_line "ok fase build em unless_phases de kaizen (tabela)"
check "estrutura: unless_phases confere cada fase"      has_line "ok fase qa em unless_phases de kaizen (tabela)"
check "estrutura: o gh lista os labels uma vez"         [ "$(grep -c '^label list' "$FAKE/gh.log")" -eq 1 ]
# sem --table vale a tabela do repo: a mesma saída de quando ela é apontada, seja qual for o conteúdo dela
mc; REPO_OUT="$OUT"; REPO_RC="$RC"
mc --table "$TABLE"
check "sem --table: lê a tabela do repo"                bash -c '[ -n "$1" ] && [ "$1" = "$2" ] && [ "$3" -eq "$4" ]' _ "$OUT" "$REPO_OUT" "$RC" "$REPO_RC"

# ---------------------------------------------------------------- 2. id inexistente
table -e 's/claude-opus-5-5/claude-opus-9-9/' -e 's/gpt-6-astra/gpt-9-nada/'
mc --table "$TMP/table.toml"
check "id inexistente: código 1"                        [ "$RC" -eq 1 ]
check "id inexistente no Claude: FALTA com o id"        has_line "FALTA claude-opus-9-9 (claude)"
check "id inexistente no Codex: FALTA com o id"         has_line "FALTA gpt-9-nada (codex)"
check "id inexistente no Codex: esforço dele não sai"   hasnt_str "gpt-9-nada esforço"
check "id inexistente: os outros seguem ok"             has_line "ok $SONNET (claude)"
check "id inexistente: só os dois faltam"               [ "$(count FALTA)" -eq 2 ]
# id que só existe como parte de um mais longo não vale (claude-sonnet-5 dentro de claude-sonnet-5-5)
table -e 's/claude-sonnet-5-5/claude-sonnet-5/' -e 's/gpt-6.1-sol/gpt-6.1/'
mc --table "$TMP/table.toml"
check "id que é prefixo de outro: FALTA no Claude"      has_line "FALTA claude-sonnet-5 (claude)"
check "id que é prefixo de outro: FALTA no Codex"       has_line "FALTA gpt-6.1 (codex)"
table -e 's/claude-opus-5-5/claude-opus-5-5[1m]/'
mc --table "$TMP/table.toml"
check "id com [1m]: confere o id sem o sufixo"          has_line "ok claude-opus-5-5[1m] (claude)"

# ---------------------------------------------------------------- 3. esforço não suportado
table -e 's/effort = "medium"/effort = "ultra"/'
mc --table "$TMP/table.toml"
check "esforço não suportado: código 1"                 [ "$RC" -eq 1 ]
check "esforço não suportado: FALTA com id e esforço"   has_line "FALTA gpt-6-luna esforço ultra (codex)"
check "esforço não suportado: o id em si está ok"       has_line "ok gpt-6-luna (codex)"
check "esforço não suportado: só ele falta"             [ "$(count FALTA)" -eq 1 ]

# ---------------------------------------------------------------- 4. estrutura
table -e 's/"build", "qa", /"build", /' -e 's/"ops", "ctx", /"ops", /'
mc --table "$TMP/table.toml"
check "fase sem linha: código 1"                        [ "$RC" -eq 1 ]
check "fase sem linha: FALTA com a fase"                has_line "FALTA linha da fase qa (tabela)"
check "faixa ctx sem linha: FALTA"                      has_line "FALTA linha da fase ctx (tabela)"
check "fase sem linha: as outras seguem ok"             has_line "ok linha da fase build (tabela)"
table -e 's/"ops", "ctx", /"ops", "ctx", "deploy", /'
mc --table "$TMP/table.toml"
check "fase fora do ADR-07: FALTA, código 1"            bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA fase deploy (ADR-07)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/label = "docs"/label = "nao-existe"/'
mc --table "$TMP/table.toml"
check "exceção com label que não existe: código 1"      [ "$RC" -eq 1 ]
check "exceção com label que não existe: FALTA"         has_line "FALTA label nao-existe (repo)"
check "exceção com label que existe: ok"                has_line "ok label kaizen (repo)"
touch "$FAKE/gh.down"; ex
check "gh fora do ar: labels desconhecidos, código 3"   bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido label kaizen (repo)" <<<"$2"' _ "$RC" "$OUT"
check "gh fora do ar: aviso"                            grep -qF 'aviso: o gh não listou os labels do repo' <<<"$ERR"
check "gh fora do ar: o resto segue conferido"          has_line "ok $OPUS (claude)"
rm "$FAKE/gh.down"
cp "$BIN/gh" "$TMP/gh.bak"; printf '#!/usr/bin/env bash\necho "isto não é JSON"\n' > "$BIN/gh"; ex
check "gh com resposta que não é JSON: desconhecido"    bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido label docs (repo)" <<<"$2"' _ "$RC" "$OUT"
cp "$TMP/gh.bak" "$BIN/gh"

# ---------------------------------------------------------------- 5. cache do Codex ausente, velho ou ilegível
rm "$TMP/codex/models_cache.json"; ex
check "cache ausente: código 3"                         [ "$RC" -eq 3 ]
check "cache ausente: id desconhecido, não ok"          has_line "desconhecido gpt-6-astra (codex)"
check "cache ausente: esforço desconhecido"             has_line "desconhecido gpt-6-luna esforço medium (codex)"
check "cache ausente: nenhum ok do Codex"               hasnt_str "ok gpt-"
check "cache ausente: aviso com o caminho"              grep -qF "aviso: cache de modelos do Codex ausente ou ilegível ($TMP/codex/models_cache.json" <<<"$ERR"
check "cache ausente: o Claude segue conferido"         has_line "ok $OPUS (claude)"
good_cache 8; ex
check "cache com 8 dias: desconhecido, código 3"        bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido gpt-6.1-sol (codex)" <<<"$2"' _ "$RC" "$OUT"
check "cache com 8 dias: aviso com a idade"             grep -qF 'aviso: cache de modelos do Codex com 8 dias, mais de 7' <<<"$ERR"
good_cache 6; ex
check "cache com 6 dias: vale, código 0"                [ "$RC" -eq 0 ]
good_cache 1; jq 'del(.fetched_at)' "$TMP/codex/models_cache.json" > "$TMP/c.json"; cp "$TMP/c.json" "$TMP/codex/models_cache.json"
ex
check "cache sem fetched_at: vale a data do arquivo"    [ "$RC" -eq 0 ]
touch -d '-9 days' "$TMP/codex/models_cache.json"; ex
check "cache sem fetched_at e arquivo velho: desconhecido" bash -c '[ "$1" -eq 3 ] && grep -qF "com 9 dias" <<<"$2"' _ "$RC" "$ERR"
echo 'isto não é JSON' > "$TMP/codex/models_cache.json"; ex
check "cache que não é JSON: desconhecido, com aviso"   bash -c '[ "$1" -eq 3 ] && grep -qF "ausente ou ilegível" <<<"$2"' _ "$RC" "$ERR"
echo '{"fetched_at": "2026", "models": "nada"}' > "$TMP/codex/models_cache.json"; touch "$TMP/codex/models_cache.json"; ex
check "cache com models fora do formato: desconhecido"  bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido gpt-6-luna (codex)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/claude-opus-5-5/claude-opus-9-9/'
mc --table "$TMP/table.toml"
check "FALTA e desconhecido juntos: código 1"           bash -c '[ "$1" -eq 1 ] && grep -q "^desconhecido " <<<"$2"' _ "$RC" "$OUT"
good_cache

# ---------------------------------------------------------------- 6. binário do Claude
OUTE_MODELS_CLAUDE_BIN="$TMP/nao-existe" ex
check "binário apontado não existe: desconhecido, código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido $3 (claude)" <<<"$2"' _ "$RC" "$OUT" "$OPUS"
check "binário apontado não existe: aviso"              grep -qF 'aviso: Claude não conferido' <<<"$ERR"
check "binário apontado não existe: o Codex segue conferido" has_line "ok gpt-6-astra (codex)"
: > "$TMP/claude-vazio"; OUTE_MODELS_CLAUDE_BIN="$TMP/claude-vazio" ex
check "binário vazio: desconhecido, com aviso"          bash -c '[ "$1" -eq 3 ] && grep -qF "Claude não conferido" <<<"$2"' _ "$RC" "$ERR"
# sem OUTE_MODELS_CLAUDE_BIN: o claude do PATH, pulando o shim (link para oute-agent-shim), senão a reserva
printf '#!/usr/bin/env bash\necho "shim $*" >> "%s/called"; exit 1\n' "$FAKE" > "$SHIMS/oute-agent-shim"
chmod +x "$SHIMS/oute-agent-shim"; ln -s oute-agent-shim "$SHIMS/claude"
mkdir -p "$TMP/home/bin" "$TMP/versions"; claude_bin "$TMP/versions/9.9.9" "$OPUS" "$SONNET"
ln -s "$TMP/versions/9.9.9" "$TMP/home/bin/claude"
unset OUTE_MODELS_CLAUDE_BIN; SAVED_PATH="$PATH"
PATH="$SHIMS:$TMP/home/bin:$SAVED_PATH" ex
check "claude do PATH: pula o shim e lê o binário real" bash -c '[ "$1" -eq 1 ] && grep -qxF "ok $3 (claude)" <<<"$2" && grep -qxF "FALTA $4 (claude)" <<<"$2"' _ "$RC" "$OUT" "$OPUS" "$HAIKU"
claude_bin "$RES/claude" "$OPUS" "$SONNET" "$HAIKU"
# PATH sem claude nenhum: só o shim, o gh falso (bash + jq) e o que o models-check precisa para rodar
for c in env bash python3 jq; do ln -s "$(command -v "$c")" "$EMPTY/$c"; done
PATH="$SHIMS:$BIN:$EMPTY" OUTE_AGENTS_FALLBACK="$RES" ex
check "sem claude no PATH: lê a reserva da imagem"      bash -c '[ "$1" -eq 0 ] && grep -qxF "ok $3 (claude)" <<<"$2"' _ "$RC" "$OUT" "$HAIKU"
PATH="$SHIMS:$BIN:$EMPTY" ex
check "sem claude nem reserva: desconhecido, código 3"  bash -c '[ "$1" -eq 3 ] && grep -qF "binário do claude não encontrado" <<<"$2"' _ "$RC" "$ERR"
export OUTE_MODELS_CLAUDE_BIN="$TMP/claude-real"
PATH="$EMPTY" ex
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
check "linha sem effort: código 2"                      bash -c '[ "$1" -eq 2 ] && grep -qF "[default] sem effort" <<<"$2"' _ "$RC" "$ERR"
table -e '/^phases = \["ops"/d'; mc --table "$TMP/table.toml"
check "[[line]] sem phases: código 2"                   bash -c '[ "$1" -eq 2 ] && grep -qF "[[line]] 3 sem phases" <<<"$2"' _ "$RC" "$ERR"
table -e '/^label = "docs"/d'; mc --table "$TMP/table.toml"
check "[[exception]] sem label: código 2"               bash -c '[ "$1" -eq 2 ] && grep -qF "[[exception]] 2 sem label" <<<"$2"' _ "$RC" "$ERR"
table -e 's/^unless_phases = .*/unless_phases = ["build", "zz"]/'; mc --table "$TMP/table.toml"
check "unless_phases com fase fora do ADR-07: FALTA, código 1"  bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA fase zz em unless_phases de kaizen (tabela)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/^unless_phases = .*/unless_phases = "build"/'; mc --table "$TMP/table.toml"
check "unless_phases que não é lista: código 2"         bash -c '[ "$1" -eq 2 ] && grep -qF "[[exception]] 1 com unless_phases inválido" <<<"$2"' _ "$RC" "$ERR"
mc --tabela x
check "opção desconhecida: código 2, com o uso"         bash -c '[ "$1" -eq 2 ] && grep -qF "uso: models-check" <<<"$2"' _ "$RC" "$ERR"
mc --table
check "--table sem valor: código 2"                     bash -c '[ "$1" -eq 2 ] && grep -qF -- "--table sem valor" <<<"$2"' _ "$RC" "$ERR"
mc --help
check "--help: o uso, código 0"                         bash -c '[ "$1" -eq 0 ] && grep -qF "scripts/models-check [--table <arquivo>]" <<<"$2"' _ "$RC" "$OUT"

# ---------------------------------------------------------------- 7b. revisor das etapas da rodada (#507)
ex
check "revisor: a tabela de exemplo passa, sem FALTA"    bash -c '[ "$1" -eq 0 ] && ! grep -q "^FALTA " <<<"$2"' _ "$RC" "$OUT"
check "revisor: o autor é um modelo da tabela"           has_line "ok autor claude-sonnet-5-5 do revisor 1 é um modelo da tabela (tabela)"
check "revisor: outro modelo que o autor"                has_line "ok revisor claude-opus-5-5 é de outro modelo que o autor claude-sonnet-5-5 (tabela)"
check "revisor: o autor do dispatcher (fase plan) tem revisor, no Claude e no Codex" bash -c 'grep -qxF "ok revisor do autor claude-sonnet-5-5 (dispatcher, fase plan) (tabela)" <<<"$1" && grep -qxF "ok revisor do autor gpt-6.1-sol (dispatcher, fase plan) (tabela)" <<<"$1"' _ "$OUT"
table -e 's/^model = "claude-opus-5-5"/model = "claude-opus-9-9"/'; mc --table "$TMP/table.toml"
check "revisor com id que o Claude não tem: FALTA, código 1" bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA claude-opus-9-9 (claude)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/^model = "claude-opus-5-5"/model = "claude-sonnet-5-5"/'; mc --table "$TMP/table.toml"
check "revisor igual ao autor: FALTA, código 1"          bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA revisor claude-sonnet-5-5 é de outro modelo que o autor claude-sonnet-5-5 (tabela)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/^writers = \["claude-sonnet-5-5", "gpt-6.1-sol"\]/writers = ["gpt-6.1-sol"]/'; mc --table "$TMP/table.toml"
check "autor do dispatcher sem revisor: FALTA, código 1" bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA revisor do autor claude-sonnet-5-5 (dispatcher, fase plan) (tabela)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/^writers = \["claude-opus-5-5", "gpt-6-astra"\]/writers = ["claude-opus-5-5", "gpt-9-9"]/'; mc --table "$TMP/table.toml"
check "autor que não é modelo da tabela: FALTA, código 1" bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA autor gpt-9-9 do revisor 2 é um modelo da tabela (tabela)" <<<"$2"' _ "$RC" "$OUT"
python3 - "$EX" > "$TMP/table.toml" <<'PY'
import sys
t = open(sys.argv[1]).read()
old = 'agent = "claude"\nmodel = "claude-opus-5-5"\neffort = "high"'
assert old in t
print(t.replace(old, 'agent = "codex"\nmodel = "gpt-6-luna"\neffort = "medium"', 1), end="")
PY
mc --table "$TMP/table.toml"
check "revisor com agent = codex: recusado, código 2 (sem isolamento conferido)" bash -c '[ "$1" -eq 2 ] && grep -qF "[[reviewer]] 1: agent = \"codex\" não vale por enquanto" <<<"$2" && [ -z "$3" ]' _ "$RC" "$ERR" "$OUT"
table -e 's/^agent = "claude"/agent = "outro"/'; mc --table "$TMP/table.toml"
check "revisor com agent fora de claude e codex: código 2" bash -c '[ "$1" -eq 2 ] && grep -qF "[[reviewer]] 1 sem writers, agent (claude), model ou effort" <<<"$2"' _ "$RC" "$ERR"
table -e 's/^writers = \["claude-sonnet-5-5", "gpt-6.1-sol"\]/writers = []/'; mc --table "$TMP/table.toml"
check "revisor sem autor na lista: código 2"             bash -c '[ "$1" -eq 2 ] && grep -qF "[[reviewer]] 1 sem writers" <<<"$2"' _ "$RC" "$ERR"
check "tabela do repo: tem [[reviewer]] e o par passa na estrutura" bash -c 'grep -q "^\[\[reviewer\]\]" "$1" && ! "$2" --table "$1" 2>/dev/null | grep -E "^FALTA (autor|revisor)"' _ "$TABLE" "$MC"

# ---------------------------------------------------------------- 7b. assinaturas (#598): padrão, colunas, modo das reservas
# tabela com uma terceira assinatura fictícia (`fict`), com a coluna em toda linha
sub3() { local extra=("$@"); sed -e 's/^codex = \(.*\)$/codex = \1\nfict = "fict-x"/' -e 's/^name = "codex"$/name = "codex"\n\n[[subscription]]\nname = "fict"/' \
  -e 's/^writers = \(\["claude-sonnet-5-5", "gpt-6.1-sol"\)\]/writers = \1, "fict-x"]/' ${extra[@]+"${extra[@]}"} "$EX" > "$TMP/table.toml"; return $?; }
sub3; mc --table "$TMP/table.toml"
check "três assinaturas completas: sem FALTA, o id da terceira fica desconhecido (código 3)" bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido fict-x (fict)" <<<"$2" && ! grep -q "^FALTA" <<<"$2"' _ "$RC" "$OUT"
check "três assinaturas: avisa que só claude e codex têm conferência" bash -c 'grep -qF "assinatura fict: sem conferência dos ids" <<<"$1"' _ "$ERR"
check "três assinaturas: uma padrão só, e a coluna da terceira em toda linha" bash -c 'grep -qxF "ok uma assinatura padrão só (claude) (tabela)" <<<"$1" && grep -qxF "ok modelo da assinatura fict em [[line]] 2 (tabela)" <<<"$1"' _ "$OUT"
sub3; sed -i 's/^name = "fict"$/name = "fict"\ndefault = true/' "$TMP/table.toml"; mc --table "$TMP/table.toml"
check "duas padrão: FALTA, código 1"                    bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA uma assinatura padrão só (claude, fict) (tabela)" <<<"$2"' _ "$RC" "$OUT"
sub3 -e 's/^default = true$//'; mc --table "$TMP/table.toml"
check "nenhuma padrão: FALTA, código 1"                 bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA uma assinatura padrão só (nenhuma) (tabela)" <<<"$2"' _ "$RC" "$OUT"
sub3; python3 - "$TMP/table.toml" <<'PY'
import re
import sys
t = open(sys.argv[1]).read()
open(sys.argv[1], "w").write(re.sub(r'(?s)(\[\[line\]\]\nphases = \["build".*?)fict = "fict-x"\n', r"\1", t, count=1))
PY
mc --table "$TMP/table.toml"
check "linha sem a coluna de uma assinatura: FALTA, código 1" bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA modelo da assinatura fict em [[line]] 2 (tabela)" <<<"$2"' _ "$RC" "$OUT"
table -e 's/^reserve_mode = "mais-livre"/reserve_mode = "ordem"/'; mc --table "$TMP/table.toml"
check "modo ordem: aceito"                              bash -c '[ "$1" -eq 0 ]' _ "$RC"
table -e 's/^reserve_mode = "mais-livre"/reserve_mode = "sorteio"/'; mc --table "$TMP/table.toml"
check "modo desconhecido: código 2, sem stdout"         bash -c '[ "$1" -eq 2 ] && grep -qF "reserve_mode desconhecido" <<<"$2" && [ -z "$3" ]' _ "$RC" "$ERR" "$OUT"
table -e 's/^name = "codex"$/name = "claude"/'; mc --table "$TMP/table.toml"
check "assinatura repetida: código 2"                   bash -c '[ "$1" -eq 2 ] && grep -qF "nome repetido" <<<"$2"' _ "$RC" "$ERR"
table -e '/^\[\[subscription\]\]/,/^reserve_mode/d'; mc --table "$TMP/table.toml"
check "sem [[subscription]]: código 2"                  bash -c '[ "$1" -eq 2 ] && grep -qF "sem [[subscription]]" <<<"$2"' _ "$RC" "$ERR"
check "tabela do repo: uma padrão só e toda assinatura com linha por fase" bash -c '! "$2" --table "$1" 2>/dev/null | grep -E "^FALTA (uma assinatura|modelo da assinatura)" && "$2" --table "$1" 2>/dev/null | grep -qxF "ok uma assinatura padrão só (claude) (tabela)"' _ "$TABLE" "$MC"

# ---------------------------------------------------------------- 9. zai e chain por linha (#677)
ZT="$TMP/zai.toml"
cat > "$ZT" <<'TOML'
[[subscription]]
name = "claude"
default = true

[[subscription]]
name = "zai"
agent = "claude"
prefixes = ["glm-"]

[[subscription]]
name = "codex"

[select]
reserve_mode = "mais-livre"

[default]
claude = "claude-sonnet-5-5"
zai = "glm-5.3"
codex = "gpt-6.1-sol"
effort = "high"

[[line]]
phases = ["strat", "intent", "spec", "arch", "design", "plan", "qa", "iter", "learn"]
chain = ["claude", "zai", "codex"]
claude = "claude-opus-5-5"
zai = "glm-5.3"
codex = "gpt-6-astra"
effort = "high"

[[line]]
phases = ["build", "ship", "ops", "ctx"]
chain = ["zai", "claude", "codex"]
claude = "claude-sonnet-5-5"
zai = "glm-5.3"
codex = "gpt-6.1-sol"
effort = "high"

[[exception]]
label = "kaizen"
chain = ["zai", "claude", "codex"]
claude = "claude-sonnet-5-5"
zai = "glm-5.3"
codex = "gpt-6-luna"
effort = "medium"

[[reviewer]]
writers = ["claude-sonnet-5-5", "gpt-6.1-sol", "glm-5.3"]
agent = "claude"
model = "claude-opus-5-5"
effort = "high"

[[reviewer]]
writers = ["claude-opus-5-5", "gpt-6-astra"]
agent = "claude"
model = "claude-sonnet-5-5"
effort = "high"
TOML
zt() { local args=("$@"); sed "${args[@]}" "$ZT" > "$TMP/zai-x.toml"; return $?; }
# sem a chave: o id da zai fica desconhecido (código 3), nunca FALTA, e nenhuma chamada à API
rm -f "${SD:?}/requests.jsonl"
OUTE_MODELS_ZAI_URL="$ZAI_URL" mc --table "$ZT"
check "zai sem chave: id desconhecido, código 3, nenhum FALTA" bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido glm-5.3 (zai)" <<<"$2" && ! grep -q "^FALTA" <<<"$2"' _ "$RC" "$OUT"
check "zai sem chave: avisa e não chama a API"          bash -c 'grep -qF "sem OUTE_ZAI_API_KEY" <<<"$1" && [ ! -e "$2/requests.jsonl" ]' _ "$ERR" "$SD"
check "zai: o resto da tabela confere (claude e codex ok)" has_line "ok claude-opus-5-5 (claude)"
check "chain: assinatura da tabela, sem repetir e com coluna" bash -c 'grep -qxF "ok assinatura zai da chain de [[line]] 2 é da tabela (tabela)" <<<"$1" && grep -qxF "ok chain de [[line]] 2 sem assinatura repetida (tabela)" <<<"$1" && grep -qxF "ok modelo da assinatura codex da chain de [[exception]] 1 (tabela)" <<<"$1"' _ "$OUT"
check "revisor: glm-5.3 tem revisor (dispatcher, fase plan)" has_line "ok revisor do autor glm-5.3 (dispatcher, fase plan) (tabela)"
check "revisor: glm-5.3 é autor da tabela e de outro modelo que o revisor" bash -c 'grep -qxF "ok autor glm-5.3 do revisor 1 é um modelo da tabela (tabela)" <<<"$1" && grep -qxF "ok revisor claude-opus-5-5 é de outro modelo que o autor glm-5.3 (tabela)" <<<"$1"' _ "$OUT"
# com a chave: confere o id na API; a chave vai só no cabeçalho
printf '%s' '{"data":[{"id":"glm-5.3","type":"model"},{"id":"glm-4.6","type":"model"}]}' > "$SD/zai-models.body"
CHAVE="chave-$RANDOM-$RANDOM"
OUTE_ZAI_API_KEY="$CHAVE" OUTE_MODELS_ZAI_URL="$ZAI_URL" SSL_CERT_FILE="$SD/cert.pem" mc --table "$ZT"
check "zai com chave: id na API, ok, código 0"          bash -c '[ "$1" -eq 0 ] && grep -qxF "ok glm-5.3 (zai)" <<<"$2" && [ -z "$3" ]' _ "$RC" "$OUT" "$ERR"
check "zai com chave: um GET em /v1/models com Bearer"  bash -c '[ "$(jq -s "length" "$1/requests.jsonl")" -eq 1 ] && jq -s -e --arg a "Bearer $2" ".[0].method == \"GET\" and .[0].auth == \$a and .[0].path == \"/zai/api/anthropic/v1/models\"" "$1/requests.jsonl" >/dev/null' _ "$SD" "$CHAVE"
check "zai com chave: a chave não aparece na saída"      bash -c '! grep -qF "$1" <<<"$2$3"' _ "$CHAVE" "$OUT" "$ERR"
zt 's/zai = "glm-5.3"/zai = "glm-9.9"/'
OUTE_ZAI_API_KEY="$CHAVE" OUTE_MODELS_ZAI_URL="$ZAI_URL" SSL_CERT_FILE="$SD/cert.pem" mc --table "$TMP/zai-x.toml"
check "zai com chave: id fora da API é FALTA, código 1"  bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA glm-9.9 (zai)" <<<"$2"' _ "$RC" "$OUT"
for modo in 5xx lixo formato 429; do
  printf '%s' "$modo" > "$SD/zai-models.mode"
  OUTE_ZAI_API_KEY="$CHAVE" OUTE_MODELS_ZAI_URL="$ZAI_URL" SSL_CERT_FILE="$SD/cert.pem" mc --table "$ZT"
  check "zai com a API em modo $modo: desconhecido, código 3, nunca FALTA" bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido glm-5.3 (zai)" <<<"$2" && ! grep -q "^FALTA" <<<"$2" && ! grep -qF "$3" <<<"$4"' _ "$RC" "$OUT" "$CHAVE" "$ERR"
done
rm -f "${SD:?}/zai-models.mode"
OUTE_ZAI_API_KEY="$CHAVE" OUTE_MODELS_ZAI_URL="https://127.0.0.1:1/x" SSL_CERT_FILE="$SD/cert.pem" mc --table "$ZT"
check "zai com a API fora do ar: desconhecido, código 3" bash -c '[ "$1" -eq 3 ] && grep -qxF "desconhecido glm-5.3 (zai)" <<<"$2"' _ "$RC" "$OUT"
insegura="ht""tp://127.0.0.1:1/x"
OUTE_ZAI_API_KEY="$CHAVE" OUTE_MODELS_ZAI_URL="$insegura" mc --table "$ZT"
check "zai: endereço sem https é recusado (código 2), sem chamada" bash -c '[ "$1" -eq 2 ] && grep -qF "só pode ser https" <<<"$2"' _ "$RC" "$ERR"
# chain
zt '0,/^chain = \["claude", "zai", "codex"\]/s//chain = ["claude", "claude", "codex"]/'; mc --table "$TMP/zai-x.toml"
check "chain com assinatura repetida: FALTA, código 1"   bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA chain de [[line]] 1 sem assinatura repetida (tabela)" <<<"$2"' _ "$RC" "$OUT"
zt '0,/^chain = \["claude", "zai", "codex"\]/s//chain = ["claude", "nada", "codex"]/'; mc --table "$TMP/zai-x.toml"
check "chain com nome fora da tabela: FALTA, código 1"   bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA assinatura nada da chain de [[line]] 1 é da tabela (tabela)" <<<"$2"' _ "$RC" "$OUT"
python3 - "$ZT" "$TMP/zai-x.toml" <<'PY'
import re
import sys
t = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(re.sub(r'(\[\[line\]\]\nphases = \["build".*?)zai = "glm-5.3"\n', r"\1", t, count=1, flags=re.S))
PY
mc --table "$TMP/zai-x.toml"
check "chain com assinatura sem coluna na linha: FALTA, código 1" bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA modelo da assinatura zai da chain de [[line]] 2 (tabela)" <<<"$2"' _ "$RC" "$OUT"
for ruim in '[]' '"zai"' '[1]'; do
  zt "0,/^chain = .*/s//chain = $ruim/"; mc --table "$TMP/zai-x.toml"
  check "chain $ruim: fora do formato, código 2, sem stdout" bash -c '[ "$1" -eq 2 ] && grep -qF "chain fora do formato" <<<"$2" && [ -z "$3" ]' _ "$RC" "$ERR" "$OUT"
done
zt 's/"gpt-6.1-sol", "glm-5.3"\]/"gpt-6.1-sol"]/'; mc --table "$TMP/zai-x.toml"
check "glm-5.3 sem revisor: FALTA, código 1"            bash -c '[ "$1" -eq 1 ] && grep -qxF "FALTA revisor do autor glm-5.3 (dispatcher, fase plan) (tabela)" <<<"$2"' _ "$RC" "$OUT"
check "tabela do repo: toda chain confere (sem FALTA em chain)" bash -c '! "$2" --table "$1" 2>/dev/null | grep -E "^FALTA .*chain"' _ "$TABLE" "$MC"

# ---------------------------------------------------------------- 8. nenhuma chamada a modelo
check "nenhum claude, codex ou shim foi executado"      [ ! -e "$FAKE/called" ]
check "o gh só listou labels"                           bash -c '! grep -qv "^label list " "$1"' _ "$FAKE/gh.log"

check_end
