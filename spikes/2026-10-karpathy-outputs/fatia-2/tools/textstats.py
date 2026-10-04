#!/usr/bin/env python3
"""textstats.py <lang pt|en> <arquivo>… — forma da prosa (spike #458, pergunta 3). Saída TSV.
Prosa = o arquivo sem front matter, sem blocos cercados e sem linhas de tabela; trecho entre crases vira a palavra COD;
marcador de lista e de título saem. Frase = trecho terminado em . ! ? ; ou : seguido de espaço ou fim, com >= 3 palavras.
Parágrafo = bloco separado por linha em branco; item de lista conta como parágrafo próprio.
Colunas: arquivo palavras(wc -w do arquivo) frases media_pal_frase mediana max pct_>20 pct_>25 paragrafos
         max_frases_paragrafo pct_paragrafos_>6frases pct_frases_passivas(heurística).
Voz passiva é HEURÍSTICA por regex (verbo ser/estar + particípio): erra nos dois sentidos; vale para comparar antes e depois."""
import re, sys, statistics
PASS = {
 "pt": re.compile(r"\b(foi|foram|é|são|era|eram|será|serão|seja|sejam|sendo|ser|está|estão|estava|estavam|ficou|ficaram|fica|ficam)\s+(?!que\b)(\w+(?:ado|ada|ados|adas|ido|ida|idos|idas|so|sa|sos|sas|to|ta|tos|tas))\b", re.I),
 "en": re.compile(r"\b(is|are|was|were|be|been|being)\s+(\w+ed|\w+en|built|done|made|run|set|sent|written|read|left|kept|found|given|shown|known|taken|seen|held|put|cut|lost|spent|told)\b", re.I),
}
def prose(text):
    text = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("|"): continue
        line = re.sub(r"`[^`]*`", "COD", line)
        line = re.sub(r"\*\*|__", "", line)
        out.append(line)
    return out
def blocks(lines):
    paras, cur = [], []
    for l in lines:
        if not l.strip():
            if cur: paras.append(" ".join(cur)); cur = []
        elif re.match(r"^\s*([-*]|\d+[.)])\s+", l) or l.startswith("#"):
            if cur: paras.append(" ".join(cur)); cur = []
            cur.append(re.sub(r"^\s*([-*]|\d+[.)]|#+)\s+", "", l))
        else: cur.append(l.strip())
    if cur: paras.append(" ".join(cur))
    return paras
def sents(par):
    r = []
    for s in re.split(r"(?<=[.!?;:])\s+", par):
        n = len(re.findall(r"[\w#/§-]+", s))
        if n >= 3: r.append(s)
    return r
lang = sys.argv[1]
for f in sys.argv[2:]:
    raw = open(f).read()
    paras = [sents(p) for p in blocks(prose(raw))]
    paras = [p for p in paras if p]
    allv = [s for p in paras for s in p]
    ns = [len(re.findall(r"[\w#/§-]+", s)) for s in allv]
    if not ns: print(f, "sem prosa", sep="\t"); continue
    pas = sum(1 for s in allv if PASS[lang].search(s))
    pc = [len(p) for p in paras]
    print(f, len(raw.split()), len(ns), f"{statistics.mean(ns):.1f}", statistics.median(ns), max(ns),
          f"{100*sum(n>20 for n in ns)/len(ns):.0f}", f"{100*sum(n>25 for n in ns)/len(ns):.0f}",
          len(paras), max(pc), f"{100*sum(c>6 for c in pc)/len(pc):.0f}", f"{100*pas/len(allv):.0f}", sep="\t")
