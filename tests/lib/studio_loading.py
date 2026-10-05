"""Lê os trechos dos espaços como o htmx; usado nos testes ASGI e HTTP da tela."""
from html.parser import HTMLParser
import re
from urllib.parse import urlsplit


class Slots(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.html = html
        self.lines = [0]
        for line in html.splitlines(True):
            self.lines.append(self.lines[-1] + len(line))
        self.depth = 0
        self.current = None
        self.slots = []
        self.feed(html)

    def at(self):
        line, col = self.getpos()
        return self.lines[line - 1] + col

    def handle_starttag(self, tag, attrs):
        if tag != 'div':
            return
        attrs = dict(attrs)
        if self.current is None and 'data-bloco' in attrs:
            self.current = (self.at(), attrs['hx-get'])
            self.depth = 0
        if self.current:
            self.depth += 1

    def handle_endtag(self, tag):
        if tag == 'div' and self.current:
            self.depth -= 1
            if not self.depth:
                start, url = self.current
                self.slots.append((start, self.at() + len('</div>'), url))
                self.current = None


def expand(html, fetch):
    """`fetch(path, query)` -> (status, HTML). Inclui catálogos que descobrem novos espaços."""
    status = 200
    for start, end, url in reversed(Slots(html).slots):
        parts = urlsplit(url)
        code, body = fetch(parts.path, parts.query)
        if code != 200:
            status = code
        else:
            nested, body = expand(body, fetch)
            if nested != 200:
                status = nested
        html = html[:start] + body + html[end:]
    # Equivale ao afterSwap de loading.js, sem rodar JavaScript no teste ASGI/HTTP.
    if '<title>' in html:
        for title in re.findall(r'<template data-document-title>(.*?)</template>', html, re.S):
            html = re.sub(r'<title>.*?</title>', lambda _: '<title>' + title + '</title>', html, count=1, flags=re.S)
        html = re.sub(r'<template data-document-title>.*?</template>', '', html, flags=re.S)
    return status, html
