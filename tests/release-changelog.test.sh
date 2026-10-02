#!/usr/bin/env bash
# CHANGELOG em fragmentos (#121): o scripts/release monta a seção da versão com changelog.d/ + o que restar no
# [Unreleased] e apaga os fragmentos no commit de release. Bash puro, sem Docker: tudo num repo git temporário,
# com cópia do scripts/release, do scripts/changelog e do que eles chamam. Nada toca o repo de verdade.
# Uso: tests/release-changelog.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1

command -v python3 >/dev/null || die "python3 ausente"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
export GIT_AUTHOR_NAME=teste GIT_AUTHOR_EMAIL=teste@example.invalid
export GIT_COMMITTER_NAME=teste GIT_COMMITTER_EMAIL=teste@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
TODAY="$(date +%Y-%m-%d)"

g() { git -C "$REPO" "$@"; }
frag() { mkdir -p "$REPO/changelog.d"; cat > "$REPO/changelog.d/$1"; }
commit() { g add -A && g commit -q -m "$1"; }
# release <versão>: roda o scripts/release do repo temporário; saída em $OUT, código em $rc
release() { OUT="$("$REPO/scripts/release" "$1" 2>&1)"; rc=$?; }
changelog() { OUT="$("$REPO/scripts/changelog" "$@" 2>&1)"; rc=$?; }
# o repo como estava no commit <ref>, sem as tags de teste criadas depois
back_to() { g reset -q --hard "$1" && g clean -qfd; }

mkdir -p "$REPO/scripts" "$REPO/.githooks"
git init -q -b main "$REPO" || die "git init falhou"
cp "$ROOT/scripts/release" "$ROOT/scripts/changelog" "$ROOT/scripts/exec-files" "$REPO/scripts/"
cp "$ROOT/.githooks/pre-commit" "$REPO/.githooks/"
echo 1.0.0 > "$REPO/VERSION"
cat > "$REPO/CHANGELOG.md" <<'MD'
# Changelog

Formato: Keep a Changelog.

## [Unreleased]

## [1.0.0] - 2026-01-01

