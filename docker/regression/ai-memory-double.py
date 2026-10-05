#!/usr/bin/env python3
"""Dublê do servidor MCP `ai-memory` para o oute-regression (#484): fala o protocolo MCP por stdio (JSON por linha),
grava cada chamada de ferramenta (nome e argumentos) como uma linha JSON em `memory.log`, na pasta de trabalho do
processo, e responde que deu certo. Nada chega à memória de verdade. Só biblioteca padrão."""
import json
import sys

TOOLS = [
    ("memory_write_page", "Grava uma página de memória."),
    ("memory_query", "Consulta a memória."),
    ("memory_recent", "Lista as páginas recentes."),
    ("memory_status", "Estado da memória."),
]
LOG_NAME = "memory.log"  # nome fixo, na pasta de trabalho do processo (o oute-regression entra na pasta do pedido antes)
SCHEMA = {"type": "object", "additionalProperties": True}


def reply(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
    return out


def handle(msg):
    """Responde a uma requisição (mensagem com id); devolve None para notificação."""
    method, msg_id = msg.get("method"), msg.get("id")
    if msg_id is None:
        return None  # notificação (ex.: notifications/initialized): sem resposta
    params = msg.get("params") or {}
    if method == "initialize":
        return reply(msg_id, {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                              "capabilities": {"tools": {}},
                              "serverInfo": {"name": "ai-memory", "version": "regression-double"}})
    if method == "tools/list":
        return reply(msg_id, {"tools": [{"name": n, "description": d, "inputSchema": SCHEMA} for n, d in TOOLS]})
    if method == "tools/call":
        with open(LOG_NAME, "a") as f:
            f.write(json.dumps({"tool": params.get("name"), "args": params.get("arguments") or {}}) + "\n")
        return reply(msg_id, {"content": [{"type": "text", "text": "ok (dublê do oute-regression)"}], "isError": False})
    if method == "ping":
        return reply(msg_id, {})
    return reply(msg_id, error={"code": -32601, "message": "método desconhecido"})


def main():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        handle(msg)


if __name__ == "__main__":
    main()
