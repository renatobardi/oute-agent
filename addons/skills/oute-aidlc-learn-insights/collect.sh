#!/usr/bin/env bash
# Coleta da fase learn (#109, ADR-07 adendo "ciclo learn → iter"): fatos e contagens de um ciclo, só
# metadados. Fontes: GitHub (issues e PRs dos repos do /workspace), rodadas do swarm e canal de aprovação
# (só deste host) e telemetria (via observe.sh da oute-aidlc-ops-observe). Só leitura. Nenhum conteúdo sai
# daqui: do canal, só o cabeçalho (id, rc, como, recusado); dos PRs, o corpo só vira classificação ("so_ship", "parcial") e números de issue.
#
# Uso: collect.sh [all|ciclo|github|rodadas|canal|telemetria] [--desde DATA] [--content-hours N]
#   --desde DATA       início da janela (padrão: fechamento da última issue de ciclo; sem ciclo, 7 dias)
#   --content-hours N  repassado ao observe.sh (padrão 0 = só agregados do agent-studio e listagem do bucket)
# Ambiente: OUTE_CYCLE_REPO (padrão renatobardi/oute-agent), OUTE_WORKSPACE (/workspace),
#   OUTE_SWARM_DIR (~/.oute/swarm), OUTE_INBOX (~/inbox), OUTE_OBSERVE (observe.sh da ops-observe).
# Saída: seções em TSV; "LACUNA<TAB>fonte<TAB>motivo" = o que a janela não cobre. Código != 0 só quando
# uma fonte não pôde ser lida (linha "ERRO").
set -euo pipefail

