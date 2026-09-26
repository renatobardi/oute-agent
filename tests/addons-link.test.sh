#!/usr/bin/env bash
# Testes do linker de addons (#66, spec #65 "Testing Decisions"). Bash puro, sem Docker.
# Só comportamento externo: roda docker/addons-link contra uma pasta de addons de fixture e um HOME
# temporário e confere o sistema de arquivos + os avisos (stderr) + o código de saída.
# Uso: tests/addons-link.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINKER="${LINKER:-$ROOT/docker/addons-link}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ---------------------------------------------------------------- fixture
# skill(<pasta de addons> <pasta> [name do frontmatter]): SKILL.md no formato agentskills.io
skill() {
  mkdir -p "$1/skills/$2"
  printf -- '---\nname: %s\ndescription: skill de teste\n---\n\n# %s\n' "${3:-$2}" "$2" > "$1/skills/$2/SKILL.md"
}
# caso novo: pasta de addons + HOME limpos; A e H ficam globais
fresh() {
  A="$TMP/$1/addons"; H="$TMP/$1/home"
  mkdir -p "$A/skills" "$H"
}
# roda o linker; guarda stderr em $ERR e código em $RC
run() { ERR="$("$LINKER" "$A" "$H" 2>&1 >/dev/null)"; RC=$?; }
linked()  { [[ -L "$H/$1/$2" && "$(readlink "$H/$1/$2")" == "$A/skills/$2" && -f "$H/$1/$2/SKILL.md" ]]; }
absent()  { [[ ! -e "$H/$1/$2" && ! -L "$H/$1/$2" ]]; }
warned()  { grep -q -- "$1" <<<"$ERR"; }
snapshot() { (cd "$H" && find . -print0 | sort -z | xargs -0 ls -ld --time-style=+%s 2>/dev/null | awk '{$1=$1; print}'); }

[[ -x "$LINKER" ]] || { echo "FAIL linker ausente ou sem +x: $LINKER"; exit 1; }

# 1. skill válida -> link nas duas pastas (cria as pastas)
fresh valida; skill "$A" oute-foo; run
check "válida: código 0"                         [ "$RC" -eq 0 ]
check "válida: link em .claude/skills"           linked .claude/skills oute-foo
check "válida: link em .agents/skills"           linked .agents/skills oute-foo

# 2. segunda execução -> mesmo estado, sem aviso
before="$(snapshot)"; run; after="$(snapshot)"
check "idempotente: código 0"                    [ "$RC" -eq 0 ]
check "idempotente: mesmo estado"                [ "$before" == "$after" ]
check "idempotente: sem aviso"                   [ -z "$ERR" ]

# 3a. nome já existente como pasta real -> intacto + aviso
fresh colisao; skill "$A" oute-foo
mkdir -p "$H/.claude/skills/oute-foo"; echo meu > "$H/.claude/skills/oute-foo/SKILL.md"
mkdir -p "$H/.agents/skills"; ln -s /algum/outro/lugar "$H/.agents/skills/oute-foo"
run
check "colisão: código 0"                        [ "$RC" -eq 0 ]
check "colisão: pasta real intacta"              [ -d "$H/.claude/skills/oute-foo" -a ! -L "$H/.claude/skills/oute-foo" ]
check "colisão: conteúdo da pasta real intacto"  [ "$(cat "$H/.claude/skills/oute-foo/SKILL.md")" == meu ]
# 3b. nome já existente como link para outro lugar -> intacto + aviso
check "colisão: link alheio intacto"             [ "$(readlink "$H/.agents/skills/oute-foo")" == /algum/outro/lugar ]
check "colisão: aviso para .claude/skills"       warned ".claude/skills/oute-foo"
check "colisão: aviso para .agents/skills"       warned ".agents/skills/oute-foo"

# 4. skill removida da fixture -> link quebrado removido (e só ele)
fresh removida; skill "$A" oute-foo; skill "$A" oute-bar; run
rm -rf "$A/skills/oute-bar"
mkdir -p "$H/.claude/skills"; ln -s /nao/existe "$H/.claude/skills/quebrado-alheio"
run
check "removida: código 0"                       [ "$RC" -eq 0 ]
check "removida: link sumiu de .claude/skills"   absent .claude/skills oute-bar
check "removida: link sumiu de .agents/skills"   absent .agents/skills oute-bar
check "removida: skill restante continua"        linked .claude/skills oute-foo
check "removida: link quebrado alheio intacto"   [ -L "$H/.claude/skills/quebrado-alheio" ]

# 5. pasta de addons inexistente -> código 0 + aviso, sem criar nada
fresh inexistente; rm -rf "$A"; run
check "inexistente: código 0"                    [ "$RC" -eq 0 ]
check "inexistente: aviso"                       warned "$A"
check "inexistente: nada criado no HOME"         [ -z "$(ls -A "$H")" ]

# 6. skill inválida -> sem link + aviso
fresh invalida
skill "$A" foo                                   # sem prefixo oute-
mkdir -p "$A/skills/oute-semskill"; echo x > "$A/skills/oute-semskill/README.md"   # sem SKILL.md
skill "$A" oute-nome oute-outro-nome             # name != pasta
skill "$A" oute-ok
run
check "inválida: código 0"                       [ "$RC" -eq 0 ]
for d in .claude/skills .agents/skills; do
  check "inválida: sem prefixo não linkada ($d)"   absent "$d" foo
  check "inválida: sem SKILL.md não linkada ($d)"  absent "$d" oute-semskill
  check "inválida: name≠pasta não linkada ($d)"    absent "$d" oute-nome
  check "inválida: a válida é linkada ($d)"        linked "$d" oute-ok
done
check "inválida: aviso sem prefixo"              warned "foo"
check "inválida: aviso sem SKILL.md"             warned "oute-semskill"
check "inválida: aviso name≠pasta"               warned "oute-nome"

# 7. pastas synced (claude.ai) e .system (Codex) pré-existentes -> intactas
fresh preexistentes; skill "$A" oute-foo
mkdir -p "$H/.claude/skills/synced/alguma" "$H/.agents/skills/.system/outra" "$H/.codex/skills/.system/outra"
echo s > "$H/.claude/skills/synced/alguma/SKILL.md"
echo c > "$H/.agents/skills/.system/outra/SKILL.md"
echo c > "$H/.codex/skills/.system/outra/SKILL.md"
before="$(cd "$H" && find .claude/skills/synced .agents/skills/.system .codex -print0 | sort -z | xargs -0 ls -ld --time-style=+%s | awk '{$1=$1; print}')"
run; run
after="$(cd "$H" && find .claude/skills/synced .agents/skills/.system .codex -print0 | sort -z | xargs -0 ls -ld --time-style=+%s | awk '{$1=$1; print}')"
check "preexistentes: código 0"                  [ "$RC" -eq 0 ]
check "preexistentes: synced/.system intactas"   [ "$before" == "$after" ]
check "preexistentes: conteúdo intacto"          [ "$(cat "$H/.claude/skills/synced/alguma/SKILL.md")$(cat "$H/.codex/skills/.system/outra/SKILL.md")" == sc ]
check "preexistentes: sem aviso"                 [ -z "$ERR" ]
check "preexistentes: skill linkada"             linked .agents/skills oute-foo

printf '\n%d ok, %d falha(s)\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
