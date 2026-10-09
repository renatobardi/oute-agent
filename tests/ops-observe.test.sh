#!/usr/bin/env bash
# Testes do observe.sh da skill oute-aidlc-ops-observe (#259, ADR-08 §9): a seção `studio` lê o `GET /v1/usage`
# (janela e base) e o `GET /v1/alerts` do agent-studio de verdade (tests/lib/agent-studio.sh), com a credencial de
# leitura fora do argv. O DuckDB de exemplo nasce pela ingestão (POST /v1/traces, /v1/logs e
# /v1/metrics), com fatos relativos a agora: o script usa a hora corrente. A seção do bucket roda com um rclone
# falso. Sem Docker e sem rede externa.
# Uso: tests/ops-observe.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/addons/skills/oute-aidlc-ops-observe/observe.sh"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init
CHECK_OUT=+1   # o bad mostra a saída inteira

[[ -f "$SCRIPT" ]] || die "script ausente: $SCRIPT"
check "sintaxe (bash -n)"                              bash -n "$SCRIPT"

# ---------------------------------------------------------------- DuckDB de exemplo (fatos relativos a agora)
# janela = últimas 24 h; base = os 7 dias antes dela. Na base, dois dias com dado (há 2 e há 4 dias).
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys, time
from otlp_json import claude_call, event, kv, queue_metrics, rl, rs, span
tmp = sys.argv[1]
NOW = int(time.time()); W = NOW - 3600; B1 = NOW - 2 * 86400; B2 = NOW - 4 * 86400
claude = {"host.name": "oute-server", "service.name": "claude-code", "oute.agent": "claude"}
codex = {"host.name": "oute-mac", "service.name": "codex_exec", "oute.agent": "codex"}
velho = {"host.name": "oute-velho", "service.name": "codex_exec", "oute.agent": "codex"}
router = {"host.name": "oute-server", "service.name": "jev-router", "oute.agent": "router"}
cl = lambda **a: {"model": "claude-sonnet-5", **a}
cx = lambda m, i=0, o=0: {"model": m, "codex.turn.token_usage.non_cached_input_tokens": i,
                          "codex.turn.token_usage.output_tokens": o}
