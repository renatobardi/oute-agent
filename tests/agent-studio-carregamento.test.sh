#!/usr/bin/env bash
# #536: casco sem leitura, pedidos por bloco, falhas locais, página inteira e cache de abertura.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'rm -rf "${TMP:?}"' EXIT
studio_init
PYTHONPATH="$ROOT/tests/lib:$ROOT/docker/agent-studio" "$STUDIO_PY" - "$TMP" "$ROOT" > "$TMP/py.out" 2>&1 <<'PY'
import concurrent.futures
import re
import sys
import threading
import time
from urllib.parse import urlsplit
from starlette.datastructures import QueryParams
from agent_studio import web
try:
    from agent_studio import loading
except ImportError:
    loading = None
from agent_studio.app import create_app
from agent_studio.config import load
from pycheck import check
from studio_asgi import TOKEN, Broken, raw_get
from studio_db import StudioDB
from studio_loading import Slots

root = sys.argv[2]
config = load()


class Unread(Broken):
    def __init__(self):
        self.calls = 0

    def __getattr__(self, name):
        def fail(*args):
            self.calls += 1
            raise RuntimeError('causa-privada')
        return fail


unread = Unread()
app = create_app(unread, TOKEN, config=config)
denied_app = create_app(unread, TOKEN + 'x', config=config)


def denied(url):
    parts = urlsplit(url)
    headers = {}
    status, _ = raw_get(denied_app, parts.path, parts.query, response_headers=headers)
    return status == 401 and headers.get('hx-redirect', '').startswith('/login?next=')


queries = {p: 'hours=168&repo=owner%2Frepo&custo=efetivo' for p in
           ('/', '/conversas', '/sessoes', '/uso', '/ferramentas', '/precos', '/pedidos', '/rodadas')}
queries.update({'/conversa': 'id=c', '/sessao': 'id=t', '/pedido': 'id=p', '/rodada': 'id=r',
           '/ciclo': 'id=owner%2Frepo%231', '/conversa/logs': 'id=c&offset=200',
           '/conversa/span': 'trace=t&span=s', '/ferramenta': 'nome=Bash'})
for path, query in queries.items():
    status, body = raw_get(app, path, query)
    title, nav, detail, blocks = loading.SCREENS[path] if loading is not None else ('', '', True, [('ausente', 'faixa')])
    slots = Slots(body).slots
    expected = len(blocks) + (0 if detail else 2)
    check(f'{path}: casco com título, menu e todos os espaços, sem ler banco', status == 200 and unread.calls == 0
          and '<h1>' in body and title in body and 'class="barra"' in body and len(slots) == expected)
    check(f'{path}: pedidos próprios, shimmer e alternativa sem JS', len({u for _, _, u in slots}) == expected
          and 'class="shimmer"' in body and 'aria-busy="true"' in body and '<noscript>' in body and 'full=1' in body)
    check(f'{path}: trecho sem login dá 401 com HX-Redirect', bool(slots) and all(denied(u) for _, _, u in slots))

css = open(root + '/docker/agent-studio/agent_studio/static/studio.css').read()
check('shimmer tem formas e movimento reduzido', all('.carregamento.'+s in css for s in ('grafico','tabela','indicadores'))
      and re.search(r'prefers-reduced-motion:\s*reduce[^}]*animation:\s*none',css) is not None)
check('casco oferece página inteira sem JavaScript', '<noscript>' in body and 'full=1' in body)
st, failed_body = raw_get(app, '/bloco/conversas/tabela', 'hours=168')
check('falha chega no bloco com retentativa', st == 500 and 'data-bloco-erro' in failed_body
      and 'Tentar novamente' in failed_body and '<html' not in failed_body)
check('outro bloco responde após falha', raw_get(app, '/bloco/conversas/decisoes', 'hours=168')[0] == 200)
for path, query, row in (('/conversa/span', 'trace=t&span=s', False), ('/conversa/logs', 'id=c', True)):
    st, failed_body = raw_get(create_app(Broken(), TOKEN), path, query, headers=(("HX-Request", "true"),))
    check(path + ': falha ao clicar é local e preserva tipo do alvo', st == 500 and 'data-bloco-erro' in failed_body
          and 'Tentar novamente' in failed_body and '<html' not in failed_body
          and failed_body.lstrip().startswith('<tr' if row else '<div'))

if loading is None:
    check('catálogo e cache de blocos existem', False)
    sys.exit(0)
