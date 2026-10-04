#!/usr/bin/env python3
"""table.py <tokens.tsv> — tabela Markdown da pergunta 7: por arquivo e medida, o valor em pt e a diferença % de b e c."""
import sys, collections
d = collections.defaultdict(dict); files = []
for l in open(sys.argv[1]):
    if l.startswith("#"): continue
    f, v, m, n = l.rstrip("\n").split("\t"); d[(f, m)][v] = int(n)
    if f not in files: files.append(f)
M = ["words", "o200k", "claude-haiku-4-5-20251001", "claude-sonnet-5-5", "claude-opus-5-5"]
def row(name, get):
    cells = []
    for m in M:
        a, b, c = (get(m, v) for v in ("a-pt", "b-en-concise", "c-en-ste80"))
        cells.append(f"{a} · {b} ({100*(b-a)/a:+.1f}%) · {c} ({100*(c-a)/a:+.1f}%)")
    return f"| {name} | " + " | ".join(cells) + " |"
print("| arquivo | palavras (`wc -w`) | o200k_base | Haiku 4.5 | Sonnet 5.5 | Opus 5.5 |\n|---|---|---|---|---|---|")
for f in files: print(row(f"`{f}`", lambda m, v: d[(f, m)][v]))
print(row("**total**", lambda m, v: sum(d[(f, m)][v] for f in files)))
