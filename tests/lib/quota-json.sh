#!/usr/bin/env bash
# quota-json.sh (#621, #676): `qcota <% do Claude> <% do Codex> [<% da zai>]` grava em $FAKE/quota.json a cota (janela de 5 h) que o
# `oute-quota` falso (tests/lib/fake-oute-quota.sh) devolve ao oute-select; sem o terceiro argumento a zai não aparece no JSON.
# Para `source` depois de definir $FAKE; apague o arquivo no fim (`rm -f "${FAKE:?}/quota.json"`) para voltar à cota folgada.
qcota() {
  local used_claude="$1" used_codex="$2" used_zai="${3:-}"
  jq -n --argjson c "$used_claude" --argjson x "$used_codex" --arg z "$used_zai" '{schema: 1, max_pct: 98, reset_grace_s: 1200, agents: {claude: {status: "ok", windows: {"5h": {used_pct: $c, resets_in_s: 9000}}}, codex: {status: "ok", windows: {"5h": {used_pct: $x, resets_in_s: 9000}}}}} | if $z == "" then . else .agents.zai = {status: "ok", windows: {"5h": {used_pct: ($z|tonumber), resets_in_s: 9000}}} end' > "$FAKE/quota.json"
  return $?
}
