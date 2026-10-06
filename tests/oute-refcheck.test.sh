#!/usr/bin/env bash
# Testes do `oute-refcheck` (#485): confere que cada referência de um texto existe e o Bardi abre. Um `gh` falso no
# PATH guarda o que recebeu (só `gh api` GET) e responde com fixtures; um repo git temporário dá SHA e arquivo:linha.
# Só comportamento externo: stdout, stderr, código de saída e as chamadas que o gh falso viu.
# Uso: tests/oute-refcheck.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
command -v python3 >/dev/null && command -v git >/dev/null || die "precisa de python3 e git"
RC="$ROOT/docker/oute-refcheck"
[[ -x "$RC" ]] || die "oute-refcheck ausente ou sem +x: $RC"

BIN="$TMP/bin"; FAKE="$TMP/fake"; REPO="$TMP/repo"; mkdir -p "$BIN" "$FAKE" "$REPO"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
# gh falso: só `gh api repos/<dono>/<repo>/issues/<n>` e `…/issues/comments/<id>` (GET). Existem as issues em
# $FAKE/issues (uma por linha) e os comentários em $FAKE/comments ("<id> <n da issue>"). $FAKE/gh.down = fora do ar;
# $FAKE/gh.hang = não responde.
echo "$*" >> "$FAKE/gh.log"
[ "${1:-}" = api ] || { echo "VIOLATION subcomando $1" >> "$FAKE/gh.log"; exit 7; }
for a in "$@"; do case "$a" in -X|--method|-f|-F|--field|--raw-field|--input) echo "VIOLATION $a" >> "$FAKE/gh.log"; exit 7 ;; esac; done
[ ! -e "$FAKE/gh.hang" ] || exec sleep 5
[ ! -e "$FAKE/gh.down" ] || { echo "gh falso: fora do ar" >&2; exit 1; }
path="$2"
case "$path" in
  repos/*/*/issues/comments/*)
    id="${path##*/}"; n="$(awk -v i="$id" '$1 == i {print $2}' "$FAKE/comments")"
    [ -n "$n" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    echo "https://api.github.com/repos/o/r/issues/$n" ;;
  repos/*/*/issues/*)
    n="${path##*/}"; grep -qx "$n" "$FAKE/issues" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    echo "$n" ;;
  *) echo "gh falso: caminho $path" >&2; exit 1 ;;
esac
GH
chmod +x "$BIN/gh"
printf '10\n20\n' > "$FAKE/issues"; printf '555 10\n' > "$FAKE/comments"

git -C "$REPO" init -q -b main
printf 'a\nb\nc\n' > "$REPO/um.txt"; mkdir "$REPO/docker"; printf 'x\ny\n' > "$REPO/docker/oute-x"
git -C "$REPO" add -A; git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm um
SHA1="$(git -C "$REPO" rev-parse HEAD)"; S1="${SHA1:0:10}"
printf 'd\ne\n' >> "$REPO/um.txt"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qam dois
SHA2="$(git -C "$REPO" rev-parse HEAD)"; S2="${SHA2:0:10}"
# sentinela hex sem ser commit: 12 caracteres com letra e dígito
FAKESHA="deadbeef1234"

run() { # run <texto> [env…]: roda o comando no repo temporário, com o gh falso; guarda $OUT e $RCODE
  local txt="$1"; shift
  OUT="$(cd "$REPO" && printf '%s\n' "$txt" | env PATH="$BIN:$PATH" FAKE="$FAKE" OUTE_REFCHECK_REPO=o/r OUTE_REFCHECK_REFS=HEAD "$@" python3 "$RC" 2>&1)"
  RCODE=$?
  return 0
}
rm -f "${FAKE:?}/gh.log"

