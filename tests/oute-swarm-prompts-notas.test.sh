#!/usr/bin/env bash
# Testes do oute-swarm, tema: instruções de redação ao Bardi: PT controlado, canal de aprovação, Haiku (#478, #480, #481).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh).
# Acrescente caso novo no arquivo do tema (agent-notes.md → este arquivo).
# Uso: tests/oute-swarm-prompts-notas.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/oute-swarm-prompts.sh"
W="$ROOT/docker/swarm-worker.md"; N="$ROOT/docker/agent-notes.md"; PT="$ROOT/docs/pt-controlado.md"
for f in "$D" "$W"; do
  b="${f##*/}"
  check "pt-controlado: $b manda a saída ao Bardi em pt-BR (#478)"  grep -qF 'Em pt-BR, mesmo que o prompt' "$f"
  check "pt-controlado: $b pede fonte que o Bardi abre, sem scratchpad (#478)" grep -qF 'nunca caminho de scratchpad ou de arquivo temporário' "$f"
  check "pt-controlado: $b rotula recomendação sem fonte (#478)"    grep -qF 'rotulada "recomendação do autor"' "$f"
  check "pt-controlado: $b usa fazer merge (#478)"                  grep -qF 'Diga "fazer merge", não "mergear"' "$f"
  check "pt-controlado: $b aponta o doc (#478)"                     grep -qF 'docs/pt-controlado.md' "$f"
done
# notas em inglês (#486, ADR-09 decisão 4): a regra da saída ao Bardi é explícita e em pt-BR
check "pt-controlado: notas mandam escrever o texto ao Bardi em pt-BR, mesmo com fonte em inglês (#478, #486)" grep -qF '**Write it in pt-BR**, even if the prompt, skill or source is in English' "$N"
check "pt-controlado: notas pedem fonte que o Bardi abre, sem scratchpad (#478)" grep -qF 'never a scratchpad or temp-file path' "$N"
check "pt-controlado: notas rotulam recomendação sem fonte (#478)" grep -qF 'labelled "recomendação do autor"' "$N"
check "pt-controlado: notas usam fazer merge, nunca mergear (#478)" grep -qF 'Write "fazer merge", never "mergear"' "$N"
check "pt-controlado: notas escrevem não verificado quando falta fonte (#478)" grep -qF 'no source: write "não verificado"' "$N"
check "pt-controlado: notas apontam o doc (#478)"                 grep -qF 'docs/pt-controlado.md' "$N"
check "pt-controlado: worker: reescrever não muda fato (#478)"    grep -qF 'Reescrever não muda fato, condição nem valor' "$W"
check "pt-controlado: notas: reescrever não muda fato (#478)"     grep -qF 'Rewriting does not change a fact, condition or value' "$N"
check "pt-controlado: dispatcher resume sem mudar fato (#478)"    grep -qF 'não mude fato, condição nem valor' "$D"
check "pt-controlado: doc tem as 15 regras (#478)"                bash -c '[ "$(grep -cE "^\| ([1-9]|1[0-5]) \| \*\*" "$1")" -eq 15 ]' _ "$PT"
check "pt-controlado: doc fixa fazer merge (#478)"                grep -qF '| fazer merge | mergear, mesclar, integrar |' "$PT"
check "pt-controlado: AGENTS.md cita o doc (#478)"                grep -qF 'docs/pt-controlado.md' "$ROOT/AGENTS.md"
# 480. canal de aprovação: # RESUMO e # CUIDADO: no script proposto
SV="$ROOT/addons/skills/oute-aidlc-ship-verify/SKILL.md"; OB="$ROOT/addons/skills/oute-aidlc-ops-observe/SKILL.md"
check "canal: notas pedem bloco # RESUMO (#480)"                  grep -qF 'opens with a `# RESUMO` comment block' "$N"
check "canal: RESUMO lista faz, host, altera, não toca, reinicia (#480)" grep -qF 'what it does, which host, what it changes, what it does **not** touch, whether it restarts anything' "$N"
check "canal: CUIDADO antes de passo que remove, recria, para ou não se desfaz (#480)" grep -qF 'a line `# CUIDADO: <o que o passo faz>. <o que se perde>.` (command first, risk after' "$N"
check "canal: aviso não exagera nem tranquiliza (#480)"           grep -qF 'no exaggeration, no reassurance' "$N"
check "canal: afirmação de segurança só se o script garante (#480)" grep -qF 'Write "não toca em X" only if the script guarantees it' "$N"
check "canal: ship-verify abre o pedido com # RESUMO (#480)"      grep -qF "'# RESUMO'" "$SV"
check "canal: ops-observe cita a regra (#480)"                    grep -qF 'abre com `# RESUMO` e traz `# CUIDADO:`' "$OB"
# o exemplo das notas, extraído e rodado com e sem os blocos, dá a mesma saída: são comentário
EX="$TMP/canal-exemplo.sh"
awk '/^   ```bash$/{n++; next} /^   ```$/{if(n>=2)exit; next} n>=2 && /^   /{sub(/^   /,""); print}' "$N" > "$EX"
check "canal: exemplo extraído das notas tem # RESUMO e # CUIDADO: (#480)" bash -c 'grep -q "^# RESUMO" "$1" && grep -q "^# CUIDADO: " "$1"' _ "$EX"
sed -e 's/^docker volume rm oute-x$/echo rm oute-x/' "$EX" > "$TMP/canal-a.sh"
grep -v -e '^# RESUMO' -e '^# CUIDADO:' -e '^# Faz:' "$TMP/canal-a.sh" > "$TMP/canal-b.sh"
check "canal: com e sem os blocos o script dá a mesma saída (#480)" bash -c '[ "$(bash "$1" 2>&1)" == "$(bash "$2" 2>&1)" ] && [ -n "$(bash "$1" 2>&1)" ]' _ "$TMP/canal-a.sh" "$TMP/canal-b.sh"
check "canal: bash -n no script com os blocos (#480)"             bash -n "$TMP/canal-a.sh"
# 481. sessão em Haiku: a redação final para o Bardi vai a um subagente em Sonnet
for f in "$W"; do b="$(basename "$f")"
  check "haiku: $b manda a redação final a um subagente em Sonnet (#481)" grep -qF 'A sessão em Haiku passa a redação final a um subagente em Sonnet' "$f"
  check "haiku: $b passa fatos e fontes ao subagente (#481)"        grep -qF 'Ela entrega ao subagente os fatos e as fontes' "$f"
  check "haiku: $b confere o resultado contra os fatos (#481)"      grep -qF 'a sessão confere o texto do subagente contra os fatos' "$f"
  check "haiku: $b diz como saber o próprio modelo (#481)"          grep -qF '**Como saber o próprio modelo:**' "$f"
  check "haiku: $b trata id desconhecido como Haiku (#481)"         grep -qF 'Se o id não aparecer, trate a sessão como Haiku' "$f"
  check "haiku: $b sem subagente publica e avisa (#481)"            grep -qF 'avisa, na primeira linha do texto, que ele saiu do Haiku' "$f"
