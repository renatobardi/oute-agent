#!/usr/bin/env bash
# Testes do `oute-shot` (#472): screenshot PNG de página local no Firefox headless da imagem.
# Um `firefox` falso (OUTE_SHOT_FIREFOX) grava argv, ambiente e o user.js do perfil e escreve um PNG mínimo; confere
# destino aceito/recusado, tamanhos, tema, perfil descartável, ambiente sem segredo e os ramos de erro. Com
# OUTE_SHOT_REAL_FIREFOX=<binário> roda também contra o Firefox de verdade (no CI e sem a variável, esses casos pulam).
# Uso: tests/oute-shot.test.sh   (sai != 0 se algo falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
SHOT="$ROOT/docker/oute-shot"
[[ -x "$SHOT" ]] || die "oute-shot ausente ou sem +x: $SHOT"

SCH=http   # esquema montado de partes: sem literal de endereço sem TLS no arquivo (SonarCloud)
FAKE="$TMP/fake"; mkdir -p "$FAKE" "$TMP/work"
# o oute-shot roda o navegador com `env -i`: o diretório do falso e o modo vão fixos no script, não pelo ambiente
{ printf '#!/usr/bin/env bash\nFAKE=%q\nFAKE_FF_MODE="$(cat %q 2>/dev/null || echo ok)"\n' "$FAKE" "$FAKE/mode"; cat <<'FF'
# firefox falso: registra e escreve um PNG mínimo no --screenshot
n=$(( $(cat "$FAKE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/n"
printf '%s\n' "$@" > "$FAKE/argv.$n"
env > "$FAKE/env.$n"
prof=""; dest=""; prev=""
for a in "$@"; do
  [ "$prev" = --profile ] && prof="$a"
  [ "$prev" = --screenshot ] && dest="$a"
  prev="$a"
done
echo "$prof" > "$FAKE/prof.$n"
cp "$prof/user.js" "$FAKE/user.$n"
case "$FAKE_FF_MODE" in
  ok) printf '\x89PNG\r\n\x1a\nfake' > "$dest" ;;
  fail) echo "boom do firefox" >&2; exit 1 ;;
  noimg) exit 0 ;;
  notpng) echo lixo > "$dest" ;;
  hang) exec sleep 30 ;;
esac
FF
} > "$TMP/firefox"
chmod 755 "$TMP/firefox"
SECRET="tok$(openssl rand -hex 12)"
export GH_TOKEN="$SECRET" SONAR_TOKEN="$SECRET"
export OUTE_SHOT_FIREFOX="$TMP/firefox"