check('query normaliza campos vazios e duplicados do formulário', loading.pairs(QueryParams('hours=168&repo=&hours=168')) == [('hours','168')])
check('tela fora do catálogo retorna erro local', raw_get(app,'/bloco/inventado/tabela')[0] == 404
      and 'data-bloco-erro' in raw_get(app,'/bloco/inventado/tabela')[1])

# Dados reais: 45 conversas. A tabela ainda lê a janela inteira antes de filtrar/ordenar/cortar (#583).
db = StudioDB(sys.argv[1], 'blocos')
now = time.time_ns()
for i in range(45):
    db.span(now - (i+1)*3600*10**9, 2, model='test-model', conv=f'c-{i:02d}', task='t', repo='owner/repo', input=1000)
store = db.flush()
app = create_app(store, TOKEN, config=config)
status, shell = raw_get(app, '/conversas', 'hours=168&repo=owner%2Frepo&ord=calls&tam=20')
slots = {urlsplit(u).path.rsplit('/',1)[1]: u for _, _, u in Slots(shell).slots}
real = store.conversations
calls = []


def counted(*args):
    calls.append(1)
    return real(*args)


store.conversations = counted


def request_url(url):
    p = urlsplit(url)
    return raw_get(app, p.path, p.query, headers=(("HX-Request", "true"),))


_, filters = request_url(slots['filtros'])
status, table = request_url(slots['tabela'])
check('filtros e tabela compartilham uma leitura completa', len(calls) == 1 and status == 200 and
      len(re.findall('data-conversa=', table)) == 20 and '1 a 20 de 45' in table)
check('cada resposta leva só o bloco escolhido', '<table' not in filters and '<form' not in table
      and '<html' not in table and '<h1' not in table)
check('URL de bloco preserva período, repositório, ordem e tamanho', all(v in slots['tabela'] for v in
      ('hours=168','repo=owner%2Frepo','ord=calls','tam=20')))
check('links de tabela voltam à tela, sem view nem full', 'href="/conversas?' in table and 'view=' not in table and 'full=' not in table)
_, full = raw_get(app, '/conversas', 'hours=168&full=1')
check('página inteira sem JS mostra conteúdo e não cria espaços', '<table' in full and 'data-bloco=' not in full and 'data-alertas' in full)
check('parâmetro inválido falha antes da leitura', raw_get(app,'/conversas','pag=0')[0] == 400 and len(calls) == 2)
check('bloco fora da lista não abre leitura', raw_get(app,'/bloco/conversas/inventado','hours=168')[0] == 404 and len(calls) == 2)

def balanced(body):
    stack = []
    for closing, tag in re.findall(r'<(/?)(div|table|section)\b[^>]*>', body):
        if closing:
            if not stack or stack.pop() != tag:
                return False
        else:
            stack.append(tag)
    return not stack


_, spans = raw_get(app, '/bloco/conversa/spans', 'id=c-00')
span_id, trace = re.search(r'data-span="([^"]+)" data-trace="([^"]+)"', spans).groups()
for path, query in (('/bloco/conversa/logs/conteudo', 'id=c-00'),
                    ('/bloco/conversa/span/conteudo', 'trace='+trace+'&span='+span_id)):
    st, fragment = raw_get(app, path, query, headers=(("HX-Request", "true"),))
    check(path + ': fragmento tem raízes completas', st == 200 and balanced(fragment))

# Erro de leitura não fica no cache e a retentativa recupera o mesmo bloco.
status, shell = raw_get(app, '/conversas', 'hours=168')
slot = next(u for _, _, u in Slots(shell).slots if '/tabela?' in u)
store.conversations = lambda *args: (_ for _ in ()).throw(RuntimeError('causa-privada'))
status, error = request_url(slot)
check('leitura falha no lugar, com retentativa e sem causa', status == 500 and 'data-bloco-erro' in error
      and 'Tentar novamente' in error and 'causa-privada' not in error and '<html' not in error)
store.conversations = counted
check('retentativa refaz a leitura após falha', request_url(slot)[0] == 200)
check('outro bloco segue após falha', raw_get(app,'/bloco/conversas/decisoes','hours=168')[0] == 200)
check('alertas que falham mostram aviso local', raw_get(create_app(Broken(),TOKEN),'/bloco/dashboard/alertas','hours=168')[0] == 200
      and 'não puderam ser calculados' in raw_get(create_app(Broken(),TOKEN),'/bloco/dashboard/alertas','hours=168')[1])
