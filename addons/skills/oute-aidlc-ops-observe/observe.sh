#!/usr/bin/env bash
# Leitura da telemetria (ADR-04 e ADR-08, #108 e #259): agent-studio (GET /v1/usage e GET /v1/alerts, agregados)
# + bucket oute-observability (listagem e uma allowlist de chaves de metadados). Só leitura: nada é escrito no
# agent-studio nem no bucket. Nenhum valor de conteúdo (prompt, resposta, comando, e-mail) sai daqui.
# Segredos só pelo ambiente: AGENT_STUDIO_READ_TOKEN, a credencial de leitura (o curl a lê pelo stdin, fora do
# argv), com AGENT_STUDIO_URL (rede docker no oute-server, vhost da tailnet no Mac), e o remote "oci" do rclone
# (RCLONE_CONFIG_OCI_*, montado pelo entrypoint). OUTE_OBS_BUCKET troca o remote:bucket (padrão oci:oute-observability).
#
# Uso: observe.sh [studio|bucket|all] [--hours N] [--content-hours N] [--baseline-days N]
#   --hours N          janela do resumo (padrão 24)
#   --content-hours N  quanto do bucket baixar para ler metadados (padrão 6; 0 = só listagem)
#   --baseline-days N  dias anteriores à janela usados como base de comparação (padrão 7; 0 = sem base)
# Saída: seções em TSV; linhas "ANOMALIA<TAB>…" resumem o que chamou atenção e "ALERTA<TAB>…" são os alertas do
# pipeline. Código 0 mesmo com anomalias; != 0 só quando uma fonte não pôde ser lida (a linha "ERRO" diz qual).
set -euo pipefail

MODE=all; HOURS=24; CHOURS=6; BDAYS=7
while [[ $# -gt 0 ]]; do
  case "$1" in
    studio|bucket|all) MODE="$1" ;;
    --hours) HOURS="$2"; shift ;;
    --content-hours) CHOURS="$2"; shift ;;
    --baseline-days) BDAYS="$2"; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "observe: argumento desconhecido: $1" >&2; exit 2 ;;
  esac
  shift
done
for n in "$HOURS" "$CHOURS" "$BDAYS"; do [[ "$n" =~ ^[0-9]+$ ]] || { echo "observe: número inválido: $n" >&2; exit 2; }; done
[[ "$HOURS" -gt 0 ]] || { echo "observe: --hours precisa ser > 0" >&2; exit 2; }

STUDIO="${AGENT_STUDIO_URL:-}"; STUDIO="${STUDIO%/}"
BUCKET="${OUTE_OBS_BUCKET:-oci:oute-observability}/otel"
NOW="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
W_FROM="$(iso $((NOW - HOURS * 3600)))"; W_TO="$(iso "$NOW")"
B_FROM="$(iso $((NOW - HOURS * 3600 - BDAYS * 86400)))"
RC=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT  # lotes baixados do bucket vivem só aqui

# agentes esperados neste host: OUTE_AGENTS (claude-code,codex) no vocabulário do oute.agent; o Pi saiu (#217)
expected() {
  local a; IFS=',' read -r -a list <<<"${OUTE_AGENTS:-}"
  for a in ${list[@]+"${list[@]}"}; do [[ "$a" == pi ]] && continue; [[ "$a" == claude-code ]] && a=claude; printf '%s\n' "$a"; done
}

# ---------------------------------------------------------------- agent-studio (GET /v1/usage e /v1/alerts)
# studio_get <caminho?query> <arquivo>: a credencial de leitura vai pelo stdin do curl (-K -), nunca no argv.
# Falha (rede, HTTP != 200, corpo que não é objeto JSON) = código 1, com o motivo em STUDIO_WHY (sem o corpo).
studio_get() {
  local code tok="${AGENT_STUDIO_READ_TOKEN//\\/\\\\}"; tok="${tok//\"/\\\"}"
  code="$(curl -sS --max-time 60 -o "$2" -w '%{http_code}' -K - "$STUDIO$1" 2>"$2.err" \
    <<<"header = \"Authorization: Bearer $tok\"")" \
    || { STUDIO_WHY="$(sed 's/^curl: ([0-9]*) //' "$2.err" | tr '\n' ' ' | head -c 200)"; return 1; }
  [[ "$code" == 200 ]] || { STUDIO_WHY="HTTP $code"; return 1; }
  jq -e 'type == "object"' "$2" >/dev/null 2>&1 || { STUDIO_WHY="a resposta não é um objeto JSON"; return 1; }
}

