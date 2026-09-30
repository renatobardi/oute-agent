#!/usr/bin/env python3
"""Receptor OTLP/HTTP falso para os testes (#124): grava cada POST em <dir>/<n>.json (e a rota em <n>.path) e
responde 200.
Uso: otlp-receiver.py <dir>   (escreve a porta em <dir>/port; RCV_SLEEP=s atrasa a resposta;
RCV_REJECT=<texto>: POST que contém o texto recebe 400 e não é gravado;
RCV_TOKEN=<token>: POST sem `Authorization: Bearer <token>` recebe 401, não é gravado e soma uma linha em
<dir>/unauthorized; RCV_PORT=<porta>: porta fixa, para derrubar e subir de novo no mesmo endereço)"""
import http.server
import os
import sys
import threading
import time

D = sys.argv[1]
# POSTs simultâneos (o SDK manda logs e métricas em threads próprias) não podem disputar o mesmo número
LOCK = threading.Lock()
os.makedirs(D, exist_ok=True)


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        token = os.environ.get("RCV_TOKEN")
        if token and self.headers.get("Authorization") != f"Bearer {token}":
            with LOCK, open(os.path.join(D, "unauthorized"), "a") as f:
                f.write("401\n")
            self.send_response(401)
            self.end_headers()
            return
        time.sleep(float(os.environ.get("RCV_SLEEP", "0")))
        reject = os.environ.get("RCV_REJECT")
        if reject and reject.encode() in body:
            self.send_response(400)
            self.end_headers()
            return
        with LOCK:
            n = len([f for f in os.listdir(D) if f.endswith(".json")]) + 1
            with open(os.path.join(D, f".{n}.tmp"), "wb") as f:
                f.write(body)
            with open(os.path.join(D, f"{n:04d}.path"), "w") as f:  # rota do POST (/v1/logs, /v1/metrics…)
                f.write(self.path)
            os.replace(os.path.join(D, f".{n}.tmp"), os.path.join(D, f"{n:04d}.json"))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *a):
        pass


s = http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("RCV_PORT", "0"))), H)
with open(os.path.join(D, "port"), "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
