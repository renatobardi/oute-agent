# Binário fixado do otelcol-contrib para os testes do collector (#161, #162), para `source` depois de definir ROOT,
# TMP e die. otelcol_bin: usa o otelcol-contrib do PATH se for a versão do compose; senão baixa o binário fixado e
# confere o sha256 (cache em ~/.cache/oute-tests). Define OTELCOL e V.
V=0.161.0
grep -q "opentelemetry-collector-contrib:\${OUTE_OTELCOL_VERSION:-$V}" "$ROOT/docker/compose.yaml" \
  || die "a versão do collector no compose mudou: atualize V e os checksums deste teste"
otelcol_bin() {
  local p os arch sum url cache tgz got
  p="$(command -v otelcol-contrib || true)"
  if [[ -n "$p" ]] && "$p" --version 2>/dev/null | grep -q " $V\$"; then OTELCOL="$p"; return; fi
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) die "SO sem binário fixado: $(uname -s)" ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) die "arquitetura sem binário fixado: $(uname -m)" ;; esac
  # sha256 dos .tar.gz da release v0.161.0 (opentelemetry-collector-releases, conferidos com os .sha256 publicados)
  case "$os-$arch" in
    linux-amd64)  sum=778c689efa681ff6e4722ce9f66b9b7f57c3ba009ab2e2b43dc2e0315862c731 ;;
    linux-arm64)  sum=cd5de93213a0dbb90e4998b3b9e4e15ed691ec635cf7cf4147f95799fb16b676 ;;
    darwin-amd64) sum=357fc0a7a77f5d42cab2f46af6be301062a7824b82454cc264cb8661fa9a8734 ;;
    darwin-arm64) sum=ccc0cf5de5242adcaedc7b5aebed43a1dc56aa2dc7de6ebc495d5db60512d34c ;;
  esac
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$V/otelcol-contrib_${V}_${os}_${arch}.tar.gz"
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/oute-tests"; tgz="$cache/otelcol-contrib_${V}_${os}_${arch}.tar.gz"
  mkdir -p "$cache"
  sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
  if [[ ! -f "$tgz" || "$(sha "$tgz")" != "$sum" ]]; then
    echo "# baixando otelcol-contrib $V ($os/$arch)"
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$tgz.part" "$url" || die "download do otelcol-contrib falhou"
    got="$(sha "$tgz.part")"
    [[ "$got" == "$sum" ]] || { rm -f "$tgz.part"; die "checksum do otelcol-contrib não confere ($got)"; }
    mv "$tgz.part" "$tgz"
  fi
  tar -xzf "$tgz" -C "$TMP" otelcol-contrib || die "tar do otelcol-contrib falhou"
  OTELCOL="$TMP/otelcol-contrib"
}