### Added
- **primeira versão** (#1).
MD
frag README.md <<'MD'
# changelog.d
### Isto não é fragmento
MD
: | frag .gitkeep   # arquivo oculto também não é fragmento
commit "base" || die "commit base falhou"
BASE="$(g rev-parse HEAD)"

# ---------------------------------------------------------------- montagem: várias subseções → seção única e ordenada
# transição: duas entradas ainda escritas direto no [Unreleased]
python3 - "$REPO/CHANGELOG.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("## [Unreleased]\n", """## [Unreleased]

### Fixed
- **do unreleased, fixed** (#5).

### Added
- **do unreleased, added** (#6).
""", 1))
PY
frag 30-corrige.md <<'MD'
### Fixed
- **fragmento 30** (#30).
MD
frag 7-novo.md <<'MD'

### Security
- **fragmento 7, security** (#7).

### Added
- **fragmento 7, added** (#7).
  - subitem com recuo
  - outro subitem

MD
frag 120-muda.md <<'MD'
### Changed
- **fragmento 120** (#120).
### Added
- **fragmento 120, added** (#120).
MD
frag 9-sai.md <<'MD'
### Removed
- **fragmento 9** (#9).
MD
frag 30-outro-slug.md <<'MD'
### Added
- **fragmento 30, outro slug** (#30).
MD
commit "fragmentos" || die "commit dos fragmentos falhou"
FRAGS="$(g rev-parse HEAD)"

cat > "$WORK/expected.md" <<MD
# Changelog

Formato: Keep a Changelog.

## [Unreleased]

## [1.1.0] - $TODAY

### Added
- **do unreleased, added** (#6).
- **fragmento 7, added** (#7).
  - subitem com recuo
  - outro subitem
- **fragmento 30, outro slug** (#30).
- **fragmento 120, added** (#120).

### Changed
- **fragmento 120** (#120).

### Removed
- **fragmento 9** (#9).

### Fixed
- **do unreleased, fixed** (#5).
- **fragmento 30** (#30).

### Security
- **fragmento 7, security** (#7).

## [1.0.0] - 2026-01-01

### Added
- **primeira versão** (#1).
MD

changelog check
check "check: fragmentos válidos saem com 0" [ "$rc" -eq 0 ]
check "check: imprime a seção que a release montaria" grep -qF -- '- **fragmento 120, added** (#120).' <<<"$OUT"
check "check: não grava nem apaga nada" [ -z "$(g status --porcelain)" ]

release 1.1.0
check "release: sai com 0" [ "$rc" -eq 0 ]
OUT="$(diff "$WORK/expected.md" "$REPO/CHANGELOG.md" 2>&1)"
check "release: seção única, subseções na ordem do Keep a Changelog, issues em ordem numérica, [Unreleased] vazio" [ -z "$OUT" ]
check "release: VERSION com a versão nova" [ "$(cat "$REPO/VERSION")" = 1.1.0 ]
check "release: um commit só" [ "$(g rev-list --count "$FRAGS..HEAD")" -eq 1 ]
check "release: tag na versão nova" [ "$(g rev-parse 'v1.1.0^{commit}')" = "$(g rev-parse HEAD)" ]
OUT="$(g show --name-status --format= HEAD | sort)"
check "release: fragmentos apagados no commit de release, com VERSION e CHANGELOG" [ "$OUT" = "$(printf '%s\n' \
  'D	changelog.d/120-muda.md' 'D	changelog.d/30-corrige.md' 'D	changelog.d/30-outro-slug.md' \
  'D	changelog.d/7-novo.md' 'D	changelog.d/9-sai.md' 'M	CHANGELOG.md' 'M	VERSION' | sort)" ]
check "release: README e arquivo oculto do changelog.d ficam" [ -f "$REPO/changelog.d/README.md" -a -f "$REPO/changelog.d/.gitkeep" ]
check "release: árvore limpa depois" [ -z "$(g status --porcelain)" ]

# sem fragmento e com o [Unreleased] vazio: seção só com o título, como antes da #121
release 1.1.1
check "sem fragmento: sai com 0" [ "$rc" -eq 0 ]
check "sem fragmento: seção vazia entre o [Unreleased] e a versão anterior" \
  grep -qzF "$(printf '## [Unreleased]\n\n## [1.1.1] - %s\n\n## [1.1.0] - ' "$TODAY")" "$REPO/CHANGELOG.md"

# repo sem changelog.d nenhum (nem o README): o único fragmento sai e a pasta some
back_to "$FRAGS"; g tag -d v1.1.0 v1.1.1 >/dev/null
g rm -q -r changelog.d && frag 3-so.md <<'MD'
### Added
- **único** (#3).
MD
commit "um fragmento, sem README"
release 1.2.0
check "sem README: sai com 0" [ "$rc" -eq 0 ]
check "sem README: a pasta vazia some" [ ! -e "$REPO/changelog.d" ]
check "sem README: árvore limpa" [ -z "$(g status --porcelain)" ]
release 1.2.1
check "sem a pasta changelog.d: sai com 0, só VERSION e CHANGELOG no commit" \
  [ "$rc" -eq 0 -a "$(g show --name-only --format= HEAD | sort | tr '\n' ' ')" = "CHANGELOG.md VERSION " ]
g tag -d v1.2.0 v1.2.1 >/dev/null

# ---------------------------------------------------------------- ramos de erro: a release para sem mudar nada
# refuses <descrição> <trecho da mensagem>: com o estado inválido já commitado, a release sai com 1, diz o
# motivo e não deixa VERSION, CHANGELOG, fragmento, commit nem tag pela metade
refuses() {
  local desc="$1" msg="$2" head
  commit "caso: $desc" || { bad "$desc: commit do caso"; return; }
  head="$(g rev-parse HEAD)"
  release 2.0.0
  check "$desc: sai com 1" [ "$rc" -eq 1 ]
  check "$desc: diz o motivo" grep -qF -- "$msg" <<<"$OUT"
  check "$desc: nada mudou (árvore limpa, mesmo commit, sem tag)" \
    [ -z "$(g status --porcelain)" -a "$(g rev-parse HEAD)" = "$head" -a -z "$(g tag -l v2.0.0)" ]
  back_to "$BASE"
}
back_to "$BASE"

frag 40-x.md <<'MD'
### Feature
- **subseção que não existe** (#40).
MD
refuses "subseção desconhecida" "changelog.d/40-x.md:1: subseção desconhecida '### Feature'"

frag 41-x.md <<'MD'
- **entrada sem subseção** (#41).
MD
refuses "entrada sem subseção" "changelog.d/41-x.md:1: texto fora de subseção"

frag 42-x.md <<'MD'
### Added

MD
refuses "subseção sem entrada" "changelog.d/42-x.md: subseção '### Added' sem entrada"

: | frag 43-x.md
refuses "fragmento vazio" "changelog.d/43-x.md: fragmento sem subseção"

frag 44-x.md <<'MD'
### Added
- **ok** (#44).
## [9.9.9] - 2026-01-01
MD
refuses "título de nível 2 no fragmento" "changelog.d/44-x.md:3: título de nível 1 ou 2"

frag 45-x.md <<'MD'
### Added
texto solto, sem marcador
MD
refuses "entrada sem marcador" "changelog.d/45-x.md: a entrada de '### Added' tem que começar com '- '"

frag nota.md <<'MD'
### Added
- **sem número de issue no nome** (#46).
MD
refuses "nome fora do padrão" "changelog.d/nota.md: nome fora do padrão <issue>-<slug>.md"

python3 - "$REPO/CHANGELOG.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("## [Unreleased]\n", "## [Unreleased]\n- **linha sem subseção** (#47).\n", 1))
PY
refuses "[Unreleased] com linha fora de subseção" "CHANGELOG.md [Unreleased]:1: texto fora de subseção"

# dois erros: os dois aparecem numa rodada só
frag 48-x.md <<'MD'
### Nope
- a
MD
frag 49-x.md <<'MD'
- b
MD
changelog check
check "check: sai com 1 com fragmento inválido" [ "$rc" -eq 1 ]
check "check: um erro por fragmento, todos de uma vez" [ "$(grep -c '^changelog: changelog.d/4[89]-x.md' <<<"$OUT")" -eq 2 ]
back_to "$BASE"

sed -i.bak 's/^## \[Unreleased\]$/## [Não lançado]/' "$REPO/CHANGELOG.md" && rm "$REPO/CHANGELOG.md.bak"
changelog check
check "check: CHANGELOG sem [Unreleased] sai com 1" [ "$rc" -eq 1 ]
check "check: CHANGELOG sem [Unreleased] diz o motivo" grep -qF 'CHANGELOG.md sem seção [Unreleased]' <<<"$OUT"
back_to "$BASE"

changelog
check "uso: sem comando sai com 2" [ "$rc" -eq 2 ]
changelog release 1.0.1
check "uso: release sem a data sai com 2" [ "$rc" -eq 2 ]
check "uso: nada mudou" [ -z "$(g status --porcelain)" ]

# ---------------------------------------------------------------- dois PRs com fragmentos diferentes não conflitam
g switch -q -c pr-a "$BASE"
frag 50-a.md <<'MD'
### Added
- **PR a** (#50).
MD
commit "pr a"
g switch -q -c pr-b "$BASE"
frag 51-b.md <<'MD'
### Added
- **PR b** (#51).
MD
commit "pr b"
g switch -q main
check "fragmentos: merge do PR a"                  g merge -q --no-ff --no-edit pr-a
check "fragmentos: merge do PR b, sem conflito"    g merge -q --no-ff --no-edit pr-b
check "fragmentos: os dois na main"                [ -f "$REPO/changelog.d/50-a.md" -a -f "$REPO/changelog.d/51-b.md" ]
# o que a #121 resolve: os mesmos dois PRs escrevendo no [Unreleased] conflitam
back_to "$BASE"
for pr in c d; do
  g switch -q -c "pr-$pr" "$BASE"
  python3 - "$REPO/CHANGELOG.md" "$pr" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace("## [Unreleased]\n", f"## [Unreleased]\n\n### Added\n- **PR {sys.argv[2]}**.\n", 1))
PY
  commit "pr $pr"
done
g switch -q main
g merge -q --no-ff --no-edit pr-c >/dev/null 2>&1
check "contraprova: os dois no [Unreleased] conflitam" bash -c '! git -C "$1" merge -q --no-ff --no-edit pr-d >/dev/null 2>&1' _ "$REPO"
g merge --abort; back_to "$BASE"

# ---------------------------------------------------------------- o repo de verdade
OUT="$("$ROOT/scripts/changelog" check 2>&1)"; rc=$?
check "repo: os fragmentos de changelog.d/ e o [Unreleased] passam no check" [ "$rc" -eq 0 ]
# scripts/release roda no bash 3.2 do macOS: nada do que ele não tem
OUT="$(grep -nE '\b(mapfile|readarray|timeout)\b|\$\{[A-Za-z_]+(,,|\^\^)\}|declare -[A-Za-z]*A' "$ROOT/scripts/release")"
check "repo: scripts/release sem mapfile, timeout, \${var,,} nem array associativo" [ -z "$OUT" ]

check_end
