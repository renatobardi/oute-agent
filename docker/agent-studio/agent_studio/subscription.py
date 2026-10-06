"""Filtro e quebra por assinatura (#679, ADR-08 adendo "Assinatura"): o `oute.subscription` da conversa (`claude`, `zai`
ou `codex`), que o Uso e o Dashboard usam como o filtro de repositório (`repo.py`). A regra de qual assinatura vale para
uma linha (a coluna ou, no histórico, o `oute.agent`) é do `cost.py`.

- **Na URL:** `assinatura=<nome>`; ausente ou vazio = "Todas". Valor fora de `cost.SUBSCRIPTIONS` não existe: a tela
  responde 400 (`check`), nada da URL vai ao SQL sem passar pela lista.
- **No SQL:** o valor vai sempre em parâmetro; a expressão é constante de `cost.py`.
"""
from . import cost as cost_mod, repo as repo_mod

PARAM = "assinatura"


def check(value):
    """Valor da query string -> filtro (`None` = Todas); `ValueError` se não é uma assinatura conhecida."""
    if not value:
        return None
    if value not in cost_mod.SUBSCRIPTIONS:
        raise ValueError("A assinatura tem de ser claude, zai ou codex.")
    return value


def clause(sub, prefix=""):
    """(SQL, parâmetros) do filtro, para juntar a um `WHERE` já existente (` AND …`). `sub=None` = sem filtro."""
    if sub is None:
        return "", []
    return f" AND {cost_mod.subscription_sql(prefix)} = ?", [sub]


def scope(repo=None, sub=None, repo_col=None, prefix=""):
    """O filtro de repositório e o de assinatura juntos: (SQL, parâmetros), nessa ordem."""
    rsql, rparams = repo_mod.clause(repo, repo_col)
    ssql, sparams = clause(sub, prefix)
    return rsql + ssql, [*rparams, *sparams]
