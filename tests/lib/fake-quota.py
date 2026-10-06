#!/usr/bin/env python3
"""Endpoints de cota falsos para os testes do `oute-quota` (#346, #676): o `/api/oauth/usage` do Claude, o
`/backend-api/wham/usage` do Codex e o `/api/monitor/usage/quota/limit` da zai, no mesmo servidor.

  fake-quota.py <dir>      sobe em 127.0.0.1, numa porta livre gravada em <dir>/port (com TLS: <dir>/cert.pem e key.pem)

Rotas: /claude/api/oauth/usage, /codex/backend-api/wham/usage e /zai/api/monitor/usage/quota/limit. A cada pedido lê de <dir>:
  <agente>.mode   o que responder: `ok` (padrão; corpo de <dir>/<agente>.body), `429` (com retry-after de
                  <dir>/retry-after, padrão 294), `5xx` (503), `lixo` (200 que não é JSON), `formato` (200 JSON sem as janelas)
                  e `hang` (dorme <dir>/hang segundos, padrão 3)
E grava em <dir>/requests.jsonl uma linha por pedido, de qualquer método: {"agent", "method", "path", "auth", "beta", "account"}.
"""
import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]
ROUTES = {"/claude/api/oauth/usage": "claude", "/codex/backend-api/wham/usage": "codex",
          "/zai/api/monitor/usage/quota/limit": "zai"}


def conf(name, default):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, data, headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        agent = ROUTES.get(self.path.split("?")[0])
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        with open(os.path.join(DIR, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"agent": agent, "method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization", ""),
                                "beta": self.headers.get("anthropic-beta", ""),
                                "account": self.headers.get("ChatGPT-Account-Id", "")}) + "\n")
        if agent is None:
            return self.reply(404, b"{}")
        mode = conf(agent + ".mode", "ok")
        if mode == "hang":
            time.sleep(float(conf("hang", "3")))
            return
        if mode == "429":
            return self.reply(429, b'{"error":{"type":"rate_limit_error"}}', [("retry-after", conf("retry-after", "294"))])
        if mode == "5xx":
            return self.reply(503, b'{"error":"overloaded"}')
        if mode == "lixo":
            return self.reply(200, b"isto nao e JSON")
        if mode == "formato":
            return self.reply(200, b'{"novo":{"formato":true}}')
        self.reply(200, conf(agent + ".body", "{}").encode())


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
