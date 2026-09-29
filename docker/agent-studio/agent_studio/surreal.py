"""Cliente mínimo do SurrealDB (HTTP `/rpc`, python3 stdlib) para o estado derivado (ADR-08 §3, #187).

Uma chamada = uma transação (`BEGIN … COMMIT`), com os valores sempre em variáveis (nunca interpolados no texto).
Qualquer erro (conexão, HTTP, statement com `ERR`) levanta SurrealError: a requisição volta 503 e o DuckDB faz
rollback (os dois bancos juntos ou nenhum).
"""
import base64
import json
import urllib.request


class SurrealError(RuntimeError):
    pass


class Surreal:
    def __init__(self, url, user, password, ns="oute", db="studio", timeout=5.0):
        self.url = url.rstrip("/") + "/rpc"
        self.ns, self.db, self.timeout = ns, db, timeout
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.ready = False

    def _rpc(self, sql, variables, scoped=True):
        headers = {"Accept": "application/json", "Content-Type": "application/json", "Authorization": self.auth}
        if scoped:
            headers.update({"Surreal-NS": self.ns, "Surreal-DB": self.db})
        body = json.dumps({"id": 1, "method": "query", "params": [sql, variables]}).encode()
        req = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                out = json.load(r)
        except (OSError, ValueError) as e:  # URLError é OSError
            raise SurrealError(f"SurrealDB fora ou com erro: {e}") from e
        if out.get("error"):
            raise SurrealError(f"SurrealDB: {out['error']}")
        bad = [x.get("result") for x in out.get("result") or [] if x.get("status") != "OK"]
        if bad:
            raise SurrealError(f"SurrealDB: {bad[0]}")
        return out["result"]

    def _init(self):
        # namespace e banco precisam existir antes de usar (o SurrealDB 3 não cria sozinho)
        self._rpc(f"DEFINE NAMESPACE IF NOT EXISTS {self.ns}; USE NS {self.ns}; DEFINE DATABASE IF NOT EXISTS {self.db};",
                  {}, scoped=False)
        self.ready = True

    def apply(self, statements):
        """statements = [(sql, valor)]: cada sql usa só `$v` (o valor). Tudo numa transação."""
        if not statements:
            return
        if not self.ready:
            self._init()
        parts, variables = [], {}
        for i, (sql, value) in enumerate(statements):
            name = f"v{i}"
            parts.append(sql.replace("$v", "$" + name))
            variables[name] = value
        self._rpc("BEGIN TRANSACTION;\n" + "\n".join(parts) + "\nCOMMIT TRANSACTION;", variables)

    def query(self, sql, variables=None):
        """Leitura (testes e, depois, a API)."""
        if not self.ready:
            self._init()
        return self._rpc(sql, variables or {})
