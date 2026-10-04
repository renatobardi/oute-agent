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
for f in "$D" "$W" "$N"; do
  b="${f##*/}"
  check "pt-controlado: $b manda a saída ao Bardi em pt-BR (#478)"  grep -qF 'Em pt-BR, mesmo que o prompt' "$f"
  check "pt-controlado: $b pede fonte que o Bardi abre, sem scratchpad (#478)" grep -qF 'nunca caminho de scratchpad ou de arquivo temporário' "$f"
  check "pt-controlado: $b rotula recomendação sem fonte (#478)"    grep -qF 'rotulada "recomendação do autor"' "$f"
  check "pt-controlado: $b usa fazer merge (#478)"                  grep -qF 'Diga "fazer merge", não "mergear"' "$f"
  check "pt-controlado: $b aponta o doc (#478)"                     grep -qF 'docs/pt-controlado.md' "$f"
done
check "pt-controlado: worker e notas: reescrever não muda fato (#478)" bash -c 'grep -qF "Reescrever não muda fato, condição nem valor" "$1" && grep -qF "Reescrever não muda fato, condição nem valor" "$2"' _ "$W" "$N"
check "pt-controlado: dispatcher resume sem mudar fato (#478)"    grep -qF 'não mude fato, condição nem valor' "$D"
check "pt-controlado: doc tem as 15 regras (#478)"                bash -c '[ "$(grep -cE "^\| ([1-9]|1[0-5]) \| \*\*" "$1")" -eq 15 ]' _ "$PT"
check "pt-controlado: doc fixa fazer merge (#478)"                grep -qF '| fazer merge | mergear, mesclar, integrar |' "$PT"
check "pt-controlado: AGENTS.md cita o doc (#478)"                grep -qF 'docs/pt-controlado.md' "$ROOT/AGENTS.md"
# 480. canal de aprovação: # RESUMO e # CUIDADO: no script proposto
SV="$ROOT/addons/skills/oute-aidlc-ship-verify/SKILL.md"; OB="$ROOT/addons/skills/oute-aidlc-ops-observe/SKILL.md"
check "canal: notas pedem bloco # RESUMO (#480)"                  grep -qF 'abre com um bloco `# RESUMO` (comentário)' "$N"
check "canal: RESUMO lista faz, host, altera, não toca, reinicia (#480)" grep -qF 'o que faz, em que host, o que altera, o que **não** toca e se reinicia algo' "$N"
check "canal: CUIDADO antes de passo que remove, recria, para ou não se desfaz (#480)" grep -qF '`# CUIDADO: <o que o passo faz>. <o que se perde>.`, com o comando primeiro e o risco depois' "$N"
check "canal: aviso não exagera nem tranquiliza (#480)"           grep -qF 'não exagera e não tranquiliza' "$N"
check "canal: afirmação de segurança só se o script garante (#480)" grep -qF 'Só escreva "não toca em X" se o script garante isso' "$N"
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
for f in "$W" "$N"; do b="$(basename "$f")"
  check "haiku: $b manda a redação final a um subagente em Sonnet (#481)" grep -qF 'A sessão em Haiku passa a redação final a um subagente em Sonnet' "$f"
  check "haiku: $b passa fatos e fontes ao subagente (#481)"        grep -qF 'Ela entrega ao subagente os fatos e as fontes' "$f"
  check "haiku: $b confere o resultado contra os fatos (#481)"      grep -qF 'a sessão confere o texto do subagente contra os fatos' "$f"
  check "haiku: $b diz como saber o próprio modelo (#481)"          grep -qF '**Como saber o próprio modelo:**' "$f"
  check "haiku: $b trata id desconhecido como Haiku (#481)"         grep -qF 'Se o id não aparecer, trate a sessão como Haiku' "$f"
  check "haiku: $b sem subagente publica e avisa (#481)"            grep -qF 'avisa, na primeira linha do texto, que ele saiu do Haiku' "$f"
done
# 538. sessões no mesmo container: merge de PR de rodada, processo, "o que está rodando", comentário de merge, limites
check "538: notas recusam o merge de PR de rodada aberta e dizem o que responder ao Bardi" bash -c 'grep -qF "Merge de PR de rodada aberta não é seu" "$1" && grep -qF "estado da última auditoria" "$1" && grep -qF "o merge sai pelo dispatcher dela" "$1"' _ "$N"
check "538: notas só deixam encerrar processo pelo PID ou id da tarefa" grep -qF 'Só encerre processo que você abriu' "$N"
check "538: notas dizem que pkill e killall são recusados" grep -qF '`pkill` e `killall` (e `pkill -f`) são recusados' "$N"
check "538: notas mandam listar primeiro o que a sessão abriu" grep -qF 'liste primeiro o que você abriu' "$N"
check "538: notas proíbem chamar de desta sessão o que veio de ps/pgrep" grep -qF 'Nunca chame de "desta sessão" o que veio de `ps` ou `pgrep`' "$N"
check "538: notas pedem o comentário de merge (sessão, a pedido de quem, head)" grep -qF 'a sessão (worktree e id), "a pedido do Bardi" ou a autorização usada, e o head mergeado' "$N"
check "538: notas declaram os limites (engano, não contorno; merge no site)" bash -c 'grep -qF "protegem contra engano, não contra quem contorna" "$1" && grep -qF "Não valem para merge feito pelo Bardi no site" "$1"' _ "$N"
check_end
