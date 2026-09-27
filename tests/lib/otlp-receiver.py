#!/usr/bin/env python3
"""Receptor OTLP/HTTP falso para os testes (#124): grava cada POST em <dir>/<n>.json e responde 200.
Uso: otlp-receiver.py <dir>   (escreve a porta em <dir>/port; RCV_SLEEP=s atrasa a resposta)"""
import http.server
import os
import sys
import time

D = sys.argv[1]
os.makedirs(D, exist_ok=True)


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        time.sleep(float(os.environ.get("RCV_SLEEP", "0")))
        n = len([f for f in os.listdir(D) if f.endswith(".json")]) + 1
        with open(os.path.join(D, f".{n}.tmp"), "wb") as f:
            f.write(body)
        os.replace(os.path.join(D, f".{n}.tmp"), os.path.join(D, f"{n:04d}.json"))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *a):
        pass


s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(D, "port"), "w") as f:
    f.write(str(s.server_address[1]))
s.serve_forever()
