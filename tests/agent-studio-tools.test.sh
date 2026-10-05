#!/usr/bin/env bash
# Testes da tela Ferramentas do agent-studio (#535, épico #522): o menu no grupo Análise, o uso de ferramenta por
# ferramenta (usos, erros, taxa, p95), o Bash aberto por tipo de comando (#600), por repositório e no tempo, os filtros (período, repositório, host, agente), a
# lista de conversas de cada ferramenta com os erros em destaque, a regra de contar um uso só uma vez (o span
# `claude_code.tool`, não o `tool.execution` nem o `blocked_on_user`), o gráfico do Dashboard, o escape do nome da
# ferramenta e a ausência da entrada e da saída. Chama o app pelo ASGI (tests/lib/studio_asgi.py) sobre um DuckDB de
# exemplo; sem servidor, sem rede e sem Docker.
# Uso: tests/agent-studio-tools.test.sh   (sai != 0 se algum caso falhar)
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
TOML

PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" > "$TMP/py.out" 2>&1 <<'PY'
import re, sys
from datetime import datetime, timezone

from agent_studio import config as CF
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get, raw_get
from studio_db import StudioDB
from studio_form import submit as form_submit

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2025-10-01T"
Q = "from=2025-10-01T00%3A00%3A00Z&to=2025-10-02T00%3A00%3A00Z"
NONE = "(sem)"
SECRET = "SEGREDO-DA-ENTRADA"
EVIL = "<img src=x onerror=1>"

db = StudioDB(tmp, "t")


def use(at, name, dur, exec_dur=None, conv=None, repo=None, host="oute-server", agent="claude", err=False, exec_err=False,
        ok=None, blocked=True, cls=None, argv0=None):
    """Um uso como o Claude Code manda: o span `tool` (com o nome), o `tool.execution` filho e o `blocked_on_user` filho.
    `cls` e `argv0` = os rótulos `bash_command_class` e `bash_argv0` do span `tool` (#600)."""
    attrs = {"full_command": SECRET, "tool_output": SECRET}
    if cls is not None:
        attrs["bash_command_class"] = cls
    if argv0 is not None:
        attrs["bash_argv0"] = argv0
    if name:
        attrs["tool_name"] = name
    parent = db.span(ts(at), dur, name="claude_code.tool", conv=conv, repo=repo, host=host, agent=agent, err=err, attrs=attrs)
    if blocked:
        db.span(ts(at), 0.03, name="claude_code.tool.blocked_on_user", conv=conv, repo=repo, host=host, agent=agent,
                parent=parent, attrs={"decision": "accept"})
    if exec_dur is not None:
        eattrs = {} if ok is None else {"success": ok}
        db.span(ts(at), exec_dur, name="claude_code.tool.execution", conv=conv, repo=repo, host=host, agent=agent,
                err=exec_err, parent=parent, attrs=eattrs)


# alfa (c-a1, oute-server): Bash ok, Bash com erro na execução, Read com erro no próprio span, Edit com success=false
use(f"{D}10:00:00", "Bash", 10, 2, conv="c-a1", repo="alfa", ok=True)
use(f"{D}10:05:00", "Bash", 10, 3, conv="c-a1", repo="alfa", exec_err=True)
use(f"{D}10:10:00", "Read", 10, None, conv="c-a1", repo="alfa", err=True)
use(f"{D}10:15:00", "Edit", 10, 1, conv="c-a1", repo="alfa", ok=False)
# beta (c-b1, oute-mac): Bash ok duas vezes, um uso sem nome e um do fim da janela com o filho depois dela
use(f"{D}11:00:00", "Bash", 10, 4, conv="c-b1", repo="beta", host="oute-mac", ok=True)
use(f"{D}11:30:00", "Bash", 10, 6, conv="c-b1", repo="beta", host="oute-mac", ok=True)
use(f"{D}11:40:00", None, 10, 1, conv="c-b1", repo="beta", host="oute-mac")
use("2025-10-01T23:59:59", "Grep", 5, 3, conv="c-b1", repo="beta", host="oute-mac", exec_err=True)
# sem repositório (c-solta): Read, um nome com HTML e três de um uso (para passar do corte do gráfico do Dashboard)
use(f"{D}13:00:00", "Read", 10, 2, conv="c-solta", ok=True)
use(f"{D}13:10:00", EVIL, 10, 1, conv="c-solta")
for i, name in enumerate(("T1", "T2", "T3")):
    use(f"{D}14:0{i}:00", name, 10, 1, conv="c-solta")
