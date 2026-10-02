"""Chama o app do agent-studio direto pelo ASGI, sem servidor nem porta, para os testes da tela exercitarem o app
com um store ou um SurrealDB de mentira. `get(app, path, query)` -> (status, corpo). `Broken`: store em que toda
leitura falha (a causa, "segredo-da-falha", não pode chegar à página). `Odd`: SurrealDB que responde fora do
formato. Uso: PYTHONPATH=tests/lib."""
import asyncio

TOKEN = "token-um"


def get(app, path, query="", headers=(), method="GET"):
    """`headers` = pares (nome, valor) a mais; o `Bearer` do TOKEN vai sempre."""
    msgs = []
    extra = [(k.lower().encode(), v.encode()) for k, v in headers]
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": path, "raw_path": path.encode(), "query_string": query.encode(), "root_path": "",
             "headers": [(b"authorization", f"Bearer {TOKEN}".encode()), *extra], "server": ("t", 80),
             "client": ("t", 1)}

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(m):
        msgs.append(m)

    asyncio.run(app(scope, receive, send))
    return msgs[0]["status"], b"".join(m.get("body", b"") for m in msgs[1:]).decode()


class Broken:
    def __getattr__(self, name):
        def boom(*args):
            raise RuntimeError("segredo-da-falha")
        return boom


class Odd:
    def query(self, sql, variables):
        return [{"status": "OK", "result": "não é lista"}]
