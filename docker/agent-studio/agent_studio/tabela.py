"""Tabelas das telas (#529, épico #522): ordem, filtro por coluna e página, tudo pela URL.

Uma `Table` descreve as colunas de uma lista; `parse` lê da URL a ordem, a direção, o filtro de cada coluna de categoria, a
página e o tamanho; `apply` ordena, filtra e corta as linhas já lidas. Nada daqui chega ao SQL: a ordem e o filtro valem
sobre as linhas em memória (a lista inteira, para a ordem valer entre as páginas), e o nome de coluna que vem da URL só
entra se estiver na lista fixa da tabela (senão `ValueError`, que a tela responde com 400).

Parâmetros de uma tabela (o sufixo `_x` só existe quando a tela tem mais de uma tabela):
- `ord<_x>`: a chave da coluna; `dir<_x>`: `asc` ou `desc`;
- `pag<_x>`: a página (1 em diante); `tam<_x>`: 20, 50 ou 100 (20 é o padrão);
- o filtro de cada coluna de categoria: `f_<coluna><_x>`, salvo o nome que a coluna fixa (`host` e `agent`, que as listas já
  usavam).

Os links do cabeçalho e do rodapé (`View.url`) levam todos os parâmetros da URL que não são da própria mudança; mudar a
ordem, o filtro ou o tamanho volta à primeira página. Sem JavaScript: tudo é link.
"""
import math
import re
from urllib.parse import quote, urlencode

SIZES = (20, 50, 100)
DEFAULT_SIZE = 20
ALL = 2**31 - 1     # "sem teto" para a consulta que alimenta uma tabela paginada
DIRECTIONS = ("asc", "desc")
# a direção do primeiro clique: texto de A a Z; número e hora do maior (ou mais recente) para o menor
NATURAL = {"text": "asc", "num": "desc", "time": "desc"}
_OWN = re.compile(r"^(ord|dir|pag|tam)(_[a-z]+)?$|^f_[a-z_]+$")


class Col:
    """Uma coluna. `get(row)` = o valor de ordem (`None` fica sempre no fim); `values(row)` = os valores da coluna para o
    filtro (lista; só coluna de categoria); `param` = o nome do filtro na URL (padrão `f_<key><sufixo>`)."""

    def __init__(self, key, kind="text", get=None, values=None, param=None):
        self.key, self.kind, self.get, self.values, self.param = key, kind, get, values, param


class Table:
    def __init__(self, cols, default, suffix="", anchor="", paginate=True):
        self.cols = {c.key: c for c in cols}
        self.default, self.suffix, self.anchor, self.paginate = default, suffix, anchor, paginate
        for c in cols:
            if c.values is not None and c.param is None:
                c.param = f"f_{c.key}{suffix}"

    def name(self, base):
        return base + self.suffix

    def filters(self):
        return {c.param: c for c in self.cols.values() if c.values is not None}

    def own_names(self):
        """Os nomes de parâmetro que são desta tabela: tabela sem página (a do Uso) não tem `pag` nem `tam`."""
        return {self.name(b) for b in (("ord", "dir", "pag", "tam") if self.paginate else ("ord", "dir"))} | set(self.filters())


class State:
    """O que a URL pediu para uma tabela, já validado."""

    def __init__(self, order, direction, page, size, filters, explicit):
        self.order, self.direction, self.page, self.size, self.filters, self.explicit = order, direction, page, size, filters, explicit


def check_params(q, tables):
    """Parâmetro de ordem, direção, página, tamanho ou filtro que nenhuma das `tables` da tela conhece = `ValueError`.
    O que não é nosso (janela, repositório, custo…) passa."""
    known = _own_keys(tables)
    for key in q.keys():
        if _OWN.match(key) and key not in known:
            raise ValueError("parâmetro de tabela desconhecido")
    return None


def parse(table, q):
    """Lê da URL (`q` = os parâmetros da consulta) o pedido para `table`. Valor fora da lista fixa = `ValueError`."""
    order, direction = q.get(table.name("ord")), q.get(table.name("dir"))
    if order is not None and order not in table.cols:
        raise ValueError("coluna de ordem fora da lista")
    if direction is not None and direction not in DIRECTIONS:
        raise ValueError("direção de ordem inválida (asc ou desc)")
    size = q.get(table.name("tam"))
    if size is not None and (not (size.isascii() and size.isdigit()) or int(size) not in SIZES):
        raise ValueError("tamanho de página inválido (20, 50 ou 100)")
    page = q.get(table.name("pag"))
    if page is not None and (not (page.isascii() and page.isdigit()) or not 1 <= int(page) <= 10**9):
        raise ValueError("página inválida")
    default_order, default_dir = table.default
    order = order or default_order
    direction = direction or (default_dir if order == default_order else NATURAL[table.cols[order].kind])
    filters = {c.key: q.get(p, "") for p, c in table.filters().items()}
    explicit = {b: q.get(table.name(b)) for b in ("ord", "dir", "pag", "tam") if q.get(table.name(b)) is not None}
    return State(order, direction, int(page) if page else 1, int(size) if size else DEFAULT_SIZE,
                 {k: v for k, v in filters.items() if v}, explicit)


def _sort(rows, col, direction):
    present = [r for r in rows if col.get(r) is not None]
    missing = [r for r in rows if col.get(r) is None]
    return sorted(present, key=col.get, reverse=direction == "desc") + missing