# o Codex: um span de ferramenta do MCP, sem tool_name
db.span(ts(f"{D}15:00:00"), 1, name="mcp.tools.call", conv="c-codex", agent="codex", attrs={})
# fora da janela: antes (gama) e logo depois
use("2025-09-20T10:00:00", "Bash", 10, 2, conv="c-g1", repo="gama", exec_err=True)
use("2025-10-02T00:00:01", "Bash", 10, 2, conv="c-fora", repo="alfa", exec_err=True)
# o Bash por tipo de comando (#600), num dia só dele (2025-10-03): cada classe que o Claude Code manda, o `cd`, um uso
# sem classe, uma classe que a tela não conhece e um Read com rótulo de Bash. `full_command` (o SECRET) começa por outro
# comando: se a tela o lesse, o grupo seria outro.
K = "2025-10-03T"
QK = "from=2025-10-03T00%3A00%3A00Z&to=2025-10-04T00%3A00%3A00Z"
BASH_CASES = [  # (classe, argv0, conversa, falha na execução)
    ("shell_builtin", "cd", "c-k1", True), ("shell_builtin", "cd", "c-k1", False), ("shell_builtin", "cd", "c-k2", False),
    ("shell_builtin", "echo", "c-k1", False), ("text_transform", "sed", "c-k1", False),
    ("file_read", "cat", "c-k1", True), ("file_read", "head", "c-k2", False),
    ("file_search", "grep", "c-k1", False), ("vcs", "git", "c-k1", False), ("github_cli", "gh", "c-k1", False),
    ("lang_runtime", "python3", "c-k1", False),
    ("other", "oute-task", "c-k1", False), ("fs_mutation", "mkdir", "c-k1", False), ("process_system", "ps", "c-k1", False),
    ("network", "curl", "c-k1", False), ("unparsed", None, "c-k2", True), ("package_manager", "npm", "c-k1", False),
    ("claude_cli", "claude", "c-k1", False), ("build_test", "make", "c-k1", False),
    (None, None, "c-k1", False), ("classe_nova", "x", "c-k1", False), ("other", "cd", "c-k1", False),
]
for i, (cls, argv0, conv, fail) in enumerate(BASH_CASES):
    use(f"{K}10:{i:02d}:00", "Bash", 10, 1, conv=conv, repo="alfa" if conv == "c-k1" else "beta", exec_err=fail, cls=cls, argv0=argv0)
use(f"{K}11:00:00", "Read", 10, 1, conv="c-k1", repo="alfa", cls="file_read", argv0="cat")
app = create_app(db.flush(), TOKEN, config=cfg)


def num(html, attr, scope="total"):
    m = re.search(rf'id="{scope}"[^>]*data-{attr}="([^"]*)"', html)
    return m.group(1) if m else None


def tool_rows(html):
    return {m[0]: (int(m[1]), int(m[2])) for m in re.findall(r'<tr[^>]*data-ferramenta="([^"]*)" data-usos="(\d+)" data-erros="(\d+)"', html)}


def repo_rows(html):
    return {m[0]: (int(m[1]), int(m[2])) for m in re.findall(r'data-repo="([^"]*)" data-usos="(\d+)" data-erros="(\d+)"', html)}


def clean(html):
    return html.replace("&#34;", '"')


