#!/usr/bin/env bash
# Leitura da telemetria do ADR-04 (#108): Langfuse (métricas agregadas, só metadados) + bucket
# oute-observability (listagem e uma allowlist de chaves de metadados). Só leitura: nada é escrito
# no Langfuse nem no bucket. Nenhum valor de conteúdo (prompt, resposta, comando, e-mail) sai daqui.
# Segredos só pelo ambiente: LANGFUSE_PUBLIC_KEY/LANGFUSE_SECRET_KEY (curl lê pelo stdin, fora do argv)
# e o remote "oci" do rclone (RCLONE_CONFIG_OCI_*, montado pelo entrypoint). OUTE_OBS_BUCKET troca o
# remote:bucket (padrão oci:oute-observability).
#
# Uso: observe.sh [langfuse|bucket|all] [--hours N] [--content-hours N] [--baseline-days N]
#   --hours N          janela do resumo (padrão 24)
#   --content-hours N  quanto do bucket baixar para ler metadados (padrão 6; 0 = só listagem)
#   --baseline-days N  dias anteriores à janela usados como base de comparação (padrão 7)
# Saída: seções em TSV; linhas "ANOMALIA<TAB>…" resumem o que chamou atenção. Código 0 mesmo com
# anomalias; != 0 só quando uma fonte não pôde ser lida (a seção diz qual).
set -euo pipefail