calls = [
  claude_call(W, 2, cl(input_tokens=100, output_tokens=50), 0.5),
  claude_call(W + 60, 4, cl(input_tokens=200, output_tokens=20), 0.7),
  claude_call(W + 120, 3, cl(input_tokens=1_000_000)),          # sem log api_request: de lista (3/M de entrada)
  claude_call(B1, 1, cl(input_tokens=10), 0.1),                 # base: 0,2 em 2 dias = 0,1/dia
  claude_call(B2, 1, cl(input_tokens=10), 0.1),
]
traces = {"resourceSpans": [
  rs(claude, [*(s for s, _ in calls), span("claude_code.tool", W, 1, {})]),   # tool: span, não chamada
  rs(codex, [
    *(span("session_task.turn", W + i, 1, cx("gpt-5-codex", 1000, 100), err=i < 6) for i in range(8)),   # 6 de 10 com erro
    *(span("session_task.turn", W + 30 + i, 1, cx("gpt-9-sem-preco", 500)) for i in range(2)),             # sem preço
  ]),
  rs(velho, [span("session_task.turn", B1, 1, cx("gpt-5-codex", 1000, 100))]),   # só na base: sem-telemetria
  # histórico do roteador (#218): na base e fora da janela, sem virar anomalia
  rs(router, [span("jev.decision", B1, 0.5, {"gen_ai.response.model": "openai/gpt-oss-20b",
       "gen_ai.usage.input_tokens": 50, "gen_ai.usage.output_tokens": 10, "oute.cost_usd": 0.0004})]),
]}
json.dump(traces, open(f"{tmp}/traces.json", "w"))
def log(t, sev): return {"timeUnixNano": str(int(t * 1e9)), "severityNumber": sev, "body": {"stringValue": "x"}}
# rodada do swarm aberta no Mac há 1 h e sem mais evento (#654): rodada parada, na triagem (limite de 30 min)
swarm = {"host.name": "oute-mac", "oute.instance": "oute-agent", "service.name": "oute"}
logs = {"resourceLogs": [rl(codex, [log(W, 17), log(W + 1, 21), log(W + 2, 9)]),
                         rl(claude, [l for _, l in calls if l]),
                         rl(swarm, [event(W, "oute.swarm.round.opened", "ev-r-parada", {"oute.swarm.round": "swarm-1006-0001"})])]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
# fila do collector do Mac em 90%, há 1 min: o Mac está no ar, o alerta liga
json.dump(queue_metrics("oute-mac", NOW - 60, 900), open(f"{tmp}/metrics.json", "w"))
PY
studio_prices "$TMP/prices.toml"
{ echo 'timezone = "America/Sao_Paulo"'; cat "$TMP/prices.toml"; } > "$TMP/prices-tz.toml" && mv "$TMP/prices-tz.toml" "$TMP/prices.toml"

# credencial de leitura própria (#256), com aspas e barra invertida: o script as escapa no config do curl
READ="$(python3 -c "import secrets; print(secrets.token_hex(12))")\"a\\b"
studio_start "$TMP/s1" AGENT_STUDIO_CONFIG="$TMP/prices.toml" AGENT_STUDIO_READ_TOKEN="$READ" || die "agent-studio não subiu"
check "ingestão do exemplo: 200 nos três sinais"       test "$(post traces "$TMP/traces.json") $(post logs "$TMP/logs.json") $(post metrics "$TMP/metrics.json")" = "200 200 200"

# curl que anota o argv e chama o de verdade; rclone falso (F_RCLONE_FAIL=1 = falha; lsjson = $F_LS, copy = nada)
BIN="$TMP/bin"; mkdir -p "$BIN"; ARGV="$TMP/curl.argv"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$ARGV" "$(command -v curl)" > "$BIN/curl"
cat > "$BIN/rclone" <<'SH'
#!/usr/bin/env bash
[[ "${F_RCLONE_FAIL:-}" == 1 ]] && { echo "2026/01/01 00:00:00 ERROR : falha de teste" >&2; exit 1; }
[[ "$1" == lsjson && "$*" == */traces/ ]] && cat "$F_LS" || { [[ "$1" == lsjson ]] && echo '[]'; }
exit 0
SH
chmod +x "$BIN/curl" "$BIN/rclone"
printf '[{"Path":"host=h1/instance=i1/year=2026/x.json.gz","Size":10,"ModTime":"%s"}]\n' "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S.000000000Z)" > "$TMP/ls.json"

# run [VAR=valor…] <args do observe.sh>: ambiente limpo, só com o que o agent tem
run() {
  local envs=(); while [[ "${1:-}" == *=* ]]; do envs+=("$1"); shift; done
  : > "$ARGV"
  OUT="$(env -i PATH="$BIN:$PATH" HOME="$TMP" LANG=C.UTF-8 AGENT_STUDIO_URL="$STUDIO_URL" AGENT_STUDIO_READ_TOKEN="$READ" \
    F_LS="$TMP/ls.json" OUTE_OBS_BUCKET=falso:bucket ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}

# ---------------------------------------------------------------- studio: tabelas, anomalias e alertas
run studio
check "studio: código 0, sem ERRO"                     bash -c '[ "$1" -eq 0 ] && ! grep -q "^ERRO" <<<"$0"' "$OUT" "$RC"
check "studio: diz o fuso dos dias (o do agent-studio, America/Sao_Paulo)" has "^fuso_dos_dias	America/Sao_Paulo	"
check "studio: não troca o fuso (nenhum tz= na consulta)" bash -c '! grep -q "tz=" "$1"' _ "$ARGV"
check "studio: cabeçalho com a URL, a janela e a base" has "^## agent-studio ($STUDIO_URL) · janela .*Z → .*Z · base 7 dia(s) antes$"
check "studio: lê /v1/usage da janela e da base e /v1/alerts" test "$(grep -c '/v1/usage?from=.*&to=' "$ARGV") $(grep -c '/v1/alerts$' "$ARGV") $(wc -l < "$ARGV")" = "2 1 3"
check "studio: credencial fora do argv e da saída"     bash -c '! grep -qF -- "$2" "$1" && ! grep -qF -- "$2" <<<"$0" && ! grep -qi "bearer" "$1"' "$OUT" "$ARGV" "$READ"
check "tabela: colunas (real, de lista e estimado separados)"    has_line "host	agente	chamadas	spans	erros_span	erros_log	custo_real_usd	custo_lista_usd	custo_estimado_usd	sem_preço	tokens	p95_ms	base_custo_usd/dia"
check "tabela: Claude com custo real, de lista, p95 e base/dia" has_line "oute-server	claude	3	4	0	0	1.2	3	-	0	1000370	3900	0.1"
check "tabela: Codex com erros de span e de log, sem custo real" has "^oute-mac	codex	10	10	6	2	-	0.018	-	2	9800	1000	0$"
check "anomalia erro-alto (6 de 10 spans)"             has_line "ANOMALIA	erro-alto	oute-mac/codex	6 de 10 spans com erro"
check "anomalia custo-alto (real + lista + estimado × base)"   has_line "ANOMALIA	custo-alto	oute-server/claude	US\$ 4.2 na janela (real + lista + estimado) = US\$ 4.2/dia; base US\$ 0.1/dia"
check "anomalia sem-telemetria (só na base)"           has_line "ANOMALIA	sem-telemetria	oute-velho/codex	1 chamadas e 1 spans na base e nada na janela"
check "anomalia sem-preço, com o modelo"               has_line "ANOMALIA	sem-preço	oute-mac/codex	2 chamadas de gpt-9-sem-preco sem custo real e sem preço (config/agent-studio/config.toml)"
check "router só na base: não é sem-telemetria"        hasnt "ANOMALIA	sem-telemetria	oute-server/router"
check "Codex sem base: não é custo-alto"               hasnt "ANOMALIA	custo-alto	oute-mac"
check "só as quatro anomalias"                         test "$(grep -c '^ANOMALIA' <<<"$OUT")" = 4
check "custo por modelo: do mais caro ao mais barato"  test "$(sed -n '/^### custo por modelo/,/^###/p' <<<"$OUT" | sed -n '3,5p')" = "oute-server	claude-sonnet-5	3	1.2	3	-	0
oute-mac	gpt-5-codex	8	-	0.018	-	0
oute-mac	gpt-9-sem-preco	2	-	-	-	2"
check "alertas: os cinco ativos contados (três do pipeline e os dois de custo da #747)"               has_line "alertas_ativos	5"
check "alerta de rodada parada: o detalhe traz o id da rodada e o motivo (#654)" has "^ALERTA	round_stalled	oute-mac	oute-agent	3[0-9]*	seconds	1800	.*Z	rodada swarm-1006-0001 [(]triage[)]$"
check "alerta da fila do Mac, com o exporter"          has "^ALERTA	queue	oute-mac	oute-agent	0.9	ratio	0.5	.*Z	otlp_http/studio_logs$"
check "alerta de host sem dado (oute-server, 1 h)"     has "^ALERTA	host_no_data	oute-server	-	3[0-9]*	seconds	1800	.*Z	-$"
check "último dado por host"                           bash -c 'grep -q "^oute-mac	false	.*Z	[0-9]*$" <<<"$0" && grep -q "^oute-server	true	.*Z	3[0-9]*$" <<<"$0"' "$OUT"

run studio --baseline-days 0
check "sem base: código 0 e uma consulta de uso só"    test "$RC $(grep -c '/v1/usage' "$ARGV")" = "0 1"
check "sem base: nem custo-alto nem sem-telemetria"    test "$(grep '^ANOMALIA' <<<"$OUT" | cut -f2 | sort | tr '\n' ' ')" = "erro-alto sem-preço "

run studio --hours 1000
check "janela longa (> 30 dias): código 0, base vira janela" bash -c '[ "$1" -eq 0 ] && grep -q "^oute-velho	codex	1	1	" <<<"$0"' "$OUT" "$RC"

# ---------------------------------------------------------------- argumentos
run xpto
check "modo desconhecido: código 2"                    bash -c '[ "$1" -eq 2 ] && grep -q "argumento desconhecido: xpto" <<<"$0"' "$OUT" "$RC"
run studio --hours 0
check "--hours 0: código 2"                            [ "$RC" -eq 2 ]
run --help
check "--help: uso com studio|bucket|all, até a linha do código de saída" bash -c '[ "$1" -eq 0 ] && grep -q "^Uso: observe.sh \[studio|bucket|all\]" <<<"$0" && tail -n 1 <<<"$0" | grep -q "linha \"ERRO\" diz qual"' "$OUT" "$RC"

# ---------------------------------------------------------------- fonte ilegível = linha ERRO e código != 0
erro() { [[ "$RC" -eq 1 ]] && has "^ERRO	$1"; }
run AGENT_STUDIO_URL= studio
check "sem AGENT_STUDIO_URL: ERRO e código 1, sem chamada" bash -c '[ ! -s "$1" ]' _ "$ARGV"
check "sem AGENT_STUDIO_URL: diz a variável"           erro "AGENT_STUDIO_URL ausente"
run AGENT_STUDIO_READ_TOKEN= studio
check "sem AGENT_STUDIO_READ_TOKEN: ERRO, código 1, sem chamada" bash -c '[ ! -s "$1" ]' _ "$ARGV"
check "sem AGENT_STUDIO_READ_TOKEN: diz a variável e o item do vault" erro "AGENT_STUDIO_READ_TOKEN ausente no ambiente (item agent-studio da pasta oute-agent"
run AGENT_STUDIO_READ_TOKEN="$STUDIO_TOKEN" studio
check "credencial de ingestão não lê: ERRO HTTP 401"   erro "/v1/usage da janela ilegível: HTTP 401"
check "401: sem tabela e sem a credencial na saída"    bash -c '! grep -q "^### " <<<"$0" && ! grep -qF -- "$1" <<<"$0"' "$OUT" "$STUDIO_TOKEN"
run AGENT_STUDIO_URL="$STUDIO_URL/healthz?x=" studio
check "resposta 200 que não é JSON: ERRO"              erro "/v1/usage da janela ilegível: a resposta não é um objeto JSON"
run AGENT_STUDIO_URL="$STUDIO_URL/" studio
check "URL com barra no fim: lê igual"                 bash -c '[ "$1" -eq 0 ] && grep -q "^alertas_ativos	5" <<<"$0"' "$OUT" "$RC"

# ---------------------------------------------------------------- all = studio + bucket
run all --content-hours 0
check "all: código 0, as duas seções, studio antes"    bash -c '[ "$1" -eq 0 ] && [ "$(grep "^## " <<<"$0" | cut -c1-15 | tr "\n" "|")" = "## agent-studio|## Bucket (fals|" ]' "$OUT" "$RC"
check "all: seção do bucket mantida (último lote)"     has "^traces	h1	i1	.*	1	10$"
check "all: anomalias das duas fontes"                 bash -c 'grep -q "^ANOMALIA	sinal-faltando	h1/i1" <<<"$0" && grep -q "^ANOMALIA	erro-alto	oute-mac/codex" <<<"$0"' "$OUT"
run bucket --content-hours 0
check "bucket: só a seção do bucket, sem chamada ao agent-studio" bash -c '[ "$1" -eq 0 ] && ! grep -q "agent-studio" <<<"$0" && [ ! -s "$2" ]' "$OUT" "$RC" "$ARGV"
run F_RCLONE_FAIL=1 all --content-hours 0
check "all com o bucket ilegível: ERRO, código 1"      erro "listagem de traces falhou: ERROR : falha de teste"
check "all com o bucket ilegível: o studio sai inteiro" has_line "alertas_ativos	5"
run AGENT_STUDIO_READ_TOKEN= all --content-hours 0
check "all com o studio ilegível: ERRO, código 1"      erro "AGENT_STUDIO_READ_TOKEN ausente"
check "all com o studio ilegível: o bucket sai inteiro" has "^traces	h1	i1	"

# ---------------------------------------------------------------- agent-studio fora do ar ou com a leitura quebrada
studio_stop
run studio
check "agent-studio fora do ar: ERRO com o motivo do curl" erro "/v1/usage da janela ilegível: .*[Cc]onnect"
studio_start "$TMP/s2" STUDIO_FAIL_USAGE=1 AGENT_STUDIO_READ_TOKEN="$READ" || die "agent-studio (falha injetada) não subiu"
run studio
check "leitura que falha no servidor: ERRO HTTP 500"   erro "/v1/usage da janela ilegível: HTTP 500"
studio_stop

# ---------------------------------------------------------------- custo-alto: por dia dos dois lados (#298)
# um gasto por dia (há 1 h, há 1 dia + 1 h, …, há 9 dias + 1 h), custo real: igual = 2/dia sempre; acima = 2,5/dia nos
# 3 últimos dias e 2 antes (72 h somam 7,5 > 3 × 2, mas por dia não passa); pico = 9 no último dia e 1 antes
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" <<'PY'
import json, sys, time
from otlp_json import claude_call, rl, rs
tmp = sys.argv[1]
NOW = int(time.time())
gasto = {"h-igual": lambda k: 2, "h-acima": lambda k: 2.5 if k < 3 else 2, "h-pico": lambda k: 9 if k == 0 else 1}
spans, logs = [], []
for host, usd in gasto.items():
    res = {"host.name": host, "service.name": "claude-code", "oute.agent": "claude"}
    calls = [claude_call(NOW - 3600 - k * 86400, 1, {"model": "claude-sonnet-5", "input_tokens": 10}, usd(k)) for k in range(10)]
    spans.append(rs(res, [s for s, _ in calls])); logs.append(rl(res, [l for _, l in calls]))
json.dump({"resourceSpans": spans}, open(f"{tmp}/traces3.json", "w"))
json.dump({"resourceLogs": logs}, open(f"{tmp}/logs3.json", "w"))
PY
studio_start "$TMP/s3" AGENT_STUDIO_CONFIG="$TMP/prices.toml" AGENT_STUDIO_READ_TOKEN="$READ" || die "agent-studio (custo por dia) não subiu"
check "custo por dia: ingestão do exemplo"             test "$(post traces "$TMP/traces3.json") $(post logs "$TMP/logs3.json")" = "200 200"
alto() { grep '^ANOMALIA	custo-alto' <<<"$OUT"; }
PICO_24='ANOMALIA	custo-alto	h-pico/claude	US$ 9 na janela (real + lista + estimado) = US$ 9/dia; base US$ 1/dia'
run studio
check "24 h: código 0"                                 [ "$RC" -eq 0 ]
check "24 h: gasto igual ao da base e pouco acima não disparam, o pico dispara" test "$(alto)" = "$PICO_24"
run studio --hours 72
check "72 h: código 0"                                 [ "$RC" -eq 0 ]
check "72 h: total da janela e base por dia na tabela" has "^h-acima	claude	3	3	0	0	7.5	-	-	0	30	1000	2$"
check "72 h: gasto igual ao da base e pouco acima não disparam, o pico dispara por dia" test "$(alto)" = "ANOMALIA	custo-alto	h-pico/claude	US\$ 11 na janela (real + lista + estimado) = US\$ 3.67/dia; base US\$ 1/dia"
run studio --hours 6
check "janela menor que 24 h conta como um dia (2 em 6 h contra 2/dia não dispara)" test "$(alto)" = "$PICO_24"
studio_stop

# ---------------------------------------------------------------- compose: o agent sabe onde ler
AGENT="$(compose_service agent)"
URL_LINE="$(grep '^      AGENT_STUDIO_URL: ' <<<"$AGENT")"
check "compose: agent com AGENT_STUDIO_URL vindo do oute up (rede docker no oute-server, vhost no Mac)" grep -q '^      AGENT_STUDIO_URL: ${AGENT_STUDIO_URL:-[^}]*agent-studio:8430}$' <<<"$URL_LINE"
check "compose: o mesmo endereço que o collector recebe" test "$URL_LINE" = "$(compose_service otel-collector | grep '^      AGENT_STUDIO_URL: ')"
check "compose: a credencial de leitura segue só no agent_env" bash -c '! grep -v "^ *#" <<<"$0" | grep -q "AGENT_STUDIO_READ_TOKEN"' "$AGENT"

check_end
