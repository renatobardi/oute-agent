#!/usr/bin/env bash
# Testes do oute-agents-install e da reserva do shim (#195). Bash puro, sem Docker nem rede.
# O `curl` falso devolve, para a URL de cada instalador oficial, um script que cria ~/.local/bin/<agente> e registra o
# ambiente e o PATH que recebeu. HOME temporário por caso.
# Uso: tests/oute-agents-install.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/docker/oute-agents-install"
SHIM="$ROOT/docker/shims/oute-agent-shim"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# ---------------------------------------------------------------- fixture
STUB="$TMP/stub"; SHIMS="$TMP/shims"; FALLBACK="$TMP/fallback"; SYS="$TMP/sys"
mkdir -p "$STUB" "$SHIMS" "$FALLBACK" "$SYS"
# PATH do sistema sem claude/codex/pi (a máquina que roda o teste pode ter os da imagem antiga em /usr/bin)
for f in /usr/bin/* /bin/*; do
  case "${f##*/}" in claude|codex|pi) continue ;; esac
  [[ -e "$SYS/${f##*/}" ]] || ln -s "$f" "$SYS/${f##*/}"
done
cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
# curl falso: só a URL importa. Roda sob `env -i`, então lê o estado do caso pelo HOME.
url="${!#}"
case "$url" in
  https://claude.ai/install.sh) a=claude ;;
  https://chatgpt.com/codex/install.sh) a=codex ;;
  https://pi.dev/install.sh) a=pi ;;
  *) exit 22 ;;
esac
printf '%s\n' "$a" >> "$HOME/curl.calls"
[[ -e "$HOME/fail.$a" ]] && exit 22
cat <<EOF
mkdir -p "\$HOME/.local/bin"
printf '#!/bin/sh\necho $a-home\n' > "\$HOME/.local/bin/$a"
chmod +x "\$HOME/.local/bin/$a"
env > "\$HOME/env.$a"
printf '%s\n' "\$PATH" > "\$HOME/path.$a"
printf '%s\n' "\${CODEX_NON_INTERACTIVE:-}" > "\$HOME/nonint.$a"
EOF
SH
chmod +x "$STUB/curl"
for a in claude codex pi; do
  printf '#!/bin/sh\necho %s-fallback\n' "$a" > "$FALLBACK/$a"; chmod +x "$FALLBACK/$a"
  ln -s "$SHIM" "$SHIMS/$a"
done

# caso novo: HOME limpo em $H
fresh() { H="$TMP/$1"; mkdir -p "$H"; }
# roda o instalador com os shims e a reserva no PATH (como no container); guarda saída em $OUT e código em $RC
run() {
  OUT="$(HOME="$H" OPENROUTER_API_KEY=segredo-teste GH_TOKEN=segredo-teste \
    OUTE_SHIMS_DIR="$SHIMS" OUTE_AGENTS_FALLBACK="$FALLBACK" \
    PATH="$SHIMS:$FALLBACK:$STUB:$SYS" "$INSTALL" "$@" 2>&1)"; RC=$?
}
installed() { [[ -x "$H/.local/bin/$1" ]]; }
calls()     { [[ "$(cat "$H/curl.calls" 2>/dev/null | tr '\n' ' ')" == "$1" ]]; }
said()      { grep -q -- "$1" <<<"$OUT"; }

# ---------------------------------------------------------------- casos
fresh first; run
check "primeira subida: rc 0"                               [ "$RC" -eq 0 ]
check "primeira subida: instala os três no home"            bash -c "[[ -x '$H/.local/bin/claude' && -x '$H/.local/bin/codex' && -x '$H/.local/bin/pi' ]]"
check "primeira subida: um instalador por agente, na ordem"  calls "claude codex pi "
check "codex roda sem prompt (CODEX_NON_INTERACTIVE=1)"     grep -qx 1 "$H/nonint.codex"
check "instalador não herda segredos"                       bash -c "! grep -q segredo-teste '$H'/env.*"
check "PATH do instalador sem os shims"                     bash -c "! grep -q '$SHIMS' '$H'/path.*"
check "PATH do instalador sem a reserva da imagem"          bash -c "! grep -q '$FALLBACK' '$H'/path.*"
check "PATH do instalador com ~/.local/bin"                 grep -q "$H/.local/bin" "$H/path.pi"

rm -f "$H/curl.calls"; run
check "segunda subida: rc 0"                                [ "$RC" -eq 0 ]
check "segunda subida: não reinstala (o agente se atualiza)" bash -c "[[ ! -e '$H/curl.calls' ]]"
check "segunda subida: avisa que já está instalado"         said "claude: já instalado"

fresh partial; mkdir -p "$H/.local/bin"; printf '#!/bin/sh\n' > "$H/.local/bin/codex"; chmod +x "$H/.local/bin/codex"; run
check "só instala o que falta"                              calls "claude pi "

fresh failing; touch "$H/fail.codex"; run
check "instalador falhou: rc 1"                             [ "$RC" -eq 1 ]
check "instalador falhou: avisa e cita a reserva"           said "AVISO: codex não foi instalado"
check "instalador falhou: os outros seguem"                 bash -c "[[ -x '$H/.local/bin/claude' && -x '$H/.local/bin/pi' && ! -e '$H/.local/bin/codex' ]]"

fresh one; run pi
check "argumento: instala só o pedido"                      calls "pi "

fresh unknown; run foo
check "agente desconhecido: rc 1"                           [ "$RC" -eq 1 ]
check "agente desconhecido: avisa"                          said "agente desconhecido: foo"

fresh locked; mkdir -p "$H/.oute"; exec 8>"$H/.oute/agents-install.lock"; flock -n 8; run; exec 8>&-
check "outra instalação rodando: sai 0 sem instalar"        bash -c "[[ $RC -eq 0 && ! -e '$H/curl.calls' ]]"

# ---------------------------------------------------------------- shim: reserva da imagem
# fora de repo git e sem terminal o shim passa direto para o binário real; roda com $1 como fallback, saída em $OUT
shim() { OUT="$(cd "$TMP" && HOME="$H" OUTE_AGENTS_FALLBACK="$1" PATH="$SHIMS:$H/.local/bin:$SYS" "$SHIMS/$2" </dev/null 2>&1)"; RC=$?; }
fresh shim; mkdir -p "$H/.local/bin"
shim "$FALLBACK" claude
check "shim sem o agente no home: usa a reserva"            [ "$OUT" = claude-fallback ]
printf '#!/bin/sh\necho claude-home\n' > "$H/.local/bin/claude"; chmod +x "$H/.local/bin/claude"
shim "$FALLBACK" claude
check "shim com o agente no home: usa o do home"            [ "$OUT" = claude-home ]
shim "$TMP/nada" pi
check "shim sem home nem reserva: rc 127"                   [ "$RC" -eq 127 ]
check "shim sem home nem reserva: avisa"                    said "pi não encontrado"

printf '\n%d ok, %d falhas\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