st, html = get(app, "/ferramentas", Q)
EXPECT = {"Bash": (4, 1), "Read": (2, 1), "Edit": (1, 1), "(sem nome)": (1, 0), "Grep": (1, 1), EVIL.replace("<", "&lt;").replace(">", "&gt;"): (1, 0),
          "T1": (1, 0), "T2": (1, 0), "T3": (1, 0)}
rows = tool_rows(html)
EXPECT_ESC = {k.replace("&lt;", "&lt;"): v for k, v in EXPECT.items()}

# ---- o menu e a tela
nav = re.search(r'<nav class="nav-grupo" aria-label="Análise">(.*?)</nav>', get(app, "/", Q)[1], re.S)
check("o menu Ferramentas está no grupo Análise e leva a /ferramentas", nav is not None and 'href="/ferramentas"' in nav.group(1) and "Ferramentas" in nav.group(1))
check("a tela abre (200), só de leitura (sem formulário que não seja o filtro)", st == 200 and "<h1>Ferramentas</h1>" in html and html.count("<form") == html.count('<form class="filtro"') + html.count('<form method="post" action="/logout"'))
check("o item do menu fica marcado na tela", re.search(r'<a class="nav-item" href="/ferramentas" aria-current="page">', html) is not None)
other = create_app(db.st, "outra-credencial", config=cfg)  # a credencial do get() não vale nesta: é quem não entrou
check("sem login as duas telas mandam para o login (303)", get(other, "/ferramentas", Q)[0] == 303 and get(other, "/ferramenta", Q + "&nome=Bash")[0] == 303)
check("janela inválida: 400", get(app, "/ferramentas", "hours=abc")[0] == 400)

# ---- a regra de contagem: um uso = um span claude_code.tool
check("total da janela: 13 usos (os spans tool.execution e blocked_on_user não contam) e 4 erros", num(html, "usos") == "13" and num(html, "erros") == "4")
check("por ferramenta: usos e erros de cada uma, na janela (Bash 4/1, Read 2/1, Edit 1/1, sem nome 1/0, Grep 1/1…)",
      rows == {"Bash": (4, 1), "Read": (2, 1), "Edit": (1, 1), "(sem nome)": (1, 0), "Grep": (1, 1),
               "&lt;img src=x onerror=1&gt;": (1, 0), "T1": (1, 0), "T2": (1, 0), "T3": (1, 0)})
check("falha = erro no span tool, ou no execution filho, ou success=false (Read, Bash, Edit)",
      rows["Read"][1] == 1 and rows["Bash"][1] == 1 and rows["Edit"][1] == 1)
check("o filho do uso do fim da janela (começa depois dela) conta: Grep com erro", rows["Grep"] == (1, 1))
check("uso fora da janela (antes e depois) não entra: Bash tem 4, não 6", rows["Bash"][0] == 4)
check("taxa de erro por ferramenta (Bash 25%) e geral (4 de 13)", 'data-ferramenta="Bash" data-usos="4" data-erros="1" data-taxa="0.25"' in html and 'data-taxa="0.307' in html)
p95 = float(re.search(r'data-ferramenta="Bash"[^>]*data-p95-ms="([\d.]+)"', html).group(1))
check("p95 da duração: o da execução filha (2, 3, 4 e 6 s → 5,7 s), não o do span tool (10 s)", abs(p95 - 5700) < 1)
check("p95 do uso sem filho: o do próprio span (Read de c-a1 e c-solta: 10 s e 2 s)",
      abs(float(re.search(r'data-ferramenta="Read"[^>]*data-p95-ms="([\d.]+)"', html).group(1)) - 9600) < 1)

# ---- por repositório
check("por repositório: alfa 4 usos e 3 erros, beta 4 e 1, sem repositório 5 e 0 (soma = 13)",
      repo_rows(html) == {"alfa": (4, 3), "beta": (4, 1), "": (5, 0)})

