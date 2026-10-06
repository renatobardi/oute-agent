#!/usr/bin/env bash
# Vaga de teste (#623): o limite de testes ao mesmo tempo no container inteiro, e não por sessão. Para `source` (sem
# depender de mais nada); o tests/lib/check.sh já carrega e chama o slot_take, então todo tests/*.test.sh pega uma
# vaga, rodado sozinho ou num laço em paralelo. As sessões do container são o mesmo usuário e dividem a pasta das
# vagas: a soma dos testes de todas elas fica no número de vagas.
# slot_count: quantas vagas há: OUTE_TEST_SLOTS (inteiro a partir de 1), senão o `nproc`, senão 1.
# slot_take: pega uma vaga (`flock` num dos arquivos <pasta>/<i>.lock) e espera se todas estão ocupadas. A vaga fica
#   num descritor deste processo (SLOT_FD) e o kernel a solta quando ele morre, mesmo com `kill -9`. Exporta
#   OUTE_TEST_SLOT=<i>: processo filho que chama o slot_take de novo (teste que roda outro script) não pega outra.
#   Devolve 0 com a vaga, ou quando não há o que limitar: OUTE_TEST_SLOT já definido, CI (`CI` ou `GITHUB_ACTIONS`,
#   onde os testes seguem em série) ou máquina sem `flock` (o Mac). Devolve 1, com aviso em stderr e
#   OUTE_TEST_SLOT=0, se a pasta das vagas não pode ser criada ou se o prazo de espera acabou: o teste roda sem vaga.
# slot_release: solta a vaga deste processo (no fim do processo o kernel já solta).
# Executado, em vez de carregado: `tests/lib/slot.sh <comando…>` pega a vaga e roda o comando com ela.
# Variáveis: OUTE_TEST_SLOT_DIR (pasta das vagas, padrão /tmp/oute-test-slots: fixa, para valer entre sessões e em
#   ambiente limpo, com outro HOME), OUTE_TEST_SLOT_WAIT (prazo de espera em segundos, padrão 900) e
#   OUTE_TEST_SLOT=0 (desliga).
# Limite conhecido: processo filho herda o descritor. Um servidor de teste que sobra órfão segura a vaga até morrer;
#   o arquivo da vaga traz o PID e o nome de quem a pegou.
slot_count() {
  local n="${OUTE_TEST_SLOTS:-}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n="$(nproc 2>/dev/null || true)"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=1
  echo "$n"
  return 0
}
# _slot_try <arquivo> <segundos>: tenta a trava do arquivo (0 = sem esperar); com ela, define SLOT_FD
_slot_try() {
  local file="$1" secs="$2" fd how=(-n)
  { exec {fd}>>"$file"; } 2>/dev/null || return 1
  [[ "$secs" == 0 ]] || how=(-w "$secs")
  if flock "${how[@]}" "$fd" 2>/dev/null; then
    SLOT_FD="$fd"
    printf '%s %s\n' "$$" "$0" > "$file" 2>/dev/null || true
    return 0
  fi
  exec {fd}>&-
  return 1
}
_slot_off() {
  local why="$1"
  echo "# slot: $why; o teste roda sem vaga" >&2
  export OUTE_TEST_SLOT=0
  return 1
}
slot_take() {
  local dir="${OUTE_TEST_SLOT_DIR:-/tmp/oute-test-slots}" wait_s="${OUTE_TEST_SLOT_WAIT:-900}" n i round=0 start="$SECONDS"
  [[ -z "${OUTE_TEST_SLOT:-}" ]] || return 0
  [[ -z "${CI:-}${GITHUB_ACTIONS:-}" ]] || return 0
  command -v flock >/dev/null 2>&1 || return 0
  [[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=900
  mkdir -p "$dir" 2>/dev/null || { _slot_off "não criei a pasta das vagas ($dir)"; return 1; }
  n="$(slot_count)"
  while :; do
    for ((i = 1; i <= n; i++)); do
      if _slot_try "$dir/$i.lock" 0; then export OUTE_TEST_SLOT="$i"; return 0; fi
    done
    (( SECONDS - start < wait_s )) || break
    (( round > 0 )) || echo "# slot: as $n vagas de teste estão ocupadas ($dir); espero uma por até ${wait_s}s" >&2
    # espera dentro do flock (1 s numa vaga por volta): acorda na hora em que ela solta, sem depender do `sleep`
    i=$(( round % n + 1 )); round=$((round + 1))
    if _slot_try "$dir/$i.lock" 1; then export OUTE_TEST_SLOT="$i"; return 0; fi
  done
  _slot_off "nenhuma das $n vagas ($dir) soltou em ${wait_s}s"
  return 1
}
slot_release() {
  [[ -z "${SLOT_FD:-}" ]] || { exec {SLOT_FD}>&-; }
  unset SLOT_FD OUTE_TEST_SLOT
  return 0
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -gt 0 ]] || { echo "uso: tests/lib/slot.sh <comando…>" >&2; exit 2; }
  slot_take || true
  exec "$@"
fi
