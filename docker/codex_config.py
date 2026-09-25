#!/usr/bin/env python3
"""Mescla as chaves gerenciadas pelo oute no ~/.codex/config.toml sem tocar no resto.

Uso: codex_config.py <config.toml> <environment> [yolo 1|0]

Por quê (bug da 0.5.3–0.5.7): o entrypoint editava o TOML com sed apagando intervalos entre
marcadores de texto; o ai-memory também edita o arquivo (mcp_servers, hooks) e a seção dele
acabava dentro do intervalo apagado -> Codex sem MCP e sem captura. Aqui a edição é estrutural
(tomlkit): só sandbox_mode e [otel] são nossos; o resto é preservado.
"""
import pathlib
import re
import sys

import tomlkit

path = pathlib.Path(sys.argv[1])
env = sys.argv[2]
yolo = (sys.argv[3] if len(sys.argv) > 3 else "1") == "1"
text = path.read_text() if path.exists() else ""
# migração: remove os blocos com marcadores gerados pelas versões <= 0.5.7
text = re.sub(r"(?ms)^# >>> oute (otel|sandbox).*?^# <<< oute \1[^\n]*\n?", "", text)
cfg = tomlkit.parse(text).unwrap()

# #5: bwrap precisa de user namespace, que o container não tem; o container é a fronteira (ADR-01)
cfg["sandbox_mode"] = "danger-full-access"
# yolo (ADR-01, adendo 2026-09-25): sem pedir aprovação dentro do container; OUTE_AGENT_YOLO=0 volta ao padrão do Codex
if yolo:
    cfg["approval_policy"] = "never"
else:
    cfg.pop("approval_policy", None)
# #13/#19: logs + traces -> otel-collector (conteúdo só no bucket; Langfuse recebe metadados)
cfg["otel"] = {
    "environment": env,
    "log_user_prompt": True,
    "exporter": {"otlp-http": {"endpoint": "http://otel-collector:4318/v1/logs", "protocol": "binary"}},
    "trace_exporter": {"otlp-http": {"endpoint": "http://otel-collector:4318/v1/traces", "protocol": "binary"}},
}

out = tomlkit.document()
out.add(tomlkit.comment("sandbox_mode, approval_policy e [otel]: gerenciados pelo entrypoint do oute-agent. Demais seções: ai-memory / usuário."))
for key, val in cfg.items():  # chaves soltas antes de qualquer tabela (senão caem dentro da última tabela)
    if not isinstance(val, dict):
        out.add(key, val)
for key, val in cfg.items():
    if isinstance(val, dict):
        out.add(key, val)

tmp = path.with_suffix(".toml.tmp")
tmp.write_text(tomlkit.dumps(out))
tmp.replace(path)
