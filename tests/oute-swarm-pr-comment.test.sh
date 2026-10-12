#!/usr/bin/env bash
# Testes do oute-swarm, tema: `pr-comment`, o comentário de PR que confere as referências antes de sair (#829).
# Roda o oute-refcheck de verdade (com um gh falso que só responde às issues de $FAKE/issues), e um gh falso que
# anota o `pr comment` e guarda o corpo. Bash puro, sem herdr nem rede (dublês e apoio em tests/lib/swarm.sh).
# Uso: tests/oute-swarm-pr-comment.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'guarda_stop; rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/otlp.sh"
guarda_start "$TMP/guarda"
rcv_stop   # sem receptor neste arquivo: porta fechada, nenhum evento alcança o coletor (a guarda, sem receptor, não vê nada, #815)
. "$ROOT/tests/lib/swarm.sh"
# o oute-refcheck de verdade (o da imagem, /usr/local/bin): o repo dele é fixo, o gh falso não se importa com ele
ln -s "$ROOT/docker/oute-refcheck" "$BIN/oute-refcheck"
export OUTE_REFCHECK_REPO=o/r

# gh falso do tema, no lugar do de swarm.sh: `api` (o oute-refcheck, GET) responde às issues de $FAKE/issues; `pr
# comment <n> --body-file <f>` anota e guarda o corpo em $FAKE/comentado-<n>.md. $FAKE/gh.down = gh fora do ar;
# $FAKE/gh.comment-fail = o comentário é recusado. (gh.down só derruba a leitura, `api`: o comentário segue.)
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/gh.log"
case "$1" in
  api) [[ ! -e "$FAKE/gh.down" ]] || { echo "gh: HTTP 503" >&2; exit 1; }
       n="${2##*/}"; grep -qx "$n" "$FAKE/issues" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
       echo "$n" ;;
  pr) [[ "${2:-}" == comment ]] || { echo "gh falso: sem suporte a '$*'" >&2; exit 1; }
      [[ ! -e "$FAKE/gh.comment-fail" ]] || { echo "gh falso: comentário recusado" >&2; exit 1; }
      cp "$5" "$FAKE/comentado-$3.md"
      echo "https://github.com/o/r/pull/$3#issuecomment-4242" ;;
  *) echo "gh falso: sem suporte a '$*'" >&2; exit 1 ;;
esac
SH
chmod +x "$BIN/gh"

# pc <caso> <texto>: uma rodada limpa, com as issues 5 e 7 abertas, e o texto no arquivo $TMP/<caso>/texto.md
pc() {
  local caso="$1" texto="$2"
  round "$caso"
  printf '5\n7\n' > "$FAKE/issues"
  mkdir -p "$TMP/$caso"; printf '%s\n' "$texto" > "$TMP/$caso/texto.md"
  return 0
}
# publicado <caso> <pr>: o corpo chegou ao gh (o arquivo do comentário existe e é o do texto)
publicado() { local caso="$1" pr="$2"; cmp -s "$FAKE/comentado-$pr.md" "$TMP/$caso/texto.md"; return $?; }

# 1. referências ok: publica, com a URL do comentário na saída e o corpo como foi escrito
CASE=ok; pc "$CASE" 'Ver #5 e #7.'
sw pr-comment 12 --body-file "$TMP/$CASE/texto.md"
check "ok: código 0"                                         [ "$RC" -eq 0 ]
check "ok: imprime a URL do comentário"                      grep -qxF 'https://github.com/o/r/pull/12#issuecomment-4242' <<<"$OUT"
check "ok: o gh recebeu pr comment 12 --body-file"           grep -qF 'pr comment 12 --body-file' "$FAKE/gh.log"
check "ok: o corpo publicado é o do arquivo"                 publicado "$CASE" 12

# 2. número de PR com # na frente, aceito
CASE=hash; pc "$CASE" 'Ver #5.'
sw pr-comment '#12' --body-file "$TMP/$CASE/texto.md"
check "aceita #12: código 0 e publica no 12"                 bash -c '[ "$1" -eq 0 ] && [ -e "$2/comentado-12.md" ]' _ "$RC" "$FAKE"

# 3. referência quebrada: não publica, código 1, o refcheck aparece na saída e o motivo no stderr
CASE=quebrada; pc "$CASE" 'Ver #999 e #5.'
sw pr-comment 12 --body-file "$TMP/$CASE/texto.md"
check "quebrada: código 1"                                   [ "$RC" -eq 1 ]
check "quebrada: nada foi comentado"                         [ ! -e "$FAKE/comentado-12.md" ]
check "quebrada: o gh não recebeu pr comment"                bash -c '! grep -qF "pr comment" "$1"' _ "$FAKE/gh.log"
check "quebrada: a saída do refcheck marca a referência"     grep -qF 'quebrada' <<<"$OUT"
check "quebrada: o stderr diz que não comentou"              grep -qF 'não comentou: referência quebrada ou que não abre' <<<"$ERR"

# 4. referência que não abre (caminho de /tmp): não publica, código 1
CASE=naoabre; pc "$CASE" 'Ver o relatório em /tmp/relatorio.md.'
sw pr-comment 12 --body-file "$TMP/$CASE/texto.md"
check "nao-abre: código 1 e nada comentado"                  bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/comentado-12.md" ]' _ "$RC" "$FAKE"
check "nao-abre: a saída marca nao-abre"                     grep -qF 'nao-abre' <<<"$OUT"

# 5. só não conferidas (gh fora do ar): publica com o aviso, código 0
CASE=naoconf; pc "$CASE" 'Ver #5.'; : > "$FAKE/gh.down"
sw pr-comment 12 --body-file "$TMP/$CASE/texto.md"
check "nao-conferido: código 0 e comentou"                   bash -c '[ "$1" -eq 0 ] && [ -e "$2/comentado-12.md" ]' _ "$RC" "$FAKE"
check "nao-conferido: o aviso diz que não foi conferido"     grep -qF 'referências não conferidas (gh fora do ar)' <<<"$ERR"

# 6. o gh recusa o comentário: código 1 com a mensagem do próprio comando
CASE=recusa; pc "$CASE" 'Ver #5.'; : > "$FAKE/gh.comment-fail"
sw pr-comment 12 --body-file "$TMP/$CASE/texto.md"
check "gh recusa: código 1"                                  [ "$RC" -eq 1 ]
check "gh recusa: a mensagem diz que o gh pr comment falhou" grep -qF 'gh pr comment #12 falhou' <<<"$ERR"

# 7. uso e arquivo: sem --body-file, número inválido ou arquivo ilegível: código 1, nada comentado
CASE=uso; pc "$CASE" 'Ver #5.'
sw pr-comment 12
check "sem --body-file: código 1 e o uso na saída de erro"   bash -c '[ "$1" -eq 1 ] && grep -qF "uso: oute-swarm pr-comment" <<<"$2"' _ "$RC" "$ERR"
sw pr-comment abc --body-file "$TMP/$CASE/texto.md"
check "número não numérico: código 1"                        [ "$RC" -eq 1 ]
sw pr-comment 12 --body-file "$TMP/$CASE/sem-arquivo.md"
check "arquivo ilegível: código 1"                           bash -c '[ "$1" -eq 1 ] && grep -qF "arquivo ilegível" <<<"$2"' _ "$RC" "$ERR"
check "uso e arquivo: nada comentado"                        [ ! -e "$FAKE/comentado-12.md" ]

check_end
