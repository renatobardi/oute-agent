#!/usr/bin/env python3
"""HTML (stdin) -> JSON: um objeto por elemento com atributo `data-*`, na ordem do documento, com os `data-*`
(sem o prefixo), a `tag` e o `text` (o texto do elemento, espaços colapsados). Para os testes da tela do
agent-studio conferirem a página pelo que o servidor devolve, sem navegador."""
import json
import sys
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}


class Parser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.out = [], []

    def handle_starttag(self, tag, attrs):
        data = {k[5:]: v for k, v in attrs if k.startswith("data-")}
        item = {**data, "tag": tag, "_text": []} if data else None
        if item is not None:
            self.out.append(item)
        if tag not in VOID:
            self.stack.append((tag, item))

    def handle_endtag(self, tag):
        while self.stack:
            t, _ = self.stack.pop()
            if t == tag:
                break

    def handle_data(self, text):
        for _, item in self.stack:
            if item is not None:
                item["_text"].append(text)


p = Parser()
p.feed(sys.stdin.read())
for item in p.out:
    item["text"] = " ".join(" ".join(item.pop("_text")).split())
json.dump(p.out, sys.stdout, ensure_ascii=False)