done
check "haiku: notas mandam a redação final a um subagente em Sonnet (#481)" grep -qF 'Haiku hands the final wording to a Sonnet subagent (`Agent` tool, `model: "sonnet"`)' "$N"
check "haiku: notas passam fatos, fontes e regras ao subagente (#481)" grep -qF 'giving it the facts, the sources and the rules of `docs/pt-controlado.md`' "$N"
check "haiku: notas conferem o texto do subagente contra os fatos (#481)" grep -qF "check the subagent's text against the facts: every number, condition and source must match what you passed, no new fact" "$N"
check "haiku: notas dizem como saber o próprio modelo (#481)"     grep -qF '**Own model:** read the model id in the session context' "$N"
check "haiku: notas tratam id desconhecido como Haiku (#481)"     grep -qF 'No id: treat as Haiku' "$N"
check "haiku: notas sem subagente publicam e avisam na primeira linha (#481)" grep -qF 'say on its first line that it came from Haiku and was not reviewed by Sonnet' "$N"
# 538. sessões no mesmo container: merge de PR de rodada, processo, "o que está rodando", comentário de merge, limites
check "538: notas recusam o merge de PR de rodada aberta e dizem o que responder ao Bardi" bash -c 'grep -qF "Merging a PR of an open round is not yours" "$1" && grep -qF "the last audit state" "$1" && grep -qF "the merge goes through that round" "$1"' _ "$N"
check "538: notas só deixam encerrar processo pelo PID ou id da tarefa" grep -qF 'Only kill a process you opened' "$N"
check "538: notas dizem que pkill e killall são recusados" grep -qF '`pkill` and `killall` (and `pkill -f`) are refused' "$N"
check "538: notas mandam listar primeiro o que a sessão abriu" grep -qF 'list first what you opened' "$N"
check "538: notas proíbem chamar de desta sessão o que veio de ps/pgrep" grep -qF 'Never call "from this session" what came from `ps` or `pgrep`' "$N"
check "538: notas pedem o comentário de merge (sessão, a pedido de quem, head)" grep -qF 'the session (worktree and id), "a pedido do Bardi" or the authorization used, the merged head' "$N"
check "538: notas declaram os limites (engano, não contorno; merge no site)" bash -c 'grep -qF "protect against mistakes, not against circumvention" "$1" && grep -qF "do not apply to a merge the Bardi does on the website" "$1"' _ "$N"
# 650. release, deploy e verificação: ler a fila do canal e as rodadas abertas antes de propor
SR="$ROOT/addons/skills/oute-aidlc-ship-release/SKILL.md"
check "650: notas mandam ler a fila (oute-inbox) e as rodadas (oute-swarm busy) antes de propor" bash -c 'grep -qF "Before proposing one, read the channel queue (\`oute-inbox\`" "$1" && grep -qF "open rounds (\`oute-swarm busy\`" "$1"' _ "$N"
check "650: notas não propõem outro com pedido pendente de outra sessão e avisam o Bardi" grep -qF 'If **another session** has a pending release or deploy request, do not propose another: tell the Bardi' "$N"
check "650: notas pedem no # RESUMO as rodadas abertas e as sessões que caem" grep -qF 'which rounds are open and which sessions go down' "$N"
check "650: ship-release traz o passo da fila antes do pedido" bash -c 'grep -qF "oute-inbox " "$1" && grep -qF "oute-swarm busy" "$1" && grep -qF "quais rodadas estão abertas e quais sessões caem" "$1"' _ "$SR"
check "665: notas mandam rodar gh issue list antes de todo gh issue create, em item próprio" grep -qF '**Before every `gh issue create`, run `gh issue list --state open --search' "$N"
check "665: notas mandam comentar na issue aberta em vez de criar outra" grep -qF 'new evidence goes in a comment on it (`gh issue comment <n>`)' "$N"
check_end
