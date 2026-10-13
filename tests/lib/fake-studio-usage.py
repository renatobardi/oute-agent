#!/usr/bin/env python3
"""Dublê do agent-studio para o `GET /v1/usage?rodada=<id>` (#844, tests/oute-swarm-dark.test.sh).
Uso: fake-studio-usage.py <pasta> <token>. Sobe em 127.0.0.1, porta sorteada, e grava a porta em <pasta>/port.
Comandos por arquivo em <pasta> (lidos a cada pedido):
  cost-<rodada>   número: o custo real da rodada (padrão 0)
  mode            ok (padrão) | erro (HTTP 500) | lento (responde depois de 6 s, acima do teto de 3 s) | lixo (200 sem JSON)
Cada pedido entra em <pasta>/requests.log: `<caminho>?<query> auth=ok|ruim`. O token nunca é gravado."""
import http.server
import json
import os
import socketserver
import sys
import time
import urllib.parse

DIR, TOKEN = sys.argv[1], sys.argv[2]


def read(name, default=""):
    try:
        with open(os.path.join(DIR, name), encoding="utf-8") as f:
            return f.read().strip() or default
    except OSError:
        return default


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        auth = "ok" if self.headers.get("Authorization") == f"Bearer {TOKEN}" else "ruim"
        with open(os.path.join(DIR, "requests.log"), "a", encoding="utf-8") as f:
            f.write(f"{url.path}?{url.query} auth={auth}\n")
        if auth != "ok":
            return self.reply(401, '{"message": "unauthorized"}')
        mode = read("mode", "ok")
        if mode == "lento":
            time.sleep(6)
        if mode == "erro":
            return self.reply(500, '{"message": "consulta falhou"}')
        if mode == "lixo":
            return self.reply(200, "<html>nao e json</html>")
        rodada = urllib.parse.parse_qs(url.query).get("rodada", [""])[0]
        cost = float(read(f"cost-{rodada}", "0"))
        # o formato do `usage.round_usage`: custo real, de lista e estimado somam o custo da rodada
        return self.reply(200, json.dumps({"rodada": rodada, "totals": {"calls": 1, "cost": {
            "real_usd": cost / 2, "listed_usd": cost / 2, "estimated_usd": None}}}))


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


srv = Server(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w", encoding="utf-8") as f:
    f.write(str(srv.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
srv.serve_forever()
