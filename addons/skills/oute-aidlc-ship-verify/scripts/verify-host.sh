#!/usr/bin/env bash
# verify-host.sh — verificação pós-deploy de UM host (oute-server ou Mac), só leitura (#107).
# Não roda sozinho: o agente manda este texto pelo canal de aprovação, com a versão esperada na frente:
#   { printf 'EXPECTED=%q\n' 0.7.26; cat verify-host.sh; } | oute-propose "ship: verificar deploy v0.7.26"
# Roda como o usuário do host (sem --root). Confere: versão (repo e imagem rodando), serviços do compose
# (com oute-agent-studio e oute-surrealdb onde o profile agent-studio está ligado, ADR-08) e PRESENÇA de telemetria recente no bucket oute-observability. Análise da telemetria não é daqui.
# Saída: uma linha por item (OK | AVISO | FALHA) e um resumo. Código 1 se houver FALHA.
# bash 3.2 (macOS): sem mapfile, sem timeout, sem ${v,,}.
set -euo pipefail

EXPECTED="${EXPECTED:-}"
WINDOW_MIN="${WINDOW_MIN:-60}"   # janela da telemetria (minutos)
SERVICES="oute-agent oute-ai-memory oute-otel-collector"
STUDIO_SERVICES="oute-agent-studio oute-surrealdb"   # profile agent-studio do compose (ADR-08): só no oute-server
nfail=0; nwarn=0
ok()   { printf 'OK     %s\n' "$*"; }
warn() { nwarn=$((nwarn + 1)); printf 'AVISO  %s\n' "$*"; }
fail() { nfail=$((nfail + 1)); printf 'FALHA  %s\n' "$*"; }

echo "== verificação pós-deploy: host $(hostname), esperado ${EXPECTED:-<não informado>}"

# --- oute do host: PATH, link do `oute install` ou checkout padrão
OUTE_BIN="${OUTE_BIN:-}"
if [[ -z "$OUTE_BIN" ]]; then
  for c in "$(command -v oute 2>/dev/null || true)" "$HOME/.local/bin/oute" "$HOME/bin/oute" "$HOME/oute-agent/scripts/oute"; do
    [[ -n "$c" && -x "$c" ]] && { OUTE_BIN="$c"; break; }
  done
fi
[[ -n "$OUTE_BIN" ]] || { fail "não achei o comando oute (PATH, ~/.local/bin, ~/oute-agent/scripts)"; echo "== resumo: $nfail falha(s), $nwarn aviso(s)"; exit 1; }
command -v docker >/dev/null 2>&1 || { fail "docker fora do PATH"; echo "== resumo: $nfail falha(s), $nwarn aviso(s)"; exit 1; }

# profile agent-studio ligado neste host? Mesma regra do `oute up`: OUTE_AGENT_STUDIO=1 no ambiente ou no .env do
# checkout (achado pelo link do `oute install`; sem readlink -f, que o macOS antigo não tem)
studio_on() {
  local v="${OUTE_AGENT_STUDIO:-}" src="$OUTE_BIN" dir
  if [[ -z "$v" ]]; then
    while [[ -L "$src" ]]; do dir="$(cd "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"; [[ "$src" == /* ]] || src="$dir/$src"; done
    dir="$(cd "$(dirname "$src")/.." 2>/dev/null && pwd)" || return 1
    v="$(sed -n 's/^[[:space:]]*OUTE_AGENT_STUDIO=//p' "$dir/.env" 2>/dev/null | sed "s/[[:space:]]*#.*//; s/^[\"']//; s/[\"']\$//" | tail -1)"
  fi
  [[ "$v" == 1 ]]
}

# --- 1. versão
echo "-- versão"
ver_out="$("$OUTE_BIN" version 2>&1)" || true
printf '%s\n' "$ver_out" | sed 's/^/       /'
repo_ver="$(printf '%s\n' "$ver_out" | sed -n 's/^repo: *\([^ ]*\).*/\1/p' | head -1)"
run_ver="$(printf '%s\n' "$ver_out" | sed -n 's/^running: *//p' | head -1)"
origin_host="$(printf '%s\n' "$ver_out" | sed -n 's/^origem:.*host=\([^ ]*\).*/\1/p' | head -1)"
origin_inst="$(printf '%s\n' "$ver_out" | sed -n 's/^origem:.*instance=\([^ ]*\).*/\1/p' | head -1)"
if [[ -z "$EXPECTED" ]]; then
  warn "EXPECTED não informado: só comparo repo × imagem rodando"
  EXPECTED="$repo_ver"
