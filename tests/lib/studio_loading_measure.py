"""#536: resposta ASGI até o casco e todos os blocos do Dashboard de sete dias.

Reprodução: PYTHONPATH=tests/lib:docker/agent-studio <python do venv dos testes>
            tests/lib/studio_loading_measure.py
Cinco bancos novos, 700 spans / 700 conversas. Não mede navegador, rede ou host.
Um único event loop atende os pedidos, como o servidor; até oito simultâneos.
Copiar este apoio e studio_asgi.py / studio_loading.py para a base permite medir o mesmo conjunto antes da mudança.
"""
import asyncio
import statistics
import tempfile
import time
from urllib.parse import urlsplit

from agent_studio.app import create_app
from agent_studio.config import load
from studio_db import StudioDB
import studio_asgi
from studio_loading import Slots

raw_get = studio_asgi.async_get
cfg = load()
rows = []
for run in range(5):
    with tempfile.TemporaryDirectory() as directory:
        db = StudioDB(directory, 'measure')
        now = time.time_ns()
        for i in range(700):
            db.span(now - (i + 1) * 840 * 10**9, 2, model='model-test', conv=f'conv-{i}',
                    task=f'task-{i % 20}', input=1000, output=100)
        store = db.flush()
        app = create_app(store, studio_asgi.TOKEN, config=cfg)
        async def measure():
            start = time.perf_counter()
            status, html = await raw_get(app, '/', 'hours=168')
            shell_ms = (time.perf_counter() - start) * 1000
            assert status == 200
            limit = asyncio.Semaphore(8)

            async def fetch(slot):
                url = urlsplit(slot[2])
                async with limit:
                    code, _ = await raw_get(app, url.path, url.query)
                    assert code == 200

            await asyncio.gather(*(fetch(slot) for slot in Slots(html).slots))
            return shell_ms, (time.perf_counter() - start) * 1000

        rows.append(asyncio.run(measure()))
        store.close()
print('700 spans / 700 conversas; 7 dias; 5 bancos novos; ASGI local; blocos em até 8 pedidos simultâneos')
for i, (shell, last) in enumerate(rows, 1):
    print(f'{i}: casco={shell:.3f} ms; último={last:.3f} ms')
print(f'mediana: casco={statistics.median(r[0] for r in rows):.3f} ms; último={statistics.median(r[1] for r in rows):.3f} ms')