# ---- o gráfico no tempo
pts = re.findall(r'<g class="ponto" data-bucket="([^"]*)" data-usos="(\d+)" data-erros="(\d+)"', html)
check("gráfico: 24 pontos por hora (janela de 24 h) e a soma dos usos é a do total", len(pts) == 24 and sum(int(u) for _, u, _ in pts) == 13)
check("gráfico: a hora 10 tem 4 usos e 3 erros; a 23h tem o Grep", ("2025-10-01 10", "4", "3") in pts and ("2025-10-01 23", "1", "1") in pts)
dia = get(app, "/ferramentas", "from=2025-09-29T00%3A00%3A00Z&to=2025-10-02T00%3A00%3A00Z")[1]
check("janela de 3 dias: o gráfico passa a ser por dia", 'data-unit="day"' in dia and len(re.findall(r'<g class="ponto"', dia)) == 3)
check("a nota diz que só o Claude Code manda span de ferramenta", "o Codex não" in html)

# ---- filtros
check("repo=beta: só os usos do repositório beta (4, 1 erro)", num(get(app, "/ferramentas", Q + "&repo=beta")[1], "usos") == "4")
check("repo='(sem)': os 5 usos sem repositório", num(get(app, "/ferramentas", Q + f"&repo={NONE}")[1], "usos") == "5")
check("host=oute-mac: os 4 usos de c-b1", num(get(app, "/ferramentas", Q + "&host=oute-mac")[1], "usos") == "4")
check("agent=codex: nenhum uso (o Codex não manda span de ferramenta com nome), 200 e o aviso", get(app, "/ferramentas", Q + "&agent=codex")[0] == 200
      and 'id="vazio"' in get(app, "/ferramentas", Q + "&agent=codex")[1] and num(get(app, "/ferramentas", Q + "&agent=codex")[1], "usos") == "0")
check("os filtros combinam: beta e oute-server = nenhum uso", num(get(app, "/ferramentas", Q + "&repo=beta&host=oute-server")[1], "usos") == "0")
sel = lambda name: re.findall(r'<option value="([^"]*)"', re.search(rf'<select name="{name}">(.*?)</select>', html, re.S).group(1))
check("opções: repositórios com fato (alfa, beta) e 'sem repositório'; hosts; agentes com codex", sel("repo") == ["", "alfa", "beta", NONE]
      and sel("host") == ["", "oute-mac", "oute-server"] and sel("agent") == ["", "claude", "codex"])
check("o formulário tem período (janelas prontas, De e Até), repositório, host e agente",
      all(x in html for x in ('<nav class="janelas"', 'name="de"', 'name="ate"', "<label>Repositório", "<label>Host", "<label>Agente")))

# o formulário renderizado, enviado como o navegador envia
(st2, h2), sent = form_submit(get, app, "/ferramentas", Q, repo="beta", host="oute-mac")
check("formulário enviado com repositório e host: 200, os campos no envio e só os 4 usos de beta", st2 == 200 and ("repo", "beta") in sent
      and ("host", "oute-mac") in sent and num(h2, "usos") == "4")
(st2, h2), sent = form_submit(get, app, "/ferramentas", "hours=168")
check("formulário enviado sem escolher (Todos): repo, host e agente em branco e 200", st2 == 200 and ("repo", "") in sent and ("host", "") in sent and ("agent", "") in sent)

# ---- a lista de conversas de uma ferramenta
st, bash = get(app, "/ferramenta", Q + "&nome=Bash")
conv = re.findall(r'<tr[^>]*data-conversa="([^"]*)" data-usos="(\d+)" data-erros="(\d+)"', bash)
check("Bash: as conversas que o usaram, com os erros primeiro (c-a1 2 usos e 1 erro, depois c-b1 2 e 0)", st == 200
      and conv == [("c-a1", "2", "1"), ("c-b1", "2", "0")])
