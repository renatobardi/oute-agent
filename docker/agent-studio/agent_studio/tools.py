"""Ferramentas `/ferramentas` e `/ferramenta` (#535, épico #522): o uso de ferramentas dos agentes, só leitura.

**O que é um uso (regra no ADR-08, "Uso de ferramenta"):** um span `claude_code.tool`. Cada um tem um filho
`claude_code.tool.execution` (mesmo `tool_use_id`) e, em geral, um `claude_code.tool.blocked_on_user`; esses dois não
entram na contagem, senão o mesmo uso valeria dois ou três. O nome é o `tool_name` do span `tool` (o `execution` não o
tem); sem nome, `NO_NAME`. Falha = o span `tool` com status de erro, ou o `execution` filho com status de erro ou
com `success` igual a `false`. Duração = a do `execution` (o `tool` inclui a espera da aprovação) ou, sem ele, a do `tool`.

- **Só o Claude Code:** o Codex não manda span de ferramenta com nome (ADR-08); com o filtro `codex` a tela mostra zero.
- **Sem entrada nem saída da ferramenta:** nenhum atributo do span além de `tool_name` e `success` é lido; o conteúdo
  fica no detalhe da conversa.
- **Janela:** o `execution` é procurado até `EXEC_PAD_NS` depois do fim da janela, para o filho de um uso do fim dela.
- **No SQL:** filtros sempre em parâmetro; o resto do texto é constante deste módulo.
"""
from . import dashboard as dash_mod, repo as repo_mod, tz as tz_mod
from .cost import SPAN_STATUS_ERROR

NO_NAME = "(sem nome)"
EXEC_PAD_NS = 60 * 1_000_000_000
TOP = 8             # ferramentas no gráfico do Dashboard
CONV_LIMIT = 200    # conversas na lista de uma ferramenta
NO_REPO = "sem repositório"

_TOOL = "claude_code.tool"
_EXEC = "claude_code.tool.execution"


def _rows(con, sql, params):
    cur = con.execute(sql, params)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def _uses(from_ns, to_ns, repo=None, host=None, agent=None, tool=None):
    """(CTE `uses`, parâmetros): um uso por linha, na janela, com os filtros. Colunas: conv, used_ns, host, agent, repo, tool,
    dur (ns), failed."""
    rsql, rparams = repo_mod.clause(repo, "t.oute_repo")
    extra, eparams = "", []
    for col, value in (("t.host_name", host), ("t.oute_agent", agent)):
        if value:
            extra += f" AND {col} = ?"
            eparams.append(value)
    name = f"COALESCE(NULLIF(json_extract_string(t.attributes, '$.tool_name'), ''), '{NO_NAME}')"
    if tool is not None:
        extra += f" AND {name} = ?"
        eparams.append(tool)
    sql = (
        "WITH ex AS (SELECT trace_id, parent_span_id AS sid, max(duration_ns) AS dur, "
        "bool_or(status_code = ? OR json_extract_string(attributes, '$.success') = 'false') AS failed "
        "FROM spans WHERE name = ? AND time_unix_nano >= ? AND time_unix_nano < ? GROUP BY trace_id, parent_span_id), "
        f"uses AS (SELECT t.session_id AS conv, t.time_unix_nano AS used_ns, t.host_name AS host, t.oute_agent AS agent, "
        f"t.oute_repo AS repo, {name} AS tool, COALESCE(ex.dur, t.duration_ns) AS dur, "
        "(t.status_code = ? OR COALESCE(ex.failed, FALSE)) AS failed "
        "FROM spans t LEFT JOIN ex ON ex.trace_id = t.trace_id AND ex.sid = t.span_id "
        f"WHERE t.name = ? AND t.time_unix_nano >= ? AND t.time_unix_nano < ?{rsql}{extra})")
    return sql, [SPAN_STATUS_ERROR, _EXEC, from_ns, to_ns + EXEC_PAD_NS, SPAN_STATUS_ERROR, _TOOL, from_ns, to_ns,
                 *rparams, *eparams]


def _rate(errors, uses):
    return errors / uses if uses else None


def _by_tool(con, from_ns, to_ns, repo=None, host=None, agent=None, limit=None):
    cte, params = _uses(from_ns, to_ns, repo, host, agent)
    rows = _rows(con, f"{cte} SELECT tool, count(*) AS uses, count(*) FILTER (WHERE failed) AS errors, "
                      "quantile_cont(CAST(dur AS DOUBLE), 0.95) / 1e6 AS p95_ms FROM uses GROUP BY tool "
                      f"ORDER BY uses DESC, tool{f' LIMIT {int(limit)}' if limit else ''}", params)
    peak = rows[0]["uses"] if rows else 0
    for r in rows:
        r["rate"] = _rate(r["errors"], r["uses"])
        r["frac"] = r["uses"] / peak if peak else 0.0
    return rows


