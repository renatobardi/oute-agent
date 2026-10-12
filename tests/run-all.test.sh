#!/usr/bin/env bash
# Testes do tests/run-all.sh (#829): roda os testes em paralelo, mede a duração de cada um e dá código 1 se algum
# falha. Os testes são falsos, de uma pasta temporária: dois esperam um pelo outro (só passam se rodam ao mesmo tempo),
# um falha com uma mensagem no log. Bash puro, sem rede. Uso: tests/run-all.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
RUN="$ROOT/tests/run-all.sh"
[[ -x "$RUN" ]] || die "run-all.sh ausente ou sem +x: $RUN"

# barreira <meu> <do outro>: marca o próprio arquivo e espera (até 20 s) o do outro; sai com 1 se não chegar
for nome in a b; do
  if [[ "$nome" == a ]]; then outro=b; else outro=a; fi
  cat > "$TMP/$nome.test.sh" <<SH
#!/usr/bin/env bash
: > "$TMP/$nome.up"
for _ in \$(seq 1 200); do [ -e "$TMP/$outro.up" ] && exit 0; sleep 0.1; done
echo "barreira: o outro teste não chegou"; exit 1
SH
done
cat > "$TMP/c.test.sh" <<'SH'
#!/usr/bin/env bash
echo "falha de propósito do c"; exit 3
SH
# o teste filho não vê a variável do runner (o check-lib confere `OUT` sem definir: #829, auditoria)
cat > "$TMP/d.test.sh" <<'SH'
#!/usr/bin/env bash
echo "variavel OUT no filho: ${OUT-vazio}"; exit 1
SH

# 1. dois testes que só passam juntos, mais um que falha: código 1, os dois ok, o c FALHOU, o log do c na saída
OUT="$(OUTE_TEST_JOBS=2 bash "$RUN" "$TMP/a.test.sh" "$TMP/b.test.sh" "$TMP/c.test.sh" 2>&1)"; RC=$?
check "paralelo: código 1 porque um teste falhou"            [ "$RC" -eq 1 ]
check "paralelo: a e b passam (rodaram ao mesmo tempo)"      bash -c 'grep -qE "^ok +[0-9.]+s +.*a\.test\.sh$" <<<"$1" && grep -qE "^ok +[0-9.]+s +.*b\.test\.sh$" <<<"$1"' _ "$OUT"
check "paralelo: c aparece como FALHOU"                      grep -qE "^FALHOU +[0-9.]+s +.*c\.test\.sh$" <<<"$OUT"
check "paralelo: o log do c vai para a saída"                grep -qF "falha de propósito do c" <<<"$OUT"
check "paralelo: o resumo conta 3 testes e 1 falha"          grep -qF -- "--- 3 testes, 1 falharam" <<<"$OUT"
check "paralelo: a duração sai com uma casa decimal"         grep -qE "^ok +[0-9]+\.[0-9]s " <<<"$OUT"
OUT="$(OUTE_TEST_JOBS=1 bash "$RUN" "$TMP/d.test.sh" 2>&1)"; RC=$?
check "filho sem OUT: o teste vê a variável vazia, não a do runner" grep -qF "variavel OUT no filho: vazio" <<<"$OUT"
check "paralelo: os 5 mais lentos aparecem"                  grep -qF -- "--- 5 mais lentos:" <<<"$OUT"

# 2. só testes que passam: código 0 e nenhum FALHOU
rm -f "${TMP:?}/a.up" "${TMP:?}/b.up"
OUT="$(OUTE_TEST_JOBS=2 bash "$RUN" "$TMP/a.test.sh" "$TMP/b.test.sh" 2>&1)"; RC=$?
check "só passam: código 0"                                  [ "$RC" -eq 0 ]
check "só passam: nenhum FALHOU"                             bash -c '! grep -qF FALHOU <<<"$1"' _ "$OUT"

# 3. sem teste para rodar: código 2 e aviso
OUT="$(bash "$RUN" "$TMP/nao-existe.test.sh" 2>&1)"; RC=$?
check "sem teste: código 2"                                  [ "$RC" -eq 2 ]
check "sem teste: o aviso diz que não há teste"              grep -qF "nenhum teste para rodar" <<<"$OUT"

check_end
