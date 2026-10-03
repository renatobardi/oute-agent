#!/usr/bin/env bash
# Testes do collect.sh da skill oute-aidlc-learn-insights (#109). Bash puro, sem rede: `gh` e o observe.sh
# são falsos; rodadas, inbox e /workspace são fixtures. Confere janela, contagens, lacunas e que conteúdo
# (corpo de PR, saída de pedido do canal) nunca aparece na saída. Uso: tests/learn-insights.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/addons/skills/oute-aidlc-learn-insights/collect.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=+1   # o bad mostra a saída inteira

d() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
CANARIO="CANARIO-CONTEUDO-7f3a"

# /workspace falso: um repo com remote do GitHub, um sem remote
WS="$TMP/ws"; mkdir -p "$WS"
git init -q "$WS/alvo" && git -C "$WS/alvo" remote add origin https://github.com/dono/alvo.git
git init -q "$WS/solto"
git init -q "$WS/outro" && git -C "$WS/outro" remote add origin https://github.com/dono/outro.git

# gh falso: F_CICLO=fechado|aberto|nenhum; F_GH_FAIL=1 derruba tudo
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
[[ "\${F_GH_FAIL:-}" == 1 ]] && exit 1
case "\$1 \$2" in
  "issue list")
    if [[ "\$*" == *"ciclo in:title"* ]]; then
      case "\${F_CICLO:-nenhum}" in
        fechado) echo '[{"number":9,"title":"ciclo 2026-09-01","state":"CLOSED","createdAt":"2026-09-01T00:00:00Z","closedAt":"$(d '3 days ago')"},{"number":10,"title":"ciclo seguinte sem data","state":"CLOSED","createdAt":"2026-09-02T00:00:00Z","closedAt":"$(d '1 hour ago')"}]' ;;
        aberto)  echo '[{"number":11,"title":"ciclo 2026-09-20","state":"OPEN","createdAt":"2026-09-20T00:00:00Z","closedAt":null}]' ;;
        *)       echo '[]' ;;
      esac
    elif [[ "\$*" == *dono/outro* ]]; then
      echo '[{"number":5,"title":"sem aidlc","state":"OPEN","createdAt":"$(d '90 days ago')","closedAt":null,"updatedAt":"$(d '60 days ago')","labels":[{"name":"infra"}]}]'
    else
      echo '[{"number":1,"title":"kaizen novo","state":"OPEN","createdAt":"$(d '1 day ago')","closedAt":null,"updatedAt":"$(d '1 day ago')","labels":[{"name":"kaizen"},{"name":"aidlc:spec"}]},
             {"number":2,"title":"parada","state":"OPEN","createdAt":"$(d '90 days ago')","closedAt":null,"updatedAt":"$(d '60 days ago')","labels":[{"name":"aidlc:intent"}]},
             {"number":3,"title":"bug velho","state":"CLOSED","createdAt":"$(d '90 days ago')","closedAt":"$(d '80 days ago')","updatedAt":"$(d '80 days ago')","labels":[{"name":"bug"}]}]'
    fi ;;
  "pr list")
    echo '[{"number":7,"title":"parcial","state":"MERGED","createdAt":"$(d '2 days ago')","mergedAt":"$(d '1 day ago')","closedAt":"$(d '1 day ago')","body":"Refs #1\n\n## Falta\n- $CANARIO"},
           {"number":8,"title":"inteiro","state":"MERGED","createdAt":"$(d '2 days ago')","mergedAt":"$(d '1 day ago')","closedAt":"$(d '1 day ago')","body":"Closes #1 $CANARIO"}]' ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/gh"

# rodadas: uma na janela (com log), uma antiga
SW="$TMP/swarm"; mkdir -p "$SW/swarm-nova" "$SW/swarm-velha"
printf 'repo=/workspace/alvo\nmax=2\nlabel=ready\nstarted=%s\n' "$(d '1 day ago')" > "$SW/swarm-nova/meta"
printf '1-a w1:p1 claude x\n2-b w1:p2 codex x\n' > "$SW/swarm-nova/spawned"
printf 'T watch [sessao] #1 a: idle (sem PR)\nT watch [sessao] #1 a: done (sem PR)\nT watch [sessao] #2 b: blocked (x)\nT tell 1-a ok\n' > "$SW/swarm-nova/log"
printf 'repo=/workspace/alvo\nstarted=%s\n' "$(d '40 days ago')" > "$SW/swarm-velha/meta"

# canal: ok, falho, recusado e um antigo; a saída do pedido traz o canário
IN="$TMP/inbox"; mkdir -p "$IN"
id() { printf '%s-%s' "$(date -u -d "$1" +%Y%m%d-%H%M%S)" "$2"; }
printf '# id: x\n# rc: 0\n# como: user\n# aprovado: y\n# sha256: z\n\n%s\n' "$CANARIO" > "$IN/$(id '2 days ago' pedido-bom).out"
printf '# id: x\n# rc: 1\n# como: root\n# aprovado: y\n# sha256: z\n\n# rc: 0 %s\n' "$CANARIO" > "$IN/$(id '1 day ago' pedido-falho).out"
printf '# id: x\n# rc: 126\n# recusado: y\n# sha256: z\n\nrecusado %s\n' "$CANARIO" > "$IN/$(id '1 day ago' pedido-recusado).out"
printf '# id: x\n# rc: 1\n# como: root\n' > "$IN/$(id '30 days ago' pedido-antigo).out"

