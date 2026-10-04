#!/usr/bin/env python3
"""fisher.py <ok_a> <n_a> <ok_b> <n_b> — teste exato de Fisher, duas caudas, para 2 proporções (sem scipy)."""
import sys
from math import comb
oa, na, ob, nb = map(int, sys.argv[1:5])
k = oa + ob; n = na + nb
p = lambda x: comb(na, x) * comb(nb, k - x) / comb(n, k)
obs = p(oa)
print(f"p = {sum(p(x) for x in range(max(0, k - nb), min(na, k) + 1) if p(x) <= obs + 1e-12):.3f}")
