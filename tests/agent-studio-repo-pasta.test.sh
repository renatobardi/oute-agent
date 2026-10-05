#!/usr/bin/env bash
# Testes do repositório da pasta no agent-studio (#599, ADR-04 "Repositório da pasta"): a conversa aberta direto numa pasta
# chega com `oute.task.repo` e sem `oute.task.id`. Ela entra no filtro de repositório das cinco telas (Dashboard, Conversas,
# Sessões, Uso, Ferramentas) sob o repositório dela e na fase `interativa`; `desconhecida` fica só para a sessão com id e
# sem fase. No histórico, o repositório é inferido só pelo `file_path` dos spans de ferramenta (`repo_infer`): checkout
# principal, subpasta, worktree (formato novo e antigo) e a pasta codificada do harness; caminho fora de repositório,
# empate, conversa sem `file_path` e o texto do comando não dão repositório. Sem Docker e sem processo em segundo plano.
# As datas ficam depois de 2026-10-06 (o corte do acerto do histórico, #617), para valer a regra normal.
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
import logging, re, sys
from datetime import datetime, timezone

import duckdb
from agent_studio import config as CF, repo_infer as RI, store as ST
from agent_studio.app import create_app
from pycheck import check
from studio_asgi import TOKEN, get
from studio_db import StudioDB

tmp = sys.argv[1]
cfg = CF.load(f"{tmp}/config.toml")
SEC = 10**9
ts = lambda s: int(datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()) * SEC
D = "2026-11-01T"
Q = "from=2026-11-01T00%3A00%3A00Z&to=2026-11-02T00%3A00%3A00Z"
NONE = "(sem)"
tok = dict(input=1000, output=100)

# ---- 1. path_repo: o que cada forma de caminho diz
K = {"alfa", "beta", "alfa-web"}
p = lambda path: RI.path_repo(path, K)
check("checkout principal: /workspace/<repo>/arquivo", p("/workspace/alfa/README.md") == "alfa")
check("subpasta: o repositório, não a subpasta", p("/workspace/alfa/docs/adr/0004.md") == "alfa")
check("worktree no formato novo: <espaço>/<repo>-<slug>", p("/workspace/.worktrees/meu-espaco/beta-12-x/a.py") == "beta")
check("worktree no formato antigo: <repo>-<slug>", p("/workspace/.worktrees/beta-9-y/docs/a.md") == "beta")
check("worktree: vale o nome conhecido mais longo", p("/workspace/.worktrees/e/alfa-web-3-z/a") == "alfa-web")
check("worktree num espaço com nome de repositório: vale a pasta da worktree", p("/workspace/.worktrees/alfa/beta-1-x/a") == "beta")
check("pasta codificada do harness, checkout principal", p("/tmp/claude-10001/-workspace-alfa/conv/x.txt") == "alfa")
check("pasta codificada em ~/.claude/projects", p("/home/oute/.claude/projects/-workspace-beta/memory/a.md") == "beta")
check("pasta codificada de worktree, formato antigo", p("/tmp/claude-10001/-workspace--worktrees-beta-9-y/conv/x") == "beta")
check("pasta codificada de worktree, espaço e repositório iguais", p("/tmp/claude-10001/-workspace--worktrees-beta-beta-9-y/c/x") == "beta")
check("pasta codificada de worktree com dois nomes conhecidos diferentes: dúvida, sem repositório",
      p("/tmp/claude-10001/-workspace--worktrees-alfa-beta-9-y/c/x") is None)
check("pasta codificada de espaço desconhecido: sem repositório", p("/tmp/claude-10001/-workspace--worktrees-meu-beta-9-y/c/x") is None)
check("pasta codificada de subpasta: sem repositório (não dá para separar do nome)", p("/tmp/claude-10001/-workspace-alfa-docs/c/x") is None)
check("repositório que o banco não conhece: sem repositório", p("/workspace/gama/a.py") is None and p("/workspace/.worktrees/e/gama-1-x/a") is None)
check("a pasta /workspace/<repo> sem arquivo dentro não vota", p("/workspace/alfa") is None)
check("fora de repositório: /tmp, home e caminho relativo", [p("/tmp/aud1/head/a"), p("/home/oute/notas.md"), p("alfa/a.py"), p("")] == [None] * 4)
check("valor que não é texto e banco sem repositório conhecido", RI.path_repo(None, K) is None and RI.path_repo("/workspace/alfa/a", set()) is None)
check("dois repositórios com a mesma forma codificada: fora",
      RI.path_repo("/tmp/claude-1/-workspace-a-b/c/x", {"a.b", "a_b"}) is None)

