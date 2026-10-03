#!/usr/bin/env python3
"""Fontes de preço falsas para os testes da conferência diária (#339): o models.dev e o OpenRouter no mesmo servidor.

  fake-price-sources.py <dir>   sobe em 127.0.0.1, numa porta livre gravada em <dir>/port (TLS: <dir>/cert.pem e key.pem)

Rotas: /models.dev/api.json e /openrouter/api/v1/models. A cada pedido lê de <dir>:
  <fonte>.body   o JSON a responder (padrão `{}`); <fonte> = `models.dev` ou `openrouter`
  <fonte>.mode   `ok` (padrão), `500`, `redirect` (302 para uma URL de outro esquema), `hang` (dorme <dir>/hang segundos,
                 padrão 30), `big` (declara 40 MiB de corpo e não manda), `bigstream` (manda 33 MiB sem declarar o
                 tamanho) e `lixo` (200 que não é JSON)
E grava em <dir>/requests.jsonl uma linha por pedido, de qualquer método: {"source", "method", "path", "auth", "cookie"}.
"""
import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]
ROUTES = {"/models.dev/api.json": "models.dev", "/openrouter/api/v1/models": "openrouter"}


def conf(name, default):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def handle_any(self):
        source = ROUTES.get(self.path.split("?")[0])
        with open(os.path.join(DIR, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"source": source, "method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization", ""),
                                "cookie": self.headers.get("Cookie", "")}) + "\n")
        try:
            self.answer(source)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def answer(self, source):
        if source is None:
            return self.reply(404, b"{}")
        mode = conf(source + ".mode", "ok")
        if mode == "500":
            return self.reply(500, b'{"erro":"interno"}')
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "ftp://127.0.0.1/api.json")
            self.send_header("Content-Length", "0")
            return self.end_headers()
        if mode == "hang":
            time.sleep(float(conf("hang", "30")))
            return
        if mode == "big":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(40 * 2**20))
            return self.end_headers()
        if mode == "bigstream":
            self.protocol_version = "HTTP/1.0"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            chunk = b" " * 65536
            for _ in range(33 * 16):
                self.wfile.write(chunk)
            self.close_connection = True
            return
        if mode == "lixo":
            return self.reply(200, b"isto nao e JSON")
        self.reply(200, conf(source + ".body", "{}").encode())

    def reply(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


for m in ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"):
    setattr(Handler, "do_" + m, Handler.handle_any)


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.daemon_threads = True
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(os.path.join(DIR, "cert.pem"), os.path.join(DIR, "key.pem"))
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    tmp = os.path.join(DIR, "port.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp, os.path.join(DIR, "port"))
    srv.serve_forever()


if __name__ == "__main__":
    main()
