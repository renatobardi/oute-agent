#!/usr/bin/env python3
"""Lint de regras de shell que já voltaram como lição (#652), só sobre o que o diff acrescenta.
Lê um diff unificado (arquivo ou stdin) e confere:
  1. `rm` com variável sem `${VAR:?}` (#539, #578): em linha nova, `rm` cujo argumento tem `$VAR`, `${VAR}` ou
     `$(…)`. Passa `${VAR:?…}`, caminho literal e `$(mktemp -d…)`. `# rm-ok: <motivo>` na linha dispensa.
  2. Função de shell nova (#501, #585; SonarCloud S7679 e S7682): a linha de definição é nova, e o corpo tem
     `$1`..`$9` fora de uma linha `local …`, ou não termina em `return` explícito. Função antiga não se confere.
Só arquivo de shell (`.sh`, ou sem extensão em scripts/, docker/ e tests/). O corpo da função é lido do arquivo
na árvore de trabalho (`--root`, padrão `.`). Uso: diff-lint.py [--root DIR] [arquivo-de-diff]
Imprime `<arquivo>:<linha>: <achado>` e sai 1 se achar algum."""
import os
import re
import sys

SHELL_DIRS = ('scripts/', 'docker/', 'tests/')
DEF_RE = re.compile(r'^\s*(?:function\s+([A-Za-z_][\w.:-]*)\s*(?:\(\s*\))?|([A-Za-z_][\w.:-]*)\s*\(\s*\))\s*\{')
RM_RE = re.compile(r'''(?:^|(?<=[;&|(){'"])|(?<=\bthen\s)|(?<=\bdo\s)|(?<=\belse\s)|(?<=\bsudo\s)|(?<=\bxargs\s))\s*rm\s+''')
EXP_RE = re.compile(r'\$(\{[^}]*\}|\(|[A-Za-z_]\w*|[0-9@*#?!$-])')
POS_RE = re.compile(r'\$(?:[1-9]|\{[1-9])')


def is_shell(path):
    base = os.path.basename(path)
    if base.endswith('.sh'):
        return True
    return '.' not in base and path.startswith(SHELL_DIRS)


def parse_diff(text):
    """[(arquivo, linha nova, texto)] das linhas acrescentadas."""
    out = []
    path = None
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if line.startswith('+++ '):
            path = None if line[4:].startswith('/dev/null') else line[6:] if line[4:6] == 'b/' else line[4:]
            continue
        m = re.match(r'@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', line)
        if not m:
            continue
        old = int(m.group(1) if m.group(1) is not None else 1)
        new = int(m.group(3) if m.group(3) is not None else 1)
        n = int(m.group(2))
        while (old > 0 or new > 0) and i < len(lines):
            h = lines[i]
            i += 1
            if h.startswith('\\'):
                continue
            if h.startswith('+'):
                if path:
                    out.append((path, n, h[1:]))
                n += 1
                new -= 1
            elif h.startswith('-'):
                old -= 1
            else:
                n += 1
                old -= 1
                new -= 1
    return out


def strip_code(s, keep_double=False):
    """Tira aspas simples, aspas duplas (a menos de keep_double), ${…} e comentário, para contar chaves."""
    s = re.sub(r"'[^']*'", "''", s)
    if not keep_double:
        s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    s = re.sub(r'\$\{[^}]*\}', 'V', s)
    return re.sub(r'(?:^|\s)#.*$', '', s)


def rm_findings(text):
    """Achado de `rm` com variável numa linha; '' se não houver."""
    if re.search(r'#\s*rm-ok:', text) or text.lstrip().startswith('#'):
        return ''
    for m in RM_RE.finditer(text):
        start = m.end()
        # a aspa que abre o trecho (trap 'rm …', bash -c "rm …") fecha onde acaba o comando
        before = text[:m.start()].rstrip()
        quote = before[-1] if before and before[-1] in '\'"' else ''
        rest = text[start:]
        end = len(rest)
        for stop in (';', '&&', '||', '|', ')', '#'):
            j = rest.find(stop)
            if j >= 0:
                end = min(end, j)
        if quote:
            j = rest.find(quote)
            if j >= 0:
                end = min(end, j) if quote == "'" else end
        args = rest[:end]
        if quote != "'":
            args = re.sub(r"'[^']*'", "''", args)
        args = args.replace('$(mktemp -d', 'MKTEMP(')
        for e in EXP_RE.finditer(args):
            body = e.group(1)
            if body.startswith('{') and re.match(r'\{[A-Za-z_]\w*:\?', body):
                continue
            return 'rm com variável sem ${VAR:?}: ' + text.strip()
    return ''


def func_body(lines, start):
    """Linhas do corpo da função que abre em lines[start] (índice), com o índice de cada uma; None sem fechar."""
    depth = 0
    body = []
    heredoc = None
    for idx in range(start, len(lines)):
        raw = lines[idx]
        if heredoc is not None:
            if raw.strip('\t') == heredoc:
                heredoc = None
            continue
        code = strip_code(raw)
        h = re.search(r'<<-?\s*[\'"]?(\w+)[\'"]?', code)
        depth += code.count('{') - code.count('}')
        body.append((idx, raw, code))
        if depth <= 0:
            return body
        if h:
            heredoc = h.group(1)
    return None


def func_findings(path, lineno, lines):
    """Achados da função nova que abre na linha `lineno` (1-based) do arquivo."""
    m = DEF_RE.match(lines[lineno - 1])
    if not m:
        return []
    name = m.group(1) or m.group(2)
    body = func_body(lines, lineno - 1)
    if body is None:
        return []
    out = []
    for idx, raw, _ in body:
        inner = raw[raw.index('{') + 1:] if idx == lineno - 1 else raw
        if re.match(r'\s*(?:local|declare|typeset)\b', inner):
            continue
        scan = re.sub(r"'[^']*'", "''", inner.replace('\\$', ''))
        scan = re.sub(r'(?:^|\s)#.*$', '', scan)
        if POS_RE.search(scan):
            out.append(f'{path}:{idx + 1}: função {name}: parâmetro posicional fora de `local` (S7679)')
    codes = [c for _, _, c in body]
    codes[0] = codes[0][codes[0].index('{') + 1:]
    text = '\n'.join(codes)
    text = text[:text.rfind('}')]
    stmts = [x.strip() for x in re.split(r'[;\n]', text) if x.strip()]
    if not stmts or not re.match(r'return\b', stmts[-1]):
        out.append(f'{path}:{lineno}: função {name}: sem return explícito no fim (S7682)')
    return out


def main(argv):
    root = '.'
    files = []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == '--root':
            root = args.pop(0)
        else:
            files.append(a)
    if files:
        with open(files[0], encoding='utf-8', errors='replace') as f:
            text = f.read()
    else:
        text = sys.stdin.read()
    found = []
    cache = {}
    for path, n, line in parse_diff(text):
        if not is_shell(path):
            continue
        hit = rm_findings(line)
        if hit:
            found.append(f'{path}:{n}: {hit}')
        if DEF_RE.match(line):
            if path not in cache:
                try:
                    with open(os.path.join(root, path), encoding='utf-8', errors='replace') as f:
                        cache[path] = f.read().split('\n')
                except OSError:
                    cache[path] = []
            if cache[path]:
                found.extend(func_findings(path, n, cache[path]))
    for item in found:
        print(item)
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