OBS="$TMP/observe.sh"
printf '#!/usr/bin/env bash\necho "OBSERVE $*"\nexit "${F_OBS_RC:-0}"\n' > "$OBS"

run() {
  OUT="$(env PATH="$BIN:/usr/bin:/bin" HOME="$TMP" OUTE_WORKSPACE="$WS" OUTE_SWARM_DIR="$SW" OUTE_INBOX="$IN" \
    OUTE_OBSERVE="$OBS" OUTE_HOST=h1 "$@" 2>&1)"; RC=$?
}

[[ -f "$SCRIPT" ]] || { echo "FAIL script ausente: $SCRIPT"; exit 1; }
check "sintaxe (bash -n)" bash -n "$SCRIPT"

run bash "$SCRIPT" all
check "all: código 0"                          [ "$RC" -eq 0 ]
check "janela padrão de 7 dias sem ciclo"      has 'origem	padrão de 7 dias'
check "sem ciclo aberto: learn abre retroativa" has 'ciclo_aberto	nenhum'
check "só repos com remote do GitHub"          hasnt 'solto'
check "issues por repo"                        has 'dono/alvo	1	0	2	1'
check "fase com parada há 30 dias"             has 'aidlc:intent	1	1'
check "repo sem aidlc fora da tabela de fases" bash -c '! grep -q "^(sem fase)" <<<"$0" && grep -q "^fora_da_tabela	dono/outro" <<<"$0"' "$OUT"
check "kaizen da janela listado"               has 'dono/alvo	#1	OPEN	kaizen,aidlc:spec'
check "bug fora da janela não entra"           hasnt '#3	CLOSED'
check "PRs: parcial contado"                   has 'dono/alvo	2	2	0	1'
check "PR parcial listado, inteiro não"        bash -c 'grep -q "#7	.*	parcial" <<<"$0" && ! grep -q "#8	" <<<"$0"' "$OUT"
check "rodada da janela com contagens"         has 'swarm-nova	alvo	ready	.*	2	1	1	1	1'
check "rodada antiga fora"                     hasnt 'swarm-velha'
check "lacuna das rodadas (host local)"        has 'LACUNA	rodadas	só o host h1'
check "canal: contagens"                       has 'pedidos	3'
check "canal: falho e recusado listados"       bash -c 'grep -q "pedido-falho	root	rc=1" <<<"$0" && grep -q "pedido-recusado	-	recusado" <<<"$0"' "$OUT"
check "canal: pedido antigo fora"              hasnt 'pedido-antigo'
check "canal: bom não listado"                 hasnt 'pedido-bom'
check "telemetria chama o observe.sh"          has 'OBSERVE all --hours 168 --baseline-days 7 --content-hours 0'
check "conteúdo nunca aparece"                 hasnt "$CANARIO"

run env F_CICLO=fechado bash "$SCRIPT" ciclo
check "janela desde o último ciclo fechado"    has 'origem	fechamento da última issue de ciclo'
check "título fora do padrão não é ciclo"      hasnt 'ciclo seguinte sem data'
check "janela de ~72 h"                        has 'horas	7[23]$'

run env F_CICLO=aberto bash "$SCRIPT" ciclo
check "ciclo aberto identificado"              has 'ciclo_aberto	#11'

run bash "$SCRIPT" rodadas --desde '60 days ago'
check "--desde amplia a janela"                has 'swarm-velha'

run bash "$SCRIPT" canal --desde '2000-01-01'
check "janela > 30 dias: sem lacuna de telemetria (o agent-studio guarda tudo)" bash -c 'grep -q "^horas	[0-9]\{6\}$" <<<"$0"' "$OUT"

run env OUTE_OBSERVE="$TMP/nao-existe" bash "$SCRIPT" telemetria
check "sem observe.sh: lacuna, código 0"       bash -c '[ "$1" -eq 0 ] && grep -q "LACUNA	telemetria" <<<"$0"' "$OUT" "$RC"

run env F_OBS_RC=1 bash "$SCRIPT" telemetria
check "observe.sh falho: código 1"             [ "$RC" -eq 1 ]

run env F_GH_FAIL=1 bash "$SCRIPT" github
check "gh fora: ERRO e código 1"               bash -c '[ "$1" -eq 1 ] && grep -q "^ERRO	issues de dono/alvo" <<<"$0"' "$OUT" "$RC"

run env F_GH_FAIL=1 bash "$SCRIPT" rodadas
check "gh fora: janela não diz 'nenhum ciclo'" has 'origem	padrão de 7 dias (issues de ciclo ilegíveis)'
check "gh fora: lacuna dos ciclos na janela"   has 'LACUNA	ciclos'

run bash "$SCRIPT" --desde amanhã-talvez
check "data inválida: código 2"                [ "$RC" -eq 2 ]

check_end
