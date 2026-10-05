#!/usr/bin/env python3
"""Dublê do servidor MCP `ai-memory` para o oute-regression (#484): fala o protocolo MCP por stdio (JSON por linha),
grava cada chamada de ferramenta (nome e argumentos) como uma linha JSON no arquivo dado em argv[1] e responde que deu
certo. Nada chega à memória de verdade. Só biblioteca padrão."""
import json
import sys

TOOLS = [
    ("memory_write_page", "Grava uma página de memória."),
    ("memory_query", "Consulta a memória."),
    ("memory_recent", "Lista as páginas recentes."),
    ("memory_status", "Estado da memória."),
]
SCHEMA = {"type": "object", "additionalProperties": True}


def reply(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


def main():
    log = sys.argv[1]
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method, msg_id = msg.get("method"), msg.get("id")
        if msg_id is None:
            continue  # notificação (ex.: notifications/initialized): sem resposta
        if method == "initialize":
            version = (msg.get("params") or {}).get("protocolVersion", "2025-06-18")
            reply(msg_id, {"protocolVersion": version, "capabilities": {"tools": {}},
                           "serverInfo": {"name": "ai-memory", "version": "regression-double"}})
        elif method == "tools/list":
            reply(msg_id, {"tools": [{"name": n, "description": d, "inputSchema": SCHEMA} for n, d in TOOLS]})
        elif method == "tools/call":
            params = msg.get("params") or {}
            with open(log, "a") as f:
                f.write(json.dumps({"tool": params.get("name"), "args": params.get("arguments") or {}}) + "\n")
            reply(msg_id, {"content": [{"type": "text", "text": "ok (dublê do oute-regression)"}], "isError": False})
        elif method == "ping":
            reply(msg_id, {})
        else:
            reply(msg_id, error={"code": -32601, "message": "método desconhecido"})


if __name__ == "__main__":
    main()
