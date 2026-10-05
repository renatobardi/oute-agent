"""Chama o app do agent-studio direto pelo ASGI, sem servidor nem porta, para os testes da tela exercitarem o app
com um store ou um SurrealDB de mentira. `get(app, path, query)` -> (status, corpo). `Broken`: store em que toda
leitura falha (a causa, "segredo-da-falha", não pode chegar à página). `Odd`: SurrealDB que responde fora do
formato. Uso: PYTHONPATH=tests/lib."""
import asyncio
import secrets

TOKEN = secrets.token_hex(16)


async def async_get(app, path, query="", headers=(), method="GET", response_headers=None):
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

    await app(scope, receive, send)
    if response_headers is not None:
        response_headers.update((k.decode().lower(), v.decode()) for k, v in msgs[0].get("headers", []))
    return msgs[0]["status"], b"".join(m.get("body", b"") for m in msgs[1:]).decode()


def raw_get(app, path, query="", headers=(), method="GET", response_headers=None):
    return asyncio.run(async_get(app, path, query, headers, method, response_headers))


def get(app, path, query="", headers=(), method="GET"):
    """Abre o casco e lê cada bloco por sua rota. `raw_get` mede apenas uma resposta."""
    from studio_loading import expand
    status, body = raw_get(app, path, query, headers, method)
    if status == 200 and method == "GET":
        code, body = expand(body, lambda p, q: raw_get(app, p, q, (*headers, ("HX-Request", "true"))))
        if code != 200:
            status = code
    return status, body


class Broken:
    def __getattr__(self, name):
        def boom(*args):
            raise RuntimeError("segredo-da-falha")
        return boom


class Odd:
    def query(self, sql, variables):
        return [{"status": "OK", "result": "não é lista"}]