run "veja #10 e #20."
check "#N que existe: ok e saída 0" bash -c '[ "$1" = 0 ]' _ "$RCODE"
check "#N: uma linha ok por issue" has_line "$(printf 'ok\t#N\t#10')"
check "#N: resumo com 2 ok" has '^# 2 referências: 2 ok, 0 quebrada'
run "veja #999"
check "#N que não existe: quebrada e saída 1" bash -c '[ "$1" = 1 ]' _ "$RCODE"
check "#N que não existe: linha quebrada" has '^quebrada.#N.#999'
run "#10 de novo #10"
check "referência repetida sai uma vez" bash -c '[ "$(grep -c "^ok" <<<"$1")" = 1 ]' _ "$OUT"

run "commit $S1 e $S2"
check "SHA de commit que existe: ok e saída 0" bash -c '[ "$1" = 0 ] && [ "$(grep -c "^ok.sha" <<<"$2")" = 2 ]' _ "$RCODE" "$OUT"
run "commit $FAKESHA"
check "SHA que não existe: quebrada e saída 1" bash -c '[ "$1" = 1 ] && grep -q "^quebrada.sha.$2" <<<"$3"' _ "$RCODE" "$FAKESHA" "$OUT"
run "dia 20241004 e a palavra deadbeef"
check "número puro e palavra não viram SHA" bash -c '[ "$1" = 0 ] && grep -q "^# 0 referências" <<<"$2"' _ "$RCODE" "$OUT"

run "ver docker/oute-x:2 e um.txt:5"
check "arquivo:linha existente: ok" has '^ok.arquivo:linha.docker/oute-x:2'
check "arquivo:linha em arquivo na raiz: ok" has '^ok.arquivo:linha.um.txt:5'
run "ver docker/oute-x:3"
check "linha além do fim: quebrada com o total" bash -c '[ "$1" = 1 ] && grep -q "arquivo tem 2 linhas" <<<"$2"' _ "$RCODE" "$OUT"
run "ver docker/nao-existe:1"
check "arquivo que não existe: quebrada" has '^quebrada.arquivo:linha.docker/nao-existe:1.arquivo não existe'
run "ver um.txt:4-5"
check "faixa de linhas: ok quando cabe" has '^ok.arquivo:linha.um.txt:4-5'
run "ver um.txt:4-6"
check "faixa que passa do fim: quebrada" has '^quebrada.arquivo:linha.um.txt:4-6'
run "ver um.txt:4@$S1"
check "arquivo:linha@sha confere no commit citado (linha 4 não existe lá)" has '^quebrada.arquivo:linha.um.txt:4@'
run "ver um.txt:3@$S1"
check "arquivo:linha@sha: ok no commit citado" has '^ok.arquivo:linha.um.txt:3@'
run "ver um.txt:1@$FAKESHA"
check "arquivo:linha@sha com sha que não existe: quebrada" has '^quebrada.arquivo:linha.um.txt:1@'

run "comentário https://github.com/o/r/issues/10#issuecomment-555"
check "link de comentário que responde 200: ok" has '^ok.comentario'
run "comentário https://github.com/o/r/pull/10#issuecomment-777"
check "link de comentário que não existe: quebrada" bash -c '[ "$1" = 1 ] && grep -q "^quebrada.comentario" <<<"$2"' _ "$RCODE" "$OUT"
run "comentário https://github.com/o/r/issues/20#issuecomment-555"
check "comentário de outra issue: quebrada" has 'comentário é de outra issue ou PR'

rm -f "${FAKE:?}/gh.log"
run "dono https://github.com/../r/issues/10#issuecomment-555 e repo https://github.com/o/../issues/10#issuecomment-555 e https://github.com/../../pull/10#issuecomment-555"
check "link de comentário com .. no dono ou no repo: não é conferido" bash -c '! grep -q "comentario" <<<"$1"' _ "$OUT"
check "link de comentário com ..: o gh não é chamado com .." bash -c '! grep -qF ".." "$1" 2>/dev/null' _ "$FAKE/gh.log"

