#!/usr/bin/env bash
# `gh issue view <n> --json labels|state` falso, para os testes do seletor de modelo (#219) e do watch (#387).
# O `gh` falso de cada teste entrega a ele o caso "issue view": `"issue view") exec bash "$TESTLIB/fake-gh-issue.sh" "$@" ;;`.
# Lê de $FAKE: labels-<n> (um label por linha; arquivo vazio = issue sem label; sem arquivo = issue que não existe,
# código 1), gh-issue-<n>.json (JSON com {state: "OPEN|CLOSED", ...}), gh.down (o gh falha) e gh.hang (não responde).
# Cada chamada fica em $FAKE/gh-issue.log, como "<pasta em que rodou> <n>".
n="${3:-}"
jq_expr=""; for ((i = 1; i < $#; i++)); do [[ "${!i}" != --jq ]] || jq_expr="$((i + 1))"; done
[[ -z "$jq_expr" ]] || jq_expr="${!jq_expr}"
echo "$(basename "$PWD") $n" >> "$FAKE/gh-issue.log"
[[ ! -e "$FAKE/gh.hang" ]] || exec sleep "${FAKE_GH_HANG:-5}"
[[ ! -e "$FAKE/gh.down" ]] || { echo "gh falso: fora do ar" >&2; exit 1; }

# gh-issue-<n>.json (watch, #387) ou labels-<n> (seletor, #219); com --jq <expr>, filtra como o gh (jq -r)
if [[ -f "$FAKE/gh-issue-$n.json" ]]; then out="$(cat "$FAKE/gh-issue-$n.json")"
elif [[ -f "$FAKE/labels-$n" ]]; then out="$(jq -Rn '{labels: [inputs | select(. != "") | {name: .}]}' < "$FAKE/labels-$n")"
else echo "gh falso: issue $n não encontrada" >&2; exit 1; fi
if [[ -n "$jq_expr" ]]; then jq -r "$jq_expr" <<<"$out"; else echo "$out"; fi
