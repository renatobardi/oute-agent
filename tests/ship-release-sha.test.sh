#!/usr/bin/env bash
# Testes do passo 8 da skill oute-aidlc-ship-release (#829): o pedido de release pelo canal leva o sha da main
# conferido e o script para sem alterar nada se o origin/main do host for outro. Extrai o bloco de bash do passo 8 do
# SKILL.md e roda numa main de teste (origin local, bare), com um scripts/release falso que só anota a versão.
# Bash puro, sem rede. Uso: tests/ship-release-sha.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
SKILL="$ROOT/addons/skills/oute-aidlc-ship-release/SKILL.md"
[[ -r "$SKILL" ]] || die "SKILL.md ausente: $SKILL"

# bloco <arquivo>: o primeiro bloco ```bash depois do título "## 8." (o script do pedido pelo canal)
bloco() { local arq="$1"; awk '/^## 8\./ {f = 1} f && /^```bash$/ {g = 1; next} g && /^```$/ {exit} g' "$arq"; return $?; }
bloco "$SKILL" > "$TMP/pedido.tpl"
check "o passo 8 tem um bloco de bash"                     test -s "$TMP/pedido.tpl"
check "o bloco tem RESUMO e CUIDADO antes do push"          bash -c 'grep -q "^# RESUMO" "$1" && grep -q "^# CUIDADO:" "$1"' _ "$TMP/pedido.tpl"
check "o bloco tem set -euo pipefail na primeira linha"     bash -c 'head -n1 "$1" | grep -qx "set -euo pipefail"' _ "$TMP/pedido.tpl"
check "o bloco não tem sintaxe quebrada"                    bash -n "$TMP/pedido.tpl"

# main de teste: origin bare com a main (um commit), o clone do host na main, e um scripts/release falso que grava a
# versão em $TMP/release.log e cria a tag local v<versão>
ORIG="$TMP/origin.git"; HOST="$TMP/host"
git init -q --bare "$ORIG"
git init -q -b main "$HOST"
git -C "$HOST" config user.email t@t; git -C "$HOST" config user.name t
git -C "$HOST" commit -q --allow-empty -m base
git -C "$HOST" remote add origin "$ORIG"; git -C "$HOST" push -q origin main
mkdir -p "$HOST/scripts"
cat > "$HOST/scripts/release" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$RELEASE_LOG"
git tag "v$1"
SH
chmod +x "$HOST/scripts/release"
export RELEASE_LOG="$TMP/release.log"

# pedido <sha> <versão> <arquivo>: o bloco com o sha e a versão do relatório, rodado na main de teste
pedido() {
  local sha="$1" versao="$2" arq="$3"
  sed -e "s/<sha conferido>/$sha/" -e "s/<x.y.z>/$versao/g" "$TMP/pedido.tpl" > "$arq"
  (cd "$HOST" && bash "$arq" > "$TMP/saida.txt" 2>&1); RC=$?
  return 0
}
CONF="$(git -C "$HOST" rev-parse HEAD)"

# 1. origin/main igual ao sha conferido: roda o release, publica a main e a tag
pedido "$CONF" 0.9.0 "$TMP/ok.sh"
check "sha igual: código 0"                                  [ "$RC" -eq 0 ]
check "sha igual: scripts/release recebeu a versão"          grep -qx "0.9.0" "$RELEASE_LOG"
check "sha igual: a tag foi para o origin"                   git -C "$ORIG" rev-parse -q --verify refs/tags/v0.9.0
check "sha igual: a main do origin é a do host"              [ "$(git -C "$ORIG" rev-parse main)" = "$(git -C "$HOST" rev-parse HEAD)" ]

# 1b. scripts/release ausente no checkout: para antes de qualquer passo, sem tag nem release
mv "$HOST/scripts/release" "$TMP/release.guardado"
rm -f "${RELEASE_LOG:?}"
pedido "$(git -C "$ORIG" rev-parse main)" 0.9.3 "$TMP/sem-release.sh"
mv "$TMP/release.guardado" "$HOST/scripts/release"
check "sem scripts/release: código 1"                        [ "$RC" -eq 1 ]
check "sem scripts/release: a saída diz que está ausente"    grep -qF "scripts/release ausente" "$TMP/saida.txt"
check "sem scripts/release: nenhuma tag 0.9.3 no origin"     bash -c '! git -C "$1" rev-parse -q --verify refs/tags/v0.9.3' _ "$ORIG"

# 2. a origin avançou depois da conferência: para no passo 1, sem release, sem tag e sem push
git -C "$HOST" commit -q --allow-empty -m "entrou depois"
git -C "$HOST" push -q origin main
NOVO="$(git -C "$HOST" rev-parse HEAD)"
git -C "$HOST" reset -q --hard "$CONF"
rm -f "${RELEASE_LOG:?}"
pedido "$CONF" 0.9.1 "$TMP/diverge.sh"
check "origin diferente: código 1"                           [ "$RC" -eq 1 ]
check "origin diferente: a saída diz o sha atual e o conferido" bash -c 'grep -qF "origin/main é $2, não o conferido ($1)" "$3"' _ "$CONF" "$NOVO" "$TMP/saida.txt"
check "origin diferente: o release não rodou"                [ ! -e "$RELEASE_LOG" ]
check "origin diferente: nenhuma tag 0.9.1 no origin"        bash -c '! git -C "$1" rev-parse -q --verify refs/tags/v0.9.1' _ "$ORIG"
check "origin diferente: o host não mudou de commit"         [ "$(git -C "$HOST" rev-parse HEAD)" = "$CONF" ]

# 3. alteração local na main do host: para antes de trocar de branch ou puxar
echo lixo > "$HOST/sujo.txt"; git -C "$HOST" add sujo.txt
pedido "$(git -C "$ORIG" rev-parse main)" 0.9.2 "$TMP/sujo.sh"
check "árvore suja: código 1"                                [ "$RC" -eq 1 ]
check "árvore suja: o release não rodou"                     [ ! -e "$RELEASE_LOG" ]
check "árvore suja: diz que há alterações locais"            grep -qF "há alterações locais" "$TMP/saida.txt"

check_end
