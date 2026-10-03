#!/usr/bin/env bash
# `claude`/`codex` falsos (#258): copie ou linke com o nome do agente num diretório do PATH. Servem ao oute-select
# (checagem de disponibilidade da reserva) e ao oute-task (o agente que ele executa no fim).
#   claude auth status / codex login status: sai com $FAKE_CLAUDE_AUTH_RC / $FAKE_CODEX_LOGIN_RC (padrão 0); com
#       $FAKE_AUTH_HANG=<agente>, esse agente dorme em vez de responder (o seletor tem teto de 5 s); cada chamada vai
#       para $FAKE/auth.log ("<agente> <args>"), se $FAKE existir
#   qualquer outra chamada: grava o ambiente, o diretório e os argumentos em $FAKE/<agente>.{env,pwd,args}, imprime
#       "agente falso <agente>" e sai com $FAKE_RC (padrão 0)
n="$(basename "$0")"
if [[ ( "$n" == claude && "${1:-} ${2:-}" == "auth status" ) || ( "$n" == codex && "${1:-} ${2:-}" == "login status" ) ]]; then
  [[ -z "${FAKE:-}" ]] || echo "$n $*" >> "$FAKE/auth.log"
  [[ "${FAKE_AUTH_HANG:-}" != "$n" ]] || exec sleep 30
  if [[ "$n" == claude ]]; then exit "${FAKE_CLAUDE_AUTH_RC:-0}"; else exit "${FAKE_CODEX_LOGIN_RC:-0}"; fi
fi
env > "$FAKE/$n.env"; pwd -P > "$FAKE/$n.pwd"; printf '%s\n' "$@" > "$FAKE/$n.args"
echo "agente falso $n"
exit "${FAKE_RC:-0}"