fi
if [[ "$repo_ver" == "$EXPECTED" ]]; then ok "repo em $repo_ver"; else fail "repo em '${repo_ver:-?}', esperado $EXPECTED (faltou git pull --tags?)"; fi
if [[ "$run_ver" == "$EXPECTED" ]]; then ok "imagem rodando $run_ver"; else fail "imagem rodando '${run_ver:-?}', esperado $EXPECTED (faltou oute pull + down/up?)"; fi

# --- 2. serviços
echo "-- serviços"
if studio_on; then SERVICES="$SERVICES $STUDIO_SERVICES"
else echo "       profile agent-studio desligado neste host: $STUDIO_SERVICES não conferidos"; fi
for s in $SERVICES; do
  st="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.Config.Image}}' "$s" 2>/dev/null)" \
    || { fail "$s: container não existe"; continue; }
  IFS='|' read -r status health restarts started image <<EOF
$st
EOF
  info="$image, desde $started, restarts=$restarts${health:+, health=$health}"
  if [[ "$status" != running ]]; then fail "$s: $status ($info)"
  elif [[ -n "$health" && "$health" != healthy ]]; then fail "$s: health=$health ($info)"
  elif [[ "$restarts" != 0 ]]; then warn "$s: rodando, mas reiniciou $restarts vez(es) ($info)"
  else ok "$s: running ($info)"; fi
done
# volume-init é one-shot: tem que ter saído com 0
vi="$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}' oute-volume-init 2>/dev/null || echo 'ausente|-')"
case "$vi" in
  exited\|0) ok "oute-volume-init: saiu com 0" ;;
  *) warn "oute-volume-init: $vi (esperado exited|0)" ;;
esac

# --- 3. telemetria: só PRESENÇA de objetos recentes no bucket (ADR-04). Análise: oute-aidlc-ops-observe.
echo "-- telemetria (últimos ${WINDOW_MIN} min, bucket oute-observability)"
if [[ -z "$origin_host" || -z "$origin_inst" ]]; then
  fail "origem (host/instance) não saiu no oute version; não sei qual partição olhar"
elif ! command -v rclone >/dev/null 2>&1; then
  warn "rclone ausente no host: não conferi o bucket"
else
  any=0
  for sig in traces metrics logs; do
    prefix="otel/$sig/host=$origin_host/instance=$origin_inst"
    # `oute storage <sub> <path> <args…>` = rclone <sub> oci:$OUTE_BUCKET/<path> <args…> (credencial do agent.env)
    if ! list="$(OUTE_BUCKET=oute-observability "$OUTE_BIN" storage lsf "$prefix" --recursive --files-only --max-age "${WINDOW_MIN}m" 2>/dev/null)"; then
      warn "$sig: não consegui listar $prefix"; continue
    fi
    n="$(printf '%s' "$list" | grep -c . || true)"
    if [[ "$n" -gt 0 ]]; then ok "$sig: $n objeto(s) novo(s) em $prefix"; any=1
    else warn "$sig: nenhum objeto novo em $prefix"; fi
  done
  [[ $any == 1 ]] || fail "nenhuma telemetria nova do host=$origin_host instance=$origin_inst em ${WINDOW_MIN} min"
fi
# erros de exportação do collector desde que subiu (só contagem + as últimas linhas)
errs="$(docker logs --since "${WINDOW_MIN}m" oute-otel-collector 2>&1 | grep -Ei '"?level"?[:=]"?error|	error	|exporting failed|dropping data' || true)"
if [[ -n "$errs" ]]; then
  warn "otel-collector: $(printf '%s\n' "$errs" | grep -c .) linha(s) de erro em ${WINDOW_MIN} min; últimas:"
  printf '%s\n' "$errs" | tail -n 5 | cut -c1-300 | sed 's/^/       /'
else
  ok "otel-collector: sem erro de exportação no log em ${WINDOW_MIN} min"
fi

echo "== resumo: $nfail falha(s), $nwarn aviso(s)"
[[ $nfail -eq 0 ]]
