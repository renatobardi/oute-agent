#!/usr/bin/env bash
# Testes do `oute deploy-contract check|parse` (#843, ADR-10): o contrato `.oute/deploy.toml` do repo alvo do modo dark.
# Bash puro, repos git temporários, sem rede. Uso: tests/oute-deploy-contract.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC="$ROOT/scripts/deploy-contract"
OUTE="$ROOT/scripts/oute"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
. "$ROOT/tests/lib/check.sh"
CHECK_OUT=20
G=(git -c user.email=t@t -c user.name=t)

# repo <nome>: repo com contrato válido commitado (três scripts 100755, host)
repo() {
  local d="$TMP/$1"
  rm -rf "${d:?}"; git init -q "$d" -b main; mkdir -p "$d/.oute"
  local s; for s in deploy verify rollback; do printf '#!/usr/bin/env bash\nset -euo pipefail\necho %s\n' "$s" > "$d/.oute/$s.sh"; done
  chmod 755 "$d"/.oute/*.sh
  printf '# contrato\ndeploy = ".oute/deploy.sh"\nverify = ".oute/verify.sh"  # depois\nrollback = ".oute/rollback.sh"\nhost = "oute-server"\n' > "$d/.oute/deploy.toml"
  "${G[@]}" -C "$d" add -A && "${G[@]}" -C "$d" commit -qm contrato
  return 0
}
commit() { local r="$1" m="$2"; "${G[@]}" -C "$TMP/$r" add -A && "${G[@]}" -C "$TMP/$r" commit -qm "$m"; return 0; }
run() { OUT="$("$@" 2>&1)"; RC=$?; return 0; }

repo ok; run "$DC" check "$TMP/ok"
check "contrato válido: sai 0"                          [ "$RC" -eq 0 ]
check "contrato válido: imprime os quatro campos"       grep -qF "contrato ok: deploy=.oute/deploy.sh verify=.oute/verify.sh rollback=.oute/rollback.sh host=oute-server" <<<"$OUT"
run "$OUTE" deploy-contract check "$TMP/ok"
check "oute deploy-contract chama o mesmo check"        [ "$RC" -eq 0 ] 

# três caminhos existem
repo f1; git -C "$TMP/f1" rm -q -f .oute/rollback.sh; commit f1 sem-rollback; run "$DC" check "$TMP/f1"
check "rollback ausente: sai 1 e nomeia a chave"        bash -c '[ "$1" -eq 1 ] && grep -qF "(.oute/rollback.sh) não existe no HEAD" <<<"$2"' _ "$RC" "$OUT"
# modo 100755
repo f2; chmod 644 "$TMP/f2/.oute/deploy.sh"; commit f2 modo; run "$DC" check "$TMP/f2"
check "deploy sem 100755: sai 1"                        [ "$RC" -eq 1 ]
check "deploy sem 100755: diz o modo"                   bash -c 'grep -F "(.oute/deploy.sh)" <<<"$1" | grep -qF "100644 blob"' _ "$OUT"
# symlink no lugar do script: não é 100755 blob
repo f3; rm "${TMP:?}/f3/.oute/verify.sh"; ln -s deploy.sh "$TMP/f3/.oute/verify.sh"; commit f3 link; run "$DC" check "$TMP/f3"
check "verify symlink: sai 1"                           [ "$RC" -eq 1 ]
# host
repo f4; sed -i.bak 's/^host = .*/host = ""/' "$TMP/f4/.oute/deploy.toml"; rm -f "${TMP:?}/f4/.oute/deploy.toml.bak"; commit f4 host; run "$DC" check "$TMP/f4"
check "host vazio: sai 1 e diz o motivo"                bash -c '[ "$1" -eq 1 ] && grep -qF "host" <<<"$2"' _ "$RC" "$OUT"
# caminho que sai do repo
repo f5; sed -i.bak 's#^deploy = .*#deploy = "../fora.sh"#' "$TMP/f5/.oute/deploy.toml"; rm -f "${TMP:?}/f5/.oute/deploy.toml.bak"; commit f5 trav; run "$DC" check "$TMP/f5"
check "caminho com '..': recusa"                        bash -c '[ "$1" -eq 1 ] && grep -qF "caminho relativo seguro" <<<"$2"' _ "$RC" "$OUT"
# contrato só no disco, sem commit
repo f6; "${G[@]}" -C "$TMP/f6" rm -q --cached .oute/deploy.toml; "${G[@]}" -C "$TMP/f6" commit -qm tira; run "$DC" check "$TMP/f6"
check "contrato fora do commit: sai 1"                  bash -c '[ "$1" -eq 1 ] && grep -qF "não existe no HEAD" <<<"$2"' _ "$RC" "$OUT"
# repo que não existe
run "$DC" check "$TMP/nao-existe"
check "repo inexistente: sai 1"                         [ "$RC" -eq 1 ]
run "$DC" check
check "check sem caminho: uso, código 2"                [ "$RC" -eq 2 ]

# segredo: valor que parece token no contrato, sem mostrá-lo
# valores gerados a cada execução (nada literal que pareça credencial no arquivo)
rnd() { local n="$1"; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$n"; return 0; }
TOK="ghp_Aa1$(rnd 30)"
repo s1; printf 'host = "%s"\n' "$TOK" > "$TMP/s1/.oute/deploy.toml.novo"
printf '# contrato\ndeploy = ".oute/deploy.sh"\nverify = ".oute/verify.sh"\nrollback = ".oute/rollback.sh"\nhost = "%s"\n' "$TOK" > "$TMP/s1/.oute/deploy.toml"; rm -f "${TMP:?}/s1/.oute/deploy.toml.novo"
commit s1 token; run "$DC" check "$TMP/s1"
check "token no contrato: sai 1"                        [ "$RC" -eq 1 ]
check "token no contrato: a saída não repete o valor"   bash -c '! grep -qF "$1" <<<"$2" && grep -qF "parece segredo" <<<"$2"' _ "$TOK" "$OUT"
# chave desconhecida (lugar onde um segredo se esconderia)
repo s2; printf 'senha = "x"\n' >> "$TMP/s2/.oute/deploy.toml"; commit s2 chave; run "$DC" check "$TMP/s2"
check "chave desconhecida: recusa"                      bash -c '[ "$1" -eq 1 ] && grep -q "chave .senha. desconhecida" <<<"$2"' _ "$RC" "$OUT"
# segredo no script do contrato
repo s3; printf 'API_TOKEN="%s"\n' "Zq9$(rnd 20)" >> "$TMP/s3/.oute/verify.sh"; commit s3 literal; run "$DC" check "$TMP/s3"
check "literal em variável de token no script: recusa"  bash -c '[ "$1" -eq 1 ] && grep -qF "(.oute/verify.sh) tem linha que parece segredo" <<<"$2"' _ "$RC" "$OUT"
# regra ampliada (ajuste 6 da auditoria): cada forma entra num script do contrato e tem de ser recusada, sem mostrar o valor
HEX="$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 40)"
B64="Aa1$(rnd 12)/$(rnd 12)"
n=0
for linha in "ADMIN_KEY=$HEX" "AUTH=$B64" "DB_PASS=Aa1$(rnd 20)" "CREDENTIALS=$(rnd 24)" 'curl -H "Authorization: Bearer '"$(rnd 30)"'" https://x' \
             'git clone https://usuario:'"$(rnd 20)"'@github.com/o/r.git' "x=sk_live_$(rnd 24)" "x=npm_$(rnd 30)" "x=hf_$(rnd 30)" "x=shpat_$(rnd 30)" "x=SG.$(rnd 22)" "x=\"$B64\""; do
  n=$((n + 1)); r="r$n"; repo "$r"; printf '%s\n' "$linha" >> "$TMP/$r/.oute/rollback.sh"; commit "$r" forma; run "$DC" check "$TMP/$r"
  check "forma de segredo $n: recusa e não mostra o valor" bash -c '[ "$1" -eq 1 ] && grep -qF "(.oute/rollback.sh) tem linha que parece segredo" <<<"$2" && ! grep -qF -- "${3#*[=:]}" <<<"$2"' _ "$RC" "$OUT" "$linha"
done
# o que NÃO é segredo: ler do ambiente, caminho comprido, host comprido
repo s4; printf 'TOKEN="${GH_TOKEN:?}"\nTOKEN_FILE=/run/secrets/agent_env\nssh oute-server-production-eu-1 true\n' >> "$TMP/s4/.oute/deploy.sh"
sed -i.bak 's#^host = .*#host = "oute-server-production-eu-1"#' "$TMP/s4/.oute/deploy.toml"; rm -f "${TMP:?}/s4/.oute/deploy.toml.bak"; commit s4 ambiente; run "$DC" check "$TMP/s4"
check "segredo do ambiente e nome longo de host passam" [ "$RC" -eq 0 ]
repo s5; printf 'IMG="registry.example/app@sha256:%s"\nDEST=/opt/oute/releases/current/bin\necho disk-usage task-runner risk-check\n' "$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64)" >> "$TMP/s5/.oute/deploy.sh"; commit s5 digest; run "$DC" check "$TMP/s5"
check "digest sha256: e caminho comprido passam"         [ "$RC" -eq 0 ]
check "o check diz que conferiu só o HEAD local"         grep -qF "conferi só o HEAD" <<<"$OUT"

# parse: lê da entrada padrão
OUT="$(printf 'deploy = "a.sh"\nverify = "b.sh"\nrollback = "c.sh"\nhost = "h"\n' | "$DC" parse 2>&1)"; RC=$?
check "parse: quatro linhas chave=valor"                bash -c '[ "$1" -eq 0 ] && [ "$(wc -l <<<"$2" | tr -d " ")" -eq 4 ] && grep -qx "rollback=c.sh" <<<"$2"' _ "$RC" "$OUT"
OUT="$(printf 'deploy = "a.sh"\ndeploy = "b.sh"\nverify = "b.sh"\nrollback = "c.sh"\nhost = "h"\n' | "$DC" parse 2>&1)"; RC=$?
check "parse: chave repetida recusa"                    bash -c '[ "$1" -eq 1 ] && grep -qF "repetido" <<<"$2"' _ "$RC" "$OUT"

check_end
