#!/usr/bin/env bash
# Testes do controle de período do agent-studio (#527, épico #522): as quatro telas com janela (Dashboard, Conversas,
# Sessões, Uso) têm as mesmas janelas prontas e o intervalo com dia e hora (`de`/`ate`) no fuso da tela; a consulta usa o
# mesmo intervalo que a tela mostra, o período fica na URL e vai nos links entre telas, e o intervalo inválido mostra o erro
# sem 500. O contrato do `GET /v1/usage` não muda. Chama o app pelo ASGI (tests/lib/studio_asgi.py); sem servidor, sem rede.
# Uso: tests/agent-studio-periodo.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "$TMP"' EXIT
studio_init

cat > "$TMP/config.toml" <<'TOML'
timezone = "America/Sao_Paulo"
[prices."claude-sonnet-5"]
input = 3.0
output = 15.0
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import re, sys
from datetime import datetime, timezone
from agent_studio import config as CF
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC

# São Paulo = GMT-3 (sem horário de verão em 2025). O intervalo digitado é 09:00 a 18:00 locais = 12:00Z a 21:00Z.
db = StudioDB(tmp, "p")
for at, conv in (("2025-10-01T11:30:00", "c-antes"), ("2025-10-01T12:30:00", "c-dentro"), ("2025-10-01T20:30:00", "c-dentro2"),
                 ("2025-10-01T21:30:00", "c-depois")):
    db.span(ts(at), 2, model="claude-sonnet-5", task="T1", conv=conv, input=1000, output=100)
app = create_app(db.flush(), TOKEN, config=cfg)
DE, ATE = "2025-10-01T09:00", "2025-10-01T18:00"
Q = f"de={DE}&ate={ATE}"
PAGES = ("/", "/conversas", "/sessoes", "/uso")
H = {p: get(app, p, Q) for p in PAGES}

for p in PAGES:
    st, html = H[p]
    check(f"{p}: intervalo com dia e hora, 200", st == 200)
    check(f"{p}: janelas prontas 24 horas, 7 dias, 30 dias e 366 dias, as mesmas",
          re.findall(r'<a href="[^"]*hours=(\d+)[^"]*"[^>]*>([^<]*)</a>', html) == [("24", "24 horas"), ("168", "7 dias"), ("720", "30 dias"), ("8784", "366 dias")])
    check(f"{p}: De e Até com dia e hora, rotulados com o fuso, e o valor digitado de volta",
          f'<label>De (GMT-3)<input type="datetime-local" name="de" value="{DE}">' in html
          and f'<label>Até (GMT-3)<input type="datetime-local" name="ate" value="{ATE}">' in html)
    check(f"{p}: período ativo junto do controle, no fuso da tela", "2025-10-01 09:00:00 a 2025-10-01 18:00:00 · GMT-3" in html)
    check(f"{p}: com o intervalo, nenhuma janela pronta marcada", 'aria-current="true"' not in re.search(r'<nav class="janelas".*?</nav>', html, re.S).group(0))

# a consulta usa o mesmo intervalo que a tela mostra: 12:30Z e 20:30Z (09:30 e 17:30 locais) entram; 11:30Z e 21:30Z não
tot = re.search(r'id="total" data-calls="(\d+)"', H["/uso"][1])
check("/uso: só as 2 chamadas dentro do intervalo local", tot and tot.group(1) == "2")
check("/uso: os gráficos seguem o intervalo (2 chamadas nas colunas do custo por dia)",
      sum(int(c) for c in re.findall(r'<g class="coluna" data-bucket="[^"]*" data-calls="(\d+)"', H["/uso"][1])) == 2)
conv_ids = re.findall(r'data-conversa="([^"]*)"', H["/conversas"][1])
check("/conversas: só as 2 conversas dentro do intervalo", sorted(conv_ids) == ["c-dentro", "c-dentro2"])
dash = H["/"][1]
check("Dashboard: chamadas = 2", re.search(r'data-kpi="calls" data-value="2"', dash) is not None)
check("Dashboard: ver Uso e ver Sessões levam o intervalo exato (UTC, do que a tela mostra)",
      'href="/uso?from=2025-10-01T12%3A00%3A00Z&amp;to=2025-10-01T21%3A00%3A00Z"' in dash
      and 'href="/sessoes?from=2025-10-01T12%3A00%3A00Z&amp;to=2025-10-01T21%3A00%3A00Z"' in dash)
st, via = get(app, "/uso", "from=2025-10-01T12%3A00%3A00Z&to=2025-10-01T21%3A00%3A00Z")
check("o link do Dashboard abre o Uso com o mesmo período, no fuso da tela", st == 200 and "2025-10-01 09:00:00 a 2025-10-01 18:00:00 · GMT-3" in via
      and f'name="de" value="{DE}"' in via and 'id="total" data-calls="2"' in via)
check("recarregar a mesma URL dá a mesma página", get(app, "/uso", Q)[1] == H["/uso"][1])
check("segundos também valem (formato do navegador com step)", get(app, "/uso", f"de={DE}:00&ate={ATE}:00")[0] == 200)

# janelas prontas: o link leva host e agente; formulário com a janela pronta e de/ate em branco segue valendo
_, conv = get(app, "/conversas", "hours=24&host=oute-server&agent=claude")
check("janela pronta leva host e agente", '<a href="/conversas?hours=168&amp;host=oute-server&amp;agent=claude">7 dias</a>' in conv)
st, blank = get(app, "/conversas", "hours=168&de=&ate=&host=oute-server")
check("de/ate em branco com a janela pronta: 200, a janela marcada", st == 200 and '<a href="/conversas?hours=168&amp;host=oute-server" aria-current="true">7 dias</a>' in blank)
check("sem nada, o padrão é 24 horas marcado nas 4 telas", all(get(app, p)[1].count('aria-current="true">24 horas') == 1 for p in PAGES))