# ---- 2. o banco: conversas novas (com a marca do shim) e o histórico (sem repositório em fato nenhum)
db = StudioDB(tmp, "p")


def tool(at, conv, path=None, cmd=None, repo=None, task=None):
    attrs = {"tool_name": "Read"}
    if path is not None:
        attrs["file_path"] = path
    if cmd is not None:
        attrs["full_command"] = cmd
    db.span(ts(at), 1, name="claude_code.tool", conv=conv, repo=repo, task=task, attrs=attrs)


def call(at, conv, repo=None, task=None):
    db.span(ts(at), 2, model="claude-sonnet-5", conv=conv, repo=repo, task=task, **tok)


# sessões do oute-task: os repositórios conhecidos. T-alfa tem fase (build); T-beta tem id e nenhum evento de abertura
call(f"{D}08:00:00", "c-a1", "alfa", "T-alfa"); tool(f"{D}08:01:00", "c-a1", "/workspace/.worktrees/e/alfa-1-x/a", repo="alfa", task="T-alfa")
db.log(ts(f"{D}07:59:00"), "oute.task.opened", {"oute.task.phase": "build"}, task="T-alfa", repo="alfa")
call(f"{D}08:10:00", "c-b1", "beta", "T-beta")
# conversa nova aberta direto na pasta: o shim marcou o repositório, sem oute.task.id
call(f"{D}09:00:00", "c-pasta", "alfa"); call(f"{D}09:05:00", "c-pasta", "alfa"); tool(f"{D}09:06:00", "c-pasta", "/tmp/x", repo="alfa")
# o revisor de uma rodada: uma chamada, sem ferramenta, com o repositório da rodada
db.span(ts(f"{D}09:30:00"), 2, model="claude-sonnet-5", conv="c-revisor", repo="beta", **tok)
# pasta fora de repositório: continua sem repositório
call(f"{D}09:40:00", "c-fora")
# histórico, sem repositório em fato nenhum
call(f"{D}10:00:00", "h-main"); tool(f"{D}10:01:00", "h-main", "/workspace/alfa/README.md")
db.log(ts(f"{D}10:02:00"), "tool_result", {}, conv="h-main")
call(f"{D}10:10:00", "h-sub"); tool(f"{D}10:11:00", "h-sub", "/workspace/alfa/docs/adr/0004.md")
call(f"{D}10:20:00", "h-wt"); tool(f"{D}10:21:00", "h-wt", "/workspace/.worktrees/e/beta-12-x/a.py"); tool(f"{D}10:22:00", "h-wt", "/workspace/.worktrees/beta-9-y/a.py")
call(f"{D}10:30:00", "h-enc"); tool(f"{D}10:31:00", "h-enc", "/tmp/claude-10001/-workspace-alfa/h-enc/x.txt")
call(f"{D}10:40:00", "h-maioria")
for i, path in enumerate(("/workspace/alfa/a", "/workspace/alfa/b", "/workspace/beta/c", "/tmp/y")):
    tool(f"{D}10:4{i + 1}:00", "h-maioria", path)
call(f"{D}10:50:00", "h-empate"); tool(f"{D}10:51:00", "h-empate", "/workspace/alfa/a"); tool(f"{D}10:52:00", "h-empate", "/workspace/beta/b")
call(f"{D}11:00:00", "h-tmp"); tool(f"{D}11:01:00", "h-tmp", "/tmp/aud1/head/a")
call(f"{D}11:10:00", "h-sem")  # revisor antigo ou conversa sem ferramenta: nenhum file_path
call(f"{D}11:20:00", "h-cmd"); tool(f"{D}11:21:00", "h-cmd", cmd="cd /workspace/alfa && cat /workspace/alfa/README.md")
st = db.flush()

plan = RI.plan(st.con)
WANT = {"h-main": "alfa", "h-sub": "alfa", "h-wt": "beta", "h-enc": "alfa", "h-maioria": "alfa"}
check("plan (só leitura): cada conversa do histórico com o repositório da pasta", plan["inferred"] == WANT)
check("plan: candidatas = conversas sem repositório com algum file_path (7)", plan["candidates"] == 7)
check("plan: nada gravado", st.con.execute("SELECT count(*) FROM spans WHERE session_id LIKE 'h-%' AND oute_repo IS NOT NULL").fetchone()[0] == 0)
check("empate, só /tmp, sem file_path e só o texto do comando: sem repositório",
      not {"h-empate", "h-tmp", "h-sem", "h-cmd"} & set(plan["inferred"]))
