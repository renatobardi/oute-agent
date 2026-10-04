#!/usr/bin/env bash
# forma.sh — forma da prosa antes e depois (P1, P2, P3), a partir dos arquivos desta pasta. Saída em medidas/forma.tsv.
# P5 não entra aqui: o artefato é privado; os números dele foram medidos com o mesmo textstats.py fora do repo.
set -euo pipefail
cd "$(dirname "$0")/.."
t=tools/textstats.py; tmp="$(mktemp -d)"
printf 'artefato\tpalavras\tfrases\tmedia_pal_frase\tmediana\tmax\tpct_frases_>20\tpct_frases_>25\tparagrafos\tmax_frases_par\tpct_par_>6frases\tpct_frases_passivas(heuristica)\n'
$t pt p1/original-auditoria-457.md p1/sonnet/pedido-merge.md p1/haiku/pedido-merge.md p3/original-resumo-ciclo-437.md p3/p3-texto.md
for f in p2/original.sh p2/sonnet/pedido.sh p2/haiku/pedido.sh; do
  n="$tmp/$(echo "$f" | tr / _).txt"; tools/p2prose.py "$f" > "$n"; $t pt "$n" | sed "s|^$n|$f (prosa extraida)|"
done
rm -rf "${tmp:?}"
