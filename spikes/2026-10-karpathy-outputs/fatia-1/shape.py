#!/usr/bin/env python3
"""shape.py <repo> <variants-dir> — forma do texto por arquivo e variante (spike #458).
Frase = trecho de prosa terminado em . ! ? ; ou : seguido de espaço/fim, depois de tirar blocos cercados, linhas de
tabela e de substituir cada trecho entre crases por uma palavra (COD). Saída TSV:
arquivo variante frases media_palavras mediana pct_acima_25 max."""
import re, sys, statistics
repo, var = sys.argv[1], sys.argv[2]
FILES = ["docker/swarm.md","docker/swarm-worker.md","docker/agent-notes.md","AGENTS.md",
 "addons/skills/oute-aidlc-qa-pr-audit/SKILL.md","addons/skills/oute-aidlc-ops-observe/SKILL.md",
 "addons/skills/oute-aidlc-ship-verify/SKILL.md"]
def sentences(text):
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("|"): continue
        line = re.sub(r"`[^`]*`", "COD", line)
        line = re.sub(r"^\s*([-*]|\d+\.|#+)\s+", "", line)
        for s in re.split(r"(?<=[.!?;:])\s+", line):
            n = len(re.findall(r"[\w#/§-]+", s))
            if n >= 3: out.append(n)
    return out
for f in FILES:
    for v in ["a-pt","b-en-concise","c-en-ste80"]:
        p = f"{repo}/{f}" if v == "a-pt" else f"{var}/{v}/{f}"
        s = sentences(open(p).read())
        print(f, v, len(s), f"{statistics.mean(s):.1f}", statistics.median(s),
              f"{100*sum(1 for n in s if n>25)/len(s):.0f}", max(s), sep="\t")