def top(con, from_ns, to_ns, repo=None):
    """As ferramentas mais usadas para o gráfico do Dashboard: `{"rows", "total", "errors"}` (total e erros = da janela inteira)."""
    rows = _by_tool(con, from_ns, to_ns, repo, limit=TOP)
    cte, params = _uses(from_ns, to_ns, repo)
    total = _rows(con, f"{cte} SELECT count(*) AS uses, count(*) FILTER (WHERE failed) AS errors FROM uses", params)[0]
    return {"rows": rows, "total": total["uses"], "errors": total["errors"]}


def _by_repo(con, from_ns, to_ns, repo, host, agent):
    cte, params = _uses(from_ns, to_ns, repo, host, agent)
    rows = _rows(con, f"{cte} SELECT repo, count(*) AS uses, count(*) FILTER (WHERE failed) AS errors FROM uses "
                      "GROUP BY repo ORDER BY uses DESC, repo NULLS LAST", params)
    peak = rows[0]["uses"] if rows else 0
    for r in rows:
        r["none"] = r["repo"] is None
        r["repo"] = r["repo"] or NO_REPO
        r["rate"] = _rate(r["errors"], r["uses"])
        r["frac"] = r["uses"] / peak if peak else 0.0
    return rows


def _series(con, from_ns, to_ns, tz, repo, host, agent):
    """Usos e erros por hora (janela até 48 h) ou por dia, no fuso da tela: os mesmos baldes do gráfico do Dashboard."""
    hourly = to_ns - from_ns <= dash_mod.HOURLY_MAX_NS
    fmt, keys = dash_mod._bucket_keys(from_ns, to_ns, tz, hourly)
    cte, params = _uses(from_ns, to_ns, repo, host, agent)
    local = f"timezone('{tz.key}', make_timestamp_ns(CAST(used_ns AS BIGINT)) AT TIME ZONE 'UTC')"
    found = {r["b"]: r for r in _rows(
        con, f"{cte} SELECT strftime({local}, '{fmt}') AS b, count(*) AS uses, count(*) FILTER (WHERE failed) AS errors "
             "FROM uses GROUP BY b", params)}
    n = len(keys)
    points = []
    for i, (key, d) in enumerate(keys.items()):
        r = found.get(key) or {"uses": 0, "errors": 0}
        points.append({"key": key, "label": f"{d:%d/%m} {d:%H}h" if hourly else f"{d:%d/%m}",
                       "tick": dash_mod._tick(i, n, d, hourly), "uses": r["uses"], "errors": r["errors"], "x": (i + 0.5) / n})
    peak = dash_mod._nice(max((p["uses"] for p in points), default=0))
    for p in points:
        p["frac"] = p["uses"] / peak
        p["err_frac"] = p["errors"] / peak
    return {"unit": "hour" if hourly else "day", "points": points, "max": peak, "mid": peak // 2,
            "total": sum(p["uses"] for p in points)}


def _options(con, from_ns, to_ns):
    """Hosts e agentes com algum span na janela (todos os spans, não só os de ferramenta: `codex` aparece, com zero usos)."""
    rows = _rows(con, "SELECT host_name AS h, oute_agent AS a FROM spans WHERE time_unix_nano >= ? AND time_unix_nano < ? "
                      "GROUP BY ALL", [from_ns, to_ns])
    return (sorted({r["h"] for r in rows if r["h"]}), sorted({r["a"] for r in rows if r["a"]}),
            repo_mod.options(con, from_ns, to_ns))


def snapshot(con, from_ns, to_ns, tz=tz_mod.UTC, repo=None, host=None, agent=None):
    """O que a tela `/ferramentas` mostra, na janela [from_ns, to_ns) e com os filtros de repositório, host e agente."""
    tools = _by_tool(con, from_ns, to_ns, repo, host, agent)
    uses, errors = sum(t["uses"] for t in tools), sum(t["errors"] for t in tools)
    hosts, agents, repos = _options(con, from_ns, to_ns)
    return {"tools": tools, "uses": uses, "errors": errors, "rate": _rate(errors, uses),
            "by_repo": _by_repo(con, from_ns, to_ns, repo, host, agent),
            "series": _series(con, from_ns, to_ns, tz, repo, host, agent), "hosts": hosts, "agents": agents, "repos": repos}


def conversations(con, tool, from_ns, to_ns, repo=None, host=None, agent=None):
    """As conversas que usaram a ferramenta `tool` na janela, com os usos e os erros dela em cada uma: as com mais erros
    primeiro, depois as mais recentes. `None` se a ferramenta não tem nenhum uso nos filtros."""
    cte, params = _uses(from_ns, to_ns, repo, host, agent, tool)
    rows = _rows(con, f"{cte} SELECT conv, count(*) AS uses, count(*) FILTER (WHERE failed) AS errors, min(used_ns) AS first_ns, "
                      "max(used_ns) AS last_ns, arg_min(host, used_ns) AS host, arg_min(agent, used_ns) AS agent, arg_min(repo, used_ns) AS repo "
                      "FROM uses GROUP BY conv ORDER BY errors DESC, last_ns DESC, conv NULLS LAST", params)
    if not rows:
        return None
    return {"total": len(rows), "conversations": rows[:CONV_LIMIT], "uses": sum(r["uses"] for r in rows),
            "errors": sum(r["errors"] for r in rows)}
