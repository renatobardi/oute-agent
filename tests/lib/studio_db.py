"""DuckDB de exemplo do agent-studio para os testes da tela: spans e logs escritos direto, com a hora do fato que o teste dá.
Uso: PYTHONPATH=tests/lib:docker/agent-studio; `StudioDB(<dir>, <nome>)`, `.span(...)`, `.log(...)`, `.flush()` -> Store.
`sub=` (#679) = o `oute.subscription` da conversa (coluna e resource); sem ele, vale o `agent`."""
import json

from agent_studio import store as ST

SEC = 10**9


class StudioDB:
    """Spans e logs de exemplo escritos direto no DuckDB; a hora do fato é a que o teste dá."""

    def __init__(self, tmp, name):
        self.st = ST.Store(f"{tmp}/{name}.duckdb")
        self.n = 0
        self.spans, self.logs = [], []

    def span(self, at_ns, dur_s, name="claude_code.llm_request", model=None, task=None, conv=None, host="oute-server",
             agent="claude", err=False, attrs=None, repo=None, parent=None, sub=None, **tok):
        self.n += 1
        row = {"dedupe_key": f"s:{self.n}", "time_unix_nano": at_ns, "end_unix_nano": at_ns + int(dur_s * SEC),
               "duration_ns": int(dur_s * SEC), "host_name": host, "oute_agent": agent, "session_id": conv, "oute_task_id": task,
               "trace_id": parent[0] if parent else f"{self.n:032x}", "span_id": f"{self.n:016x}",
               "parent_span_id": parent[1] if parent else None, "name": name, "status_code": 2 if err else 0,
               "model": model, "received_unix_nano": at_ns, "attributes": json.dumps(attrs or {}), "oute_repo": repo,
               "oute_subscription": sub,
               "resource_attributes": json.dumps({**({"oute.task.repo": repo} if repo else {}), **({"oute.subscription": sub} if sub else {})})}
        row.update({f"{k}_tokens" if k != "cost_usd" else k: v for k, v in tok.items()})
        self.spans.append(row)
        return row["trace_id"], row["span_id"]  # para o `parent=` de um filho (ex.: tool.execution)

    def log(self, at_ns, name, attrs, body="", task=None, rnd=None, host="oute-server", repo=None, conv=None, sev=9, agent=None, sub=None):
        self.n += 1
        self.logs.append({"dedupe_key": f"l:{self.n}", "time_unix_nano": at_ns, "host_name": host, "oute_task_id": task,
                          "oute_swarm_round": rnd, "event_name": name, "severity_number": sev, "body": body, "session_id": conv,
                          "oute_repo": repo, "attributes": json.dumps(attrs), "oute_agent": agent, "oute_subscription": sub,
                          "resource_attributes": json.dumps({**({"oute.task.repo": repo} if repo else {}), **({"oute.subscription": sub} if sub else {})}),
                          "received_unix_nano": at_ns})

    def flush(self):
        self.st.write({"spans": self.spans, "logs": self.logs})
        return self.st