MODE=all; HOURS=24; CHOURS=6; BDAYS=7
while [[ $# -gt 0 ]]; do
  case "$1" in
    langfuse|bucket|all) MODE="$1" ;;
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

LF="${LANGFUSE_HOST:-https://cloud.langfuse.com}"
BUCKET="${OUTE_OBS_BUCKET:-oci:oute-observability}/otel"
AGENTS=(claude codex router unknown)
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

# ---------------------------------------------------------------- Langfuse (API v2 de métricas)
lf_metrics() {  # lf_metrics <query json>: a credencial vai pelo stdin (-K -), nunca no argv
  curl -sS --fail-with-body --max-time 60 -G -K - "$LF/api/public/v2/metrics" \
    --data-urlencode "query=$1" <<<"user = \"$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY\""
}
lf_query() {  # lf_query <agente> <from> <to> <timeDimension json ou "">
  local td=""; [[ -n "$4" ]] && td=",\"timeDimension\":$4"
  lf_metrics "{\"view\":\"observations\",\"dimensions\":[{\"field\":\"environment\"},{\"field\":\"level\"}],\"metrics\":[{\"measure\":\"count\",\"aggregation\":\"count\"},{\"measure\":\"totalCost\",\"aggregation\":\"sum\"},{\"measure\":\"totalTokens\",\"aggregation\":\"sum\"},{\"measure\":\"latency\",\"aggregation\":\"p95\"}],\"filters\":[{\"column\":\"metadata\",\"operator\":\"=\",\"key\":\"agent\",\"value\":\"$1\",\"type\":\"stringObject\"}],\"fromTimestamp\":\"$2\",\"toTimestamp\":\"$3\"$td}" \
    | jq -c --arg a "$1" '.data[] | . + {agent: $a}'
}

langfuse() {
  echo "## Langfuse ($LF) · janela $W_FROM → $W_TO · base $BDAYS dia(s) antes"
  if [[ -z "${LANGFUSE_PUBLIC_KEY:-}" || -z "${LANGFUSE_SECRET_KEY:-}" ]]; then
    echo "ERRO	LANGFUSE_PUBLIC_KEY/LANGFUSE_SECRET_KEY ausentes no ambiente (item langfuse do vault)"; return 1
  fi
  local tmp="$TMP/lf" a; mkdir -p "$tmp"
  for a in "${AGENTS[@]}"; do
    lf_query "$a" "$W_FROM" "$W_TO" "" >>"$tmp/win" || { echo "ERRO	consulta da janela ($a) falhou"; return 1; }
    lf_query "$a" "$B_FROM" "$W_FROM" '{"granularity":"day"}' >>"$tmp/base" || { echo "ERRO	consulta da base ($a) falhou"; return 1; }
  done
  touch "$tmp/win" "$tmp/base"
  echo "### por host (environment) × agente, na janela"
  # base por dia = soma da base ÷ dias da base que têm algum dado (a base pode ser mais nova que --baseline-days);
  # "production" é o environment dos traces anteriores à 0.7.5 (sem host.name): fica na tabela, fora das anomalias
  jq -rs --slurpfile base <(jq -s . "$tmp/base") '
    def n: (. // 0) | tonumber;
    ([$base[0][].time_dimension] | unique | length | if . == 0 then 1 else . end) as $bdays
    | ($base[0] | group_by([.environment, .agent]) | map({key: "\(.[0].environment)/\(.[0].agent)",
       value: {obs: (map(.count_count|n) | add), cost: (map(.sum_totalCost|n) | add)}}) | from_entries) as $b
    | group_by([.environment, .agent])
    | map({env: .[0].environment, agent: .[0].agent,
           obs: (map(.count_count|n) | add), err: (map(select(.level=="ERROR") | .count_count|n) | add // 0),
           cost: (map(.sum_totalCost|n) | add), tok: (map(.sum_totalTokens|n) | add),
           p95: (map(.p95_latency|n) | max)}) as $w
    | (["host","agente","observações","erros","custo_usd","tokens","p95_ms","base_custo_usd/dia"] | @tsv),
      ($w[] | [.env, .agent, .obs, .err, (.cost*10000|round/10000), .tok, (.p95|round),
               (($b["\(.env)/\(.agent)"].cost // 0) / $bdays * 10000 | round / 10000)] | @tsv),
      ( # anomalias (custo-alto só com uso na base: sem histórico não há o que comparar; uso sem custo ainda compara)
        ($w[] | select(.err >= 5 and .err / .obs > 0.05)
              | ["ANOMALIA","erro-alto","\(.env)/\(.agent)","\(.err) de \(.obs) observações com level=ERROR"] | @tsv),
        ($w[] | ($b["\(.env)/\(.agent)"].cost // 0) as $bc | select(.cost > 1 and ($b["\(.env)/\(.agent)"].obs // 0) > 0 and .cost > 3 * $bc / $bdays)
              | ["ANOMALIA","custo-alto","\(.env)/\(.agent)","US$ \(.cost*100|round/100) na janela; base US$ \($bc/$bdays*100|round/100)/dia"] | @tsv),
        ($w[] | select(.agent == "unknown")
              | ["ANOMALIA","agente-unknown","\(.env)","\(.obs) observações de cliente do router sem X-Oute-Agent"] | @tsv),
        ($b | to_entries[] | select(.value.obs > 0 and (.key | startswith("production/") | not)) | .key as $k
              | select([$w[] | "\(.env)/\(.agent)"] | index($k) | not)
              | ["ANOMALIA","sem-telemetria","\($k)","\(.value.obs) observações na base e nenhuma na janela"] | @tsv)
      )' "$tmp/win" || { echo "ERRO	resumo do Langfuse falhou"; return 1; }
  echo "### custo por modelo, na janela"
  lf_metrics "{\"view\":\"observations\",\"dimensions\":[{\"field\":\"environment\"},{\"field\":\"providedModelName\"}],\"metrics\":[{\"measure\":\"count\",\"aggregation\":\"count\"},{\"measure\":\"totalCost\",\"aggregation\":\"sum\"}],\"filters\":[],\"fromTimestamp\":\"$W_FROM\",\"toTimestamp\":\"$W_TO\"}" \
    | jq -r '(["host","modelo","observações","custo_usd"] | @tsv),
             (.data | map(select(.providedModelName != null)) | sort_by(-(.sum_totalCost // 0))[]
              | [.environment, .providedModelName, .count_count, ((.sum_totalCost // 0)*10000|round/10000)] | @tsv)' \
    || { echo "ERRO	consulta por modelo falhou"; return 1; }
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
  langfuse) langfuse || RC=1 ;;
  bucket)   bucket   || RC=1 ;;
  all)      langfuse || RC=1; echo; bucket || RC=1 ;;
esac
exit "$RC"
