#!/usr/bin/env python3
"""Sobe o app do agent-studio para os testes (ADR-08, #185), como o `python -m agent_studio`, com uma costura:
STUDIO_FAIL=1 faz a gravação falhar DEPOIS do INSERT, antes do commit (confere o rollback e o 503)."""
import os
import sys

import agent_studio.__main__ as main
from agent_studio import store


class FailingStore(store.Store):
    def _insert(self, table, rows):
        r = super()._insert(table, rows)
        raise RuntimeError(f"falha injetada depois do insert em {table}")


if os.environ.get("STUDIO_FAIL") == "1":
    main.Store = FailingStore
sys.exit(main.main())
