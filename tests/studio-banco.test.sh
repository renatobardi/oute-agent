#!/usr/bin/env bash
# Testes do padrão de leitura do banco do agent-studio, docs/studio-banco.md (#829): o doc traz o venv da imagem, a
# janela por time_unix_nano, a leitura só (read_only=True) e o comando pronto, e o AGENTS.md aponta para ele. O comando
# pronto roda de verdade num DuckDB de teste (com o venv da imagem, se houver, senão com o python3 que tenha duckdb);
# sem duckdb em lugar nenhum, esse caso fica de fora e o teste diz isso.
# Uso: tests/studio-banco.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
DOC="$ROOT/docs/studio-banco.md"
[[ -r "$DOC" ]] || die "doc ausente: $DOC"

check "doc: traz o python do venv da imagem"            grep -qF '/opt/agent-studio/venv/bin/python' "$DOC"
check "doc: filtra pela hora do fato (time_unix_nano)"  grep -qF 'time_unix_nano >= ?' "$DOC"
check "doc: a consulta abre o DuckDB só para leitura"   grep -qF 'read_only=True' "$DOC"
check "doc: a janela vem de datas UTC em nanossegundos (inteiro)" grep -qF 'timestamp()) * 10**9' "$DOC"
check "AGENTS.md aponta para o doc"                      grep -qF 'docs/studio-banco.md' "$ROOT/AGENTS.md"

# comando pronto: o bloco entre `docker exec … <<'PY'` e `PY`, com o caminho do DuckDB trocado pelo de teste
awk '/<<.PY.$/ {g = 1; next} g && /^PY$/ {exit} g' "$DOC" > "$TMP/consulta.py"
check "comando pronto: o bloco do python existe"        test -s "$TMP/consulta.py"
PY=""
for cand in /opt/agent-studio/venv/bin/python python3; do
  command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import duckdb' 2>/dev/null && { PY="$cand"; break; }
done
if [[ -z "$PY" ]]; then
  echo "# sem duckdb em nenhum python: a consulta não roda aqui (só o texto foi conferido)"
else
  "$PY" - "$TMP/db.duckdb" <<'EOP' 2>/dev/null || { echo "# não consegui montar o DuckDB de teste"; }
import sys, duckdb
con = duckdb.connect(sys.argv[1])
con.execute("CREATE TABLE logs (dedupe_key VARCHAR PRIMARY KEY, time TIMESTAMPTZ, time_unix_nano UBIGINT, host_name VARCHAR)")
# o 3º registro cai no dia 11 em horário local (-03:00) mas no dia 12 em UTC: a janela em UTC não o pode contar
from datetime import datetime
rows = [("a", "2026-10-11T12:00:00Z", "oute-server"),
        ("b", "2026-10-11T13:00:00Z", "mac"),
        ("c", "2026-10-11T23:30:00-03:00", "mac"),
        ("d", "2026-10-12T00:00:00Z", "oute-server")]
for k, t, h in rows:
    ns = int(datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()) * 10**9
    con.execute("INSERT INTO logs VALUES (?, ?, ?, ?)", [k, t, ns, h])
con.close()
EOP
  sed "s|/data/agent-studio/agent-studio.duckdb|$TMP/db.duckdb|" "$TMP/consulta.py" > "$TMP/consulta-teste.py"
  OUT="$("$PY" "$TMP/consulta-teste.py" 2>&1)"; RC=$?
  check "consulta: roda com código 0"                    [ "$RC" -eq 0 ]
  check "consulta: conta só o dia 11 em UTC, por host"   [ "$(printf '%s\n' "$OUT" | tr '\n' ' ')" = "mac	1 oute-server	1 " ]
fi
check_end
