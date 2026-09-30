#!/usr/bin/env bash
# Testes do oute-agents-install e da reserva do shim (#195, #199). Bash puro, sem Docker nem rede.
# claude: a reserva falsa responde a `install` criando ~/.local/bin/claude. codex: o `curl` falso entrega, para a URL do
# install.sh da release fixa, um instalador que cria ~/.local/bin/codex; o teste passa o sha256 dele. Os dois registram o
# ambiente e o PATH que receberam. HOME temporário por caso.
# Uso: tests/oute-agents-install.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/docker/oute-agents-install"
SHIM="$ROOT/docker/shims/oute-agent-shim"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; return 0; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; return 0; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; return 0; }

# ---------------------------------------------------------------- fixture
STUB="$TMP/stub"; SHIMS="$TMP/shims"; FALLBACK="$TMP/fallback"; SYS="$TMP/sys"
CODEX_V=9.9.9
mkdir -p "$STUB" "$SHIMS" "$FALLBACK" "$SYS"
# PATH do sistema sem claude/codex/pi (a máquina que roda o teste pode ter os da imagem antiga em /usr/bin)
for f in /usr/bin/* /bin/*; do
  case "${f##*/}" in
    claude|codex|pi) continue ;;
    *) ;;
  esac
  [[ -e "$SYS/${f##*/}" ]] || ln -s "$f" "$SYS/${f##*/}"
done
# trecho comum dos instaladores falsos: cria o agente $a no home e registra o que recebeu
record() {
  cat <<EOF
mkdir -p "\$HOME/.local/bin"
printf '#!/bin/sh\\necho $1-home\\n' > "\$HOME/.local/bin/$1"
chmod +x "\$HOME/.local/bin/$1"
printf '%s\\n' $1 >> "\$HOME/install.calls"
env > "\$HOME/env.$1"
printf '%s\\n' "\$PATH" > "\$HOME/path.$1"
printf '%s\\n' "\${CODEX_NON_INTERACTIVE:-}" > "\$HOME/nonint.$1"
EOF
  return 0
}
{ echo '#!/bin/sh'; record codex; } > "$TMP/codex-install.sh"
CODEX_SUM="$(sha256sum "$TMP/codex-install.sh" | cut -d' ' -f1)"
cat > "$STUB/curl" <<SH
#!/usr/bin/env bash
# curl falso: só -o e a URL importam. Roda sob \`env -i\`, então lê o estado do caso pelo HOME.
out=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
printf '%s\n' "\$url" >> "\$HOME/curl.calls"
[[ -e "\$HOME/fail.codex" ]] && exit 22
[[ "\$url" == "https://github.com/openai/codex/releases/download/rust-v$CODEX_V/install.sh" ]] || exit 22
if [[ -e "\$HOME/tamper.codex" ]]; then echo 'echo adulterado' > "\$out"; else cp "$TMP/codex-install.sh" "\$out"; fi
SH
chmod +x "$STUB/curl"
# reserva: claude responde a `install` (como o binário nativo); fora isso, os dois só dizem quem são
{
  echo '#!/bin/sh'
  echo 'if [ "${1:-}" = install ]; then'
  echo '  [ -e "$HOME/fail.claude" ] && exit 1'
  record claude
  echo '  exit 0'
  echo 'fi'
  echo 'echo claude-fallback'
} > "$FALLBACK/claude"
printf '#!/bin/sh\necho codex-fallback\n' > "$FALLBACK/codex"
chmod +x "$FALLBACK/claude" "$FALLBACK/codex"
# pi: só o shim (o Pi saiu do stack, #217), como na imagem
for a in claude codex pi; do ln -s "$SHIM" "$SHIMS/$a"; done

# caso novo: HOME limpo em $H
fresh() { H="$TMP/$1"; mkdir -p "$H"; return 0; }
# roda o instalador com os shims e a reserva no PATH (como no container) e os pins da imagem; guarda saída em $OUT e
# código em $RC. PINS="" simula imagem sem os pins do codex.
run() {
  OUT="$(HOME="$H" OPENROUTER_API_KEY=segredo-teste GH_TOKEN=segredo-teste \
    OUTE_SHIMS_DIR="$SHIMS" OUTE_AGENTS_FALLBACK="$FALLBACK" \
    OUTE_CODEX_VERSION="${PIN_V-$CODEX_V}" OUTE_CODEX_INSTALLER_SHA256="${PIN_SUM-$CODEX_SUM}" \
    PATH="$SHIMS:$FALLBACK:$STUB:$SYS" "$INSTALL" "$@" 2>&1)"; RC=$?
  return 0
}
calls()     { local want="$1"; [[ "$(cat "$H/install.calls" 2>/dev/null | tr '\n' ' ')" == "$want" ]]; return $?; }
said()      { local pat="$1"; grep -q -- "$pat" <<<"$OUT"; return $?; }

