#!/usr/bin/env bash
# quota-json.sh (#621): `qcota <% do Claude> <% do Codex>` grava em $FAKE/quota.json a cota (janela de 5 h) que o `oute-quota`
# falso (tests/lib/fake-oute-quota.sh) devolve ao oute-select. Para `source` depois de definir $FAKE; apague o arquivo no fim
# (`rm -f "${FAKE:?}/quota.json"`) para voltar à cota folgada.
qcota() {
  local used_claude="$1" used_codex="$2"
  jq -n --argjson c "$used_claude" --argjson x "$used_codex" '{schema: 1, max_pct: 98, reset_grace_s: 1200, agents: {claude: {status: "ok", windows: {"5h": {used_pct: $c, resets_in_s: 9000}}}, codex: {status: "ok", windows: {"5h": {used_pct: $x, resets_in_s: 9000}}}}}' > "$FAKE/quota.json"
  return $?
}
