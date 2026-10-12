#!/usr/bin/env bash
# Testes do `oute approve suggest` (#726): a lista de comandos repetidos do histórico do canal, no host. Bash puro,
# sem Docker: o `docker` do PATH é falso e só registra a chamada em $F_DOCKER (o suggest não pode chamá-lo). O
# histórico é montado à mão em $OUTE_HOME/approve: approve.log (uma linha por decisão, como o approve_one grava) e
# runs/<id>.sh (o script como o oute-propose o escreve). Datas fixas no log: o teste não lê o relógio.
# Uso: tests/oute-approve-suggest.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail
# credenciais reais nunca chegam ao scripts/oute daqui (docker é falso, mas o script lê o ambiente)
for v in $(compgen -e | grep -E '^(OCI_|GH_TOKEN$|GITHUB_TOKEN$|AGENT_STUDIO_|BW_)' || true); do unset "$v"; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTE="$ROOT/scripts/oute"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=40   # o bad mostra o fim da saída

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$F_DOCKER"
exit 9
SH
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH" OUTE_HOST=teste OUTE_INSTANCE=teste F_DOCKER="$TMP/docker.calls" F_RAN="$TMP/ran"
AP="$TMP/host/.oute/approve"

reset() {
  rm -rf "$TMP/host" "$F_DOCKER" "$F_RAN"; mkdir -p "$AP/runs"
  return 0
}
# pedido no histórico: $1=id $2=como (user|root) $3=decisão (exec|recusado) $4=data do log; stdin=corpo do script
hist() {
  local id="$1" as="$2" dec="$3" ts="$4" rc="rc=0"
  { printf '# oute-propose\n# titulo: teste %s\n# como: %s\n# agente: claude\n\nset -euo pipefail\n' "$id" "$as"; cat; } > "$AP/runs/$id.sh"
  [[ "$dec" == exec ]] || rc="-"
  printf '%s\tteste\t%s\tabcdef012345\t%s\t%s\tteste %s\n' "$ts" "$id" "$dec" "$rc" "$id" >> "$AP/approve.log"
  return 0
}
run_suggest() {
  OUT="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve suggest "$@" 2>&1)"; RC=$?
  return 0
}
# linha da tabela, campo a campo: $1=pedidos $2=recusas $3=último uso $4=risco $5=comando (texto exato até o fim)
row() {
  local n="$1" rej="$2" last="$3" risk="$4" cmd="$5"
  awk -v n="$n" -v rej="$rej" -v last="$last" -v risk="$risk" -v cmd="$cmd" '
    { line = $0; sub(/^ +/, "", line)
      want = n " +" rej " +" last " +" risk " +"
      if (match(line, "^" want) && substr(line, RLENGTH + 1) == cmd) found = 1 }
    END { exit !found }' <<<"$OUT"
  return $?
}
state() { (cd "$TMP/host" && find . -type f -exec cksum {} + | LC_ALL=C sort); return 0; }

# --- 1. agrupa por comando normalizado, conta, mostra o último uso e o risco
reset
hist 20261001-100000-nginx-a root exec 2026-10-01T10:00:05Z <<'SH'
echo "1/2: confere"
nginx   -t
systemctl reload nginx
SH
hist 20261003-110000-nginx-b root exec 2026-10-03T11:00:07Z <<'SH'
echo "1/1: confere de novo"
nginx -t
SH
hist 20261002-090000-logs-a user exec 2026-10-02T09:00:01Z <<'SH'
docker logs --tail 50 oute-agent
cat ~/.oute/approve/runs/20260930-010101-restart-proprio-agent.out | tail -n 5
touch "$F_RAN"
SH
hist 20261004-090000-logs-b user exec 2026-10-04T09:00:02Z <<'SH'
docker   logs --tail 50   oute-agent
cat ~/.oute/approve/runs/20261001-020202-outro-pedido.out | tail -n 5
touch "$F_RAN"
SH
hist 20261005-090000-logs-c user recusado 2026-10-05T09:00:03Z <<'SH'
docker logs --tail 50 oute-agent
rm -rf ~/algo
SH
before="$(state)"
run_suggest
check "suggest: sai com 0" test "$RC" = 0
check "cabeçalho: 4 executados e 1 recusado, com o caminho do log" has_line "oute approve suggest: 4 pedido(s) executado(s) e 1 recusado(s) em $AP/approve.log"
check "root: nginx -t em 2 pedidos (espaço repetido é o mesmo comando), último uso do 2º" row 2 0 2026-10-03T11:00:07Z root "nginx -t"
check "leitura: docker logs em 2 executados e 1 recusado, último uso só dos executados" row 2 1 2026-10-04T09:00:02Z leitura "docker logs --tail 50 oute-agent"
check "normaliza o id de pedido dentro do comando: dois ids, um grupo" row 2 0 2026-10-04T09:00:02Z leitura "cat ~/.oute/approve/runs/{id}.out | tail -n 5"
check "escrita: touch em 2 pedidos" row 2 0 2026-10-04T09:00:02Z escrita 'touch "$F_RAN"'
check "padrão --min 2: comando de 1 pedido só fica fora" hasnt_str "systemctl reload nginx"
check "comando só de pedido recusado fica fora" hasnt_str "rm -rf"
check "echo de passo e set -euo não entram na lista" bash -c '! grep -qE " (echo|set) " <<<"$1"' _ "$(grep -E '^ +[0-9]' <<<"$OUT")"
check "ordem: mais pedidos primeiro; no empate, o uso mais recente" test "$(grep -E '^ +[0-9]' <<<"$OUT" | awk '{print $3}' | head -1)" = 2026-10-04T09:00:02Z
check "diz que nada foi aplicado" has "^nada foi aplicado: a lista é só sugestão"

