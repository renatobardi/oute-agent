# Apoio dos testes que rodam em paralelo (#336), para `source` (sem depender de mais nada, nem do check.sh). Os
# tests/*.test.sh podem rodar juntos (`xargs -P "$(nproc)"`): o que eles dividem é o cache em ~/.cache/oute-tests e
# as portas locais, e esta lib é o único lugar que trata os dois.
# cache_dir: o diretório do cache de teste ($XDG_CACHE_HOME ou ~/.cache, mais /oute-tests).
# cache_sha256 <arquivo>: o sha256 em hexa (sha256sum no Linux, shasum no Mac).
# cache_publish <destino> <verifica> <constrói> [arg…]: deixa <destino> montado e íntegro no cache, sem trava (o Mac
#   não tem flock). Se `verifica <destino> [arg…]` já passa, não faz nada. Senão `constrói <caminho> [arg…]` monta
#   em <destino>.tmp.<pid>, um caminho só deste processo, e a entrada no cache é um rename atômico: quem perde a
#   corrida (o destino já existe e não está vazio) descarta o que montou e usa o que já está lá. Um destino que
#   existe mas não passa na verificação (resto de uma montagem que morreu) sai do caminho antes. Devolve 0 se, no
#   fim, `verifica` passa; 1 se a construção falhou ou o resultado não passa (e então nada entra no cache). Não deixa .tmp nem .bad para trás.
#   Em diretório que se move (venv: o python acha o site-packages pelo próprio caminho, os scripts de bin/ não).
# cache_download <nome> <url> <sha256>: baixa para o cache (por https, com checksum) e define CACHE_FILE; um download
#   que não confere nunca entra no cache.
# free_port: uma porta local que ninguém escuta agora. Duas chamadas seguidas, de testes diferentes, podem devolver a
#   mesma: por isso quem sobe um servidor tenta de novo com outra (spawn_try).
# STARTUP_TIMEOUT (60 s) e START_TRIES (3): o prazo de subida de SurrealDB, collector e agent-studio, e quantas portas
#   se tenta; num lugar só, porque 30 testes em 4 CPUs estouram os 10 s e 15 s de antes.
# spawn_wait <pid> <saúde…>: espera o comando de saúde passar. Devolve 0 (saudável), 1 (o processo morreu antes do
#   health) ou 2 (prazo estourado, ainda vivo).
# spawn_try <tentativas> <primeira-porta> <lança> <saúde…>: `lança <porta>` sobe o servidor em segundo plano e define
#   SPAWN_PID; `saúde… <porta>` é o comando de saúde. Se o processo morre antes do health (porta tomada por outro
#   teste), tenta de novo com outra porta, até <tentativas>; <primeira-porta> vazia = free_port. Define SPAWN_PORT.
#   Devolve 0, ou 1 com o processo já derrubado.
PAR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARTUP_TIMEOUT=60
START_TRIES=3
cache_dir() { echo "${XDG_CACHE_HOME:-$HOME/.cache}/oute-tests"; }
cache_sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
cache_publish() {
  local dest="$1" verify="$2" build="$3" tmp
  shift 3
  "$verify" "$dest" "$@" 2>/dev/null && return 0
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.tmp.$$"; rm -rf "${tmp:?}"
  { "$build" "$tmp" "$@" && "$verify" "$tmp" "$@" 2>/dev/null; } || { rm -rf "${tmp:?}"; return 1; }
  if [[ -e "$dest" ]] && ! "$verify" "$dest" "$@" 2>/dev/null; then
    mv "$dest" "$dest.bad.$$" 2>/dev/null && rm -rf "${dest:?}.bad.$$"
  fi
  python3 -c 'import os, sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError:
    sys.exit(1)' "$tmp" "$dest" || true
  rm -rf "${tmp:?}"
  "$verify" "$dest" "$@" 2>/dev/null
}
_cache_sha_ok() { [[ -f "$1" && "$(cache_sha256 "$1")" == "$3" ]]; }
_cache_fetch() {
  local got
  echo "# baixando $(basename "$CACHE_FILE")"
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$1" "$2" || return 1
  got="$(cache_sha256 "$1")"
  [[ "$got" == "$3" ]] || { echo "# checksum de $(basename "$CACHE_FILE") não confere ($got)"; return 1; }
}
cache_download() {
  CACHE_FILE="$(cache_dir)/$1"
  cache_publish "$CACHE_FILE" _cache_sha_ok _cache_fetch "$2" "$3"
}
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
spawn_wait() {
  local pid="$1" end=$((SECONDS + STARTUP_TIMEOUT)); shift
  while ((SECONDS < end)); do
    kill -0 "$pid" 2>/dev/null || return 1
    # saudável só se o processo continua vivo: numa porta tomada, quem responde ao health é o outro servidor
    if "$@" >/dev/null 2>&1; then kill -0 "$pid" 2>/dev/null && return 0; return 1; fi
    sleep 0.1
  done
  return 2
}
spawn_try() {
  local tries="$1" port="$2" launch="$3" n rc; shift 3
  for ((n = 1; n <= tries; n++)); do
    [[ -n "$port" ]] || port="$(free_port)"
    SPAWN_PORT="$port"
    "$launch" "$port"
    spawn_wait "$SPAWN_PID" "$@" "$port"; rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    kill "$SPAWN_PID" 2>/dev/null; wait "$SPAWN_PID" 2>/dev/null
    [[ "$rc" -eq 1 ]] || return 1
    echo "# subida falhou na porta $port (tentativa $n de $tries)" >&2
    port=""
  done
  return 1
}
