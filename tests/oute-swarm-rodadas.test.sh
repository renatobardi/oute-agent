#!/usr/bin/env bash
# Testes do oute-swarm, tema: rodadas que não colidem e ganham nome amigável (#605): id técnico único (mkdir sem -p, sufixo curto),
# nome `Adjetivo_Substantivo` sorteado entre os que nenhuma rodada aberta usa, o nome onde o Bardi olha (aba, log, aviso, prompt,
# list, evento), spawn recusado para issue com sessão aberta em outra rodada do repo e as outras rodadas à vista na abertura.
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh). Os temas ficam em arquivos
# separados (tests/oute-swarm-<tema>.test.sh, #425) para dois PRs com casos em temas diferentes não editarem o mesmo trecho.
# Uso: tests/oute-swarm-rodadas.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"
trap 'rcv_stop; rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/swarm-otlp.sh"

NAMES="$ROOT/docker/agent-studio/agent_studio/names.py"
NAME_RE='^[A-Z][a-z]+_[A-Z][a-z]+$'
# date falso: o minuto da abertura fica fixo (1005-1200), o resto passa para o date de verdade; é o que põe duas aberturas no mesmo minuto
cat > "$BIN/date" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%m%d-%H%M" && -z "${FAKE_DATE_REAL:-}" ]]; then echo 1005-1200; else exec /bin/date "$@"; fi
SH
chmod +x "$BIN/date"

# open_in <repo> [args…]: abre o dispatcher no repo, com o HOME do caso e as listas de nomes do repo; stdout em $OUT, stderr em $ERR
open_in() {
  local repo="$1"; shift
  OUT="$(env -u OUTE_SWARM_ID -u OUTE_SWARM_REPO -u OUTE_SWARM_MAX PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" \
         OUTE_NAMES_PY="${NAMES_FILE:-$NAMES}" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 HERDR_PANE_ID=w1:p0 HERDR_TAB_ID=w1:t0 \
         "$SWARM" "$repo" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
  return 0
}
meta_of() {
  local rid="$1" key="$2"
  sed -n "s/^$key=//p" "$H/.oute/swarm/$rid/meta" | head -1
  return 0
}
# as rodadas de teste abertas, da mais antiga para a mais nova (a última é a aberta por último)
ids() {
  ls -tr "$H/.oute/swarm" | grep -v '^swarm-test$'
  return 0
}