run "rascunho em /tmp/claude-1/x/relatorio.md e /tmp/claude-1/x/scratchpad/nota.txt"
check "/tmp e scratchpad: nao-abre e saída 1" bash -c '[ "$1" = 1 ] && [ "$(grep -c "^nao-abre" <<<"$2")" = 2 ]' _ "$RCODE" "$OUT"
run "arquivo /tmp/a/b.md:3"
check "caminho de /tmp com :linha conta uma vez, como nao-abre" bash -c '[ "$(grep -c "^" <<<"$1")" = 2 ] && grep -q "^nao-abre" <<<"$1"' _ "$OUT"

# gh fora do ar ou sem resposta: por referência, sem travar; só o que usa gh vira nao-conferido
touch "$FAKE/gh.down"
run "veja #10 e $S1 e um.txt:1"
check "gh fora do ar: #N vira nao-conferido" has '^nao-conferido.#N.#10.gh fora do ar'
check "gh fora do ar: SHA e arquivo:linha seguem conferidos" bash -c 'grep -q "^ok.sha" <<<"$1" && grep -q "^ok.arquivo:linha" <<<"$1"' _ "$OUT"
check "gh fora do ar, nada quebrado: saída 3" bash -c '[ "$1" = 3 ]' _ "$RCODE"
run "veja #10 e #999 e /tmp/x/a.md"
check "gh fora do ar com /tmp: o nao-abre ainda dá saída 1" bash -c '[ "$1" = 1 ]' _ "$RCODE"
rm -f "${FAKE:?}/gh.down"
touch "$FAKE/gh.hang"
start=$SECONDS
run "veja #10 e #20" OUTE_REFCHECK_TIMEOUT=1
check "gh sem resposta: nao-conferido por referência, dentro do prazo" bash -c '[ "$(grep -c "^nao-conferido.*gh sem resposta" <<<"$1")" = 2 ] && [ "$2" -lt 5 ] && [ "$3" = 3 ]' _ "$OUT" "$((SECONDS - start))" "$RCODE"
rm -f "${FAKE:?}/gh.hang"

# só leitura: toda chamada do gh foi `api` sem método de escrita
check "o gh só foi chamado com api, sem método de escrita" bash -c '! grep -q VIOLATION "$1" && [ -s "$1" ]' _ "$FAKE/gh.log"
check "o gh só leu repos/o/r/…" bash -c '! grep -qv "^api repos/o/r/" "$1"' _ "$FAKE/gh.log"

# entrada e uso
printf 'texto com #20\n' > "$TMP/in.md"
OUT="$(cd "$REPO" && env PATH="$BIN:$PATH" FAKE="$FAKE" OUTE_REFCHECK_REPO=o/r python3 "$RC" "$TMP/in.md" 2>&1)"; RCODE=$?
check "lê de arquivo" bash -c '[ "$1" = 0 ] && grep -q "^ok.#N.#20" <<<"$2"' _ "$RCODE" "$OUT"
OUT="$(python3 "$RC" "$TMP/nao-existe.md" 2>&1)"; RCODE=$?
check "arquivo ilegível: saída 2" bash -c '[ "$1" = 2 ]' _ "$RCODE"
OUT="$(python3 "$RC" a b 2>&1)"; RCODE=$?
check "argumento a mais: saída 2 com a ajuda" bash -c '[ "$1" = 2 ] && grep -q "^uso:" <<<"$2"' _ "$RCODE" "$OUT"
OUT="$(python3 "$RC" --help 2>&1)"; RCODE=$?
check "--help: saída 0 e declara o limite (existe, não sustenta)" bash -c '[ "$1" = 0 ] && grep -q "EXISTE, não que ela SUSTENTA" <<<"$2"' _ "$RCODE" "$OUT"
OUT="$(printf '#10' | env PATH="$BIN:$PATH" FAKE="$FAKE" OUTE_REFCHECK_REPO=o/r OUTE_REFCHECK_TIMEOUT=abc python3 "$RC" 2>&1)"; RCODE=$?
check "OUTE_REFCHECK_TIMEOUT inválido: saída 2" bash -c '[ "$1" = 2 ]' _ "$RCODE"
run "veja #10"
check "o resumo repete o limite" has 'não que sustenta a frase'

check_end
