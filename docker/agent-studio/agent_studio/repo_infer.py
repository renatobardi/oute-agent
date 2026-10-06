"""Repositório do histórico pela pasta (#599): a conversa aberta direto numa pasta, antes de o shim marcar o
`oute.task.repo`, não tem repositório em fato nenhum. Aqui ele é inferido **só pelo `file_path` dos spans de ferramenta**
(`claude_code.tool`) da própria conversa e gravado na coluna `oute_repo` dos fatos dela. Regra no ADR-04, "Repositório da
pasta".

- **Nada além do `file_path` é lido:** nem o texto do comando (`full_command`), nem a entrada, nem a saída da ferramenta.
- **Quem entra:** conversa (`session.id`) em que nenhum fato tem repositório. Conversa com repositório em algum fato fica
  como está; por isso a segunda subida não mexe no que a primeira gravou.
- **Voto:** um por span com `file_path` que aponta um repositório **conhecido** (os `oute.task.repo` que o banco já tem).
  Vale o repositório com mais da metade dos votos; empate ou conversa sem voto = segue "sem repositório".
- **O que muda:** só a coluna `oute_repo`. O JSON `resource_attributes` fica como chegou, então o fato inferido se
  reconhece (coluna preenchida, JSON sem `oute.task.repo`) e a inferência se desfaz com um `UPDATE`.
- **No SQL:** valores sempre em parâmetro; nomes de tabela e de coluna são constantes dos módulos.
"""
import logging
import re

from . import repo as repo_mod

log = logging.getLogger("agent_studio")

TOOL_SPAN = "claude_code.tool"
FILE_PATH = "$.file_path"
TABLES = ("spans", "logs", "metrics")
_WORKSPACE, _WORKTREES = "workspace", ".worktrees"
# pasta de trabalho codificada pelo harness (cada caractere fora de [A-Za-z0-9] vira `-`): o scratchpad
# `/tmp/claude-<uid>/<pasta>/…` e o `~/.claude/projects/<pasta>/…`
_ENC_MAIN, _ENC_WORKTREE = "-workspace-", "-workspace--worktrees-"

_CANDIDATES = (
    f"SELECT session_id, json_extract_string(attributes, '{FILE_PATH}') AS path, count(*) AS n FROM spans "
    "WHERE name = ? AND session_id IS NOT NULL AND oute_repo IS NULL "
    f"AND json_extract_string(attributes, '{FILE_PATH}') IS NOT NULL "
    "AND session_id NOT IN (SELECT session_id FROM spans WHERE oute_repo IS NOT NULL AND session_id IS NOT NULL) "
    "GROUP BY ALL")
_KNOWN = ("SELECT oute_repo FROM spans WHERE oute_repo IS NOT NULL GROUP BY ALL "
          "UNION SELECT oute_repo FROM logs WHERE oute_repo IS NOT NULL GROUP BY ALL")


def _enc(name):
    return re.sub("[^A-Za-z0-9]", "-", name)


def _prefix(text, names):
    """O nome de `names` (do mais longo para o mais curto) que abre `text` seguido de `-`; `None` se nenhum."""
    for name in sorted(names, key=len, reverse=True):
        if text.startswith(name + "-"):
            return name
    return None


def _encoded_repo(folder, known):
    """Repositório de uma pasta de trabalho codificada. `-workspace-<repo>` = o checkout principal. Na worktree
    (`-workspace--worktrees-…`) o espaço do herdr e o repositório vêm colados por `-`: só vale quando não há dúvida."""
    enc = {}
    for name in known:
        enc.setdefault(_enc(name), set()).add(name)
    names = {e: next(iter(ns)) for e, ns in enc.items() if len(ns) == 1}  # dois nomes com a mesma forma codificada: fora
    if folder.startswith(_ENC_WORKTREE):
        rest = folder[len(_ENC_WORKTREE):]
        first = _prefix(rest, names)
        if first is None:
            return None
        second = _prefix(rest[len(first) + 1:], names)
        # `<a>-<b>-…` com a e b conhecidos e diferentes: formato antigo do repositório a ou espaço a com o repositório b
        return names[first] if second in (None, first) else None
    if folder.startswith(_ENC_MAIN):
        return names.get(folder[len(_ENC_MAIN):])
    return None


def path_repo(path, known):
    """Repositório que um `file_path` aponta, entre os `known`; `None` se o caminho não diz.

    - `/workspace/<repo>/…`: o checkout principal e as subpastas dele;
    - `/workspace/.worktrees/<espaço>/<repo>-<slug>/…` (e o formato antigo, sem `<espaço>`): a worktree;
    - `/tmp/claude-<uid>/<pasta codificada>/…` e `/home/<usuário>/.claude/projects/<pasta codificada>/…`: a pasta em que
      a conversa foi aberta, como o harness a grava."""
    if not isinstance(path, str) or not path.startswith("/") or not known:
        return None
    seg = path.split("/")[1:]
    if len(seg) >= 3 and seg[0] == _WORKSPACE:
        if seg[1] != _WORKTREES:
            return seg[1] if seg[1] in known else None
        return (len(seg) >= 5 and _prefix(seg[3], known)) or _prefix(seg[2], known)
    if len(seg) >= 3 and seg[0] == "tmp" and seg[1].startswith("claude-"):
        return _encoded_repo(seg[2], known)
    if len(seg) >= 5 and seg[0] == "home" and seg[2:4] == [".claude", "projects"]:
        return _encoded_repo(seg[4], known)
    return None


def plan(con):
    """Só leitura: `{"candidates": n, "inferred": {conversa: repositório}}`. `candidates` = conversas sem repositório com
    algum `file_path`."""
    known = {r for (r,) in con.execute(_KNOWN).fetchall()}
    votes = {}
    for conv, path, n in con.execute(_CANDIDATES, [TOOL_SPAN]).fetchall():
        tally = votes.setdefault(conv, {})
        name = path_repo(path, known)
        if name:
            tally[name] = tally.get(name, 0) + n
    inferred = {}
    for conv, tally in votes.items():
        total = sum(tally.values())
        best = max(tally, key=tally.get) if tally else None
        if best and tally[best] * 2 > total:
            inferred[conv] = best
    return {"candidates": len(votes), "inferred": inferred}


def apply(con):
    """Grava o repositório inferido nos fatos sem repositório de cada conversa, numa transação só. Falha = nada muda,
    um aviso no log (só o tipo do erro) e a subida segue: o histórico continua "sem repositório". Devolve o `plan` com
    `rows` (linhas alteradas por tabela) ou `None` na falha."""
    try:
        out = plan(con)
        out["rows"] = dict.fromkeys(TABLES, 0)
        if out["inferred"]:
            con.execute("BEGIN TRANSACTION")
            try:
                for table in TABLES:
                    for conv, name in out["inferred"].items():
                        n = con.execute(f"UPDATE {table} SET {repo_mod.COL} = ? WHERE session_id = ? AND {repo_mod.COL} IS NULL",
                                        [name, conv]).fetchone()
                        out["rows"][table] += n[0] if n else 0
                con.execute("COMMIT")
            except BaseException:
                con.execute("ROLLBACK")
                raise
    except Exception as e:  # noqa: BLE001 (a inferência nunca derruba a subida)
        log.warning("repo_infer: falhou (%s); o histórico segue sem repositório", type(e).__name__)
        return None
    log.info("repo_infer: %d conversa(s) sem repositório com file_path, %d com repositório inferido, linhas: %s",
             out["candidates"], len(out["inferred"]), out["rows"])
    return out