# ---------------------------------------------------------------- id único
# 1. duas aberturas no mesmo minuto, no mesmo repo, ao mesmo tempo: dois ids, duas pastas com meta
CASE=id-mesmo-repo; round "$CASE"
for i in 1 2 3; do
  ( env -u OUTE_SWARM_ID PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" OUTE_NAMES_PY="$NAMES" HERDR_ENV=1 \
      HERDR_WORKSPACE_ID=w1 HERDR_PANE_ID=w1:p0 "$SWARM" "$REPO" --max 2 >/dev/null 2>&1 ) &
done
wait
check "id: três aberturas no mesmo minuto dão três pastas"          [ "$(ids | wc -l)" -eq 3 ]
check "id: ids todos diferentes"                                    [ "$(ids | sort -u | wc -l)" -eq 3 ]
check "id: o primeiro é o do minuto, sem sufixo"                    [ -d "$H/.oute/swarm/swarm-1005-1200" ]
check "id: os outros levam sufixo curto (3 hex)"                    [ "$(ids | grep -cE '^swarm-1005-1200-[0-9a-f]{3}$')" -eq 2 ]
check "id: cada rodada tem o seu meta, com o repo e o nome"         bash -c 'for d in "$1"/swarm-1005-1200*; do grep -qx "repo=$2" "$d/meta" && grep -qE "^name=[A-Z][a-z]+_[A-Z][a-z]+$" "$d/meta" || exit 1; done' _ "$H/.oute/swarm" "$REPO"
check "id: cada rodada tem a sua abertura no log (uma linha)"       bash -c 'for d in "$1"/swarm-1005-1200*; do [ "$(grep -c " abertura " "$d/log")" -eq 1 ] || exit 1; done' _ "$H/.oute/swarm"

check "id: nenhum arquivo solto na pasta de estado (o oute-emit leria como rodada)" bash -c '[ -z "$(find "$1" -maxdepth 1 -type f)" ]' _ "$H/.oute/swarm"

# 2. repos diferentes, mesmo minuto: duas rodadas separadas, cada uma com o seu repo
CASE=id-outro-repo; round "$CASE"; OTHER="$TMP/$CASE/outro"; gitrepo "$OTHER"
open_in "$REPO" --max 2; first="$(ids | tail -1)"
open_in "$OTHER" --max 2; second="$(ids | tail -1)"
check "id: repos diferentes no mesmo minuto, dois ids"              [ -n "$first" -a -n "$second" -a "$first" != "$second" ]
check "id: cada uma com o repo dela"                                [ "$(meta_of "$first" repo)" == "$REPO" -a "$(meta_of "$second" repo)" == "$OTHER" ]
check "id: o prompt de cada dispatcher cita o id dele"              grep -qF "da rodada \`$second\`" "$FAKE/oute-task.all"

# 3. reserva atômica: pasta que já existe não é reaproveitada nem recriada (o conteúdo dela fica)
CASE=id-reserva; round "$CASE"
mkdir -p "$H/.oute/swarm/swarm-1005-1200"; echo "intacta" > "$H/.oute/swarm/swarm-1005-1200/marca"
open_in "$REPO" --max 2
check "reserva: abre, com outro id"                                 [ "$RC" -eq 0 -a "$(ids | wc -l)" -eq 2 ]
check "reserva: a pasta que já existia segue como estava"           [ "$(cat "$H/.oute/swarm/swarm-1005-1200/marca")" == intacta -a ! -e "$H/.oute/swarm/swarm-1005-1200/meta" ]
check "reserva: o dispatcher abre com o id novo (com sufixo), não com o da pasta tomada" bash -c '[ "$1" == "$2" ] && [[ "$2" =~ ^swarm-1005-1200-[0-9a-f]{3}$ ]]' _ "$(sed -n 5p "$FAKE/oute-task.args")" "$(ids | tail -1)"

# 4. sem como reservar (pasta de estado sem escrita): recusa com mensagem, sem abrir nada
CASE=id-sem-vaga; round "$CASE"
if [ "$(id -u)" -ne 0 ]; then
  chmod a-w "$H/.oute/swarm"
  open_in "$REPO" --max 2
  chmod u+w "$H/.oute/swarm"
  check "sem vaga: código diferente de 0"                           [ "$RC" -ne 0 ]
  check "sem vaga: mensagem diz que não reservou o id"              grep -q 'não consegui reservar o id da rodada' <<<"$ERR"
  check "sem vaga: o dispatcher não abriu"                          [ ! -e "$FAKE/oute-task.last" ]
fi

# 5. coord_round reconhece a worktree da rodada com sufixo (pasta <repo>-swarm-<MMDD>-<HHMM>-<hex>)
CASE=id-worktree; round "$CASE"; SUF=swarm-1005-1200-a3f
mkdir -p "$H/.oute/swarm/$SUF"; cp "$STATE/meta" "$H/.oute/swarm/$SUF/meta"; touch "$H/.oute/swarm/$SUF/spawned"
WT="$TMP/$CASE/repo-$SUF"; gitrepo "$WT"
swc "$WT" spawn 8-bar "instrução" --kaizen
check "worktree com sufixo: assume a rodada pela pasta"             bash -c '[ "$1" -eq 0 ] && grep -qF "assumindo a rodada $2" <<<"$3"' _ "$RC" "$SUF" "$ERR"
check "worktree com sufixo: a sessão entra no spawned dela"         [ -n "$(awk '$1=="8-bar"' "$H/.oute/swarm/$SUF/spawned")" ]
WT2="$TMP/$CASE/repo-sessao"; coord "$WT2" "sessao/$SUF"
swc "$WT2" spawn 9-baz "instrução" --kaizen
check "branch com sufixo: assume a rodada pelo branch"              bash -c '[ "$1" -eq 0 ] && grep -qF "assumindo a rodada $2" <<<"$3"' _ "$RC" "$SUF" "$ERR"

# ---------------------------------------------------------------- nome amigável
# 6. abertura com as listas do agent-studio: o nome vai ao meta, à aba, ao log, ao aviso e ao prompt
CASE=nome; round "$CASE"; rcv_start "$TMP/$CASE/rcv"
FAKE_SPACE=Frente-A open_in "$REPO" --max 2
nr="$(ids | tail -1)"; nm="$(meta_of "$nr" name)"
check "nome: código 0, id e nome gravados"                          bash -c '[ "$1" -eq 0 ] && [ -n "$2" ] && [[ "$3" =~ $4 ]]' _ "$RC" "$nr" "$nm" "$NAME_RE"
check "nome: as palavras são das listas do names.py (uma fonte só)" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("names", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a, _, n = sys.argv[2].partition("_")
sys.exit(0 if a in m.ADJECTIVES and n in m.NOUNS else 1)' "$NAMES" "$nm"
check "nome: o space do herdr vai ao meta"                          [ "$(meta_of "$nr" space)" == Frente-A ]
check "nome: aviso da abertura com nome e id"                       grep -qxF "dispatcher $nm ($nr) · repo repo · max 2" <<<"$ERR"
check "nome: linha de abertura do log com nome e id"                grep -qF " abertura $nr · $nm (repo repo, max 2)" "$H/.oute/swarm/$nr/log"
check "nome: rótulo da aba do dispatcher com nome e id"             grep -qxF "w1:t0 $nm · $nr" "$FAKE/tab-rename.log"
check "nome: o prompt traz o nome junto do id"                      grep -qF "da rodada \`$nr\` (nome amigável **$nm**" "$FAKE/oute-task.all"
check "nome: o id segue sendo a chave (OUTE_SWARM_ID e worktree)"   [ "$(sed -n 5p "$FAKE/oute-task.args")" == "$nr" ]
check "nome: sem marcador de prompt solto"                          bash -c '! grep -qE "[{][{](NOME|OUTRAS|NOME_TEXTO)[}][}]" "$1"' _ "$FAKE/oute-task.all"
check "nome: evento oute.swarm.round.opened leva o nome"            [ "$(ev '.name == "oute.swarm.round.opened"' | jq -c --arg r "$nr" --arg n "$nm" 'select(.attrs["oute.swarm.round"] == $r and .attrs["oute.swarm.round.name"] == $n)' | grep -c .)" -eq 1 ]
rcv_stop

# 7. o nome não repete o de rodada aberta (a fechada libera o dela): o sorteio recebe só os nomes das abertas
CASE=nome-unico; round "$CASE"
FAKE_NAMES="$TMP/$CASE/names-fake.py"
cat > "$FAKE_NAMES" <<'PY'
import sys
open(sys.argv[0] + ".args", "a").write(" ".join(sys.argv[2:]) + "\n")
print("Sorteado_Agora")
PY
for r in aberta-a:Brave_Otter aberta-b:Calm_Fox fechada-c:Wild_Wolf; do
  d="$H/.oute/swarm/swarm-0101-${r%%:*}"; mkdir -p "$d"; printf 'repo=%s\nname=%s\n' "$REPO" "${r##*:}" > "$d/meta"
done
date -u +%FT%TZ > "$H/.oute/swarm/swarm-0101-fechada-c/fechada"
mkdir -p "$H/.oute/swarm/ciclo-x/etapas"; mkdir -p "$H/.oute/swarm/avulso"; touch "$H/.oute/swarm/avulso/spawned"
NAMES_FILE="$FAKE_NAMES" open_in "$REPO" --max 2
nr="$(ids | tail -1)"
check "único: o sorteio vê só os nomes das rodadas abertas"         [ "$(tr ' ' '\n' < "$FAKE_NAMES.args" | sort | tr '\n' ' ')" == "Brave_Otter Calm_Fox " ]
check "único: o nome sorteado vai ao meta"                          [ "$(meta_of "$nr" name)" == Sorteado_Agora ]

# 7b. o sorteio de verdade: sem sobrar nenhum, sai 1 sem nome; com o resto da lista, devolve o único livre
check "names.py draw: devolve um nome no formato"                   bash -c '[[ "$(python3 "$1" draw)" =~ $2 ]]' _ "$NAMES" "$NAME_RE"
check "names.py draw: nunca devolve um nome já usado (só um livre)" python3 - "$NAMES" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("names", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
all_names = [f"{a}_{n}" for a in m.ADJECTIVES for n in m.NOUNS]
free = all_names[1234]
assert m.draw([x for x in all_names if x != free]) == free
assert m.draw(all_names) is None
assert len(set(all_names)) == len(all_names) == 4096
PY
check "names.py draw: sem sobrar nome, sai 1 e não imprime nada"   bash -c 'python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location(\"n\", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(*[f\"{a}_{n}\" for a in m.ADJECTIVES for n in m.NOUNS])" "$1" > "$2"; out="$(python3 "$1" draw $(cat "$2"))"; rc=$?; [ "$rc" -eq 1 ] && [ -z "$out" ]' _ "$NAMES" "$TMP/todos.txt"

# 8. sem as listas (ou sorteio que falha): a rodada abre só com o id, com aviso; rodada antiga sem nome continua valendo
CASE=sem-nome; round "$CASE"
NAMES_FILE="$TMP/nao-existe.py" open_in "$REPO" --max 2
nr="$(ids | tail -1)"
check "sem listas: abre, com aviso e só o id"                       bash -c '[ "$1" -eq 0 ] && [ -n "$2" ] && grep -qF "abre só com o id" <<<"$3"' _ "$RC" "$nr" "$ERR"
check "sem listas: meta sem name="                                  bash -c '! grep -q "^name=" "$1"' _ "$H/.oute/swarm/$nr/meta"
check "sem listas: aviso e log só com o id"                         bash -c 'grep -qxF "dispatcher $1 · repo repo · max 2" <<<"$2" && grep -qF " abertura $1 (repo repo, max 2)" "$3"' _ "$nr" "$ERR" "$H/.oute/swarm/$nr/log"
check "sem listas: sem rótulo de nome na aba"                       grep -qxF "w1:t0 $nr" "$FAKE/tab-rename.log"
BAD="$TMP/$CASE/names-ruim.py"; printf 'print("nome ruim")\n' > "$BAD"
NAMES_FILE="$BAD" open_in "$REPO" --max 2
nr2="$(ids | tail -1)"
check "sorteio com saída fora do formato: abre só com o id, com aviso" bash -c '[ "$1" -eq 0 ] && grep -qF "não consegui sortear o nome" <<<"$2" && ! grep -q "^name=" "$3"' _ "$RC" "$ERR" "$H/.oute/swarm/$nr2/meta"
sw spawn 8-bar "instrução"
check "rodada antiga sem nome: spawn funciona"                      [ "$RC" -eq 0 ]
sw list
check "rodada antiga sem nome: list mostra só o id"                 grep -qxF "== swarm-test" <<<"$OUT"

# ---------------------------------------------------------------- spawn: a mesma issue não abre em duas rodadas
# 9. issue com sessão aberta em outra rodada do mesmo repo é recusada (código 4), com nome e id da outra
CASE=spawn-busy; round "$CASE"
printf 'name=Brave_Otter\n' >> "$STATE/meta"          # a rodada de teste (swarm-test, com a #7 aberta) ganha um nome
B="$H/.oute/swarm/swarm-b"; mkdir -p "$B"; printf 'repo=%s\nmax=3\nstarted=2026-01-01T00:00:00Z\nname=Calm_Fox\n' "$REPO" > "$B/meta"
swb() {
  OUT="$(env PATH="$BIN:$PATH" HOME="$H" FAKE="$FAKE" OUTE_LIB="$ROOT/docker" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 OUTE_SWARM_ID=swarm-b \
         OUTE_SWARM_REPO="$REPO" OUTE_SWARM_MAX=5 "$SWARM" "$@" 2>"$FAKE/err")"; RC=$?; ERR="$(cat "$FAKE/err")"
  return 0
}
swb spawn 7-bar "instrução"
check "busy: recusa com código 4"                                   [ "$RC" -eq 4 ]
check "busy: mensagem com o nome e o id da outra rodada"            grep -qF '#7 já tem sessão aberta na rodada Brave_Otter (swarm-test): 7-foo (código 4)' <<<"$ERR"
check "busy: diz como liberar (fechar na outra rodada)"             grep -qF 'OUTE_SWARM_ID=swarm-test oute-swarm close 7-foo' <<<"$ERR"
check "busy: nada aberto (sem aba, sem linha no spawned, sem log)"  bash -c '[ ! -s "$1/spawned" ] && ! grep -q "tab create" "$2" 2>/dev/null && [ ! -e "$1/log" ]' _ "$B" "$FAKE/herdr.log"
swb spawn 8-baz "instrução"
check "busy: outra issue abre normalmente"                          bash -c '[ "$1" -eq 0 ] && [ -n "$(awk "\$1==\"8-baz\"" "$2")" ]' _ "$RC" "$B/spawned"
swb spawn 7-bar "instrução" --kaizen
check "busy: sessão kaizen da mesma issue não é bloqueada"          [ "$RC" -eq 0 ]
# a sessão kaizen de outra rodada também não bloqueia a abertura da issue dela
C="$H/.oute/swarm/swarm-c"; mkdir -p "$C"; printf 'repo=%s\nmax=3\nname=Wild_Wolf\n' "$REPO" > "$C/meta"
printf '12-kz w1:p9 claude 2026-01-01T00:00:01Z w1:t9 %s kaizen\n' "$REPO" > "$C/spawned"
swb spawn 12-novo "instrução"
check "busy: kaizen aberta em outra rodada não bloqueia a issue"    [ "$RC" -eq 0 ]
# sessão aberta em outro repo não bloqueia
D2="$H/.oute/swarm/swarm-d"; mkdir -p "$D2"; printf 'repo=%s\nmax=3\nname=Wise_Owl\n' "$TMP/$CASE/outro-repo" > "$D2/meta"
printf '15-x w1:p8 claude 2026-01-01T00:00:01Z w1:t8 %s -\n' "$TMP/$CASE/outro-repo" > "$D2/spawned"
swb spawn 15-y "instrução"
check "busy: a mesma issue em OUTRO repo abre"                      [ "$RC" -eq 0 ]
# a mesma rodada: a regra de antes (já aberta nesta rodada), não a nova
swb spawn 8-baz "instrução"
check "mesma rodada: segue a mensagem de antes, sem código 4"       bash -c '[ "$1" -eq 1 ] && grep -qF "8-baz já foi aberta nesta rodada" <<<"$2"' _ "$RC" "$ERR"
# sessão fechada na outra rodada não bloqueia (a issue pode ser reaberta)
echo 7-foo > "$STATE/closed"
swb spawn 7-baz "instrução"
check "busy: sessão anterior fechada não bloqueia"                  bash -c '[ "$1" -eq 0 ] && [ -n "$(awk "\$1==\"7-baz\"" "$2")" ]' _ "$RC" "$B/spawned"
# rodada antiga (sem nome): a mensagem diz só o id
printf '20-velha w1:p7 claude 2026-01-01T00:00:01Z w1:t7\n' > "$H/.oute/swarm/swarm-old-spawned.tmp"; mkdir -p "$H/.oute/swarm/swarm-old"
mv "$H/.oute/swarm/swarm-old-spawned.tmp" "$H/.oute/swarm/swarm-old/spawned"; printf 'repo=%s\nmax=3\n' "$REPO" > "$H/.oute/swarm/swarm-old/meta"
swb spawn 20-nova "instrução"
check "busy: rodada antiga sem nome, a mensagem traz só o id"       bash -c '[ "$1" -eq 4 ] && grep -qF "na rodada swarm-old: 20-velha (código 4)" <<<"$2"' _ "$RC" "$ERR"
check "busy: linha antiga do spawned (sem repo) vale o repo da rodada" [ "$RC" -eq 4 ]

# 10. oute-swarm busy: as issues em andamento em outras rodadas do repo, para a triagem
swb busy
check "busy cmd: lista só as abertas de outras rodadas, do repo"    bash -c '[ "$1" -eq 0 ] && [ "$(sort <<<"$2" | tr "\n" ";")" == "20 - swarm-old 20-velha;" ]' _ "$RC" "$OUT"
echo 20-velha > "$H/.oute/swarm/swarm-old/closed"; : > "$STATE/closed"
swb busy
check "busy cmd: a #7 de swarm-test volta a aparecer com o nome"    grep -qxF '7 Brave_Otter swarm-test 7-foo' <<<"$OUT"
check "busy cmd: não lista sessão da própria rodada, nem kaizen"    bash -c '! grep -qE "swarm-b|swarm-c|12-kz" <<<"$1"' _ "$OUT"
check "busy cmd: a sessão de outro repo não aparece"                bash -c '! grep -q "^15 " <<<"$1"' _ "$OUT"
swb busy --repo "$TMP/$CASE/nao-existe"
check "busy cmd: --repo que não existe recusa"                      bash -c '[ "$1" -eq 1 ] && grep -q "repo não encontrado" <<<"$2"' _ "$RC" "$ERR"
swb busy --foo
check "busy cmd: opção desconhecida recusa"                         bash -c '[ "$1" -eq 1 ] && grep -q "opção desconhecida: --foo" <<<"$2"' _ "$RC" "$ERR"

# ---------------------------------------------------------------- abertura: as outras rodadas à vista; list com nome
# 11. a abertura mostra as outras rodadas abertas do mesmo repo: nome, id, space e issues com sessão aberta
CASE=abertura-outras; round "$CASE"
printf 'name=Brave_Otter\nspace=Frente-A\n' >> "$STATE/meta"
E="$H/.oute/swarm/swarm-e"; mkdir -p "$E"; printf 'repo=%s\nname=Calm_Fox\n' "$TMP/$CASE/outro" > "$E/meta"     # outro repo: não aparece
F="$H/.oute/swarm/swarm-f"; mkdir -p "$F"; printf 'repo=%s\nname=Wild_Wolf\n' "$REPO" > "$F/meta"; date -u +%FT%TZ > "$F/fechada"   # fechada: não aparece
open_in "$REPO" --max 2
nr="$(ids | grep -vE '^swarm-[ef]$' | tail -1)"
check "outras: o aviso da abertura lista a rodada aberta do repo"   grep -qxF '  Brave_Otter (swarm-test) · space Frente-A · issues com sessão aberta: #7' <<<"$ERR"
check "outras: cabeçalho da lista"                                  grep -qxF 'outras rodadas abertas no repo repo:' <<<"$ERR"
check "outras: rodada de outro repo e rodada fechada não entram"    bash -c '! grep -qE "Calm_Fox|Wild_Wolf" <<<"$1"' _ "$ERR"
check "outras: o prompt do dispatcher traz a mesma linha"           grep -qF 'Brave_Otter (swarm-test) · space Frente-A · issues com sessão aberta: #7' "$FAKE/oute-task.all"
check "outras: a própria rodada não se lista"                       bash -c '! grep -qF "($1) · space" "$2"' _ "$nr" "$FAKE/err"
CASE=abertura-sozinha; round "$CASE"; rm -rf "${H:?}/.oute/swarm/swarm-test"
open_in "$REPO" --max 2
check "outras: sem outra rodada aberta, nada de lista e prompt diz nenhuma" bash -c '! grep -q "outras rodadas abertas" <<<"$1" && grep -qF "issues com sessão aberta): nenhuma" "$2"' _ "$ERR" "$FAKE/oute-task.all"

# 12. list mostra o nome junto do id; a triagem (swarm.md) manda usar o busy e não oferecer essas issues
CASE=list-nome; round "$CASE"; printf 'name=Brave_Otter\n' >> "$STATE/meta"
sw list
check "list: rodada com nome aparece como Nome (id)"                grep -qxF '== Brave_Otter (swarm-test)' <<<"$OUT"
check "list: as sessões seguem sob o cabeçalho"                     grep -qF '7-foo w1:p1 claude' <<<"$OUT"
check "triagem: o prompt usa oute-swarm busy e não oferece a issue" bash -c 'grep -qF "oute-swarm busy" "$1" && grep -qF "Issue com sessão aberta em outra rodada não é oferecida" "$1" && grep -qF "em andamento na rodada <nome> (<id>)" "$1"' _ "$SWARM_MD_ALL"

check_end