class View:
    """A tabela pronta para o template: as linhas da página, o rodapé e os links."""

    def __init__(self, table, state, pairs, path, rows, total, unfiltered, options):
        self.table, self.state, self._pairs, self._path = table, state, pairs, path
        self.rows, self.total, self.unfiltered, self.options = rows, total, unfiltered, options
        self.size = state.size if table.paginate else max(total, 1)
        self.pages = max(1, math.ceil(total / self.size))
        self.page = min(state.page, self.pages)
        self.first = (self.page - 1) * self.size + 1 if total else 0
        self.last = min(self.page * self.size, total)
        self.touched = bool(state.explicit) or bool(state.filters)
        self.filtered = bool(state.filters)

    def url(self, order=None, direction=None, page=None, size=None, **filters):
        """O link com a mudança pedida. Ordem, filtro e tamanho novos voltam à primeira página; `page` só muda a página."""
        t, s = self.table, self.state
        pairs = list(self._pairs)
        new = {"ord": s.explicit.get("ord"), "dir": s.explicit.get("dir"), "pag": s.explicit.get("pag"),
               "tam": s.explicit.get("tam")}
        flt = dict(s.filters)
        if order is not None:
            new["ord"], new["dir"], new["pag"] = order, direction, None
        if size is not None:
            new["tam"], new["pag"] = None if size == DEFAULT_SIZE else str(size), None
        if page is not None:
            new["pag"] = None if page == 1 else str(page)
        for key, value in filters.items():
            flt[key] = value
            new["pag"] = None
        for base, value in new.items():
            if value is not None:
                pairs.append((t.name(base), str(value)))
        for key, value in flt.items():
            if value:
                pairs.append((t.cols[key].param, value))
        return self._path + ("?" + urlencode(pairs, quote_via=quote) if pairs else "") + t.anchor

    def sort_link(self, key):
        """Link do cabeçalho: o segundo clique na coluna ordenada inverte; a coluna nova começa na direção natural dela."""
        s = self.state
        if key == s.order:
            return self.url(key, "asc" if s.direction == "desc" else "desc")
        return self.url(key, NATURAL[self.table.cols[key].kind])

    def aria_sort(self, key):
        if key != self.state.order:
            return "none"
        return "ascending" if self.state.direction == "asc" else "descending"

    def clear_url(self):
        return self.url(**{k: "" for k in self.state.filters})

    def page_links(self):
        """Páginas do rodapé: a primeira, a última e as vizinhas da atual; `None` = reticências."""
        want = sorted({1, self.pages, *range(max(1, self.page - 2), min(self.pages, self.page + 2) + 1)})
        out, prev = [], 0
        for n in want:
            if n - prev > 1:
                out.append(None)
            out.append(n)
            prev = n
        return out


def apply(table, state, rows, pairs, path):
    """Filtra, ordena e corta `rows` -> `View`. `pairs` = os pares da URL que não são desta tabela; `path` = a rota."""
    options = {}
    for c in table.cols.values():
        if c.values is not None:
            seen = {v for r in rows for v in c.values(r) if v}
            if state.filters.get(c.key):
                seen.add(state.filters[c.key])
            options[c.key] = sorted(seen)
    kept = [r for r in rows if all(f in table.cols[k].values(r) for k, f in state.filters.items())]
    kept = _sort(kept, table.cols[state.order], state.direction)
    view = View(table, state, pairs, path, kept, len(kept), len(rows), options)
    if table.paginate:
        view.rows = kept[view.first - 1:view.last] if kept else []
    return view


def _own_keys(tables):
    return set().union(*(t.own_names() for t in tables))


def foreign_pairs(q, tables, drop=None):
    """Os pares da URL que não são de nenhuma das `tables` (janela, repositório, custo…), na ordem em que vieram. Campo em
    branco do formulário e o par que `drop(chave, valor)` aceita (o valor que a tela trata como o padrão) contam como sem o
    parâmetro."""
    own = _own_keys(tables)
    return [(k, v) for k, v in q.multi_items() if k not in own and v != "" and not (drop and drop(k, v))]


def own_pairs(q, tables):
    """Os pares da URL que são das `tables`, menos a página: o que o formulário do período leva escondido (mudar o período
    não desfaz a ordem, o tamanho nem o filtro, e a página volta à primeira)."""
    own = _own_keys(tables)
    return [(k, v) for k, v in q.multi_items() if k in own and not k.startswith("pag")]


def usage_cols(u, detail=True):
    """As colunas de consumo (chamadas, tokens, custo e, na lista, p95 e erros) de uma linha cujo `u(row)` é o uso
    renderizado (`usage.rendered`). O custo de ordem é o real mais o estimado, o mesmo que o gráfico do Uso usa."""
    cols = [Col("calls", "num", lambda r: u(r)["calls"]),
            Col("tokens", "num", lambda r: u(r)["tokens"]["input"] + u(r)["tokens"]["output"]),
            Col("cost", "num", lambda r: (u(r)["cost"]["real_usd"] or 0) + (u(r)["cost"]["estimated_usd"] or 0))]
    if detail:
        cols += [Col("p95", "num", lambda r: u(r)["latency_p95_ms"]), Col("errors", "num", lambda r: u(r)["errors"]["total"])]
    return cols
