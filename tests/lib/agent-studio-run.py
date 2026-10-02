#!/usr/bin/env python3
"""Sobe o app do agent-studio para os testes (ADR-08, #185), como o `python -m agent_studio`, com uma costura:
STUDIO_FAIL=1 faz a gravação falhar DEPOIS do INSERT, antes do commit (confere o rollback e o 503);
STUDIO_FAIL_USAGE=1 faz a leitura do `/v1/usage`, do `/v1/alerts` e do `/v1/tray` falhar (confere o 500)."""
import os
import sys

import agent_studio.__main__ as main
from agent_studio import store


class FailingStore(store.Store):
    def _insert(self, table, rows):
        r = super()._insert(table, rows)
        raise RuntimeError(f"falha injetada depois do insert em {table}")


class FailingUsageStore(store.Store):
    def usage(self, *args):
        raise RuntimeError("falha injetada na leitura")

    def alerts(self, *args):
        raise RuntimeError("falha injetada na leitura")

    def tray(self, *args):
        raise RuntimeError("falha injetada na leitura")


if os.environ.get("STUDIO_FAIL") == "1":
    main.Store = FailingStore
elif os.environ.get("STUDIO_FAIL_USAGE") == "1":
    main.Store = FailingUsageStore
sys.exit(main.main())