# intervalo inválido: o erro na tela (400), nunca 500
def erro(q, msg, pages=PAGES):
    out = [get(app, p, q) for p in pages]
    return all(s == 400 and msg in b for s, b in out)

check("fim antes do início: 400 com a mensagem", erro(f"de={ATE}&ate={DE}", "o fim precisa ser depois do início"))
check("fim igual ao início: 400", erro(f"de={DE}&ate={DE}", "o fim precisa ser depois do início"))
check("acima do máximo (366 dias): 400 com a mensagem", erro("de=2024-01-01T00:00&ate=2025-10-01T00:00", "máximo de 8784 h"))
check("de sem ate: 400", erro(f"de={DE}", "informe o início e o fim"))
check("ate sem de: 400", erro(f"ate={ATE}", "informe o início e o fim"))
check("formato que não é dia e hora: 400", erro("de=ontem&ate=hoje", "início inválido"))
check("hora de depois de 2262 não derruba: 400, não 500", get(app, "/uso", "de=2025-10-01T09:00&ate=9999-12-31T23:59")[0] == 400)
check("de/ate com from/to: 400", erro(f"{Q}&from=2025-10-01&to=2025-10-02", "só um deles"))
check("from/to acima do máximo na tela: 400 (o teto vale em toda janela da tela)", erro("from=2024-01-01&to=2025-10-01", "máximo de 8784 h"))
check("exatamente 366 dias passa", get(app, "/uso", "de=2024-10-01T00:00&ate=2025-10-02T00:00")[0] == 200)
check("hours inválido segue 400", get(app, "/uso", "hours=x")[0] == 400)

# o formulário renderizado, enviado como o navegador envia (#527, auditoria): janela pronta ativa + De/Até preenchidos
from html.parser import HTMLParser
from urllib.parse import urlencode


class Fields(HTMLParser):
    def __init__(self):
        super().__init__()
        self.inputs, self.in_form = [], False

    def handle_starttag(self, tag, a):
        a = dict(a)
        if tag == "form" and "filtro" in (a.get("class") or ""):
            self.in_form = True
        elif tag == "input" and self.in_form and a.get("name"):
            self.inputs.append((a["name"], a.get("value") or ""))

    def handle_endtag(self, tag):
        if tag == "form":
            self.in_form = False


def submit(path, query, **fill):
    """Renderiza `path?query`, preenche os campos do formulário do período e devolve a resposta ao GET do envio."""
    f = Fields()
    f.feed(get(app, path, query)[1])
    sent = [(k, fill.get(k, v)) for k, v in f.inputs]
    return get(app, path, urlencode(sent)), sent


for p in PAGES:
    (st, html), sent = submit(p, "hours=168", de=DE, ate=ATE)
    check(f"{p}: formulário da janela pronta enviado com De/Até: 200, não 400 (o hours do formulário não atrapalha)",
          st == 200 and ("hours", "168") in sent and f"2025-10-01 09:00:00 a 2025-10-01 18:00:00 · GMT-3" in html)
(st, html), sent = submit("/uso", "hours=168")
check("formulário enviado sem preencher De/Até: segue na janela pronta (7 dias marcada)", st == 200 and '<a href="/uso?hours=168" aria-current="true">7 dias</a>' in html)
(st, html), sent = submit("/conversas", Q, de="2025-10-01T10:00")
check("formulário do intervalo ativo, De alterado: sem hours no envio e período novo na tela", st == 200 and not any(k == "hours" for k, _ in sent) and "2025-10-01 10:00:00 a" in html)

# o contrato do /v1/usage não muda: sem `de`/`ate` e sem teto em from/to
st, body = get(app, "/v1/usage", "from=2024-01-01&to=2025-10-01")
check("/v1/usage: from/to acima de 8784 h segue 200 (contrato intacto)", st == 200)
st, body = get(app, "/v1/usage", "hours=24")
check("/v1/usage: hours segue 200", st == 200)
check("/v1/usage: de/ate não existem no contrato (ignorados; janela de 24 h)", get(app, "/v1/usage", Q)[0] == 200)

# DST: o fuso decide, não um deslocamento fixo (fuso de verão: Nova York em julho = GMT-4 = 04:00Z para 00:00 local)
import copy
cfg2 = CF.load(f"{tmp}/config.toml")
from agent_studio import tz as TZ
cfg2.tz = TZ.parse("America/New_York")
app2 = create_app(db.st, TOKEN, config=cfg2)
st, ny = get(app2, "/uso", "de=2025-07-01T00:00&ate=2025-07-01T12:00")
check("outro fuso: a janela mostrada é a digitada, com o rótulo do fuso", st == 200 and "2025-07-01 00:00:00 a 2025-07-01 12:00:00 · GMT-4" in ny)
st, ny2 = get(app2, "/", "de=2025-07-01T00:00&ate=2025-07-01T12:00")
check("outro fuso: o link leva o UTC certo (04:00Z a 16:00Z)", 'from=2025-07-01T04%3A00%3A00Z&amp;to=2025-07-01T16%3A00%3A00Z' in ny2)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 53
check_end