check("conversa que já tem repositório (c-pasta) e a de fora de repositório não entram", not {"c-pasta", "c-fora", "c-a1"} & set(plan["inferred"]))
st.close()

# ---- 3. a subida aplica, uma vez
st = ST.Store(f"{tmp}/p.duckdb")
got = dict(st.con.execute("SELECT session_id, any_value(oute_repo) FROM spans WHERE session_id LIKE 'h-%' GROUP BY ALL").fetchall())
check("subida: o histórico ganha o repositório em todos os spans da conversa",
      {k: v for k, v in got.items() if v} == WANT
      and st.con.execute("SELECT count(*) FROM spans WHERE session_id = 'h-maioria' AND oute_repo = 'alfa'").fetchone()[0] == 5)
check("subida: os logs da conversa também", st.con.execute("SELECT oute_repo FROM logs WHERE session_id = 'h-main'").fetchall() == [("alfa",)])
check("subida: o que sobra fica sem repositório", [got[k] for k in ("h-empate", "h-tmp", "h-sem", "h-cmd")] == [None] * 4
      and st.con.execute("SELECT count(*) FROM spans WHERE session_id = 'c-fora' AND oute_repo IS NOT NULL").fetchone()[0] == 0)
check("subida: o resource_attributes não muda (o fato inferido se reconhece)",
      st.con.execute("SELECT count(*) FROM spans WHERE session_id LIKE 'h-%' AND resource_attributes <> '{}'").fetchone()[0] == 0)
check("subida: quem já tinha repositório fica como estava",
      st.con.execute("SELECT session_id, oute_repo FROM spans WHERE session_id IN ('c-a1', 'c-b1', 'c-pasta', 'c-revisor') GROUP BY ALL ORDER BY 1").fetchall()
      == [("c-a1", "alfa"), ("c-b1", "beta"), ("c-pasta", "alfa"), ("c-revisor", "beta")])
again = RI.apply(st.con)
check("segunda vez: nenhuma linha muda", again is not None and again["inferred"] == {} and sum(again["rows"].values()) == 0)

# ---- 4. falha da inferência: nada muda pela metade e a subida segue


class Broken:
    """Conexão que falha no primeiro UPDATE de `logs`, depois de `spans` já ter sido alterado na transação."""

    def __init__(self, con):
        self.con, self.sql = con, []

    def execute(self, sql, params=None):
        self.sql.append(sql.split()[0])
        if sql.startswith("UPDATE logs"):
            raise duckdb.Error("falha de teste")
        return self.con.execute(sql, params) if params is not None else self.con.execute(sql)


class Keep(logging.Handler):
    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())


keep = Keep()
logging.getLogger("agent_studio").addHandler(keep)
st.con.execute("UPDATE spans SET oute_repo = NULL WHERE session_id LIKE 'h-%'")
st.con.execute("UPDATE logs SET oute_repo = NULL WHERE session_id LIKE 'h-%'")
broken = Broken(st.con)
check("falha no meio: devolve None, sem exceção", RI.apply(broken) is None)
check("falha no meio: a transação foi desfeita (ROLLBACK) e nenhum span ficou com repositório",
      broken.sql[-1] == "ROLLBACK" and "COMMIT" not in broken.sql
      and st.con.execute("SELECT count(*) FROM spans WHERE session_id LIKE 'h-%' AND oute_repo IS NOT NULL").fetchone()[0] == 0)


class Dead:
    def execute(self, *a):
        raise duckdb.Error("falha de teste")


check("falha já na leitura: devolve None, sem exceção", RI.apply(Dead()) is None)
check("falha: um aviso por falha no log, só com o tipo do erro (sem o texto dele)",
      keep.lines == ["repo_infer: falhou (Error); o histórico segue sem repositório"] * 2)
check("depois da falha, a aplicação seguinte grava tudo", RI.apply(st.con)["inferred"] == WANT)

# ---- 5. as telas: a conversa da pasta sob o repositório dela, nos cinco filtros
app = create_app(st, TOKEN, config=cfg)


def ids(html, attr="conversa"):
    return sorted(set(re.findall(rf'data-{attr}="([^"]*)"', html)))


