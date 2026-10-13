#!/usr/bin/env bash
# Testes do oute-swarm, tema: subagente do dispatcher (#832). `subagente` grava uma linha no log da rodada e emite
# oute.swarm.round.subagent (o motivo no corpo); o watch avisa a linha nova, e não a que já estava no log quando ele começou.
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-subagente.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/swarm-otlp.sh"
guarda_start "$TMP/guarda"
trap 'guarda_stop; rcv_stop; rm -rf "${TMP:?}"' EXIT

# 1. subagente: linha no log com hora, confirmação com a rodada e oute.swarm.round.subagent com o motivo no corpo
CASE=sub; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
sw subagente "auditoria do PR #12 (aud)"
check "subagente: código 0 e confirmação com a rodada"   bash -c '[ "$1" -eq 0 ] && grep -qF "subagente registrado na rodada swarm-test" <<<"$2"' _ "$RC" "$OUT"
check "subagente: linha com hora no log"                 grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z subagente auditoria do PR #12 \(aud\)$' "$STATE/log"
check "subagente: oute.swarm.round.subagent com o motivo no corpo" [ "$(n '.name == "oute.swarm.round.subagent" and .attrs["oute.swarm.round"] == "swarm-test" and .attrs["oute.agent"] == "claude" and .body == "auditoria do PR #12 (aud)"')" -eq 1 ]

# 2. texto com quebra de linha, TAB e controle vira uma linha só; texto longo corta em 300 com … (o mesmo limite do ask)
sw subagente "$(printf 'linha um\nlinha\tdois\r\001fim')"
check "subagente: controles viram espaço, uma linha só"  bash -c '[ "$1" -eq 0 ] && grep -qE " subagente linha um linha dois fim\$" "$2"' _ "$RC" "$STATE/log"
LONG="$(printf 'x%.0s' $(seq 1 450))"
sw subagente "$LONG"
check "subagente: texto longo cortado em 300, com …"     bash -c 'l="$(grep " subagente x" "$1" | tail -1 | sed "s/^[^ ]* subagente //")"; [ "${#l}" -eq 300 ] && [ "${l: -1}" = "…" ]' _ "$STATE/log"
check "subagente: evento com o corpo limitado"           [ "$(n '.name == "oute.swarm.round.subagent" and (.body | length) == 300 and (.body | endswith("…"))')" -eq 1 ]

# 3. erros de uso e de texto: nada gravado no log
t0="$(wc -l < "$STATE/log")"
sw subagente ""
check "subagente vazio: erro, sem linha no log"          bash -c '[ "$1" -eq 1 ] && grep -qF "motivo vazio" <<<"$2" && [ "$(wc -l < "$3")" -eq "$4" ]' _ "$RC" "$ERR" "$STATE/log" "$t0"
sw subagente "$(printf '\xe2\x80\xae\xe2\x80\xa8')"
check "subagente só de marcas Unicode: vazio, erro, nada gravado" bash -c '[ "$1" -eq 1 ] && grep -qF "motivo vazio" <<<"$2" && [ "$(wc -l < "$3")" -eq "$4" ]' _ "$RC" "$ERR" "$STATE/log" "$t0"
sw subagente
check "subagente sem argumento: erro de uso"             bash -c '[ "$1" -eq 1 ] && grep -qF "uso: oute-swarm subagente" <<<"$2" && [ "$(wc -l < "$3")" -eq "$4" ]' _ "$RC" "$ERR" "$STATE/log" "$t0"
sw subagente "a" "b"
check "subagente com argumento a mais: erro de uso"      bash -c '[ "$1" -eq 1 ] && [ "$(wc -l < "$2")" -eq "$3" ]' _ "$RC" "$STATE/log" "$t0"

# 4. sem rodada (nenhuma pasta de rodada no HOME, sem OUTE_SWARM_ID): erro, nada gravado
EMPTYH="$TMP/$CASE/vazio"; mkdir -p "$EMPTYH"
OUT="$(cd "$TMP" && env -u OUTE_SWARM_ID PATH="$BIN:$PATH" HOME="$EMPTYH" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" "$SWARM" subagente "x" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
check "subagente sem rodada: erro, nada gravado"         bash -c '[ "$1" -eq 1 ] && grep -qF "nenhuma rodada" <<<"$2"' _ "$RC" "$ERR"
rcv_stop

# 5. watch: a linha que já estava no log quando o watch começou não avisa; a que chega depois da primeira passada avisa,
# uma vez, numa linha `watch [subagente]` que vai ao log e fica na saída do watch
CASE=watch; round "$CASE"
echo "2026-01-01T00:00:03Z subagente já estava no log" >> "$STATE/log"
cat > "$FAKE/on-sleep-1" <<'SH'
echo "2026-01-01T00:00:04Z subagente auditoria do PR #13" >> "$STATE/log"
SH
watch
check "watch: sai com código 0"                          [ "$RC" -eq 0 ]
check "watch: aviso da linha nova (uma vez)"             bash -c '[ "$(grep -c "\[subagente\] subagente: auditoria do PR #13" <<<"$1")" -eq 1 ]' _ "$OUT"
check "watch: a linha que já estava não avisa"           bash -c '! grep -qF "já estava no log" <<<"$1"' _ "$OUT"
check "watch: o aviso vai ao log da rodada"              logged "[subagente] subagente: auditoria do PR #13"
check_end
