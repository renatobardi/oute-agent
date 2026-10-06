"""#536: resposta ASGI até o casco e todos os blocos do Dashboard de sete dias.

Reprodução: PYTHONPATH=tests/lib:docker/agent-studio <python do venv dos testes>
            tests/lib/studio_loading_measure.py
Cinco bancos novos, 700 spans / 700 conversas. Não mede navegador, rede ou host.
Janela maior e gráfico das ferramentas (#592): `--hours <h>` (padrão 168), `--spans <n>` (chamadas ao modelo, padrão 700) e
`--tools <n>` (spans de ferramenta, padrão 0), espalhados pela janela; com `--tools`, sai também o tempo do bloco `ferramentas`.
Um único event loop atende os pedidos, como o servidor; até oito simultâneos.
Copiar este apoio e studio_asgi.py / studio_loading.py para a base permite medir o mesmo conjunto antes da mudança.
"""
import argparse
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

TOOL_NAMES = ('Bash', 'Read', 'Edit', 'Grep', 'Write', 'Agent')
parser = argparse.ArgumentParser()
parser.add_argument('--hours', type=int, default=168)
parser.add_argument('--spans', type=int, default=700)
parser.add_argument('--tools', type=int, default=0)
args = parser.parse_args()
window_ns = args.hours * 3600 * 10**9
raw_get = studio_asgi.async_get
cfg = load()
rows = []
for run in range(5):
    with tempfile.TemporaryDirectory() as directory:
        db = StudioDB(directory, 'measure')
        now = time.time_ns()
        step = window_ns // (args.spans + 1)   # 700 spans em 7 dias: um a cada 14 min, todos dentro da janela
        for i in range(args.spans):
            db.span(now - (i + 1) * step, 2, model='model-test', conv=f'conv-{i}',
                    task=f'task-{i % 20}', input=1000, output=100)
        tool_step = window_ns // (args.tools + 1)
        for i in range(args.tools):
            db.span(now - (i + 1) * tool_step, 1, name='claude_code.tool', conv=f'conv-{i % args.spans}',
                    task=f'task-{i % 20}', err=i % 50 == 0, attrs={'tool_name': TOOL_NAMES[i % len(TOOL_NAMES)]})
        store = db.flush()
        app = create_app(store, studio_asgi.TOKEN, config=cfg)
        async def measure():
            start = time.perf_counter()
            status, html = await raw_get(app, '/', f'hours={args.hours}')
            shell_ms = (time.perf_counter() - start) * 1000
            assert status == 200
            slots = Slots(html).slots
            if not slots:
                return shell_ms, shell_ms, None
            limit = asyncio.Semaphore(8)
            block_ms = {}

            async def fetch(slot):
                url = urlsplit(slot[2])
                async with limit:
                    asked = time.perf_counter()
                    code, _ = await raw_get(app, url.path, url.query)
                    assert code == 200
                    block_ms[url.path.rsplit('/', 1)[-1]] = (time.perf_counter() - asked) * 1000

            await asyncio.gather(*(fetch(slot) for slot in slots))
            return shell_ms, (time.perf_counter() - start) * 1000, block_ms.get('ferramentas')

        rows.append(asyncio.run(measure()))
        store.close()
days = f'{args.hours // 24} dias' if args.hours % 24 == 0 else f'{args.hours} h'
tools_note = f'; {args.tools} spans de ferramenta' if args.tools else ''
print(f'{args.spans} spans / {args.spans} conversas{tools_note}; {days}; 5 bancos novos; ASGI local; blocos em até 8 pedidos simultâneos')
for i, (shell, last, tools) in enumerate(rows, 1):
    tools_ms = '' if tools is None else f'; ferramentas={tools:.3f} ms'
    print(f'{i}: casco={shell:.3f} ms; último={last:.3f} ms{tools_ms}')
median = f'mediana: casco={statistics.median(r[0] for r in rows):.3f} ms; último={statistics.median(r[1] for r in rows):.3f} ms'
if all(r[2] is not None for r in rows):
    median += f'; ferramentas={statistics.median(r[2] for r in rows):.3f} ms'
print(median)
