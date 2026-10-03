#!/usr/bin/env bash
# `oute-quota` falso (#355): copie ou linke com esse nome num diretório do PATH. Serve ao oute-select (gatilho `cota`).
#   imprime o conteúdo de $FAKE/quota.json (o JSON do `oute-quota --json`; sem o arquivo, uma cota folgada nos dois), grava os
#   argumentos em $FAKE/quota.args (uma linha por chamada), espera $FAKE_QUOTA_SLEEP s (padrão 0) e sai com $FAKE_QUOTA_RC (padrão 0)
echo "$*" >> "$FAKE/quota.args"
[[ "${FAKE_QUOTA_SLEEP:-0}" == 0 ]] || sleep "$FAKE_QUOTA_SLEEP"
if [[ -f "$FAKE/quota.json" ]]; then cat "$FAKE/quota.json"; else
  W='{"status":"ok","reason":null,"stale":false,"age_s":0,"windows":{"5h":{"used_pct":10,"resets_at":"2030-01-01T00:00:00Z","resets_in_s":9000},"7d":{"used_pct":10,"resets_at":"2030-01-05T00:00:00Z","resets_in_s":300000}}}'
  printf '{"schema":1,"max_pct":90,"reset_grace_s":1200,"agents":{"claude":%s,"codex":%s}}\n' "$W" "$W"
fi
exit "${FAKE_QUOTA_RC:-0}"
