#!/usr/bin/env bash
# testes para derivação e validação de OUTE_NET_IP_RANGE (#230)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/lib/check.sh"

# cria arquivo com as funções para testar
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# extrai as funções do script do host (sed para pegar da abertura "function" ou "nome()" até o "}" que fecha)
sed -n '/^ip_to_int()/,/^}/p' "$ROOT/scripts/oute" > "$T/funcs.sh"
sed -n '/^ip_block_size()/,/^}/p' "$ROOT/scripts/oute" >> "$T/funcs.sh"
sed -n '/^derive_ip_range()/,/^}/p' "$ROOT/scripts/oute" >> "$T/funcs.sh"
sed -n '/^validate_net_ip_range()/,/^}/p' "$ROOT/scripts/oute" >> "$T/funcs.sh"
sed -n '/^validate_agent_ip_not_in_range()/,/^}/p' "$ROOT/scripts/oute" >> "$T/funcs.sh"
sed -n '/^cidrs_overlap()/,/^}/p' "$ROOT/scripts/oute" >> "$T/funcs.sh"
sed -n '/^net_subnet()/,/^}/p' "$ROOT/scripts/oute" >> "$T/funcs.sh"
sed -n '/^ensure_net_subnets()/,/^}/p' "$ROOT/scripts/oute" >> "$T/funcs.sh"
# env_get de mentira (o real lê o .env do checkout no host): net_subnet cai nele quando a variável não está no ambiente
cat >> "$T/funcs.sh" <<'STUB'
ENVF=""
env_get() {
  local k="$1"
  [[ -n "$ENVF" && -f "$ENVF" ]] && sed -n "s/^$k=//p" "$ENVF"
  return 0
}
STUB

# derivação: /16 -> metade alta /17
check "derive_ip_range 172.19.0.0/16 → 172.19.128.0/17" bash -c ". '$T/funcs.sh' && derive_ip_range 172.19.0.0/16 | grep -qx 172.19.128.0/17"
check "derive_ip_range 172.29.0.0/16 → 172.29.128.0/17" bash -c ". '$T/funcs.sh' && derive_ip_range 172.29.0.0/16 | grep -qx 172.29.128.0/17"
check "derive_ip_range 10.0.0.0/16 → 10.0.128.0/17" bash -c ". '$T/funcs.sh' && derive_ip_range 10.0.0.0/16 | grep -qx 10.0.128.0/17"
check "derive_ip_range 192.168.0.0/16 → 192.168.128.0/17" bash -c ". '$T/funcs.sh' && derive_ip_range 192.168.0.0/16 | grep -qx 192.168.128.0/17"

# subnet que não é /16 → erro exigindo OUTE_NET_IP_RANGE explícito
check "derive_ip_range /24 falha com rc != 0" bash -c ". '$T/funcs.sh' && ! derive_ip_range 172.19.0.0/24"
check "derive_ip_range /24 stderr menciona OUTE_NET_IP_RANGE" bash -c ". '$T/funcs.sh' && derive_ip_range 172.19.0.0/24 2>&1 | grep -q OUTE_NET_IP_RANGE" ; true

# validação: range dentro da subnet
check "validate_net_ip_range: 172.19.128.0/17 ok" bash -c ". '$T/funcs.sh' && validate_net_ip_range 172.19.128.0/17 172.19.0.0/16"
check "validate_net_ip_range: 172.29.128.0/17 ok" bash -c ". '$T/funcs.sh' && validate_net_ip_range 172.29.128.0/17 172.29.0.0/16"

# validação: range FORA da subnet → erro
check "validate_net_ip_range: fora falha com rc != 0" bash -c ". '$T/funcs.sh' && ! validate_net_ip_range 172.19.128.0/17 172.29.0.0/16"
check "validate_net_ip_range: fora menciona fora" bash -c ". '$T/funcs.sh' && validate_net_ip_range 172.19.128.0/17 172.29.0.0/16 2>&1 | grep -q fora" ; true
check "validate_net_ip_range: /24 fora de /24 falha" bash -c ". '$T/funcs.sh' && ! validate_net_ip_range 10.0.2.0/24 10.0.1.0/24"
check "validate_net_ip_range: /17 fora de /17 falha" bash -c ". '$T/funcs.sh' && ! validate_net_ip_range 172.29.0.0/17 172.29.128.0/17"
check "validate_net_ip_range: /21 dentro de /20 ok" bash -c ". '$T/funcs.sh' && validate_net_ip_range 172.30.8.0/21 172.30.0.0/20"