# ---------------------------------------------------------------- casos
fresh first; run
check "primeira subida: rc 0"                               [ "$RC" -eq 0 ]
check "primeira subida: instala os dois no home"            bash -c "[[ -x '$H/.local/bin/claude' && -x '$H/.local/bin/codex' ]]"
check "primeira subida: um instalador por agente, na ordem"  calls "claude codex "
check "primeira subida: sem o Pi"                           bash -c "[[ ! -e '$H/.local/bin/pi' ]]"
check "codex roda sem prompt (CODEX_NON_INTERACTIVE=1)"     grep -qx 1 "$H/nonint.codex"
# as checagens negativas exigem os registros dos dois instaladores (sem eles, `! grep` passaria sozinho)
both() { [[ -s "$H/$1.claude" && -s "$H/$1.codex" ]]; return $?; }
check "instalador não herda segredos"                       bash -c "$(declare -f both); H='$H'; both env && ! grep -q segredo-teste '$H'/env.*"
check "PATH do instalador sem os shims"                     bash -c "$(declare -f both); H='$H'; both path && ! grep -q '$SHIMS' '$H'/path.*"
check "PATH do instalador sem a reserva da imagem"          bash -c "$(declare -f both); H='$H'; both path && ! grep -q '$FALLBACK' '$H'/path.*"
check "PATH do instalador com ~/.local/bin"                 grep -q "$H/.local/bin" "$H/path.codex"
check "claude sai da reserva, sem curl"                     bash -c "[[ -s '$H/curl.calls' ]] && ! grep -q claude '$H/curl.calls'"
check "codex: só o install.sh da versão fixa"               bash -c "[[ \"\$(cat '$H/curl.calls')\" == https://github.com/openai/codex/releases/download/rust-v$CODEX_V/install.sh ]]"

rm -f "$H/install.calls" "$H/curl.calls"; run
check "segunda subida: rc 0"                                [ "$RC" -eq 0 ]
check "segunda subida: não reinstala (o agente se atualiza)" bash -c "[[ ! -e '$H/install.calls' && ! -e '$H/curl.calls' ]]"
check "segunda subida: avisa que já está instalado"         said "claude: já instalado"

fresh partial; mkdir -p "$H/.local/bin"; printf '#!/bin/sh\n' > "$H/.local/bin/codex"; chmod +x "$H/.local/bin/codex"; run
check "só instala o que falta"                              calls "claude "

fresh failing; touch "$H/fail.codex"; run
check "instalador falhou: rc 1"                             [ "$RC" -eq 1 ]
check "instalador falhou: avisa e cita a reserva"           said "AVISO: codex não foi instalado"
check "instalador falhou: os outros seguem"                 bash -c "[[ -x '$H/.local/bin/claude' && ! -e '$H/.local/bin/codex' ]]"

fresh tamper; touch "$H/tamper.codex"; run codex
check "sha256 do instalador não confere: rc 1"              [ "$RC" -eq 1 ]
check "sha256 do instalador não confere: não roda"          bash -c "[[ ! -e '$H/install.calls' && ! -e '$H/.local/bin/codex' ]]"
check "sha256 do instalador não confere: avisa"             said "sha256 do instalador do codex $CODEX_V não confere"

fresh nopins; PIN_SUM="" run codex
check "imagem sem os pins do codex: rc 1, sem download"     bash -c "[[ $RC -eq 1 && ! -e '$H/curl.calls' ]]"
check "imagem sem os pins do codex: avisa"                  said "OUTE_CODEX_INSTALLER_SHA256"

fresh badver; PIN_V='1.0.0/../x' run codex
check "versão do codex inválida: rc 1, sem download"        bash -c "[[ $RC -eq 1 && ! -e '$H/curl.calls' ]]"

fresh claudefail; touch "$H/fail.claude"; run claude
check "claude install falhou: rc 1"                         [ "$RC" -eq 1 ]
check "claude install falhou: avisa"                        said "AVISO: claude não foi instalado"

fresh one; run codex
check "argumento: instala só o pedido"                      calls "codex "

fresh gone; run pi
check "pi: rc 1, sem instalar"                              bash -c "[[ $RC -eq 1 && ! -e '$H/install.calls' ]]"
check "pi: erro claro"                                      said "Pi saiu do stack (#217), use claude ou codex"

fresh unknown; run foo
check "agente desconhecido: rc 1"                           [ "$RC" -eq 1 ]
check "agente desconhecido: avisa"                          said "agente desconhecido: foo"

fresh locked; mkdir -p "$H/.oute"; exec 8>"$H/.oute/agents-install.lock"; flock -n 8; run; exec 8>&-
check "outra instalação rodando: sai 0 sem instalar"        bash -c "[[ $RC -eq 0 && ! -e '$H/install.calls' ]]"

# ---------------------------------------------------------------- shim: reserva da imagem
# fora de repo git e sem terminal o shim passa direto para o binário real; roda com $1 como fallback, saída em $OUT
shim() {
  local fb="$1" agent="$2"
  OUT="$(cd "$TMP" && HOME="$H" OUTE_AGENTS_FALLBACK="$fb" PATH="$SHIMS:$H/.local/bin:$SYS" "$SHIMS/$agent" </dev/null 2>&1)"; RC=$?
  return 0
}
fresh shim; mkdir -p "$H/.local/bin"
shim "$FALLBACK" claude
check "shim sem o agente no home: usa a reserva"            [ "$OUT" = claude-fallback ]
printf '#!/bin/sh\necho claude-home\n' > "$H/.local/bin/claude"; chmod +x "$H/.local/bin/claude"
shim "$FALLBACK" claude
check "shim com o agente no home: usa o do home"            [ "$OUT" = claude-home ]
shim "$TMP/nada" codex
check "shim sem home nem reserva: rc 127"                   [ "$RC" -eq 127 ]
check "shim sem home nem reserva: avisa"                    said "codex não encontrado"
# pi: o binário antigo pode seguir em ~/.local/bin (volume oute-home); o shim vem antes e só avisa
printf '#!/bin/sh\necho pi-home\n' > "$H/.local/bin/pi"; chmod +x "$H/.local/bin/pi"
shim "$FALLBACK" pi
check "shim pi: rc 1, não abre o binário antigo"            bash -c "[[ $RC -eq 1 && '$OUT' != *pi-home* ]]"
check "shim pi: erro claro"                                 said "Pi saiu do stack (#217), use claude ou codex"

printf '\n%d ok, %d falhas\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
