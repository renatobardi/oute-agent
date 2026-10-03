#!/usr/bin/env python3
"""Acha `check` com condição fora dele (#285): `check "…" [ … ] && grep …` conta só o `[ … ]`; o `&& grep …` roda
depois, fora do check, e a falha dele é ignorada. Lê cada arquivo como o bash (aspas, $(…), ${…}, crases,
continuação de linha, comentário e heredoc) e aponta o `check` em início de comando seguido de `&&`, `||` ou `|`
fora de aspas. O `bash -c '… && …'` dentro do check vale. Uso: check-lint.py <arquivo…>; imprime
`<arquivo>:<linha>: check com <op> fora dele` e sai 1 se achar algum."""
import sys

OPS = ('&&', '||', ';;', '|&', '|', '&', ';', '(', ')')
KEYS = {'then', 'do', 'else', 'elif', 'if', 'while', 'until', '{', '!', 'time'}

def scan(text):
    n = len(text); out = []

    def squote(i):
        j = text.find("'", i)
        return n if j < 0 else j + 1

    def dquote(i):
        while i < n:
            c = text[i]
            if c == '\\': i += 2
            elif c == '"': return i + 1
            elif text.startswith('$(', i): i = nest(i + 2, '(', ')')
            elif text.startswith('${', i): i = nest(i + 2, '{', '}')
            elif c == '`': i = backtick(i + 1)
            else: i += 1
        return n

    def backtick(i):
        while i < n:
            if text[i] == '\\': i += 2
            elif text[i] == '`': return i + 1
            else: i += 1
        return n

    def nest(i, op, cl):
        depth = 1
        while i < n:
            c = text[i]
            if c == '\\': i += 2; continue
            if c == "'": i = squote(i + 1); continue
            if c == '"': i = dquote(i + 1); continue
            if c == '`': i = backtick(i + 1); continue
            if c == op: depth += 1
            elif c == cl:
                depth -= 1
                if depth == 0: return i + 1
            i += 1
        return n

    # start: a próxima palavra começa um comando; check: linha do `check` em curso; heredocs: delimitadores pendentes
    i = 0; start = True; word = ''; check = None; heredocs = []

    def end_word():
        nonlocal word, start, check
        if word:
            if start and word == 'check': check = text.count('\n', 0, i) + 1
            start = word in KEYS
            word = ''

    while i < n:
        c = text[i]
        if c in ' \t':
            end_word(); i += 1
        elif text.startswith('\\\n', i):
            end_word(); i += 2
        elif c == '\\':
            word += text[i:i + 2]; i += 2
        elif c == '#' and not word:
            j = text.find('\n', i); i = n if j < 0 else j
        elif c == '\n':
            end_word(); i += 1
            check = None; start = True
            for d in heredocs:
                while i < n:
                    j = text.find('\n', i); j = n if j < 0 else j
                    line = text[i:j]; i = j + 1
                    if line.strip('\t') == d: break
            heredocs = []
        elif c == "'":
            j = squote(i + 1); word += text[i:j]; i = j
        elif c == '"':
            j = dquote(i + 1); word += text[i:j]; i = j
        elif text.startswith("$'", i):
            j = i + 2
            while j < n and text[j] != "'": j += 2 if text[j] == '\\' else 1
            word += text[i:j + 1]; i = j + 1
        elif text.startswith('$(', i) or text.startswith('<(', i) or text.startswith('>(', i):
            j = nest(i + 2, '(', ')'); word += text[i:j]; i = j
        elif text.startswith('${', i):
            j = nest(i + 2, '{', '}'); word += text[i:j]; i = j
        elif c == '`':
            j = backtick(i + 1); word += text[i:j]; i = j
        elif text.startswith('<<<', i):
            word += '<<<'; i += 3
        elif text.startswith('<<', i):
            end_word(); i += 2
            if i < n and text[i] == '-': i += 1
            while i < n and text[i] in ' \t': i += 1
            j = i
            while j < n and text[j] not in ' \t\n;&|<>()': j += 1
            heredocs.append(text[i:j].replace("'", '').replace('"', '').replace('\\', ''))
            i = j
        elif c == '&' and (word.endswith(('>', '<')) or text.startswith('&>', i)):
            word += c; i += 1
        elif c in ';&|()':
            op = next(o for o in OPS if text.startswith(o, i))
            end_word()
            if check is not None and op in ('&&', '||', '|', '|&'):
                out.append((check, op))
            check = None; start = True; i += len(op)
        else:
            word += c; i += 1
    return out

bad = 0
for path in sys.argv[1:]:
    with open(path, encoding='utf-8') as f:
        for line, op in scan(f.read()):
            print(f'{path}:{line}: check com {op} fora dele')
            bad += 1
sys.exit(1 if bad else 0)
