#!/usr/bin/env python3
"""p2prose.py <script.sh> — extrai a prosa que o Bardi lê num pedido: título, linhas de comentário (fora os metadados
`# oute-propose`, `# como:`, `# agente:`, `# criado:`) e o texto de cada `echo "…"`. Uma frase por linha lógica; vai para o stdout,
para o `textstats.py`."""
import re, sys
for l in open(sys.argv[1]):
    l = l.rstrip("\n")
    m = re.match(r"\s*#\s?(.*)", l)
    if m:
        t = m.group(1)
        if re.match(r"(oute-propose|como:|agente:|criado:)", t) or not t.strip(): continue
        t = re.sub(r"^titulo:\s*", "", t); print(t + "\n"); continue
    for e in re.findall(r"echo \"([^\"]*)\"", l):
        if e.strip(): print(re.sub(r"\$\{?\w+[^ ]*", "COD", e) + "\n")