studio() {
  echo "## agent-studio (${STUDIO:-sem URL}) · janela $W_FROM → $W_TO · base $BDAYS dia(s) antes"
  [[ -n "$STUDIO" ]] || { echo "ERRO	AGENT_STUDIO_URL ausente no ambiente (compose do agent; oute down/up)"; return 1; }
  [[ -n "${AGENT_STUDIO_READ_TOKEN:-}" ]] \
    || { echo "ERRO	AGENT_STUDIO_READ_TOKEN ausente no ambiente (item agent-studio da pasta oute-agent do vault)"; return 1; }
  local tmp="$TMP/st"; mkdir -p "$tmp"
  studio_get "/v1/usage?from=$W_FROM&to=$W_TO" "$tmp/win" || { echo "ERRO	/v1/usage da janela ilegível: $STUDIO_WHY"; return 1; }
  if [[ "$BDAYS" -gt 0 ]]; then
    studio_get "/v1/usage?from=$B_FROM&to=$W_FROM" "$tmp/base" || { echo "ERRO	/v1/usage da base ilegível: $STUDIO_WHY"; return 1; }
  else
    echo '{"rows":[],"series":[]}' >"$tmp/base"
  fi
  studio_get "/v1/alerts" "$tmp/alerts" || { echo "ERRO	/v1/alerts ilegível: $STUDIO_WHY"; return 1; }
  echo "### por host × agente, na janela"
  # o /v1/usage devolve host × agente × modelo: aqui soma por host × agente (p95 = o maior entre os modelos).
  # custo real (veio na chamada) e estimado (tabela de preços) nunca se somam numa coluna; "-" = nenhuma chamada.
  # base por dia = custo da base ÷ dias da base que têm algum dado (a base pode ser mais nova que --baseline-days).
  # custo-alto compara por dia dos dois lados (#298): custo da janela ÷ dias da janela (--hours ÷ 24) contra a base
  # por dia. Janela menor que 24 h conta como um dia: uma hora de uso não vira a taxa de um dia inteiro.
  jq -r --slurpfile base "$tmp/base" --argjson hours "$HOURS" '
    def sumc(f): map(f | select(. != null)) | if length == 0 then null else add end;
    def usd: if . == null then "-" else (. * 10000 | round / 10000) end;
    def by_ha: group_by([.host // "?", .agent // "?"])
      | map({host: (.[0].host // "?"), agent: (.[0].agent // "?"), calls: (map(.calls) | add), spans: (map(.spans) | add),
             span_err: (map(.errors.spans) | add), log_err: (map(.errors.logs) | add),
             real: sumc(.cost.real_usd), est: sumc(.cost.estimated_usd), unpriced: (map(.cost.unpriced_calls) | add),
             tok: (map(.tokens | add) | add), p95: (map(.latency_p95_ms | select(. != null)) | max)}
            | . + {cost: ((.real // 0) + (.est // 0)), key: "\(.host)/\(.agent)"});
    ([$base[0].series[].day] | unique | length | if . == 0 then 1 else . end) as $bdays
    | ($hours / 24 | if . < 1 then 1 else . end) as $wdays
    | ($base[0].rows | by_ha| map({key, value: .}) | from_entries) as $b
    | (.rows | by_ha) as $w
    | (["host","agente","chamadas","spans","erros_span","erros_log","custo_real_usd","custo_estimado_usd","sem_preço","tokens","p95_ms","base_custo_usd/dia"] | @tsv),
      ($w[] | [.host, .agent, .calls, .spans, .span_err, .log_err, (.real | usd), (.est | usd), .unpriced, .tok,
               (.p95 | if . == null then "-" else round end), ((($b[.key].cost // 0) / $bdays) | usd)] | @tsv),
      ( # anomalias (custo-alto só com uso na base: sem histórico não há o que comparar)
        ($w[] | select(.span_err >= 5 and .span_err / .spans > 0.05)
              | ["ANOMALIA","erro-alto",.key,"\(.span_err) de \(.spans) spans com erro"] | @tsv),
        ($w[] | ($b[.key] // {cost: 0, calls: 0, spans: 0}) as $x
              | select(.cost > 1 and ($x.calls + $x.spans) > 0 and .cost / $wdays > 3 * $x.cost / $bdays)
              | ["ANOMALIA","custo-alto",.key,"US$ \(.cost*100|round/100) na janela (real + estimado) = US$ \(.cost/$wdays*100|round/100)/dia; base US$ \($x.cost/$bdays*100|round/100)/dia"] | @tsv),
        # pi e router: só em registro até 2026-09-30 (#217, #218); a falta deles não é anomalia
        ($b | to_entries[] | select((.value.calls + .value.spans) > 0 and (.value.agent | IN("pi", "router") | not)) | .key as $k
              | select([$w[].key] | index($k) | not)
              | ["ANOMALIA","sem-telemetria",$k,"\(.value.calls) chamadas e \(.value.spans) spans na base e nada na janela"] | @tsv),
        (.rows[] | select(.cost.unpriced_calls > 0)
              | ["ANOMALIA","sem-preço","\(.host // "?")/\(.agent // "?")","\(.cost.unpriced_calls) chamadas de \(.model // "(sem modelo)") sem custo real e sem preço (config/agent-studio/config.toml)"] | @tsv)
      ),
      "### custo por modelo, na janela",
      (["host","modelo","chamadas","custo_real_usd","custo_estimado_usd","sem_preço"] | @tsv),
      (.rows | map(select(.calls > 0)) | group_by([.host // "?", .model // "(sem modelo)"])
        | map({host: (.[0].host // "?"), model: (.[0].model // "(sem modelo)"), calls: (map(.calls) | add),
               real: sumc(.cost.real_usd), est: sumc(.cost.estimated_usd), unpriced: (map(.cost.unpriced_calls) | add)})
        | sort_by(-((.real // 0) + (.est // 0)))[]
        | [.host, .model, .calls, (.real | usd), (.est | usd), .unpriced] | @tsv),
      ((.prices.errors // [])[] | ["AVISO","config","\(.)"] | @tsv)
    ' "$tmp/win" || { echo "ERRO	resumo do /v1/usage falhou"; return 1; }
  echo "### alertas do pipeline (agora)"
  jq -r '
    "alertas_ativos\t\(.alerts | length)",
    (["ALERTA","tipo","host","instância","valor","unidade","limite","desde","detalhe"] | @tsv),
    (.alerts[] | ["ALERTA", .type, (.host // "-"), (.instance // "-"), (.value // "-"), (.unit // "-"), (.limit // "-"),
                  (.since // "-"), (.evidence | (.exporter // .attribute // .note // "-") | tostring)] | @tsv),
    ((.config.errors // [])[] | ["AVISO","config","\(.)"] | @tsv),
    "### último dado por host (agent-studio)",
    (["host","sempre_ligado","último_dado_utc","parado_há_s"] | @tsv),
    (.hosts[] | [.host, .always_on, (.last_data // "-"), (.idle_seconds // "-")] | @tsv)
    ' "$tmp/alerts" || { echo "ERRO	resumo do /v1/alerts falhou"; return 1; }
}

# ---------------------------------------------------------------- bucket (listagem + allowlist)
# motivo da falha do rclone, sem o NOTICE de "rclone.conf not found" (o remote vem do ambiente)
rclone_err() { grep -v 'rclone.conf" not found' "$TMP/b/err" | sed 's/^[0-9/]* [0-9:]* //' | tr '\n' ' ' | head -c 300; }
bucket() {
  echo "## Bucket ($BUCKET) · listagem $HOURS h + base $BDAYS dia(s) · metadados das últimas $CHOURS h"
  local tmp="$TMP/b" s; mkdir -p "$tmp"
  for s in traces logs metrics; do
    rclone lsjson -R --files-only --max-age "$((HOURS + BDAYS * 24))h" "$BUCKET/$s/" >"$tmp/ls" 2>"$tmp/err" \
      || { echo "ERRO	listagem de $s falhou: $(rclone_err)"; return 1; }
    jq -c --arg s "$s" '.[] | {s: $s, path: .Path, size: .Size, t: (.ModTime | sub("\\.[0-9]+"; "") | sub("(?<z>[+-][0-9]{2}):(?<m>[0-9]{2})$"; "\(.z)\(.m)") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime)}' \
      "$tmp/ls" >>"$tmp/list" || { echo "ERRO	listagem de $s ilegível"; return 1; }
  done
  touch "$tmp/list"
  echo "### último lote por sinal × host × instância"
  jq -rs --argjson now "$NOW" --argjson wfrom "$((NOW - HOURS * 3600))" '
    map(. + (.path | capture("^host=(?<host>[^/]+)/instance=(?<inst>[^/]+)/") // {host: "(legado)", inst: "-"}))
    | group_by([.s, .host, .inst])
    | map({s: .[0].s, host: .[0].host, inst: .[0].inst, last: (map(.t) | max),
           n: (map(select(.t >= $wfrom)) | length), bytes: (map(select(.t >= $wfrom) | .size) | add // 0)}) as $g
    | (["sinal","host","instância","último_lote_utc","idade_min","lotes_janela","bytes_janela"] | @tsv),
      ($g[] | [.s, .host, .inst, (.last | todate), (($now - .last) / 60 | floor), .n, .bytes] | @tsv),
      ($g[] | select(.host != "(legado)" and .n == 0)
            | ["ANOMALIA","sem-telemetria","\(.host)/\(.inst)/\(.s)","nenhum lote na janela; último em \(.last | todate)"] | @tsv),
      ($g | map(select(.host != "(legado)" and .n > 0)) | group_by([.host, .inst])[]
            | select(length < 3) | ["ANOMALIA","sinal-faltando","\(.[0].host)/\(.[0].inst)",
                "só \(map(.s) | join(",")) na janela (esperado traces, logs e metrics)"] | @tsv)
    ' "$tmp/list" || { echo "ERRO	resumo da listagem falhou"; return 1; }
  [[ "$CHOURS" -gt 0 ]] || return 0
  # conteúdo: baixa só os lotes recentes para uma pasta temporária (apagada ao sair) e lê só as chaves abaixo
  for s in traces logs; do
    rclone copy --max-age "${CHOURS}h" --include '*.json.gz' "$BUCKET/$s/" "$tmp/$s" 2>"$tmp/err" \
      || { echo "ERRO	download de $s falhou: $(rclone_err)"; return 1; }
  done
  echo "### metadados por host × agente (últimas $CHOURS h)"
  {
    find "$tmp/traces" -name '*.json.gz' -exec gunzip -c {} + 2>/dev/null | jq -c '
      def v: .value | (.stringValue // .intValue // .doubleValue // .boolValue);
      def attr($k): (map(select(.key == $k))[0] | v?) // null;
      .resourceSpans[]? | (.resource.attributes // []) as $r
      | .scopeSpans[]?.spans[]? | (.attributes // []) as $a
      | {host: ($r | attr("host.name") // "?"), agent: ($a | attr("oute.agent") // ($r | attr("oute.agent")) // "?"),
         spans: 1, span_err: (if (.status.code == 2 or .status.code == "STATUS_CODE_ERROR") then 1 else 0 end),
         cost: (($a | attr("oute.cost_usd")) // 0 | tonumber? // 0), logs: 0, log_err: 0}'
    find "$tmp/logs" -name '*.json.gz' -exec gunzip -c {} + 2>/dev/null | jq -c '
      def v: .value | (.stringValue // .intValue // .doubleValue // .boolValue);
      def attr($k): (map(select(.key == $k))[0] | v?) // null;
      .resourceLogs[]? | (.resource.attributes // []) as $r
      | .scopeLogs[]?.logRecords[]? | (.attributes // []) as $a | ($a | attr("event.name") // "") as $ev
      | {host: ($r | attr("host.name") // "?"), agent: ($r | attr("oute.agent") // "?"), spans: 0, span_err: 0,
         cost: (if $ev == "api_request" then (($a | attr("cost_usd")) // 0 | tonumber? // 0) else 0 end), logs: 1,
         log_err: (if ((.severityNumber // 0) >= 17 or ($ev | test("error"; "i"))) then 1 else 0 end)}'
  } | jq -rs --arg exp "$(expected | paste -sd, -)" --arg me "${OUTE_HOST:-}" '
    group_by([.host, .agent])
    | map({host: .[0].host, agent: .[0].agent, spans: (map(.spans) | add), span_err: (map(.span_err) | add),
           logs: (map(.logs) | add), log_err: (map(.log_err) | add), cost: (map(.cost) | add)}) as $g
    | (["host","agente","spans","spans_erro","logs","logs_erro","custo_usd(lista)"] | @tsv),
      ($g[] | [.host, .agent, .spans, .span_err, .logs, .log_err, (.cost*10000|round/10000)] | @tsv),
      ($g[] | select(.log_err >= 5 and .log_err / .logs > 0.05)
            | ["ANOMALIA","erro-alto","\(.host)/\(.agent)","\(.log_err) de \(.logs) logs de erro"] | @tsv),
      ($g[] | select(.agent == "?")
            | ["ANOMALIA","sem-oute.agent","\(.host)","\(.spans + .logs) registros sem oute.agent (service.name fora do transform/agent?)"] | @tsv),
      (if $me != "" then ($exp | split(",") | map(select(. != ""))[]) as $a
         | select([$g[] | select(.host == $me) | .agent] | index($a) | not)
         | ["ANOMALIA","agente-sem-telemetria","\($me)/\($a)","em OUTE_AGENTS, sem registro no bucket nas últimas horas lidas (ocioso ou quebrado?)"] | @tsv
       else empty end)' || { echo "ERRO	leitura dos metadados do bucket falhou"; return 1; }
}

case "$MODE" in
  studio) studio || RC=1 ;;
  bucket) bucket || RC=1 ;;
  all)    studio || RC=1; echo; bucket || RC=1 ;;
esac
exit "$RC"
