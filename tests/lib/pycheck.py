"""Relato de um caso nos trechos em Python dos testes, no formato que o tests/lib/check.sh soma (`check_py`,
`check_py_lines`). Uso: PYTHONPATH=tests/lib."""


def check(desc, cond):
    print(("ok   " if cond else "FAIL ") + desc)