check('decisões que falham mostram aviso local', 'não puderam ser lidas' in raw_get(create_app(Broken(),TOKEN),'/bloco/dashboard/decisoes','hours=168')[1])
check('view de outra tela ou query não reutiliza resultados', loading.Views().find('nope','/',[]) is None
      and raw_get(app,'/bloco/conversas/tabela','hours=168&view=inexistente')[0] == 410)
check('view expirada oferece reabrir, sem retentativa impossível', 'Reabrir a tela' in raw_get(app,'/bloco/conversas/tabela','view=inexistente')[1]
      and 'Tentar novamente' not in raw_get(app,'/bloco/conversas/tabela','view=inexistente')[1])

# Cache: coalescência, cópia por consumidor, descarte por prazo/limite e escopo da URL.
cache = loading.Views()
k = cache.open('/conversas',[('hours','168')])
v = cache.find(k,'/conversas',[('hours','168')])
entered, release = threading.Event(), threading.Event()
count = []


def slow():
    count.append(1)
    entered.set()
    assert release.wait(10)
    return {'rows': [1]}


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    first = pool.submit(v.read,'lista',slow,())
    assert entered.wait(10)
    second = pool.submit(v.read,'lista',slow,())
    # Uma leitura presa não impede o casco de responder; relógio só limita o teste em caso de falha.
    check('casco responde enquanto consulta está presa', raw_get(app,'/conversas','hours=168')[0] == 200 and not first.done())
    release.set()
    a,b = first.result(),second.result()
a['rows'].append(2)
check('leituras simultâneas coalescem e recebem cópias próprias', len(count) == 1 and b == {'rows':[1]})
check('cache respeita tela e query', cache.find(k,'/uso',[('hours','168')]) is None and cache.find(k,'/conversas',[('hours','24')]) is None)
v.created -= loading.TTL + 1
check('cache não serve abertura vencida', cache.find(k,'/conversas',[('hours','168')]) is None)
for i in range(loading.MAX_VIEWS + 2):
    cache.open('/conversas', [])
check('cache tem limite e remove as vencidas', len(cache.entries) == loading.MAX_VIEWS and k not in cache.entries)
check('cookie de marcação mantém Path=/rodada nas rotas novas', loading.block_url('/rodada','etapas',[]).startswith('/rodada/bloco/'))

# Dashboard: cada gráfico/indicadores tem resposta própria. Não lê alertas nem decisões para um gráfico.
real_alerts,real_decisions = store.alerts,store.decisions
store.alerts = lambda *args: (_ for _ in ()).throw(AssertionError('alertas não pedidos'))
store.decisions = lambda *args: (_ for _ in ()).throw(AssertionError('decisões não pedidas'))
_, dashboard = raw_get(app,'/','hours=168')
for _,_,u in Slots(dashboard).slots:
    name = urlsplit(u).path.rsplit('/',1)[1]
    if name in ('alertas','decisoes','insights'):
        continue
    st,body = request_url(u)
    check(f'Dashboard: {name} carrega sem esperar as faixas', st == 200 and '<html' not in body and 'data-bloco-erro' not in body)
store.alerts,store.decisions = real_alerts,real_decisions
# Uma falha do menu de repositórios não derruba os gráficos do Uso.
store.repos = lambda *args: (_ for _ in ()).throw(RuntimeError('causa-privada'))
check('Uso: erro do filtro não derruba gráfico', raw_get(app,'/bloco/uso/filtros','hours=168')[0] == 500
      and raw_get(app,'/bloco/uso/custo-dia','hours=168')[0] == 200)
check('CSP mantém script e estilo locais sem inline', 'style=' not in dashboard and 'https://' not in dashboard
      and web.HEADERS['Content-Security-Policy'] == "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
PY
PY_RC=$?
check "o Python completou os casos" test "$PY_RC" = 0
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/py.out")
if [[ "$PY_RC" != 0 ]]; then cat "$TMP/py.out"; fi
node "$ROOT/tests/lib/studio_loading_js.cjs" "$ROOT/docker/agent-studio/agent_studio/static/loading.js" > "$TMP/js.out" 2>&1
check "os eventos em JavaScript passam" test "$?" = 0
check_py_lines <(grep -E '^(ok   |FAIL )' "$TMP/js.out")
check_end
