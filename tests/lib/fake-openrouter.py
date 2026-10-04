#!/usr/bin/env python3
"""OpenRouter falso para os testes do oute-llm-proxy (#459), com TLS (<dir>/cert.pem e key.pem, gerados pelo openssl).

  fake-openrouter.py <dir>   sobe em 127.0.0.1, numa porta livre gravada em <dir>/port

Rotas: POST /api/v1/chat/completions e GET /api/v1/models. A cada pedido lê de <dir>/chat.mode (padrão `ok`):
  ok        200 com `model`, `usage` (prompt 120, completion 30, cached 20, cost 0.000321) e um texto de resposta
  nousage   200 sem `usage`
  500       500 com um corpo de erro que repete o `Authorization` recebido (para provar que o proxy tira a chave)
  429       429 com Retry-After
  sse       200 text/event-stream, com o `usage` no penúltimo pedaço
  big       200 com 20 MiB de JSON (o `usage` no fim)
  hang      dorme <dir>/hang segundos (padrão 30)
E grava uma linha por pedido em <dir>/requests.jsonl: {"method", "path", "auth", "cookie", "body", "ctype"}.
"""
import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]
MODEL = "openai/gpt-oss-120b"
RESPONSE_TEXT = "TEXTO-DE-RESPOSTA-SECRETO"


def conf(name, default):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default


USAGE = {"prompt_tokens": 120, "completion_tokens": 30, "total_tokens": 150, "cost": 0.000321,
         "prompt_tokens_details": {"cached_tokens": 20}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def handle_any(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        with open(os.path.join(DIR, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": self.headers.get("Authorization", ""),
                                "cookie": self.headers.get("Cookie", ""), "body": body,
                                "ctype": self.headers.get("Content-Type", "")}) + "\n")
        try:
            self.answer()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

    def answer(self):
        path = self.path.split("?")[0]
        if path == "/api/v1/models":
            return self.reply(200, b'{"data":[{"id":"openai/gpt-oss-120b"}]}')
        if path != "/api/v1/chat/completions":
            return self.reply(404, b"{}")
        mode = conf("chat.mode", "ok")
        if mode == "500":
            return self.reply(500, json.dumps({"error": {"message": "falha interna", "echo": self.headers.get("Authorization", "")}}).encode())
        if mode == "429":
            return self.reply(429, b'{"error":"limite"}', {"Retry-After": "7"})
        if mode == "hang":
            time.sleep(float(conf("hang", "30")))
            return
        if mode == "nousage":
            return self.reply(200, json.dumps({"id": "x", "model": MODEL, "choices": [{"message": {"content": RESPONSE_TEXT}}]}).encode())
        if mode == "sse":
            chunks = [{"model": MODEL, "choices": [{"delta": {"content": RESPONSE_TEXT}}]},
                      {"model": MODEL, "choices": [], "usage": USAGE}]
            data = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
            return self.reply(200, data.encode(), ctype="text/event-stream", length=False)
        if mode == "big":
            head = b'{"model":"' + MODEL.encode() + b'","choices":[{"message":{"content":"'
            tail = b'"}}],"usage":' + json.dumps(USAGE).encode() + b"}"
            total = 20 * 2**20
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(head) + total + len(tail)))
            self.end_headers()
            self.wfile.write(head)
            chunk = b"a" * 65536
            for _ in range(total // len(chunk)):
                self.wfile.write(chunk)
            self.wfile.write(tail)
            return
        return self.reply(200, json.dumps({"id": "x", "model": MODEL, "usage": USAGE,
                                           "choices": [{"message": {"content": RESPONSE_TEXT}}]}).encode())

    def reply(self, code, data, extra=None, ctype="application/json", length=True):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        if length:
            self.send_header("Content-Length", str(len(data)))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(data)


for m in ("GET", "POST", "PUT", "PATCH", "DELETE"):
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
