#!/usr/bin/env python3
"""TypeSafe falsa para os testes do seletor (#257): o `POST /v1/systemone` do Jev, primitivo `choice`.

  fake-typesafe.py <dir>      sobe em 127.0.0.1, numa porta livre gravada em <dir>/port, e fica no ar
                              (com TLS, se <dir>/cert.pem e <dir>/key.pem existem: o seletor só fala https, #313)

A cada pedido lê de <dir>:
  mode      o que responder: `ok` (padrão), `5xx` (503), `401`, `lixo` (200 que não é JSON), `sem-answers` (JSON sem
            a resposta), `fora` (fase que não foi oferecida), `redirect` (302 para <dir>/redirect-to) e `hang` (não
            responde: dorme <dir>/hang segundos, padrão 5)
  choice    a fase devolvida (padrão: build)
  confidence a confiança devolvida (padrão: 0.9)
E grava em <dir>/requests.jsonl uma linha por pedido: {"path", "auth", "body"} (auth = o cabeçalho Authorization).
"""
import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]


def conf(name, default):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, payload, headers=()):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        with open(os.path.join(DIR, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization", ""), "body": body}) + "\n")
        mode = conf("mode", "ok")
        if mode == "hang":
            time.sleep(float(conf("hang", "5")))
            return
        if mode == "5xx":
            return self.reply(503, {"error": "overloaded"})
        if mode == "401":
            return self.reply(401, {"error": "invalid api key"})
        if mode == "lixo":
            return self.reply(200, b"isto nao e JSON")
        if mode == "sem-answers":
            return self.reply(200, {"model": "jev-1.13.0"})
        if mode == "redirect":
            return self.reply(302, {}, [("Location", conf("redirect-to", "/"))])
        choice = "fase-que-nao-existe" if mode == "fora" else conf("choice", "build")
        try:
            confidence = json.loads(conf("confidence", "0.9"))
        except ValueError:
            confidence = conf("confidence", "0.9")
        self.reply(200, {"model": "jev-1.13.0", "usage": {"input_tokens": 1, "output_tokens": 1},
                         "answers": {"fase": {"type": "choice", "choice": choice, "confidence": confidence,
                                              "probabilities": {choice: confidence}}}})


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.daemon_threads = True
    cert, key = os.path.join(DIR, "cert.pem"), os.path.join(DIR, "key.pem")
    if os.path.exists(cert) and os.path.exists(key):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    tmp = os.path.join(DIR, "port.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp, os.path.join(DIR, "port"))
    srv.serve_forever()


if __name__ == "__main__":
    main()
