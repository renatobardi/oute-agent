# Apoio comum para testes de prompts (swarm.md, swarm-worker.md, agent-notes.md)
# Vem de tests/oute-swarm-prompts-*.test.sh, que fontes de cada teste dividem

# Caminhos para os arquivos de prompt
D="$ROOT/docker/swarm.md"; export D
W="$ROOT/docker/swarm-worker.md"; export W
N="$ROOT/docker/agent-notes.md"; export N
PT="$ROOT/docs/pt-controlado.md"; export PT

# Caminhos para skills citadas nos prompts
SV="$ROOT/addons/skills/oute-aidlc-ship-verify/SKILL.md"; export SV
OB="$ROOT/addons/skills/oute-aidlc-ops-observe/SKILL.md"; export OB
A="$ROOT/addons/skills/oute-aidlc-qa-pr-audit/SKILL.md"; export A

return 0
