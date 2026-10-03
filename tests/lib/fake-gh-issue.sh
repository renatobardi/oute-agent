#!/usr/bin/env bash
# `gh issue view <n> --json labels|state` falso, para os testes do seletor de modelo (#219) e do watch (#387).
# O `gh` falso de cada teste entrega a ele o caso "issue view": `"issue view") exec bash "$TESTLIB/fake-gh-issue.sh" "$@" ;;`.
# Lê de $FAKE: labels-<n> (um label por linha; arquivo vazio = issue sem label; sem arquivo = issue que não existe,
# código 1), gh-issue-<n>.json (JSON com {state: "OPEN|CLOSED", ...}), gh.down (o gh falha) e gh.hang (não responde).
# Cada chamada fica em $FAKE/gh-issue.log, como "<pasta em que rodou> <n>".
n="${3:-}"
json_type="${5:-}"  # o que vem após --json
echo "$(basename "$PWD") $n" >> "$FAKE/gh-issue.log"
[[ ! -e "$FAKE/gh.hang" ]] || exec sleep "${FAKE_GH_HANG:-5}"
[[ ! -e "$FAKE/gh.down" ]] || { echo "gh falso: fora do ar" >&2; exit 1; }

# Se há arquivo gh-issue-<n>.json, usa ele (novo, para watch #387)
if [[ -f "$FAKE/gh-issue-$n.json" ]]; then
  cat "$FAKE/gh-issue-$n.json"
# Senão, procura labels (antigo, para seletor #219)
elif [[ -f "$FAKE/labels-$n" ]]; then
  jq -Rn '{labels: [inputs | select(. != "") | {name: .}]}' < "$FAKE/labels-$n"
else
  echo "gh falso: issue $n não encontrada" >&2; exit 1
fi