# --- 2. nada é aplicado: não chama docker, não roda o comando do pedido, não muda arquivo do host
check "não chama docker" test ! -e "$F_DOCKER"
check "não roda comando de pedido (o touch do histórico não rodou)" test ! -e "$F_RAN"
check "não cria nem altera arquivo em \$HOME do host" test "$before" = "$(state)"

# --- 3. --min
run_suggest --min 1
check "--min 1: comando de 1 pedido aparece, como root" row 1 0 2026-10-01T10:00:05Z root "systemctl reload nginx"
run_suggest --min=3
check "--min=3: nenhum comando chega a 3" has_line "nenhum comando aparece em 3 pedido(s) executado(s) ou mais (--min 3)."
check "--min=3: sai com 0 e ainda diz que nada foi aplicado" bash -c '[[ "$1" = 0 ]] && grep -q "^nada foi aplicado" <<<"$2"' _ "$RC" "$OUT"

# --- 4. classificação de risco, linha a linha (cada comando em 1 pedido; --min 1)
reset
hist 20261001-100000-risco-user user exec 2026-10-01T10:00:00Z <<'SH'
grep -E 'a|b' /etc/hosts | wc -l
df -h > /tmp/df.txt
ls /tmp 2>/dev/null || true
sudo nft list ruleset
x="$(cat /etc/hostname)"
docker compose ps
docker compose up -d
ferramenta-desconhecida --ver
sed -i 's/a/b/' arquivo
find /var/log -name '*.gz' -delete
find /var/log -name '*.gz'
git -C /srv/repo status
git -C /srv/repo pull --ff-only
cat arquivo | sudo tee /etc/x
sha256sum /opt/pkg-0123456789abcdef0123.tar
cat <<'TXT' | wc -l
rm -rf /dentro-do-heredoc
TXT
if systemctl is-active nginx; then
  uptime
fi
journalctl -u nginx \
  --since today
SH
run_suggest --min 1
T=2026-10-01T10:00:00Z
check "leitura: pipe de leitura, com | dentro de aspas" row 1 0 "$T" leitura "grep -E 'a|b' /etc/hosts | wc -l"
check "escrita: leitura redirecionada para arquivo" row 1 0 "$T" escrita "df -h > /tmp/df.txt"
check "leitura: 2>/dev/null e || true não viram escrita" row 1 0 "$T" leitura "ls /tmp 2>/dev/null || true"
check "root: linha com sudo em pedido sem --root" row 1 0 "$T" root "sudo nft list ruleset"
check "escrita: substituição de comando" row 1 0 "$T" escrita 'x="$(cat /etc/hostname)"'
check "leitura: docker compose ps" row 1 0 "$T" leitura "docker compose ps"
check "escrita: docker compose up" row 1 0 "$T" escrita "docker compose up -d"
check "escrita: comando fora da lista de leitura" row 1 0 "$T" escrita "ferramenta-desconhecida --ver"
check "escrita: sed -i" row 1 0 "$T" escrita "sed -i 's/a/b/' arquivo"
check "escrita: find -delete" row 1 0 "$T" escrita "find /var/log -name '*.gz' -delete"
check "leitura: find sem ação" row 1 0 "$T" leitura "find /var/log -name '*.gz'"
check "leitura: git -C <dir> status" row 1 0 "$T" leitura "git -C /srv/repo status"
check "escrita: git -C <dir> pull" row 1 0 "$T" escrita "git -C /srv/repo pull --ff-only"
check "root: sudo depois do pipe" row 1 0 "$T" root "cat arquivo | sudo tee /etc/x"
check "normaliza hash longo" row 1 0 "$T" leitura "sha256sum /opt/pkg-{hash}.tar"
check "corpo de heredoc não vira comando" hasnt_str "dentro-do-heredoc"
check "leitura: condição de if com comando de leitura" row 1 0 "$T" leitura "if systemctl is-active nginx; then"
check "linha continuada com \\ é um comando só" row 1 0 "$T" leitura "journalctl -u nginx --since today"
check "fi sozinho não entra na lista" bash -c '! grep -qE " fi$" <<<"$1"' _ "$OUT"

