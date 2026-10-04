#!/usr/bin/env bash
# Testes do Dashboard `/` do agent-studio (#469, Kubo 4/4 do épico #465): os KPIs com o valor, o da janela anterior e o
# Badge de variação (`data-*`), os insights por regra (cada um com a regra que o dispara, a que não dispara e o link),
# os 6 gráficos em SVG gerado no template (sem style=, sem script, sem recurso externo), os totais batendo com o `/uso` e
# o `/v1/usage` na mesma janela, a janela de 24 h e de 7 d, o Gate pendente (SurrealDB e decisão da rodada) e os ramos de
# falha (sem SurrealDB, SurrealDB que falha, DuckDB que falha, janela inválida). Chama o app pelo ASGI
# (tests/lib/studio_asgi.py) sobre um DuckDB de exemplo; sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-dashboard.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "$TMP"' EXIT
studio_init

cat > "$TMP/config.toml" <<'TOML'
[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
cache_read = 0.3
[prices."gpt-5-codex"]
input = 1.25
output = 10.0
cache_read = 0.125
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" "$ROOT" > "$TMP/py.out" 2>&1 <<'PY'
import json, re, sys, time
from datetime import datetime, timedelta, timezone
from agent_studio import config as CF, store as ST
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, Broken, get

tmp, root = sys.argv[1], sys.argv[2]
CSS = open(f"{root}/docker/agent-studio/agent_studio/static/studio.css").read()
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
NOW = time.time_ns()


def ts(s):
    return int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC


class DB:
    """Spans e logs de exemplo escritos direto no DuckDB; a hora do fato é a que o teste dá."""

    def __init__(self, name):
        self.st = ST.Store(f"{tmp}/{name}.duckdb")
        self.n = 0
        self.spans, self.logs = [], []

    def span(self, at_ns, dur_s, name="claude_code.llm_request", model=None, task=None, conv=None, host="oute-server",
             agent="claude", err=False, attrs=None, **tok):
        self.n += 1
        row = {"dedupe_key": f"s:{self.n}", "time_unix_nano": at_ns, "end_unix_nano": at_ns + int(dur_s * SEC),
               "duration_ns": int(dur_s * SEC), "host_name": host, "oute_agent": agent, "session_id": conv, "oute_task_id": task,
               "trace_id": f"{self.n:032x}", "span_id": f"{self.n:016x}", "name": name, "status_code": 2 if err else 0,
               "model": model, "received_unix_nano": at_ns, "attributes": json.dumps(attrs or {}), "resource_attributes": "{}"}
        row.update({f"{k}_tokens" if k != "cost_usd" else k: v for k, v in tok.items()})
        self.spans.append(row)

    def log(self, at_ns, name, attrs, body="", task=None, rnd=None, host="oute-server"):
        self.n += 1
        self.logs.append({"dedupe_key": f"l:{self.n}", "time_unix_nano": at_ns, "host_name": host, "oute_task_id": task,
                          "oute_swarm_round": rnd, "event_name": name, "severity_number": 9, "body": body,
                          "attributes": json.dumps(attrs), "resource_attributes": "{}", "received_unix_nano": at_ns})

    def flush(self):
        self.st.write({"spans": self.spans, "logs": self.logs})
        return self.st


class Surreal:
    """SurrealDB de mentira: só a lista de pedidos pendentes (as duas consultas do `proposals.pending`)."""

    def __init__(self, ages_s):
        self.ages = ages_s

    def query(self, sql, variables):
        at = lambda a: datetime.fromtimestamp((NOW - a * SEC) // SEC, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        rows = [{"id": f"p{i}", "state": "pendente", "proposed_at": at(a), "title": "t"} for i, a in enumerate(self.ages)]
        return [{"status": "OK", "result": rows}, {"status": "OK", "result": [{"n": len(rows)}]}]


# ------------------------------------------------------------------------------ janela fixa de 48 h (série por hora)
# F = [2025-10-01, 2025-10-03); a anterior, P = [2025-09-29, 2025-10-01). O heatmap olha os 7 dias até o fim de F.
F0, F1 = ts("2025-10-01T00:00:00"), ts("2025-10-03T00:00:00")
P0 = ts("2025-09-29T00:00:00")
Q = "from=2025-10-01T00:00:00Z&to=2025-10-03T00:00:00Z"
H = 3600 * SEC
db = DB("fixa")
# janela anterior: 6 do sonnet (2 s) e 1 do opus (custo real 1,00)
for i in range(6):
    db.span(P0 + (5 + i) * H, 2, model="claude-sonnet-5", task="t-antiga", input=1000, output=100)
db.span(P0 + 20 * H, 9, model="claude-opus-5", task="t-antiga", input=10, cost_usd=1.0)
# janela atual: 20 do sonnet (14 de 2 s na sessão T1, 6 de 8 s na T-LENTA), tudo estimado; cache lido em todas
for i in range(14):
    db.span(F0 + (1 + i) * H, 2, model="claude-sonnet-5", task="T1", conv="conv-t1", input=10_000, output=1_000, cache_read=100_000)
for i in range(6):
    db.span(F0 + (20 + i) * H, 8, model="claude-sonnet-5", task="T-LENTA", conv="conv-lenta", input=10_000, output=1_000, cache_read=100_000)
# 2 do opus com custo real 5,00 (sem preço na tabela: o real vale), 2 do codex, 3 de um modelo sem preço
for i in range(2):
    db.span(F0 + (30 + i) * H, 12, model="claude-opus-5", task="T1", conv="conv-t1", input=100, output=10, cost_usd=5.0)
for i in range(2):
    db.span(F0 + (34 + i) * H + 600 * SEC, 3, name="session_task.turn", model="gpt-5-codex", task="T-CODEX", host="oute-mac",
            agent="codex", input=1_000_000, output=100_000)
for i in range(3):   # as 3 na mesma hora (qui 16h): o pico do heatmap
    db.span(F0 + 40 * H + i * 60 * SEC, 1, model="m<b>x</b>&y", task="T-SEM", input=500)
# 3 erros em span: 2 da mesma ferramenta e host (Bash, oute-mac) na conv-x; 1 de outra
db.span(F0 + 5 * H, 1, name="claude_code.tool", host="oute-mac", conv="conv-x", err=True, attrs={"tool_name": "Bash"})
db.span(F0 + 6 * H, 1, name="claude_code.tool", host="oute-mac", conv="conv-x", err=True, attrs={"tool_name": "Bash"})
db.span(F0 + 7 * H, 1, name="claude_code.tool", host="oute-server", conv="conv-y", err=True, attrs={"tool_name": "Read"})
# fase da sessão (o seletor registrou no opened)
for task, phase in (("T1", "build"), ("T-LENTA", "qa"), ("T-CODEX", "build"), ("t-antiga", "plan")):
    db.log(F0 - 5 * 86400 * SEC, "oute.task.opened", {"oute.task.phase": phase}, task=task)
st = db.flush()
app = create_app(st, TOKEN, config=cfg, surreal=Surreal([900, 120]))
status, html = get(app, "/", Q)
kpi = lambda page, k: re.search(rf'<div class="kpi" data-kpi="{k}"[^>]*>.*?</div>\s*</div>', page, re.S).group(0)
attrs = lambda tag: dict(re.findall(r'data-([\w-]+)="([^"]*)"', tag))
KP = {k: attrs(kpi(html, k).split(">", 1)[0]) for k in ("calls", "cost", "p95", "errors", "cache")}

check("/ responde o Dashboard (200, HTML)", status == 200 and html.startswith("<!doctype html>") and "<h1>Dashboard</h1>" in html)
check("/conversas continua", get(app, "/conversas")[0] == 200 and "<h1>Conversas</h1>" in get(app, "/conversas")[1])
check("sidebar: o item Dashboard aponta para / e é o atual",
      '<a class="nav-item" href="/" aria-current="page"><svg class="icone"' in html and 'href="/conversas"><svg' in html)
check("nas outras telas o item Dashboard também aponta para / (sem ser o atual)",
      '<a class="nav-item" href="/"><svg' in get(app, "/conversas")[1])
check("os 5 KPIs, na ordem", re.findall(r'data-kpi="(\w+)"', html) == ["calls", "cost", "p95", "errors", "cache"])
# 20 sonnet + 2 opus + 2 codex + 3 sem preço = 27; anterior = 7
check("KPI chamadas: valor, anterior e variação", KP["calls"]["value"] == "27" and KP["calls"]["prev"] == "7"
      and abs(float(KP["calls"]["delta"]) - (27 - 7) / 7) < 1e-9)
check("KPI chamadas: Badge com a variação e a seta para cima", '+286%' in kpi(html, "calls") and "lucide.svg#trending-up" in kpi(html, "calls"))
# sonnet: 20 × (10000×3 + 1000×15 + 100000×0,3)/1e6 = 1,5; codex: 2 × (1e6×1,25 + 1e5×10)/1e6 = 4,5; opus real 10
check("KPI custo: real, estimado, % estimado e sem preço", abs(float(KP["cost"]["real-usd"]) - 10.0) < 1e-6
      and abs(float(KP["cost"]["estimated-usd"]) - 6.0) < 1e-6 and abs(float(KP["cost"]["estimated-share"]) - 6 / 16) < 1e-9
      and KP["cost"]["unpriced-calls"] == "3" and abs(float(KP["cost"]["value"]) - 16.0) < 1e-6)
check("KPI custo: ≈ no valor e a nota do % estimado", "≈ US$ 16,00" in kpi(html, "cost") and "38% estimado" in kpi(html, "cost"))
check("KPI p95: 10,8 s (o opus de 12 s entra) e Badge destrutivo (piorou > 25%)", abs(float(KP["p95"]["value"]) - 10800) < 1 and 'class="badge destrutivo"' in kpi(html, "p95")
      and "piorou" in kpi(html, "p95"))
check("KPI erros: 3 spans de erro sobre 27 chamadas", KP["errors"]["errors"] == "3" and KP["errors"]["prev-errors"] == "0"
      and abs(float(KP["errors"]["value"]) - 3 / 27) < 1e-9 and "11,11%" in kpi(html, "errors") and "3 erros" in kpi(html, "errors"))
# cache: 20 × 100000 de leitura / (entrada 20×10000 + 2×100 + 2e6 + 3×500 + leitura 2e6 + criação 0)
tin = 20 * 10_000 + 2 * 100 + 2 * 1_000_000 + 3 * 500
check("KPI cache: leitura sobre a entrada total", abs(float(KP["cache"]["value"]) - 2_000_000 / (tin + 2_000_000)) < 1e-9)

# ------------------------------------------------------------------------------ totais batendo com /uso e /v1/usage
_, uso = get(app, "/uso", Q)
tot = attrs(re.search(r'<p class="cartao bloco" id="total"[^>]*>', uso).group(0))
check("totais = /uso na mesma janela (chamadas, real e estimado)", tot["calls"] == KP["calls"]["value"]
      and abs(float(tot["real-usd"]) - float(KP["cost"]["real-usd"])) < 1e-9 and abs(float(tot["estimated-usd"]) - float(KP["cost"]["estimated-usd"])) < 1e-9)
api = json.loads(get(app, "/v1/usage", Q)[1])["totals"]
check("totais = /v1/usage (chamadas, custo, p95, erros)", api["calls"] == 27 and abs(api["cost"]["real_usd"] - 10.0) < 1e-6
      and abs(api["latency_p95_ms"] - float(KP["p95"]["value"])) < 1e-6 and api["errors"]["spans"] == 3 and api["cost"]["unpriced_calls"] == 3)
by_phase = {m.group(1): int(m.group(2)) for m in re.finditer(r'data-fase="([^"]*)" data-tokens="(\d+)"', html)}
uso_phase = {m.group(1): int(m.group(2)) + int(m.group(3)) for m in re.finditer(
    r'data-phase="([^"]*)" data-calls="\d+" data-input="(\d+)" data-output="(\d+)"', uso)}
check("tokens por fase = /uso por fase (entrada + saída)", by_phase == {k: v for k, v in uso_phase.items() if v} and by_phase["qa"] == 66_000)

# ------------------------------------------------------------------------------ insights
ins = re.findall(r'<li data-insight="(\w+)" data-tone="(\w+)">(.*?)</li>', html, re.S)
keys = [i[0] for i in ins]
check("insights que disparam, na ordem do #469", keys == ["p95", "gate", "model_cost", "cache", "tool_errors", "unpriced"])
byk = {i[0]: i[2] for i in ins}
USO = "/uso?from=2025-10-01T00%3A00%3A00Z&amp;to=2025-10-03T00%3A00%3A00Z"
link = lambda k: re.search(r'class="insight-link" href="([^"]*)"', byk[k]).group(1)
check("insight p95: modelo, subida e o link da sessão com o p95 mais alto", "p95 do claude-sonnet-5 subiu 300%" in byk["p95"]
      and "8,0 s contra 2,0 s" in byk["p95"] and link("p95") == "/sessao?id=T-LENTA")
check("insight Gate: idade do pedido mais velho e link para os pedidos", "Gate parado há 15 min" in byk["gate"] and link("gate") == "/pedidos"
      and "1 Gate espera o Bardi" in byk["gate"] and "(2 no total)" in byk["gate"])
check("insight modelo caro: poucas chamadas, muito custo → uso", "claude-opus-5 é 7% das chamadas e 62% do custo" in byk["model_cost"]
      and link("model_cost") == USO)
check("insight cache: cobertura e o quanto o estimado subiria → uso", "Cache cobre 48% dos tokens de entrada" in byk["cache"]
      and "US$ 5,40 maior" in byk["cache"] and link("cache") == USO)
check("insight erros: 2 de 3 da mesma ferramenta e host → conversa", "2 de 3 erros vêm de Bash em oute-mac" in byk["tool_errors"]
      and link("tool_errors") == "/conversa?id=conv-x")
check("insight sem preço: 3 chamadas e o modelo (escapado) → preços", "3 chamadas sem preço na janela" in byk["unpriced"]
      and "m&lt;b&gt;x&lt;/b&gt;&amp;y" in byk["unpriced"] and link("unpriced") == "/precos")
check("insights: a cor é o tom (Gate âmbar, erros e p95 destrutivos) e o Gate leva o ícone hand",
      [i[1] for i in ins] == ["bad", "gate", "neutral", "neutral", "bad", "neutral"] and "lucide.svg#hand" in byk["gate"])

# ------------------------------------------------------------------------------ gráficos
sec = lambda name: re.search(rf'<section class="cartao bloco grafico" data-grafico="{name}".*?</section>', html, re.S).group(0)
check("6 gráficos, um cartão cada", re.findall(r'data-grafico="([\w-]+)"', html) ==
      ["chamadas", "custo-modelo", "latencia", "fases", "atividade", "sessoes"])
pts = re.findall(r'<g class="ponto" data-bucket="([^"]*)" data-calls="(\d+)">', sec("chamadas"))
check("1) série por hora: 48 baldes que somam as chamadas da janela", len(pts) == 48 and sum(int(c) for _, c in pts) == 27
      and 'data-unit="hour"' in sec("chamadas") and pts[0][0] == "2025-10-01 00")
check("1) linha e área em <path>, dica no <title>, 3 linhas de grade",
      sec("chamadas").count("<path") == 2 and "<title>01/10 01h · 1 chamada · p95 2,0 s</title>" in sec("chamadas")
      and sec("chamadas").count('class="grade') == 3)
check("1) eixo: teto redondo e metade", re.findall(r"<span>([\d.]+)</span>", sec("chamadas").split('class="eixo-y"')[1].split("</div>")[0]) == ["4", "2", "0"])
models = re.findall(r'<div class="barra-linha" data-modelo="([^"]*)" data-calls="(\d+)" data-real-usd="([^"]*)" data-estimated-usd="([^"]*)"', sec("custo-modelo"))
check("2) custo por modelo: em ordem de custo, com real e estimado separados", [m[0] for m in models] ==
      ["claude-opus-5", "gpt-5-codex", "claude-sonnet-5", "m&lt;b&gt;x&lt;/b&gt;&amp;y"]
      and models[0][2:] == ("10.0", "") and models[1][2] == "" and abs(float(models[2][3]) - 1.5) < 1e-9)
check("2) barras: real e estimado em <rect> de classes diferentes (o estimado é tracejado no CSS, não só de outra cor)",
      sec("custo-modelo").count('class="real"') >= 2 and 'class="estimado"' in sec("custo-modelo")
      and re.search(r"\.estimado[^}]*stroke-dasharray", CSS) is not None)
check("2) modelo sem preço diz 'sem preço' em vez de zero", "sem preço</span>" in sec("custo-modelo"))
check("2) composição: real, estimado, % e as chamadas sem preço", "Real US$ 10,00 (62%)" in sec("custo-modelo")
      and "Estimado ≈ US$ 6,00 (38%)" in sec("custo-modelo") and "3 chamadas sem preço, fora da soma" in sec("custo-modelo"))
lat = {m.group(1): m.group(0) for m in re.finditer(r'<tr data-modelo="([^"]*)" data-calls=.*?</tr>', sec("latencia"), re.S)}
check("3) latência: um modelo por linha, do p95 mais alto ao mais baixo", list(lat) ==
      ["claude-opus-5", "claude-sonnet-5", "gpt-5-codex", "m&lt;b&gt;x&lt;/b&gt;&amp;y"])
sn = attrs(lat["claude-sonnet-5"].split(">", 1)[0])
check("3) latência do sonnet: percentis em ms (20 chamadas, 6 de 8 s)", sn["calls"] == "20" and float(sn["p50-ms"]) == 2000
      and float(sn["p90-ms"]) == 8000 and float(sn["p95-ms"]) == 8000 and float(sn["p99-ms"]) == 8000)
check("3) latência: mini-barra <svg> no p95 (a maior ocupa a largura toda)", 'class="mini"' in lat["claude-opus-5"] and 'width="100.00"' in lat["claude-opus-5"])
check("4) fases: barras por fase, a maior primeiro", re.findall(r'data-fase="(\w+)"', sec("fases")) == ["build", "qa", "desconhecida"])
heat = sec("atividade")
check("5) heatmap: 7 linhas × 24 células", heat.count('class="calor-linha" data-dia=') == 7 and heat.count('class="calor-celula n') == 7 * 24 + 5)
check("5) heatmap: soma dos 7 dias até o fim da janela (inclui a anterior)", 'data-total="34"' in heat)
# a quinta 2025-10-02 14h é a única com a chamada do codex (F0 + 34h + 10 min): 2025-10-02 10:10 → qui 10h
cell = lambda d, h: re.search(rf'data-dia="{d}">.*?data-hora="{h}" data-calls="(\d+)" data-nivel="(\d)"', heat, re.S).groups()
check("5) heatmap: dia e hora certos (qui 16h tem as 3 chamadas do pico, degrau 4; qui 10h tem 1, degrau 2; seg 3h vazia, degrau 0)",
      cell("qui", 16) == ("3", "4") and cell("qui", 10) == ("1", "2") and cell("seg", 3) == ("0", "0"))
check("5) heatmap: 5 degraus de --primary na legenda e título em cada célula", all(f'class="calor-celula n{i}"' in heat for i in range(5))
      and 'title="qui 16h · 3 chamadas"' in heat and 'title="qui 10h · 1 chamada"' in heat)
top = re.findall(r'<a class="top-sessao" href="([^"]*)" data-sessao="([^"]*)" data-calls="(\d+)"', sec("sessoes"))
check("6) sessões que mais custaram: por custo, com link para a sessão", [t[1] for t in top] == ["T1", "T-CODEX", "T-LENTA"]
      and top[0] == ("/sessao?id=T1", "T1", "16"))
check("6) sessão sem custo nem preço fica de fora (T-SEM)", "T-SEM" not in sec("sessoes") and len(top) <= 5)

# ------------------------------------------------------------------------------ o que a página não pode ter
body = html.split("<main", 1)[1]
check("sem style= em lugar nenhum da página", "style=" not in html)
check("nenhum script além do htmx", re.findall(r"<script[^>]*>", html) == ['<script src="/static/htmx.min.js" defer>'])
check("nenhum recurso externo (http/https, @import, url())", not re.search(r"https?://|@import|url\(", body))
check("o JS de gráfico não existe: só <svg>, <path>, <rect>, <line> e <title>", not re.search(r"<(canvas|iframe|object|embed)", html))
check("só leitura: a tela não tem formulário de ação além do Sair", body.count("<form") == 0 and body.count("<button") == 0)
check("hover em CSS e <title>, nada de onmouse*/onclick", not re.search(r"\son\w+=", html))

# ------------------------------------------------------------------------------ 24 h e 7 d (relativas a agora)
db2 = DB("relativa")
for h in (3, 5, 7):
    db2.span(NOW - h * H, 2, model="claude-sonnet-5", task="R1", conv="c-r1", input=1000, output=100)
db2.span(NOW - 30 * H, 2, model="claude-sonnet-5", task="R0", conv="c-r0", input=1000, output=100)   # janela anterior de 24 h
db2.span(NOW - 3 * 86400 * SEC, 2, model="claude-sonnet-5", task="R2", conv="c-r2", input=1000, output=100)  # só entra nos 7 d
st2 = db2.flush()
app2 = create_app(st2, TOKEN, config=cfg)
_, h24 = get(app2, "/", "hours=24")
_, h7 = get(app2, "/", "hours=168")
k24, k7 = attrs(kpi(h24, "calls").split(">", 1)[0]), attrs(kpi(h7, "calls").split(">", 1)[0])
check("24 h: 3 chamadas, a anterior tem 1; série por hora", k24["value"] == "3" and k24["prev"] == "1" and 'data-unit="hour"' in h24)
check("7 d: 5 chamadas; série por dia com 7 ou 8 baldes", k7["value"] == "5" and 'data-unit="day"' in h7
      and 7 <= len(re.findall(r'<g class="ponto"', h7)) <= 8)
check("a série de 7 d soma as chamadas da janela", sum(int(c) for c in re.findall(r'<g class="ponto" data-bucket="[^"]*" data-calls="(\d+)"', h7)) == 5)
check("seletor de janela: links 24 h e 7 dias, o atual marcado", '<a href="/?hours=24" aria-current="true">24 h</a>' in h24
      and '<a href="/?hours=168" aria-current="true">7 dias</a>' in h7 and '<a href="/?hours=168">7 dias</a>' in h24)
check("7 d bate com /uso (hours=168)", attrs(re.search(r'<p class="cartao bloco" id="total"[^>]*>', get(app2, "/uso", "hours=168")[1]).group(0))["calls"] == "5")
check("sem a janela, o padrão é 24 h", get(app2, "/")[1].count('aria-current="true">24 h') == 1)
check("sem Gate nem erro: insights que dependem deles não aparecem", "data-insight=\"gate\"" not in h24 and "data-insight=\"tool_errors\"" not in h24)
check("janela anterior de 24 h sem Gate: sem SurrealDB o aviso diz isso", "data-gate-nao-lido" in h24 and "sem SurrealDB" in h24)

# ------------------------------------------------------------------------------ regras que NÃO disparam (limites)
db3 = DB("limites")
for i in range(8):                       # sonnet piorou, mas a janela anterior tem só 2 chamadas (< 5): sem insight de p95
    db3.span(F0 + (1 + i) * H, 9, model="claude-sonnet-5", task="L1", input=1000)
for i in range(2):
    db3.span(P0 + (1 + i) * H, 1, model="claude-sonnet-5", task="L0", input=1000)
db3.span(F0 + 3 * H, 1, name="claude_code.tool", host="oute-mac", err=True, attrs={"tool_name": "Bash"})   # 1 erro só (< 2)
db3.log(F1 - 3 * H, "oute.swarm.round.asked", {}, body="posso abrir?", rnd="r-recente")                   # decisão há 3 h... vista abaixo
app3 = create_app(db3.flush(), TOKEN, config=cfg, surreal=Surreal([120]))
_, p3 = get(app3, "/", Q)
check("p95 não dispara com menos de 5 chamadas na janela anterior", 'data-insight="p95"' not in p3)
check("um erro só não dispara o insight de erros", 'data-insight="tool_errors"' not in p3)
check("pedido pendente há 2 min não dispara o Gate (limite de 10 min)", 'data-insight="gate"' not in p3 or "há 2 min" not in p3)
check("sem chamadas sem preço, sem cache e sem custo: só os insights que valem", not re.search(r'data-insight="(unpriced|cache|model_cost)"', p3))

# ------------------------------------------------------------------------------ banco vazio, decisão pendente, falhas
app4 = create_app(DB("vazio").flush(), TOKEN, config=cfg)
s4, p4 = get(app4, "/", "hours=24")
check("banco vazio: 200 com tudo zerado e sem insight", s4 == 200 and "data-sem-insights" in p4 and 'data-kpi="calls" data-value="0"' in p4)
check("banco vazio: sem divisão por zero (p95, taxa e cache em —)", all(f'data-kpi="{k}" data-value=""' in p4 for k in ("p95", "errors", "cache")))
check("banco vazio: cada gráfico diz que está vazio, sem quebrar", "Nenhuma chamada ao modelo nesta janela." in p4
      and "Nenhum token nesta janela." in p4 and "Nenhuma sessão com custo nesta janela." in p4 and "Nenhuma chamada com duração nesta janela." in p4)
db5 = DB("decisao")
db5.log(NOW - 15 * 60 * SEC, "oute.swarm.round.asked", {}, body="posso abrir a #418?", rnd="r7")
app5 = create_app(db5.flush(), TOKEN, config=cfg)
_, p5 = get(app5, "/", "hours=24")
check("decisão pendente há 15 min dispara o Gate mesmo sem SurrealDB", "Gate parado há 15 min" in p5 and 'data-insight="gate"' in p5)
db6 = DB("decisao-nova")
db6.log(NOW - 3 * 60 * SEC, "oute.swarm.round.asked", {}, body="posso?", rnd="r8")
_, p6 = get(create_app(db6.flush(), TOKEN, config=cfg), "/", "hours=24")
check("decisão pendente há 3 min não dispara o Gate", 'data-insight="gate"' not in p6)


class Down:
    def query(self, sql, variables):
        raise RuntimeError("segredo-da-falha")


s7, p7 = get(create_app(DB("surreal-fora").flush(), TOKEN, config=cfg, surreal=Down()), "/", "hours=24")
check("SurrealDB que falha: página sai, com aviso, sem a causa", s7 == 200 and "não pôde ser lido" in p7 and "segredo-da-falha" not in p7)
s8, p8 = get(create_app(Broken(), TOKEN, config=cfg), "/", "hours=24")
check("DuckDB que falha: 500 sem a causa", s8 == 500 and "A consulta falhou" in p8 and "segredo-da-falha" not in p8)
check("janela inválida: 400", get(app4, "/", "hours=abc")[0] == 400 and get(app4, "/", "from=2025-10-02T00:00:00Z&to=2025-10-01T00:00:00Z")[0] == 400
      and get(app4, "/", "hours=0")[0] == 400)
check("HX-Request não leva o casco nem os alertas, mas a rota responde", get(app4, "/", "hours=24", headers=(("HX-Request", "true"),))[0] == 200)
check("nome de sessão com HTML sai escapado nos links e no texto", "T-LENTA" in html and "<b>x</b>" not in html)
# a consulta do Dashboard não segura a trava do escritor (#475): outras leituras e a ingestão seguem enquanto ela roda
import threading
db9 = DB("trava").flush()
calls = []
real_snapshot = ST.dash_mod.snapshot
def slow_snapshot(con, *a, **k):
    calls.append(1)
    time.sleep(1.0)
    return {"ok": len(calls)}
ST.dash_mod.snapshot = slow_snapshot
th = threading.Thread(target=db9.dashboard, args=(NOW - 3600 * SEC, NOW, CF.load().prices if hasattr(CF, "load") else None))
th.start()
time.sleep(0.2)
t0 = time.time()
db9.conversations(NOW - 3600 * SEC, NOW, None)
fast = time.time() - t0
th.join()
check("Dashboard lento não trava as outras leituras", fast < 0.5)
MIN = 60 * SEC
base = NOW // MIN * MIN
r1 = db9.dashboard(base - 3600 * SEC, base, None)
r2 = db9.dashboard(base - 3600 * SEC + 5 * SEC, base + 5 * SEC, None)
n = len(calls)
check("mesma janela no mesmo minuto: o cache evita refazer a conta", r1 is r2 and n == 1)
ST.dash_mod.snapshot = lambda con, *a, **k: con.execute("SELECT count(*) FROM range(100000000000)").fetchall()
ST.DASH_DEADLINE_S = 0.3
t0 = time.time()
try:
    db9.dashboard(NOW - 7200 * SEC, NOW, None)
    stopped = False
except Exception:
    stopped = True
check("consulta que passa do prazo é interrompida", stopped and time.time() - t0 < 5)
ST.dash_mod.snapshot = real_snapshot
PY
grep -v '^Traceback\|^  \|^RuntimeError\|^$\|^ok   \|tela: .* falhou' "$TMP/py.out" || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos"       test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 72
check_end
