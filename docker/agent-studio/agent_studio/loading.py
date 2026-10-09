"""Carregamento por bloco (#536): catálogo fixo, espaços e leituras de uma abertura.

Guarda query e resultados, sem receber cookie ou cabeçalho de autenticação.
Uma abertura vale 120 s sem pedido, com no máximo 32 aberturas: cada bloco servido renova o prazo (#591).
Bloco pedido depois do prazo abre a abertura de novo, com o mesmo id; a tela não precisa ser reaberta.
Os resultados de leituras simultâneas são compartilhados; falha não fica no cache.
"""
import copy
import re
import secrets
import threading
import time
from concurrent.futures import Future
from urllib.parse import urlencode

from markupsafe import Markup

# caminho, título, menu, detalhe, blocos (nome, forma). Nomes só deste catálogo.
SCREENS = {
    '/': ('Dashboard', 'dashboard', False, [('filtros', 'faixa'), ('kpis', 'indicadores'), ('insights', 'faixa'),
         *[(n, 'grafico') for n in ('chamadas', 'custo-modelo', 'latencia', 'fases', 'atividade', 'sessoes', 'repos', 'assinaturas', 'ferramentas')]]),
    '/conversas': ('Conversas', 'conversas', False, [('filtros', 'faixa'), ('tabela', 'tabela')]),
    '/sessoes': ('Sessões', 'sessoes', False, [('filtros', 'faixa'), ('sessoes', 'tabela'), ('conversas', 'tabela')]),
    '/uso': ('Uso por papel e por fase', 'uso', False, [('filtros', 'faixa'), ('total', 'indicadores'),
             *[(n, 'grafico') for n in ('custo-dia', 'tokens-dia', 'custo-papel', 'custo-fase', 'custo-assinatura')], ('papel', 'tabela'), ('fase', 'tabela'), ('assinatura', 'tabela'),
             ('papel-modelo', 'tabela'), ('papel-fase', 'tabela'), ('sessoes-caras', 'tabela'), ('conversas-caras', 'tabela')]),
    '/ferramentas': ('Ferramentas', 'ferramentas', False, [('filtros', 'faixa'), ('total', 'indicadores'), ('usos', 'grafico'), ('ferramentas', 'tabela'), ('repos', 'grafico')]),
    '/ferramenta': ('Ferramenta', 'ferramentas', True, [('filtros', 'faixa'), ('total', 'indicadores'), ('conversas', 'tabela')]),
    '/precos': ('Preços', 'precos', False, [('fontes', 'faixa'), ('resumo', 'indicadores'), ('modelos', 'faixa')]),
    '/planos': ('Planos', 'planos', False, [('planos', 'tabela'), ('historico', 'tabela')]),
    '/pedidos': ('Pedidos', 'pedidos', False, [('pendentes', 'tabela'), ('decididos', 'tabela')]),
    '/pedido': ('Pedido', 'pedidos', True, [('resumo', 'faixa'), ('script', 'tabela'), ('eventos', 'tabela'), ('comando', 'faixa')]),
    '/rodadas': ('Rodadas', 'rodadas', False, [('filtros', 'faixa'), ('tabela', 'tabela')]),
    '/rodada': ('Rodada', 'rodadas', True, [('resumo', 'faixa'), ('etapas', 'tabela')]),
    '/ciclo': ('Ciclo', 'rodadas', True, [('resumo', 'faixa'), ('etapa', 'faixa'), ('rodadas', 'tabela')]),
    '/conversa': ('Conversa', 'conversas', True, [('resumo', 'indicadores'), ('spans', 'tabela'), ('dados', 'faixa'), ('logs', 'tabela')]),
    '/sessao': ('Sessão', 'sessoes', True, [('resumo', 'indicadores'), ('conversas', 'tabela'), ('eventos', 'tabela'), ('dados', 'faixa')]),
    '/conversa/logs': ('Logs da conversa', 'conversas', True, [('conteudo', 'tabela')]),
    '/conversa/span': ('Span', 'conversas', True, [('conteudo', 'faixa')]),
}
TTL = 120
MAX_VIEWS = 32
KEY = re.compile(r'[A-Za-z0-9_-]{24}', re.ASCII)  # o `secrets.token_urlsafe(18)` do `Views.open`


def pairs(q):
    return [(k, v) for k, v in q.items() if v and k not in ('full', 'view') and not (k == 'custo' and v != 'pago')]


def block_url(path, block, query, view=''):
    if path == '/rodada':
        prefix = '/rodada/bloco'
    else:
        screen_path = '/dashboard' if path == '/' else path
        prefix = '/bloco' + screen_path
    return prefix + '/' + block + '?' + urlencode([*query, ('view', view)])


class View:
    def __init__(self, path, query, window=None):
        self.path, self.query, self.window = path, query, window
        self.used = time.monotonic()  # último pedido: é dele que o prazo conta (#591)
        self.lock = threading.Lock()
        self.results = {}

    def read(self, key, fn, args):
        with self.lock:
            pending = self.results.get(key)
            first = pending is None
            if first:
                pending = self.results[key] = Future()
        if first:
            try:
                pending.set_result(fn(*args))
            except Exception as exc:
                pending.set_exception(exc)
                with self.lock:
                    self.results.pop(key, None)
        # Quem monta estado e tabelas pode alterar as linhas: cada pedido recebe sua cópia.
        return copy.deepcopy(pending.result())


class Views:
    def __init__(self):
        self.entries = {}

    def _live(self, v):
        return time.monotonic() - v.used < TTL

    def open(self, path, query, window=None, key=None):
        self.entries = {k: v for k, v in self.entries.items() if self._live(v) and k != key}
        while len(self.entries) >= MAX_VIEWS:
            self.entries.pop(next(iter(self.entries)))
        key = key or secrets.token_urlsafe(18)
        self.entries[key] = View(path, query, window)
        return key

    def find(self, key, path, query):
        """A abertura `key` desta tela e query, dentro do prazo; achada, o prazo recomeça (#591)."""
        v = self.entries.get(key)
        if v and v.path == path and v.query == query and self._live(v):
            v.used = time.monotonic()
            return v
        return None

    def reopen(self, key, path, query, window):
        """Bloco pedido com a abertura `key` vencida ou descartada (#591): abre de novo com o mesmo id, para os outros
        blocos atrasados da tela compartilharem as leituras. `window()` = a janela de agora. `None` = sem abertura (o
        bloco lê sozinho): id fora do formato, ou id que está em uso por outra tela ou query."""
        v = self.entries.get(key)
        if not KEY.fullmatch(key) or (v and self._live(v)):
            return None
        self.open(path, query, window(), key)
        return self.entries[key]


def render_fragment(target, found):
    """Jinja `call fragment`: só roda o corpo escolhido; página inteira roda todos."""
    def fragment(name, caller):
        if target is None:
            return caller()
        if name == target:
            found.append(caller())
        return Markup('')
    return fragment