# pedido --root: todo comando dele é root, mesmo o de leitura; o mesmo comando sem root fica em outra linha
reset
hist 20261001-100000-como-root root exec 2026-10-01T10:00:00Z <<<'cat /etc/hosts'
hist 20261002-100000-como-user user exec 2026-10-02T10:00:00Z <<<'cat /etc/hosts'
run_suggest --min 1
check "pedido --root: comando de leitura sai como root" row 1 0 2026-10-01T10:00:00Z root "cat /etc/hosts"
check "mesmo comando em pedido sem root: linha própria, leitura" row 1 0 2026-10-02T10:00:00Z leitura "cat /etc/hosts"
# `# como: root` escrito no corpo não muda o pedido: vale o primeiro, do cabeçalho (como no approve_one)
reset
hist 20261001-100000-falso-root user exec 2026-10-01T10:00:00Z <<<$'# como: root\ncat /etc/hosts'
run_suggest --min 1
check "'# como: root' no corpo não vira root" row 1 0 2026-10-01T10:00:00Z leitura "cat /etc/hosts"

# --- 5. ramos de erro e de estado
reset; rmdir "$AP/runs"
run_suggest
check "sem approve.log: avisa e sai com 0" bash -c '[[ "$1" = 0 ]] && grep -qF "sem histórico neste host ($2/approve.log não existe)" <<<"$3"' _ "$RC" "$AP" "$OUT"
check "sem approve.log: não cria a pasta de runs" test ! -e "$AP/runs"

reset
hist 20261001-100000-com-script user exec 2026-10-01T10:00:00Z <<<'uptime'
hist 20261002-100000-sem-script user exec 2026-10-02T10:00:00Z <<<'uptime'
rm -f "$AP/runs/20261002-100000-sem-script.sh"
printf 'linha solta sem tab\n' >> "$AP/approve.log"
printf '2026-10-03T10:00:00Z\tteste\t../../fora\tabc\texec\trc=0\ttitulo\n' >> "$AP/approve.log"
printf '2026-10-03T10:00:00Z\tteste\t20261003-100000-outra-decisao\tabc\tadiado\t-\ttitulo\n' >> "$AP/approve.log"
echo 'uptime' > "$TMP/host/fora.sh"
run_suggest --min 1
check "script que sumiu de runs/: aviso com a contagem" has_line "aviso: 1 pedido(s) sem o script guardado em $AP/runs (ficam fora da contagem)"
check "script que sumiu: o pedido não entra na contagem do comando" row 1 0 2026-10-01T10:00:00Z leitura "uptime"
check "linha do log fora do formato (sem tab, id com ../, decisão desconhecida): 3 ignoradas" has_line "aviso: 3 linha(s) do log fora do formato (ignoradas)"

reset
hist 20261001-100000-controle user exec 2026-10-01T10:00:00Z <<<$'cat /etc/hosts \033[2Kescondido\r'
run_suggest --min 1
check "caractere de controle do script sai neutralizado" bash -c '! grep -q "$(printf "\033")" <<<"$1" && ! grep -q "$(printf "\r")" <<<"$1"' _ "$OUT"
check "o comando com o controle continua na lista" has "cat /etc/hosts ·\[2Kescondido"

reset; : > "$AP/approve.log"
run_suggest
check "log vazio: 0 pedidos, nenhum comando, sai com 0" bash -c '[[ "$1" = 0 ]] && grep -qF "0 pedido(s) executado(s) e 0 recusado(s)" <<<"$2" && grep -q "^nenhum comando aparece" <<<"$2"' _ "$RC" "$OUT"

# --- 6. argumentos: erro de uso = rc 2, sem ler o histórico e sem docker
reset
hist 20261001-100000-uso user exec 2026-10-01T10:00:00Z <<<'uptime'
for args in "--min" "--min 0" "--min abc" "--min=" "--aplicar" "--min 2 sobra"; do
  # shellcheck disable=SC2086
  run_suggest $args
  check "uso: 'suggest $args' sai com 2 e mostra o uso" bash -c '[[ "$1" = 2 ]] && grep -q "^uso: oute approve suggest" <<<"$2" && ! grep -q uptime <<<"$2"' _ "$RC" "$OUT"
done
check "erro de uso também não chama docker" test ! -e "$F_DOCKER"
OUT="$(HOME="$TMP/host" OUTE_HOME="$TMP/host/.oute" "$OUTE" approve --nada 2>&1)"; RC=$?
check "uso do approve cita o suggest" bash -c '[[ "$1" = 2 ]] && grep -qF "suggest [--min N]" <<<"$2"' _ "$RC" "$OUT"
check "ajuda do oute lista o approve suggest" grep -qE '^  approve suggest \[--min N\] +lista os comandos repetidos' "$OUTE"

check_end
