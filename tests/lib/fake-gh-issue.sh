#!/usr/bin/env bash
# `gh issue view <n> --json labels` falso, para os testes do seletor de modelo (#219). O `gh` falso de cada teste
# entrega a ele o caso "issue view": `"issue view") exec bash "$TESTLIB/fake-gh-issue.sh" "$@" ;;`.
# Lê de $FAKE: labels-<n> (um label por linha; arquivo vazio = issue sem label; sem arquivo = issue que não existe,
# código 1), gh.down (o gh falha, como fora do ar ou sem auth) e gh.hang (não responde: dorme $FAKE_GH_HANG s, padrão 5).
# Cada chamada fica em $FAKE/gh-issue.log, como "<pasta em que rodou> <n>".
n="${3:-}"
echo "$(basename "$PWD") $n" >> "$FAKE/gh-issue.log"
[[ ! -e "$FAKE/gh.hang" ]] || exec sleep "${FAKE_GH_HANG:-5}"
[[ ! -e "$FAKE/gh.down" ]] || { echo "gh falso: fora do ar" >&2; exit 1; }
[[ -f "$FAKE/labels-$n" ]] || { echo "gh falso: issue $n não encontrada" >&2; exit 1; }
jq -Rn '{labels: [inputs | select(. != "") | {name: .}]}' < "$FAKE/labels-$n"
