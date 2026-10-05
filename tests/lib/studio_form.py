"""O formulário de filtro (`<form class="filtro">`) como o navegador o envia, para os testes das telas do agent-studio:
renderiza a página, lê os campos `input` e o `option` marcado de cada `select` e devolve a resposta ao GET do envio.
Uso: PYTHONPATH=tests/lib; `submit(get, app, path, query, **escolhas)` -> ((status, corpo), pares enviados). `get` é o do
`studio_asgi`; `escolhas` troca o valor de um campo pelo nome."""
from html.parser import HTMLParser
from urllib.parse import urlencode


class Fields(HTMLParser):
    def __init__(self):
        super().__init__()
        self.sent, self.in_form, self.select = [], False, None
        self.chosen = {}

    def handle_starttag(self, tag, a):
        a = dict(a)
        if tag == "form" and "filtro" in (a.get("class") or ""):
            self.in_form = True
        elif self.in_form and tag == "input" and a.get("name"):
            self.sent.append((a["name"], a.get("value") or ""))
        elif self.in_form and tag == "select":
            self.select = a["name"]
            self.chosen[self.select] = ""
        elif self.in_form and tag == "option" and self.select and "selected" in a:
            self.chosen[self.select] = a.get("value") or ""

    def handle_endtag(self, tag):
        if tag == "select":
            self.select = None
        elif tag == "form":
            self.in_form = False


def submit(get, app, path, query, **pick):
    f = Fields()
    f.feed(get(app, path, query)[1])
    sent = f.sent + [(k, pick.get(k, v)) for k, v in f.chosen.items()]
    return get(app, path, urlencode([(k, pick.get(k, v)) for k, v in sent])), sent