rm -f "${FAKE:?}"/*
cd "$TMP/work" || die "sem diretório de trabalho"
echo '<h1>oi</h1>' > page.html
runo() { OUT="$("$@" 2>&1)"; RC=$?; return 0; }
calls() { cat "$FAKE/n" 2>/dev/null || echo 0; }
newf() { rm -f "${FAKE:?}"/*; return 0; }
mode() { local m="$1"; echo "$m" > "$FAKE/mode"; return 0; }
arg_has() { grep -qxF -- "$1" "$FAKE/argv.${2:-1}"; }

# --- uso e destino recusado (o navegador nem sobe) -------------------------------------------------------------------
newf
runo "$SHOT"; check "sem destino: rc 2" test "$RC" -eq 2
runo "$SHOT" page.html --foo; check "opção desconhecida: rc 2" test "$RC" -eq 2
runo "$SHOT" page.html outra.html; check "dois destinos: rc 2" test "$RC" -eq 2
runo "$SHOT" nao-existe.html; check "arquivo inexistente: rc 2" test "$RC" -eq 2
ext="https://$(printf '%s.%s' example com)/"
runo "$SHOT" "$ext"; check "https externo: rc 2" test "$RC" -eq 2
check "https externo: diz que é fora do loopback" has 'fora do loopback'
runo "$SHOT" "$SCH://$(printf '%s.%s' example com):80/"; check "http externo: rc 2" test "$RC" -eq 2
runo "$SHOT" "$SCH://localhost@$(printf '%s.%s' example com)/"; check "usuário na URL (localhost@externo): rc 2" test "$RC" -eq 2
runo "$SHOT" "$SCH://localhost.$(printf '%s.%s' example com)/"; check "localhost.externo: rc 2" test "$RC" -eq 2
runo "$SHOT" "ftp://localhost/x"; check "esquema ftp: rc 2" test "$RC" -eq 2
runo "$SHOT" page.html --all --mobile; check "--all com --mobile: rc 2" test "$RC" -eq 2
runo "$SHOT" page.html --all -o x.png; check "--all com -o: rc 2" test "$RC" -eq 2
runo "$SHOT" page.html -d pasta; check "-d sem --all: rc 2" test "$RC" -eq 2
runo "$SHOT" page.html --height abc; check "--height inválido: rc 2" test "$RC" -eq 2
runo "$SHOT" page.html --height 50; check "--height fora da faixa: rc 2" test "$RC" -eq 2
runo env OUTE_SHOT_TIMEOUT=0 "$SHOT" page.html; check "OUTE_SHOT_TIMEOUT=0: rc 2" test "$RC" -eq 2
check "recusas: o navegador não foi chamado" test "$(calls)" -eq 0

# --- aceito ----------------------------------------------------------------------------------------------------------
for u in "$SCH://localhost:8080/a" "$SCH://127.0.0.1/" "$SCH://[::1]:3000/x?y=1" "https://localhost/"; do
  newf; runo "$SHOT" "$u" -o "$TMP/loop.png"
  check "loopback aceito: $u" bash -c '[ "$1" -eq 0 ] && grep -qxF -- "$2" "$3/argv.1"' _ "$RC" "$u" "$FAKE"
done
newf; runo "$SHOT" page.html -o "$TMP/f.png"
check "arquivo local vira file:// com caminho absoluto" arg_has "file://$TMP/work/page.html"
newf; runo "$SHOT" "file://$TMP/work/page.html" -o "$TMP/f.png"
check "file:// aceito" arg_has "file://$TMP/work/page.html"

# --- tamanho, tema e saída -------------------------------------------------------------------------------------------
newf; runo "$SHOT" page.html
check "padrão: rc 0, desktop light em ./shot-desktop-light.png" bash -c '[ "$1" -eq 0 ] && [ -s shot-desktop-light.png ]' _ "$RC"
check "padrão: janela 1280x800" arg_has "--window-size=1280,800"
check "padrão: imprime o caminho do PNG" has_line "./shot-desktop-light.png"
check "padrão: light liga content-override 1 e systemUsesDarkTheme 0" bash -c 'grep -qF "prefers-color-scheme.content-override\", 1" "$1" && grep -qF "ui.systemUsesDarkTheme\", 0" "$1"' _ "$FAKE/user.1"
newf; runo "$SHOT" page.html --mobile --dark
check "mobile dark: ./shot-mobile-dark.png" test -s shot-mobile-dark.png
check "mobile: janela 390x800" arg_has "--window-size=390,800"
check "dark: content-override 0 e systemUsesDarkTheme 1" bash -c 'grep -qF "prefers-color-scheme.content-override\", 0" "$1" && grep -qF "ui.systemUsesDarkTheme\", 1" "$1"' _ "$FAKE/user.1"
newf; runo "$SHOT" page.html -o rel.png
check "saída relativa: o navegador recebe o caminho absoluto" bash -c '[ -s rel.png ] && grep -qxF -- "$1/rel.png" "$2/argv.1"' _ "$TMP/work" "$FAKE"
newf; runo "$SHOT" page.html -o "$TMP/a/b/c.png" --height 1000
check "-o cria a pasta e grava" test -s "$TMP/a/b/c.png"
check "--height 1000" arg_has "--window-size=1280,1000"
newf; runo "$SHOT" page.html --all -d "$TMP/all"
check "--all: quatro PNG" bash -c 'for f in desktop-light desktop-dark mobile-light mobile-dark; do [ -s "$1/shot-$f.png" ] || exit 1; done' _ "$TMP/all"
check "--all: quatro chamadas, 1280 e 390" bash -c '[ "$(cat "$1/n")" -eq 4 ] && grep -qxF -- --window-size=1280,800 "$1/argv.1" && grep -qxF -- --window-size=390,800 "$1/argv.3"' _ "$FAKE"
check "--all: tema na ordem light, dark, light, dark" bash -c 'for i in 1 3; do grep -qF "systemUsesDarkTheme\", 0" "$1/user.$i" || exit 1; done; for i in 2 4; do grep -qF "systemUsesDarkTheme\", 1" "$1/user.$i" || exit 1; done' _ "$FAKE"

# --- sem rede externa e sem segredo ----------------------------------------------------------------------------------
newf; runo "$SHOT" page.html
check "proxy morto: type 1, porta 9, loopback fora do proxy" bash -c 'grep -qF "network.proxy.type\", 1" "$1" && grep -qF "network.proxy.http_port\", 9" "$1" && grep -qF "network.proxy.ssl_port\", 9" "$1" && grep -qF "network.proxy.no_proxies_on\", \"localhost,127.0.0.1,[::1]\"" "$1"' _ "$FAKE/user.1"
check "ambiente do navegador sem o segredo do chamador" bash -c '! grep -qF -- "$1" "$2"' _ "$SECRET" "$FAKE/env.1"
check "ambiente do navegador só com PATH, LANG, HOME e MOZ_*" bash -c '! grep -vE "^(PATH|LANG|HOME|MOZ_[A-Z_]+|PWD|SHLVL|_|OLDPWD)=" "$1" | grep -q .' _ "$FAKE/env.1"
prof="$(cat "$FAKE/prof.1")"
check "HOME do navegador é o perfil descartável" grep -qxF "HOME=$prof" "$FAKE/env.1"
check "perfil removido ao terminar" test ! -e "$prof"
check "perfil fica fora do diretório do repo e do trabalho" bash -c 'case "$1" in "$2"/*|"$3"/*) exit 1 ;; esac' _ "$prof" "$ROOT" "$TMP/work"

# --- ramos de erro do navegador --------------------------------------------------------------------------------------
newf; mode fail; runo "$SHOT" page.html -o "$TMP/e.png"
check "navegador falha: rc 4 com a cauda do log" bash -c '[ "$1" -eq 4 ] && grep -q "boom do firefox" <<<"$2"' _ "$RC" "$OUT"
newf; mode noimg; runo "$SHOT" page.html -o "$TMP/e.png"
check "sem PNG gerado: rc 4" bash -c '[ "$1" -eq 4 ] && grep -q "não gerou o PNG" <<<"$2"' _ "$RC" "$OUT"
newf; mode notpng; runo "$SHOT" page.html -o "$TMP/e.png"
check "saída que não é PNG: rc 4" bash -c '[ "$1" -eq 4 ] && grep -q "não é PNG" <<<"$2"' _ "$RC" "$OUT"
newf; mode hang; runo env OUTE_SHOT_TIMEOUT=1 "$SHOT" page.html -o "$TMP/e.png"
check "passou do prazo: rc 4" bash -c '[ "$1" -eq 4 ] && grep -q "passou do prazo" <<<"$2"' _ "$RC" "$OUT"
newf; runo env OUTE_SHOT_FIREFOX="$TMP/nao-tem" "$SHOT" page.html
check "sem navegador: rc 3" bash -c '[ "$1" -eq 3 ] && grep -q "navegador ausente" <<<"$2"' _ "$RC" "$OUT"
check "ajuda: -h sai 0" bash -c '"$1" -h >/dev/null 2>&1' _ "$SHOT"

# --- imagem ----------------------------------------------------------------------------------------------------------
DF="$ROOT/docker/Dockerfile"
check "Dockerfile: Firefox com versão e sha256 de arm64 e amd64 (64 hex)" bash -c 'grep -qE "^ARG FIREFOX_VERSION=[0-9.]+esr$" "$1" && grep -qE "^ARG FIREFOX_SHA256_ARM64=[0-9a-f]{64}$" "$1" && grep -qE "^ARG FIREFOX_SHA256_AMD64=[0-9a-f]{64}$" "$1"' _ "$DF"
check "Dockerfile: confere o sha256 antes de extrair, só por https" bash -c 'grep -qF "sha256sum -c - \\" "$1" && grep -qF "curl -fsSL --proto '"'"'=https'"'"' -o /tmp/firefox.tar.xz" "$1" && awk "/sha256sum -c - \\\\/{c=NR} /tar -xJf \\/tmp\\/firefox.tar.xz/{t=NR} END{exit !(c && t && c<t)}" "$1"' _ "$DF"
check "Dockerfile: poppler-utils" bash -c 'grep -qE "^ +poppler-utils " "$1"' _ "$DF"
check "Dockerfile: oute-shot copiado e executável" bash -c 'grep -qxF "COPY docker/oute-shot /usr/local/bin/" "$1" && grep -qF "/usr/local/bin/oute-shot" "$1"' _ "$DF"
check "Dockerfile: sem npm install novo para o navegador" bash -c '! grep -iE "playwright|puppeteer" "$1"' _ "$DF"
check "AGENTS.md: oute-shot no mapa do repo" grep -qF '`oute-shot`' "$ROOT/AGENTS.md"
check "comandos.md: oute-shot e poppler documentados" bash -c 'grep -q "oute-shot <url|arquivo>" "$1" && grep -q "pdftoppm" "$1"' _ "$ROOT/docker/comandos.md"
check "pins: os sha256 de ARM64 e AMD64 são diferentes entre si" bash -c '[ "$(grep -E "^ARG FIREFOX_SHA256_" "$1" | cut -d= -f2 | sort -u | wc -l)" -eq 2 ]' _ "$DF"

# --- Firefox de verdade (opcional) -----------------------------------------------------------------------------------
REAL="${OUTE_SHOT_REAL_FIREFOX:-}"
if [[ -x "$REAL" ]] && command -v python3 >/dev/null; then
  export OUTE_SHOT_FIREFOX="$REAL"
  cat > real.html <<'H'
<!doctype html><meta charset=utf-8><title>t</title>
<style>body{margin:0;background:#fff;color:#000}@media(prefers-color-scheme:dark){body{background:#000;color:#fff}}</style><h1>oi</h1>
H
  runo "$SHOT" real.html --all -d "$TMP/real"
  check "real: rc 0 e quatro PNG" bash -c '[ "$1" -eq 0 ] && for f in desktop-light desktop-dark mobile-light mobile-dark; do [ -s "$2/shot-$f.png" ] || exit 1; done' _ "$RC" "$TMP/real"
  check "real: desktop 1280x800 e mobile 390x800" bash -c 'python3 -c "
import struct,sys
def wh(f):
    d=open(f,\"rb\").read(); return struct.unpack(\">II\",d[16:24])
assert wh(sys.argv[1]+\"/shot-desktop-light.png\")==(1280,800), 1
assert wh(sys.argv[1]+\"/shot-mobile-dark.png\")==(390,800), 2
" "$1"' _ "$TMP/real"
  check "real: light e dark dão imagens diferentes" bash -c '! cmp -s "$1/shot-desktop-light.png" "$1/shot-desktop-dark.png"' _ "$TMP/real"
  cat > "$TMP/bg.py" <<'P'
import sys, struct, zlib
def bg(f):
    d = open(f, "rb").read(); w, h = struct.unpack(">II", d[16:24]); bpp = {2: 3, 6: 4}[d[25]]
    i = 8; z = b""
    while i < len(d):
        n, t = struct.unpack(">I4s", d[i:i + 8])
        if t == b"IDAT": z += d[i + 8:i + 8 + n]
        i += 12 + n
    raw = zlib.decompress(z); s = w * bpp; prev = bytearray(s)
    for y in range(h):
        ft = raw[y * (s + 1)]; row = bytearray(raw[y * (s + 1) + 1:(y + 1) * (s + 1)])
        for x in range(s):
            a = row[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if ft == 1: row[x] = (row[x] + a) & 255
            elif ft == 2: row[x] = (row[x] + b) & 255
            elif ft == 3: row[x] = (row[x] + (a + b) // 2) & 255
            elif ft == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = row
    return prev[(w - 1) * bpp]   # canto inferior direito, só fundo
l, k = bg(sys.argv[1] + "/shot-desktop-light.png"), bg(sys.argv[1] + "/shot-desktop-dark.png")
sys.exit(0 if l > 200 and k < 50 else 1)
P
  check "real: fundo claro no light e escuro no dark" python3 "$TMP/bg.py" "$TMP/real"
  # servidor de loopback com uma página que pede uma imagem de um endereço que não é loopback (o IP do próprio container)
  EXTIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$EXTIP" && "$EXTIP" != 127.* ]]; then
    cat > "$TMP/srv.py" <<'P'
import http.server, threading, sys, subprocess, os
hits = []
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        hits.append((s.server.server_port, s.path)); s.send_response(200); s.send_header("Content-Type", "text/html"); s.end_headers()
        if s.path == "/page": s.wfile.write(("<img src='" + "ht" + "tp://" + sys.argv[3] + ":" + sys.argv[2] + "/ext.png'><h1>oi</h1>").encode())
    def log_message(*a): pass
lo = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H); ex = http.server.HTTPServer((sys.argv[3], int(sys.argv[2])), H)
for x in (lo, ex): threading.Thread(target=x.serve_forever, daemon=True).start()
r = subprocess.run([sys.argv[4], "ht" + "tp://127.0.0.1:" + sys.argv[1] + "/page", "-o", sys.argv[5]])
ok = r.returncode == 0 and (int(sys.argv[1]), "/page") in hits and not any(p == int(sys.argv[2]) for p, _ in hits)
sys.exit(0 if ok else 1)
P
    PL="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    PE="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
    check "real: página em loopback sai em PNG e o pedido a endereço não-loopback não chega ao destino" python3 "$TMP/srv.py" "$PL" "$PE" "$EXTIP" "$SHOT" "$TMP/srv.png"
    check "real: PNG da página em loopback existe" test -s "$TMP/srv.png"
  else
    echo "pula  caso de rede externa (sem IP que não seja loopback)"
  fi
else
  echo "pula  casos do Firefox de verdade (sem OUTE_SHOT_REAL_FIREFOX)"
fi

check_end
