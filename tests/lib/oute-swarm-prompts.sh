# Apoio comum para testes de prompts (swarm.md, swarm-worker.md, agent-notes.md)
# Vem de tests/oute-swarm-prompts-*.test.sh, que fontes de cada teste dividem; precisa de tests/lib/swarm.sh antes

# Caminhos para os arquivos de prompt
# o dispatcher é o núcleo (swarm.md) mais as etapas (swarm/*.md, #753): D é o texto dos dois juntos, para os casos
# que procuram regra sem importar em que arquivo ela ficou; DN é só o núcleo
DN="$ROOT/docker/swarm.md"; export DN
D="$SWARM_MD_ALL"; export D
ST="$SWARM_ST"; export ST
W="$ROOT/docker/swarm-worker.md"; export W
N="$ROOT/docker/agent-notes.md"; export N
PT="$ROOT/docs/pt-controlado.md"; export PT

# Caminhos para skills citadas nos prompts
SV="$ROOT/addons/skills/oute-aidlc-ship-verify/SKILL.md"; export SV
OB="$ROOT/addons/skills/oute-aidlc-ops-observe/SKILL.md"; export OB
A="$ROOT/addons/skills/oute-aidlc-qa-pr-audit/SKILL.md"; export A

return 0
