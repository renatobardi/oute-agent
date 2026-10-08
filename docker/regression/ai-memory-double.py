#!/usr/bin/env python3
"""Dublê do servidor MCP `ai-memory` para o oute-regression (#484): fala o protocolo MCP por stdio (JSON por linha),
grava cada chamada de ferramenta (nome e argumentos) como uma linha JSON em `memory.log`, na pasta de trabalho do
processo, e responde que deu certo. Nada chega à memória de verdade. Só biblioteca padrão."""
import json
import sys

LOG_NAME = "memory.log"  # nome fixo, na pasta de trabalho do processo (o oute-regression entra na pasta do pedido antes)
# Schemas por ferramenta, no formato do servidor real (#730): o glm-5.3 só emite os argumentos que o schema declara
# (com {"type": "object"} sem propriedades a chamada sai com input vazio no endpoint da Z.ai), então o dublê declara
# os mesmos parâmetros do ai-memory — workspace e project opcionais, como no real — sem dizer de onde vêm os valores:
# isso continua sendo da regra das notas que a tarefa 5 prova.
SCOPE = [
    ("workspace", "Workspace em que a ferramenta atua."),
    ("project", "Projeto em que a ferramenta atua."),
]


def props(*pairs, **opt):
    """Monta um inputSchema: pares nome→descrição; **opt marca os obrigatórios."""
    schema = {
        "type": "object",
        "properties": {n: {"type": "string", "description": d} for n, d in pairs},
    }
    required = [n for n in opt if opt[n]]
    if required:
        schema["required"] = required
    return schema


TOOLS = [
    ("memory_write_page", "Grava uma página de memória.",
     props(("path", "Caminho relativo da página."), ("body", "Conteúdo da página."),
           ("title", "Título da página."), *SCOPE, path=True, body=True)),
    ("memory_query", "Consulta a memória.",
     props(("query", "Consulta a procurar."), ("limit", "Máximo de resultados."), *SCOPE, query=True)),
    ("memory_recent", "Lista as páginas recentes.",
     props(("limit", "Máximo de páginas."), *SCOPE)),
    ("memory_status", "Estado da memória.", props(*SCOPE)),
]


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
        return reply(msg_id, {"tools": [{"name": n, "description": d, "inputSchema": s} for n, d, s in TOOLS]})
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
