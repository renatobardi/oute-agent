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
unwarned() { ! warned "$1"; }
# stat portátil: GNU (Linux/CI) ou BSD (macOS); tipo, inode, mtime (s) e tamanho de cada entrada
if stat -c '%n' . >/dev/null 2>&1; then
  statf() { stat -c '%F|%i|%Y|%s' "$1"; }
elif stat -f '%N' . >/dev/null 2>&1; then
  statf() { stat -f '%HT|%i|%m|%z' "$1"; }
else
  echo "FAIL stat sem -c (GNU) nem -f (BSD)"; exit 1
fi
# snapshot(<caminho>...): estado de <caminho>... relativos ao $H (nome, alvo do link e statf de cada
# entrada). Se algo falhar, a saída é única (nunca igual a outra) e o código é 1: a comparação falha.
snapshot() {
  local out
  out="$(cd "$H" && find "$@" -print | LC_ALL=C sort | while IFS= read -r p; do
           printf '%s|%s|' "$p" "$(readlink "$p")"; statf "$p" || exit 1
         done)" || { printf 'ERRO snapshot %s%s\n' "$RANDOM" "$RANDOM"; return 1; }
  printf '%s\n' "$out"
}

[[ -x "$LINKER" ]] || { echo "FAIL linker ausente ou sem +x: $LINKER"; exit 1; }

# 0. o snapshot enxerga mudança (arquivo recriado com outro mtime) -> as comparações abaixo valem
fresh snapshot; echo a > "$H/f"
before="$(snapshot .)"; rm "$H/f"; echo a > "$H/f"; touch -t 200001010000 "$H/f"; after="$(snapshot .)"
check "snapshot: detecta arquivo recriado"       [ "$before" != "$after" ]
check "snapshot: estado igual dá igual"          [ "$after" == "$(snapshot .)" ]

# 1. skill válida -> link nas duas pastas (cria as pastas)
fresh valida; skill "$A" oute-foo; run
check "válida: código 0"                         [ "$RC" -eq 0 ]
check "válida: link em .claude/skills"           linked .claude/skills oute-foo
check "válida: link em .agents/skills"           linked .agents/skills oute-foo

# 2. segunda execução -> mesmo estado, sem aviso
before="$(snapshot .)"; sleep 1; run; after="$(snapshot .)"
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

# 5b. pasta de addons vazia (o bind do compose cria a pasta quando ./addons não existe no host)
#     -> código 0 + aviso, sem criar nada
fresh vazia; rmdir "$A/skills"; run
check "vazia: código 0"                          [ "$RC" -eq 0 ]
check "vazia: aviso"                             warned "$A/skills"
check "vazia: nada criado no HOME"               [ -z "$(ls -A "$H")" ]

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
before="$(snapshot .claude/skills/synced .agents/skills/.system .codex)"
sleep 1; run; run
after="$(snapshot .claude/skills/synced .agents/skills/.system .codex)"
check "preexistentes: código 0"                  [ "$RC" -eq 0 ]
check "preexistentes: synced/.system intactas"   [ "$before" == "$after" ]
check "preexistentes: conteúdo intacto"          [ "$(cat "$H/.claude/skills/synced/alguma/SKILL.md")$(cat "$H/.codex/skills/.system/outra/SKILL.md")" == sc ]
check "preexistentes: sem aviso"                 [ -z "$ERR" ]
check "preexistentes: skill linkada"             linked .agents/skills oute-foo

# 8. skill linkada que fica inválida -> link nosso removido nas duas pastas + aviso
fresh recusada; skill "$A" oute-nome; skill "$A" oute-sem; skill "$A" oute-ok; run
skill "$A" oute-nome outro                       # name passa a diferir da pasta
rm "$A/skills/oute-sem/SKILL.md"                 # pasta perde o SKILL.md
run
check "recusada: código 0"                       [ "$RC" -eq 0 ]
for d in .claude/skills .agents/skills; do
  check "recusada: name≠pasta sem link ($d)"     absent "$d" oute-nome
  check "recusada: sem SKILL.md sem link ($d)"   absent "$d" oute-sem
  check "recusada: a válida continua ($d)"       linked "$d" oute-ok
  check "recusada: aviso de remoção ($d)"        warned "removido link de skill recusada $H/$d/oute-nome"
done
check "recusada: aviso de remoção (sem SKILL.md)" warned "removido link de skill recusada $H/.claude/skills/oute-sem"

# 8b. skill recusada com o nome ocupado por pasta ou link alheio -> intactos
fresh recusada-alheia; skill "$A" oute-nome outro
mkdir -p "$H/.claude/skills/oute-nome"; echo meu > "$H/.claude/skills/oute-nome/SKILL.md"
mkdir -p "$H/.agents/skills"; ln -s /algum/outro/lugar "$H/.agents/skills/oute-nome"
run
check "recusada alheia: código 0"                [ "$RC" -eq 0 ]
check "recusada alheia: pasta intacta"           [ "$(cat "$H/.claude/skills/oute-nome/SKILL.md")" == meu ]
check "recusada alheia: link intacto"            [ "$(readlink "$H/.agents/skills/oute-nome")" == /algum/outro/lugar ]
check "recusada alheia: sem aviso de remoção"    unwarned "removido"

# 9. .claude/skills existe como arquivo -> aviso com prefixo, link em .agents/skills, código 0
fresh arquivo; skill "$A" oute-foo
mkdir -p "$H/.claude"; echo x > "$H/.claude/skills"
run
check "arquivo: código 0"                        [ "$RC" -eq 0 ]
check "arquivo: .claude/skills intacto"          [ -f "$H/.claude/skills" -a "$(cat "$H/.claude/skills")" == x ]
check "arquivo: link em .agents/skills"          linked .agents/skills oute-foo
check "arquivo: aviso cita .claude/skills"       warned "$H/.claude/skills"
check "arquivo: toda linha com o prefixo"        [ -z "$(grep -v '^\[oute\] addons: ' <<<"$ERR")" ]

printf '\n%d ok, %d falha(s)\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