check("Bash: a linha com erro vem em destaque (classe e emblema com link para os erros da conversa)", 'class="com-erro"' in bash
      and 'href="/conversa?id=c-a1&amp;erros=1"' in bash and 'href="/conversa?id=c-b1&amp;erros=1"' not in bash)
check("Bash: leva ao detalhe da conversa", 'href="/conversa?id=c-a1"' in bash and num(bash, "usos") == "4" and num(bash, "erros") == "1")
check("Read com os filtros: repo=alfa só lista c-a1", [c[0] for c in re.findall(r'<tr[^>]*data-conversa="([^"]*)" data-usos="(\d+)" data-erros="(\d+)"', get(app, "/ferramenta", Q + "&nome=Read&repo=alfa")[1])] == ["c-a1"])
st, vazio = get(app, "/ferramenta", Q + "&nome=Nada")
check("ferramenta sem uso na janela: 200 e o aviso", st == 200 and 'id="vazio"' in vazio)
check("sem o nome da ferramenta: 400", get(app, "/ferramenta", Q)[0] == 400)
check("a lista da ferramenta com nome sem nome ('(sem nome)'): a conversa c-b1", re.findall(r'<tr[^>]*data-conversa="([^"]*)" data-usos', get(app, "/ferramenta", Q + "&nome=%28sem+nome%29")[1]) == ["c-b1"])
check("cada ferramenta da tela leva à lista, com a janela e os filtros", 'href="/ferramenta?nome=Bash&amp;from=2025-10-01T00%3A00%3A00Z&amp;to=2025-10-02T00%3A00%3A00Z"' in html
      and 'nome=Bash&amp;from=2025-10-01T00%3A00%3A00Z&amp;to=2025-10-02T00%3A00%3A00Z&amp;repo=beta' in get(app, "/ferramentas", Q + "&repo=beta")[1])

# ---- o Bash por tipo de comando (#600)
def group_rows(h):
    return [(m[0], int(m[1]), int(m[2]), m[3]) for m in re.findall(r'<tr class="grupo-bash[^"]*" data-grupo="([^"]*)" data-usos="(\d+)" data-erros="(\d+)" data-taxa="([^"]*)"', h)]


def group_names(h):
    return re.findall(r'<a href="/ferramenta\?nome=Bash&amp;grupo=([a-z]+)&amp;[^"]*">([^<]*)</a>', h)


def convs(h):
    return re.findall(r'<tr[^>]*data-conversa="([^"]*)" data-usos="(\d+)" data-erros="(\d+)"', h)


stk, hk = get(app, "/ferramentas", QK)
groups = group_rows(hk)
by_id = {g[0]: g[1:3] for g in groups}
bash_k = tool_rows(hk).get("Bash")
check("Bash por tipo: a linha Bash da janela tem 22 usos e 3 erros, e o Read com rótulo de Bash fica no Read", stk == 200 and bash_k == (22, 3) and tool_rows(hk).get("Read") == (1, 0))
check("Bash por tipo: no máximo 8 grupos, o maior primeiro (outros 11, cd 3, depois empate por id)",
      [g[0] for g in groups] == ["outros", "cd", "ler", "shell", "buscar", "gh", "git", "linguagem"] and len(groups) <= 8)
check("Bash por tipo: usos e erros de cada grupo (cd 3/1, ler 2/1, buscar 1/0, git 1/0, gh 1/0, linguagem 1/0, shell 2/0, outros 11/1)",
      by_id == {"cd": (3, 1), "ler": (2, 1), "buscar": (1, 0), "git": (1, 0), "gh": (1, 0), "linguagem": (1, 0), "shell": (2, 0), "outros": (11, 1)})
check("Bash por tipo: a soma dos grupos é igual aos usos e aos erros de Bash da janela", bash_k is not None
      and (sum(g[1] for g in groups), sum(g[2] for g in groups)) == bash_k)
