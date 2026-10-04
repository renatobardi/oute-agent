#!/usr/bin/env python3
"""refcheck.py <arquivo> [ref…] — confere por máquina que cada referência citada no artefato EXISTE (spike #458, pergunta 6).
Tipos: `#N` (issue ou PR do oute-agent, `gh api` GET), SHA de 7 a 40 hex (`git cat-file -e`), `caminho:linha[-linha]`
(o arquivo existe em algum dos refs e tem a linha; `@sha` logo depois fixa o commit), link de comentário do GitHub do
oute-agent (`gh api` GET). Refs padrão: refs/spike/pr457 e origin/main. Saída TSV: tipo, referência, resultado (ok/FALHA/…).
NÃO confere se a referência SUSTENTA a afirmação: isso é do revisor (subagente Opus)."""
import re, subprocess, sys
f = sys.argv[1]; refs = sys.argv[2:] or ["refs/spike/pr457", "origin/main"]
txt = open(f).read()
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)
out, seen = [], set()
def add(k, r, v):
    if (k, r) not in seen: seen.add((k, r)); out.append((k, r, v))
repo = "renatobardi/oute-agent"
for u, n, c in re.findall(r"https://github\.com/renatobardi/oute-agent/(?:pull|issues)/(\d+)(?:#issuecomment-(\d+))?()", txt):
    if c == "" and n:
        pass
for m in re.finditer(r"https://github\.com/renatobardi/oute-agent/(pull|issues)/(\d+)#issuecomment-(\d+)", txt):
    r = sh("gh", "api", f"repos/{repo}/issues/comments/{m.group(3)}", "-q", ".issue_url")
    ok = r.returncode == 0 and r.stdout.strip().endswith("/" + m.group(2))
    add("comentario", m.group(0), "ok" if ok else "FALHA")
for m in re.finditer(r"(?<![\w/&])#(\d{1,4})\b", txt):
    r = sh("gh", "api", f"repos/{repo}/issues/{m.group(1)}", "-q", ".number")
    add("#N", "#" + m.group(1), "ok" if r.returncode == 0 else "FALHA")
for m in re.finditer(r"(?<![\w/#])([0-9a-f]{7,40})\b", txt):
    s = m.group(1)
    if not re.search(r"[a-f]", s) or not re.search(r"\d", s): continue   # evita número e palavra
    r = sh("git", "cat-file", "-e", s + "^{commit}")
    add("sha", s, "ok" if r.returncode == 0 else "FALHA")
for m in re.finditer(r"`?((?:docker|scripts|addons|tests|config|docs|tray)/[\w./-]+|[\w-]+\.md):(\d+)(?:-(\d+))?`?(?:@([0-9a-f]{7,40}))?", txt):
    path, a, b, sha = m.group(1), int(m.group(2)), int(m.group(3) or m.group(2)), m.group(4)
    res = "FALHA: arquivo não existe"
    for ref in ([sha] if sha else refs):
        r = sh("git", "show", f"{ref}:{path}")
        if r.returncode == 0:
            n = len(r.stdout.splitlines())
            res = "ok" if max(a, b) <= n else f"FALHA: arquivo tem {n} linhas"
            if res == "ok": res += f" ({ref})"; break
    add("arquivo:linha", m.group(0).strip("`"), res)
for k, r, v in out: print(k, r, v, sep="\t")
bad = sum(v.startswith("FALHA") for _, _, v in out)
print(f"# {len(out)} referências distintas, {bad} falha(s)", file=sys.stderr)