MODE=all; DESDE=""; CHOURS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    all|ciclo|github|rodadas|canal|telemetria) MODE="$1" ;;
    --desde) DESDE="${2:-}"; shift ;;
    --content-hours) CHOURS="${2:-}"; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "collect: argumento desconhecido: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$CHOURS" =~ ^[0-9]+$ ]] || { echo "collect: número inválido: $CHOURS" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CYCLE_REPO="${OUTE_CYCLE_REPO:-renatobardi/oute-agent}"
WS="${OUTE_WORKSPACE:-/workspace}"
SWARM="${OUTE_SWARM_DIR:-$HOME/.oute/swarm}"
INBOX="${OUTE_INBOX:-$HOME/inbox}"
OBSERVE="${OUTE_OBSERVE:-$HERE/../oute-aidlc-ops-observe/observe.sh}"
HOST="${OUTE_HOST:-$(hostname)}"
CYCLE_RE='^ciclo [0-9]{4}-[0-9]{2}-[0-9]{2}'
NOW="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
RC=0

# ---------------------------------------------------------------- janela e ciclos
CYCLES="$(gh issue list --repo "$CYCLE_REPO" --state all --search 'ciclo in:title' --limit 100 \
  --json number,title,state,createdAt,closedAt 2>/dev/null \
  | jq -c --arg re "$CYCLE_RE" '[.[] | select(.title | test($re))] | sort_by(.createdAt) | reverse')" \
  || { CYCLES=""; }
if [[ -n "$DESDE" ]]; then
  FROM="$(date -u -d "$DESDE" +%s 2>/dev/null)" || { echo "collect: data inválida: $DESDE" >&2; exit 2; }
  ORIGEM="--desde"
elif [[ -n "$CYCLES" ]] && last="$(jq -r '[.[] | select(.state == "CLOSED") | .closedAt] | max // empty' <<<"$CYCLES")" && [[ -n "$last" ]]; then
  FROM="$(date -u -d "$last" +%s)"; ORIGEM="fechamento da última issue de ciclo"
elif [[ -n "$CYCLES" ]]; then
  FROM=$((NOW - 7 * 86400)); ORIGEM="padrão de 7 dias (nenhum ciclo fechado)"
else  # gh falhou: não dá para saber onde o último ciclo fechou
  FROM=$((NOW - 7 * 86400)); ORIGEM="padrão de 7 dias (issues de ciclo ilegíveis)"
fi
[[ "$FROM" -lt "$NOW" ]] || { echo "collect: início da janela no futuro" >&2; exit 2; }
W_FROM="$(iso "$FROM")"; W_TO="$(iso "$NOW")"
HOURS=$(( (NOW - FROM + 3599) / 3600 ))

janela() {
  echo "## janela"
  printf 'de\t%s\nate\t%s\norigem\t%s\nhoras\t%s\nhost_local\t%s\n' "$W_FROM" "$W_TO" "$ORIGEM" "$HOURS" "$HOST"
  [[ -n "$CYCLES" || -n "$DESDE" ]] || printf 'LACUNA\tciclos\tissues de ciclo ilegíveis (gh): a janela pode não começar no fim do último ciclo\n'
}

ciclo() {
  echo "## ciclos ($CYCLE_REPO)"
  [[ -n "$CYCLES" ]] || { echo "ERRO	issues de ciclo ilegíveis (gh)"; return 1; }
  jq -r '(["issue","estado","aberta","fechada","título"] | @tsv),
         (.[:10][] | ["#\(.number)", .state, .createdAt, (.closedAt // "-"), .title] | @tsv)' <<<"$CYCLES"
  jq -r 'map(select(.state == "OPEN")) | if length == 0 then "ciclo_aberto\tnenhum (a learn abre uma issue retroativa)"
         else "ciclo_aberto\t#\(.[0].number)" end' <<<"$CYCLES"
}

# ---------------------------------------------------------------- GitHub (issues e PRs, só metadados)
repos() {  # dono/repo de cada checkout principal do /workspace com remote no GitHub
  local d u
  for d in "$WS"/*/; do
    [[ -d "$d/.git" ]] || continue
    u="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
    u="${u%.git}"; [[ "$u" == *github.com[:/]* ]] || continue
    printf '%s\n' "${u#*github.com[:/]}"
  done
}

github() {
  echo "## GitHub · issues e PRs de $W_FROM a $W_TO"
  local r n=0 stale=$((NOW - 30 * 86400)) rc=0
  echo "### issues por repo"
  printf 'repo\tabertas_janela\tfechadas_janela\tabertas_agora\tparadas_30d\n'
  : >"$TMP/iss"; : >"$TMP/prs"
  while read -r r; do
    n=$((n + 1))
    gh issue list --repo "$r" --state all --limit 1000 --json number,title,state,createdAt,closedAt,updatedAt,labels 2>/dev/null \
      | jq -c --arg r "$r" '.[] | {repo: $r, n: .number, title, state, c: .createdAt, x: .closedAt, u: .updatedAt, l: [.labels[].name]}' >>"$TMP/iss" \
      || { echo "ERRO	issues de $r ilegíveis (gh)"; rc=1; continue; }
    # corpo do PR: só vira classificação (tipo: so_ship, parcial ou nulo) e números de issue, nunca é impresso
    gh pr list --repo "$r" --state all --limit 300 --search "updated:>=${W_FROM%%T*}" --json number,title,state,createdAt,mergedAt,closedAt,body 2>/dev/null \
      | jq -c --arg r "$r" '
          def falta: ((.body // "") | gsub("\r"; "") | split("\n")) as $l
            | ($l | map(test("^## Falta")) | index(true)) as $i
            | if $i == null then null
              else ($l[$i + 1:]) as $rest | ($rest | map(test("^## ")) | index(true)) as $e
                | (if $e == null then $rest else $rest[:$e] end) | map(select(test("^\\s*[-*] +\\S"))) end;
          .[] | (.body // "") as $b | falta as $f
          | {repo: $r, n: .number, title, state, c: .createdAt, m: .mergedAt, x: .closedAt,
             refs: [$b | scan("(?i)\\b(?:closes|fixes|resolves|refs) #([0-9]+)") | .[0] | tonumber] | unique,
             tipo: (if $f != null then (if ($f | length) > 0 and ($f | all(test("\\(ship\\)"))) then "so_ship" else "parcial" end)
                    elif ($b | test("(?i)\\brefs #[0-9]") and (test("(?i)\\b(closes|fixes|resolves) #[0-9]") | not)) then "parcial"
                    else null end)}' >>"$TMP/prs" \
      || { echo "ERRO	PRs de $r ilegíveis (gh)"; rc=1; }
  done < <(repos)
  [[ "$n" -gt 0 ]] || { echo "ERRO	nenhum repo com remote do GitHub em $WS"; return 1; }
  local q='def ts: if . == null then 0 else fromdateiso8601 end;'
  jq -rs --arg f "$W_FROM" --argjson s "$stale" "$q"'
    ($f | fromdateiso8601) as $from | group_by(.repo)[]
    | [.[0].repo, (map(select(.c | ts >= $from)) | length), (map(select(.x | ts >= $from)) | length),
       (map(select(.state == "OPEN")) | length), (map(select(.state == "OPEN" and (.u | ts) < $s)) | length)] | @tsv' "$TMP/iss"
  echo "### issues abertas por fase (repos que usam labels aidlc:*)"
  # repo sem nenhuma issue aidlc:* não segue o AI-DLC: fica fora da tabela, senão vira "(sem fase)" em massa
  jq -rs --argjson s "$stale" "$q"'
    ([.[] | select(any(.l[]; startswith("aidlc:"))) | .repo] | unique) as $ai
    | (["fase","abertas","paradas_30d"] | @tsv),
      (map(select(.state == "OPEN" and (.repo | IN($ai[])))
           | . + {f: ((.l | map(select(startswith("aidlc:")))[0]) // "(sem fase)")})
       | group_by(.f)[] | [.[0].f, length, (map(select((.u | ts) < $s)) | length)] | @tsv),
      ([.[].repo] | unique - $ai | select(length > 0) | "fora_da_tabela\t\(join(","))\tsem labels aidlc:*")' "$TMP/iss"
  echo "### issues kaizen, bug e ciclo na janela"
  jq -rs --arg f "$W_FROM" "$q"'
    ($f | fromdateiso8601) as $from
    | (["repo","issue","estado","labels","aberta","fechada","título"] | @tsv),
      (.[] | select((.l | index("kaizen") or index("bug")) and ((.c | ts) >= $from or (.x | ts) >= $from))
       | [.repo, "#\(.n)", .state, (.l | join(",")), .c, (.x // "-"), .title] | @tsv)' "$TMP/iss"
  echo "### PRs por repo"
  printf 'repo\tabertos_janela\tmergeados_janela\tfechados_sem_merge\tso_ship\tparciais\n'
  jq -rs --arg f "$W_FROM" "$q"'
    ($f | fromdateiso8601) as $from | group_by(.repo)[]
    | [.[0].repo, (map(select(.c | ts >= $from)) | length), (map(select(.m | ts >= $from)) | length),
       (map(select(.m == null and (.x | ts) >= $from)) | length),
       (map(select(.tipo == "so_ship" and (.m | ts) >= $from)) | length),
       (map(select(.tipo == "parcial" and (.m | ts) >= $from)) | length)] | @tsv' "$TMP/prs"
  echo "### PRs parciais (Refs / ## Falta) mergeados na janela"
  printf 'repo\tpr\tmergeado\ttipo\ttítulo\n'
  jq -rs --arg f "$W_FROM" "$q"'($f | fromdateiso8601) as $from
    | .[] | select(.tipo != null and (.m | ts) >= $from) | [.repo, "#\(.n)", .m, .tipo, .title] | @tsv' "$TMP/prs"
  echo "### issues abertas com PR mergeado na janela"
  # pendente: so_ship = só falta o (ship); nada = órfã (PR mergeado, issue aberta, nenhum item pendente).
  # Issue com algum PR da janela parcial de verdade tem pendência real e fica fora.
  printf 'repo\tissue\tpr\tpendente\n'
  jq -rs --arg f "$W_FROM" --slurpfile iss "$TMP/iss" "$q"'($f | fromdateiso8601) as $from
    | [.[] | select((.m | ts) >= $from)] as $m
    | [$iss[] | select(.state == "OPEN") | {repo, n}] as $open
    | $m[] as $p | $p.refs[] as $n
    | select($open | any(.repo == $p.repo and .n == $n))
    | select([$m[] | select(.repo == $p.repo and (.refs | index($n)) != null and .tipo == "parcial")] | length == 0)
    | [$p.repo, "#\($n)", "#\($p.n)", ($p.tipo // "nada")] | @tsv' "$TMP/prs"
  return "$rc"
}

# ---------------------------------------------------------------- rodadas do swarm (host local)
nlog() { [[ -f "$2/log" ]] && grep -c -- "$1" "$2/log" || echo 0; }  # nlog <regex> <pasta da rodada>
# done_sem_pr não conta sessão de issue `spike` (a entrega dela é o relatório, sem PR: #115, #403, #436).
# Só o label `spike` identifica; o log do swarm não marca a entrega só no GitHub. Sem resposta do gh, conta tudo.
spikes() {  # spikes <caminho do repo da rodada> → números das issues com label spike, um por linha
  local rp="$1" u
  u="$(git -C "$WS/$(basename "$rp")" remote get-url origin 2>/dev/null)" || return 0
  u="${u%.git}"; [[ "$u" == *github.com[:/]* ]] || return 0
  gh issue list --repo "${u#*github.com[:/]}" --state all --label spike --limit 1000 --json number 2>/dev/null \
    | jq -r '.[].number' 2>/dev/null || true
  return 0
}
done_sem_pr() {  # done_sem_pr <pasta da rodada> <caminho do repo> → sessões done sem PR, fora as de spike
  local d="$1" sp n
  sp="$(spikes "$2")"
  [[ -f "$d/log" ]] || { echo 0; return 0; }
  { grep -- '\[sessao\] .*: done (sem PR)' "$d/log" || true; } \
    | awk -v sp="$sp" 'BEGIN { n = split(sp, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") s["#" a[i]] = 1 }
        { for (i = 1; i <= NF; i++) if ($i ~ /^#[0-9]+$/) { if (!($i in s)) c++; next } }
        END { print c + 0 }'
  return 0
}
rodadas() {
  echo "## rodadas do swarm ($SWARM, host $HOST)"
  printf 'LACUNA\trodadas\tsó o host %s: o volume oute-home é local de cada host\n' "$HOST"
  [[ -d "$SWARM" ]] || { echo "rodadas	0 (pasta ausente)"; return 0; }
  printf 'rodada\trepo\tlabel\tinício\tsessões\tidle\tdone_sem_pr\tblocked\ttell\n'
  local d id st repo label ses
  for d in "$SWARM"/swarm-*/; do
    id="$(basename "$d")"
    st="$(sed -n 's/^started=//p' "$d/meta" 2>/dev/null)"; [[ -n "$st" ]] || continue
    [[ "$(date -u -d "$st" +%s 2>/dev/null || echo 0)" -ge "$FROM" ]] || continue
    repo="$(sed -n 's/^repo=//p' "$d/meta")"; label="$(sed -n 's/^label=//p' "$d/meta")"
    ses="$(cat "$d"/spawned "$d"/spawned.closed 2>/dev/null | awk 'NF {print $1}' | sort -u | wc -l)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(basename "${repo:--}")" "${label:--}" "$st" "$ses" \
      "$(nlog '\[sessao\] .*: idle' "$d")" "$(done_sem_pr "$d" "$repo")" \
      "$(nlog '\[sessao\] .*: blocked' "$d")" "$(nlog '^[^ ]* tell ' "$d")"
  done
}

# ---------------------------------------------------------------- canal de aprovação (host local, só cabeçalho)
canal() {
  echo "## canal de aprovação ($INBOX, host $HOST)"
  printf 'LACUNA\tcanal\tsó o host %s: ~/inbox é local de cada host\n' "$HOST"
  [[ -d "$INBOX" ]] || { echo "pedidos	0 (pasta ausente)"; return 0; }
  local f id ts rc como rec tot=0 ok=0 falha=0 recus=0 rows=""
  for f in "$INBOX"/*.out; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .out)"
    ts="$(date -u -d "$(sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2}).*/\1-\2-\3 \4:\5:\6/' <<<"$id")" +%s 2>/dev/null)" || continue
    [[ "$ts" -ge "$FROM" ]] || continue
    # só as 6 primeiras linhas, e só estas chaves: o resto do arquivo é saída do pedido (conteúdo)
    rc="$(head -n 6 "$f" | sed -n 's/^# rc: \([0-9]*\)$/\1/p')"
    como="$(head -n 6 "$f" | sed -n 's/^# como: \([a-z]*\)$/\1/p')"
    rec="$(head -n 6 "$f" | grep -c '^# recusado:' || true)"
    tot=$((tot + 1))
    if [[ "$rec" -gt 0 ]]; then recus=$((recus + 1)); rows+="$(iso "$ts")	${id:16}	-	recusado"$'\n'
    elif [[ "$rc" == 0 ]]; then ok=$((ok + 1))
    else falha=$((falha + 1)); rows+="$(iso "$ts")	${id:16}	${como:--}	rc=${rc:-?}"$'\n'
    fi
  done
  printf 'pedidos\t%s\nrc_0\t%s\nrc_diferente_de_0\t%s\nrecusados\t%s\n' "$tot" "$ok" "$falha" "$recus"
  echo "### pedidos com rc != 0 ou recusados"
  printf 'data\tpedido\tcomo\tresultado\n%s' "$rows"
}

# ---------------------------------------------------------------- telemetria (reusa o observe.sh)
telemetria() {
  echo "## telemetria (observe.sh, $HOURS h)"
  if [[ ! -f "$OBSERVE" ]]; then
    printf 'LACUNA\ttelemetria\tobserve.sh da oute-aidlc-ops-observe ausente (%s)\n' "$OBSERVE"; return 0
  fi
  bash "$OBSERVE" all --hours "$HOURS" --baseline-days 7 --content-hours "$CHOURS" \
    || { echo "ERRO	observe.sh saiu com erro (veja as linhas ERRO acima)"; return 1; }
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
janela; echo
case "$MODE" in
  ciclo)      ciclo || RC=1 ;;
  github)     github || RC=1 ;;
  rodadas)    rodadas || RC=1 ;;
  canal)      canal || RC=1 ;;
  telemetria) telemetria || RC=1 ;;
  all) for s in ciclo github rodadas canal telemetria; do "$s" || RC=1; echo; done ;;
esac
exit "$RC"
