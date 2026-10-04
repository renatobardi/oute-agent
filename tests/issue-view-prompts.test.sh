#!/usr/bin/env bash
# #475: prompts e skills leem a issue inteira (título, corpo e comentários) com --json title,body,comments;
# no gh 2.102.0 `gh issue view <n> --comments` não imprime título nem corpo. Uso: tests/issue-view-prompts.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
cd "$ROOT" || exit 1

OLD='gh issue view [^|]*--comments'
check "nenhum prompt ou skill manda ler a issue com 'gh issue view … --comments'" \
  bash -c '! git grep -n -E "$1" -- docker addons docs ":!docker/agent-studio" ":!tests"' _ "$OLD"

# o detector pega a forma antiga (sem ele o caso acima passaria no vazio)
printf '%s\n' 'leia com `gh issue view 12 --comments`' 'e `gh issue view 7 --repo a/b --comments`' > "$TMP/velho.md"
check "detector: pega a forma antiga" bash -c '[ "$(grep -c -E "$1" "$2")" -eq 2 ]' _ "$OLD" "$TMP/velho.md"
printf '%s\n' 'leia com `gh issue view 12 --json title,body,comments --jq .title`' > "$TMP/novo.md"
check "detector: não pega a forma nova" bash -c '! grep -q -E "$1" "$2"' _ "$OLD" "$TMP/novo.md"

for f in docker/agent-notes.md docker/swarm.md docker/swarm-worker.md docs/agents/issue-tracker.md \
         addons/skills/oute-aidlc-qa-pr-audit/SKILL.md addons/skills/oute-aidlc-learn-insights/SKILL.md \
         addons/skills/oute-aidlc-ctx-setup/issue-tracker-github.md; do
  check "$f usa --json title,body,comments" grep -qF -e '--json title,body,comments' "$f"
done
check "glab marcado como não verificado" grep -qF 'Not verified' addons/skills/oute-aidlc-ctx-setup/issue-tracker-gitlab.md

# o jq do comando novo imprime título, corpo e comentários (gh falso devolve o JSON de uma issue sem comentário e outra com)
JQ="$(sed -n "s/.*--json title,body,comments --jq '\([^']*\)'.*/\1/p" docker/agent-notes.md | head -1)"
check "jq extraído do agent-notes" test -n "$JQ"
if command -v jq >/dev/null; then
  SEM='{"title":"T1","body":"CORPO1","comments":[]}'
  COM='{"title":"T2","body":"CORPO2","comments":[{"author":{"login":"ana"},"url":"U1","body":"C1"}]}'
  check "jq: issue sem comentário traz título e corpo" bash -c 'out="$(printf %s "$1" | jq -r "$2")"; [[ "$out" == *T1* && "$out" == *CORPO1* ]]' _ "$SEM" "$JQ"
  check "jq: issue com comentário traz título, corpo e comentário" bash -c 'out="$(printf %s "$1" | jq -r "$2")"; [[ "$out" == *T2* && "$out" == *CORPO2* && "$out" == *ana* && "$out" == *C1* ]]' _ "$COM" "$JQ"
fi
check_end