rates = {g[0]: g[3] for g in groups}
check("Bash por tipo: cada grupo mostra a taxa de erro (cd 1 de 3, ler 50%, git 0)", rates.get("cd", "")[:5] == "0.333"
      and rates.get("ler") == "0.5" and rates.get("git") == "0.0" and "33,3" in hk)
check("Bash por tipo: `cd` só é grupo próprio na classe shell_builtin (echo vai para shell; `other` com argv0 cd, para outros)",
      by_id.get("cd") == (3, 1) and by_id.get("shell") == (2, 0))
check("Bash por tipo: unparsed, uso sem classe e classe desconhecida caem em outros (8 classes sem grupo + 3 = 11)", by_id.get("outros") == (11, 1))
check("Bash por tipo: nomes em pt-BR, cada um com link para o filtro do grupo", dict(group_names(hk)) == {
    "cd": "cd e encadeado", "ler": "ler arquivo", "buscar": "buscar", "git": "git", "gh": "GitHub (gh)",
    "linguagem": "linguagem (python e outras)", "shell": "shell e texto", "outros": "outros"})
check("Bash por tipo: os grupos vêm logo depois da linha Bash, antes da ferramenta seguinte",
      re.search(r'data-ferramenta="Bash".*?data-grupo="outros".*?data-grupo="linguagem".*?data-ferramenta="Read"', hk, re.S) is not None)
check("Bash por tipo: a tela diz que o texto do comando não é lido", "o texto do comando não é lido" in hk)
check("Bash por tipo: uso sem rótulo (os 4 da primeira janela) fica todo em outros, e a soma segue igual", group_rows(html) == [("outros", 4, 1, "0.25")])
hkb = get(app, "/ferramentas", QK + "&repo=beta")[1]
check("Bash por tipo com repo=beta: os grupos acompanham o filtro (cd 1, ler 1, outros 1) e o link leva o repositório",
      {g[0]: g[1:3] for g in group_rows(hkb)} == {"cd": (1, 0), "ler": (1, 0), "outros": (1, 1)}
      and 'href="/ferramenta?nome=Bash&amp;grupo=cd&amp;from=2025-10-03T00%3A00%3A00Z&amp;to=2025-10-04T00%3A00%3A00Z&amp;repo=beta"' in hkb)
check("Bash por tipo: janela sem Bash não tem linha de grupo", group_rows(get(app, "/ferramentas", QK + "&agent=codex")[1]) == [])
stg, hg = get(app, "/ferramenta", QK + "&nome=Bash&grupo=cd")
check("filtro por grupo: cd lista só os usos do grupo, por conversa (c-k1 2 usos e 1 erro, c-k2 1 e 0), com o nome do grupo",
      stg == 200 and convs(hg) == [("c-k1", "2", "1"), ("c-k2", "1", "0")] and num(hg, "usos") == "3" and num(hg, "erros") == "1"
      and num(hg, "grupo") == "cd" and "cd e encadeado" in hg)
check("filtro por grupo: outros traz o unparsed de c-k2 (1 uso, 1 erro) e os 10 de c-k1",
      sorted(convs(get(app, "/ferramenta", QK + "&nome=Bash&grupo=outros")[1])) == [("c-k1", "10", "0"), ("c-k2", "1", "1")])
check("filtro por grupo com repo=beta: só c-k2", convs(get(app, "/ferramenta", QK + "&nome=Bash&grupo=ler&repo=beta")[1]) == [("c-k2", "1", "0")])
check("sem grupo, a lista do Bash segue com todos os usos (22)", num(get(app, "/ferramenta", QK + "&nome=Bash")[1], "usos") == "22")
stv, hv = get(app, "/ferramenta", Q + "&nome=Bash&grupo=git")
check("grupo sem uso na janela: 200 e o aviso", stv == 200 and 'id="vazio"' in hv)
check("grupo que não existe: 400, no casco e na página inteira", raw_get(app, "/ferramenta", QK + "&nome=Bash&grupo=nada")[0] == 400
      and raw_get(app, "/ferramenta", QK + "&nome=Bash&grupo=nada&full=1")[0] == 400)