# validação: IP fixo DENTRO do range → erro
check "validate_agent_ip_not_in_range: dentro falha com rc != 0" bash -c ". '$T/funcs.sh' && ! validate_agent_ip_not_in_range 172.29.128.0/17 172.29.128.5"
check "validate_agent_ip_not_in_range: dentro menciona dentro" bash -c ". '$T/funcs.sh' && validate_agent_ip_not_in_range 172.29.128.0/17 172.29.128.5 2>&1 | grep -q dentro" ; true
check "validate_agent_ip_not_in_range: /17 baixa dentro falha" bash -c ". '$T/funcs.sh' && ! validate_agent_ip_not_in_range 172.29.0.0/17 172.29.50.5"
check "validate_agent_ip_not_in_range: /18 dentro falha" bash -c ". '$T/funcs.sh' && ! validate_agent_ip_not_in_range 172.30.64.0/18 172.30.100.5"
check "validate_agent_ip_not_in_range: /20 dentro falha" bash -c ". '$T/funcs.sh' && ! validate_agent_ip_not_in_range 10.0.0.0/20 10.0.5.100"

# validação: IP fixo FORA do range → ok
check "validate_agent_ip_not_in_range: fora ok" bash -c ". '$T/funcs.sh' && validate_agent_ip_not_in_range 172.29.128.0/17 172.29.0.5"
check "validate_agent_ip_not_in_range: /24 fora ok" bash -c ". '$T/funcs.sh' && validate_agent_ip_not_in_range 10.0.1.0/24 10.0.2.5"

# cruzamento de subnets (#707)
check "cidrs_overlap: /24 dentro de /16 cruza"              bash -c ". '$T/funcs.sh' && cidrs_overlap 172.16.0.0/24 172.16.0.0/16"
check "cidrs_overlap: /17 dentro de /16 cruza"              bash -c ". '$T/funcs.sh' && cidrs_overlap 172.19.128.0/17 172.19.0.0/16"
check "cidrs_overlap: /8 contém a /24 (lxdbr0)"             bash -c ". '$T/funcs.sh' && cidrs_overlap 10.0.0.0/8 10.173.117.0/24"
check "cidrs_overlap: /32 dentro do CGNAT (tailscale0)"     bash -c ". '$T/funcs.sh' && cidrs_overlap 100.64.0.0/10 100.66.254.24/32"
check "cidrs_overlap: /24 vizinhas não cruzam"              bash -c ". '$T/funcs.sh' && ! cidrs_overlap 172.16.0.0/24 172.16.1.0/24"
check "cidrs_overlap: /24 e o /16 da rede oute não cruzam"  bash -c ". '$T/funcs.sh' && ! cidrs_overlap 172.16.3.0/24 172.19.0.0/16"
check "cidrs_overlap: /16 fora do pool não cruza a oute"    bash -c ". '$T/funcs.sh' && ! cidrs_overlap 172.16.0.0/16 172.19.0.0/16"

# net_subnet (#707): variável exportada > .env > padrão do compose
check "net_subnet: padrão quando nada define"               bash -c ". '$T/funcs.sh' && net_subnet OUTE_NET_SUBNET_LL 172.16.2.0/24 | grep -qx 172.16.2.0/24"
printf 'OUTE_NET_SUBNET_SAIDA=10.90.0.0/24\n' > "$T/envfile"
check "net_subnet: .env ganha do padrão"                    bash -c ". '$T/funcs.sh' && ENVF='$T/envfile' net_subnet OUTE_NET_SUBNET_SAIDA 172.16.3.0/24 | grep -qx 10.90.0.0/24"
check "net_subnet: variável exportada ganha do .env" \
  bash -c ". '$T/funcs.sh' && export OUTE_NET_SUBNET_SAIDA=10.91.0.0/24 && ENVF='$T/envfile' net_subnet OUTE_NET_SUBNET_SAIDA 172.16.3.0/24 | grep -qx 10.91.0.0/24"

# ensure_net_subnets (#707): as quatro redes fixas não cruzam a oute nem entre si
check "ensure_net_subnets: padrões com a oute 172.19.0.0/16 passam"  bash -c ". '$T/funcs.sh' && ensure_net_subnets 172.19.0.0/16"
check "ensure_net_subnets: oute em 10.200.0.0/16 passa"              bash -c ". '$T/funcs.sh' && ensure_net_subnets 10.200.0.0/16"
check "ensure_net_subnets: oute cruzando a studio falha"             bash -c ". '$T/funcs.sh' && ! ensure_net_subnets 172.16.0.0/16"
check "ensure_net_subnets: mensagem cita a rede oute"                bash -c ". '$T/funcs.sh' && ensure_net_subnets 172.16.0.0/16 2>&1 | grep -q 'cruza a da rede oute'" ; true
check "ensure_net_subnets: override cruzando outra rede falha" \
  bash -c ". '$T/funcs.sh' && export OUTE_NET_SUBNET_LLM=172.16.1.0/24 && ! ensure_net_subnets 172.19.0.0/16"
check "ensure_net_subnets: mensagem cita as duas redes" \
  bash -c ". '$T/funcs.sh' && export OUTE_NET_SUBNET_LLM=172.16.1.0/24 && ensure_net_subnets 172.19.0.0/16 2>&1 | grep -q 'cruza a da rede llm'" ; true
check "ensure_net_subnets: override sem cruzar passa" \
  env OUTE_NET_SUBNET_LLM=10.201.0.0/24 bash -c ". '$T/funcs.sh' && ensure_net_subnets 172.19.0.0/16"
check_end
