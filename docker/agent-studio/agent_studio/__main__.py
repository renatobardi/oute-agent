"""`python -m agent_studio`: um processo, um worker (o DuckDB aceita um escritor só; ADR-08 §4)."""
import logging
import os
import sys

import uvicorn

from .app import create_app
from .store import Store
from .surreal import Surreal


def main():
    logging.basicConfig(level=os.environ.get("AGENT_STUDIO_LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    token = os.environ.get("AGENT_STUDIO_TOKEN", "")
    if not token:
        # sem o item agent-studio no vault o serviço não sobe (o `oute up` já avisa e não liga o profile)
        print("agent-studio: AGENT_STUDIO_TOKEN vazio (item agent-studio do vault); não subo", file=sys.stderr)
        return 1
    # SurrealDB (#187): o compose sempre passa a URL; sem ela (só nos testes de ingestão), grava só no DuckDB
    surreal = None
    surreal_url = os.environ.get("AGENT_STUDIO_SURREAL_URL", "")
    if surreal_url:
        surreal_pass = os.environ.get("AGENT_STUDIO_SURREAL_PASS", "")
        if not surreal_pass:
            print("agent-studio: AGENT_STUDIO_SURREAL_PASS vazio (item agent-studio do vault); não subo", file=sys.stderr)
            return 1
        surreal = Surreal(surreal_url, os.environ.get("AGENT_STUDIO_SURREAL_USER", "root"), surreal_pass,
                          ns=os.environ.get("AGENT_STUDIO_SURREAL_NS", "oute"),
                          db=os.environ.get("AGENT_STUDIO_SURREAL_DB", "studio"))
    db = os.environ.get("AGENT_STUDIO_DB", "/data/agent-studio/agent-studio.duckdb")
    store = Store(db)
    app = create_app(store, token, surreal)
    uvicorn.run(app, host=os.environ.get("AGENT_STUDIO_BIND", "0.0.0.0"),
                port=int(os.environ.get("AGENT_STUDIO_PORT", "8430")),
                workers=1, access_log=False, log_config=None)
    store.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