def q(repo=None):
    return Q + (f"&repo={repo}" if repo is not None else "")


ALFA = ["c-a1", "c-pasta", "h-enc", "h-main", "h-maioria", "h-sub"]
SEM = ["c-fora", "h-cmd", "h-empate", "h-sem", "h-tmp"]
check("Conversas: alfa traz a sessão, a conversa da pasta e o histórico inferido", ids(get(app, "/conversas", q("alfa"))[1]) == ALFA)
check("Conversas: beta traz a sessão, o revisor e a worktree do histórico", ids(get(app, "/conversas", q("beta"))[1]) == ["c-b1", "c-revisor", "h-wt"])
check("Conversas: 'sem repositório' = a pasta fora de repositório e o que a inferência não cobre", ids(get(app, "/conversas", q(NONE))[1]) == SEM)
sess = {r: get(app, "/sessoes", q(r))[1] for r in ("alfa", "beta", NONE)}
check("Sessões: a conversa da pasta (sem sessão) aparece no repositório dela", ids(sess["alfa"]) == ALFA and ids(sess["alfa"], "sessao") == ["T-alfa"])
check("Sessões: o revisor aparece no repositório da rodada", "c-revisor" in ids(sess["beta"]) and "c-revisor" not in ids(sess[NONE]))
check("Sessões: 'sem repositório' não traz a conversa da pasta", ids(sess[NONE]) == SEM)


def kpi(html):
    m = re.search(r'data-kpi="calls" data-value="(\d+)"', html)
    return int(m.group(1)) if m else None


def uso(html):
    m = re.search(r'id="total" data-calls="(\d+)"', html)
    return int(m.group(1)) if m else None


check("Dashboard: chamadas por filtro (alfa 7, beta 3, sem repositório 5)", [kpi(get(app, "/", q(r))[1]) for r in ("alfa", "beta", NONE)] == [7, 3, 5])
check("Uso: chamadas por filtro (alfa 7, beta 3, sem repositório 5)", [uso(get(app, "/uso", q(r))[1]) for r in ("alfa", "beta", NONE)] == [7, 3, 5])
dash = get(app, "/", Q)[1]
check("Dashboard, bloco Repositórios: a conversa da pasta conta em alfa", re.findall(r'data-repo="([^"]*)" data-calls="(\d+)"', dash)
      == [("alfa", "7"), ("", "5"), ("beta", "3")])


def usos(html):
    m = re.search(r'id="total"[^>]*data-usos="([^"]*)"', html)
    return m.group(1) if m else None


check("Ferramentas: usos por filtro (alfa 9, beta 2, sem repositório 4)", [usos(get(app, "/ferramentas", q(r))[1]) for r in ("alfa", "beta", NONE)] == ["9", "2", "4"])

# ---- 6. a fase: `interativa` para a conversa sem oute.task.id; `desconhecida` só para a sessão com id e sem fase
fases = dict(re.findall(r'data-fase="(\w+)" data-tokens="(\d+)"', dash))
check("Dashboard: as fases são build, desconhecida e interativa", sorted(fases) == ["build", "desconhecida", "interativa"])
check("Dashboard: desconhecida = só a sessão com id e sem fase (T-beta, 1 chamada); interativa = as 13 sem id",
      fases == {"build": "1100", "desconhecida": "1100", "interativa": str(13 * 1100)})
html = get(app, "/uso", Q)[1]
rows = dict(re.findall(r'data-phase="(\w+)"[^>]*data-calls="(\d+)"', html))
check("Uso: tabela por fase com interativa (13), desconhecida (1) e build (1)", rows == {"interativa": "13", "desconhecida": "1", "build": "1"})
check("Uso: a nota da tabela explica as duas", "fica em desconhecida, e conversa aberta fora do oute-task, em interativa" in html)
rows = dict(re.findall(r'data-phase="(\w+)"[^>]*data-calls="(\d+)"', get(app, "/uso", q("alfa"))[1]))
check("Uso com filtro alfa: a conversa da pasta e o histórico em interativa (6), a sessão em build (1)", rows == {"interativa": "6", "build": "1"})
st.close()
PY
grep -v '^ok   ' "$TMP/py.out" | grep -v '^FAIL' || true
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
check "o Python rodou todos os casos" test "$(grep -c -E '^(ok   |FAIL )' "$TMP/py.out")" = 49
check_end