check("grupo em ferramenta que não é o Bash: 400, no casco e na página inteira", raw_get(app, "/ferramenta", QK + "&nome=Read&grupo=ler")[0] == 400
      and raw_get(app, "/ferramenta", QK + "&nome=Read&grupo=ler&full=1")[0] == 400)
check("a página inteira (full=1) do grupo abre: 200 com os 3 usos de cd", raw_get(app, "/ferramenta", QK + "&nome=Bash&grupo=cd&full=1")[0] == 200
      and num(raw_get(app, "/ferramenta", QK + "&nome=Bash&grupo=cd&full=1")[1], "usos") == "3")
dk = get(app, "/", QK)[1]
gk = re.search(r'<section[^>]*data-grafico="ferramentas".*?</section>', dk, re.S)
check("Dashboard: o Bash segue como uma barra só (22 usos), sem grupo, com link para a tela", gk is not None
      and re.findall(r'data-ferramenta="Bash" data-usos="(\d+)"', gk.group(0)) == ["22"] and "grupo" not in gk.group(0)
      and 'href="/ferramentas?from=2025-10-03T00%3A00%3A00Z' in gk.group(0))

# ---- dado não confiável e sem entrada nem saída
page = hk + hg + html + bash + get(app, "/ferramenta", Q + "&nome=" + "%3Cimg+src%3Dx+onerror%3D1%3E")[1] + get(app, "/", Q)[1]
check("nome de ferramenta com HTML sai escapado em toda tela, nunca cru", EVIL not in page and "&lt;img src=x onerror=1&gt;" in page)
check("a tela não mostra a entrada nem a saída da ferramenta", SECRET not in page)

# ---- o Dashboard
dash = get(app, "/", Q)[1]
g = re.search(r'<section[^>]*data-grafico="ferramentas"[^>]*data-total="(\d+)" data-erros="(\d+)".*?</section>', dash, re.S)
top = re.findall(r'data-ferramenta="([^"]*)" data-usos="(\d+)" data-erros="(\d+)"', g.group(0)) if g else []
check("Dashboard: gráfico das ferramentas mais usadas, com o total e os erros da janela (13 e 4)", g is not None and g.group(1) == "13" and g.group(2) == "4")
check("Dashboard: as 8 mais usadas, a maior primeiro, e a nona (T3, empate no menor) fica de fora", len(top) == 8 and top[0] == ("Bash", "4", "1") and top[1][0] == "Read"
      and "T3" not in [t[0] for t in top] and "T1" in [t[0] for t in top])
check("Dashboard: o gráfico leva à tela Ferramentas com a janela, e cada barra à lista da ferramenta",
      g is not None and 'href="/ferramentas?from=2025-10-01T00%3A00%3A00Z&amp;to=2025-10-02T00%3A00%3A00Z"' in g.group(0)
      and 'href="/ferramenta?nome=Bash&amp;' in g.group(0))
dbeta = get(app, "/", Q + "&repo=beta")[1]
gb = re.search(r'<section[^>]*data-grafico="ferramentas"[^>]*data-total="(\d+)" data-erros="(\d+)".*?</section>', dbeta, re.S)
check("Dashboard com repo=beta: o gráfico acompanha o repositório (4 usos, 1 erro) e o link leva o repositório",
      gb is not None and gb.group(1) == "4" and gb.group(2) == "1" and "repo=beta" in re.search(r'href="(/ferramentas\?[^"]*)"', gb.group(0)).group(1))
vazio = get(app, "/", "from=2025-01-01T00%3A00%3A00Z&to=2025-01-02T00%3A00%3A00Z")[1]
check("Dashboard sem uso de ferramenta na janela: o gráfico diz que não há", "Nenhum uso de ferramenta nesta janela." in vazio)
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 64
check_end
