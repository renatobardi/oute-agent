#!/usr/bin/env bash
# Testes do oute-swarm, tema: instruções do worker: issue sem arquivo, spike, regras de teste, sessão sem ação manual, check-lib, parallel-lib, funções de shell nova, audit (#115, #100, #358, #373, #401, #417, #450, #488, #501, #585).
# Bash puro, sem herdr, gh nem rede de verdade (dublês e apoio em tests/lib/swarm.sh).
# Acrescente caso novo no arquivo do tema (swarm-worker.md → este arquivo).
# Uso: tests/oute-swarm-prompts-worker.test.sh   (sai != 0 se algum caso falhar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWARM="${SWARM:-$ROOT/docker/oute-swarm}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/lib/check.sh"
. "$ROOT/tests/lib/swarm.sh"
. "$ROOT/tests/lib/oute-swarm-prompts.sh"

WORKER_INSTR="instrução"
WORKER_PROMPT_CHECK='[ "$1" -eq 0 ] && [ -s "$2" ]'
NO_PLACEHOLDER_REGEX="{{[A-Z_]*}}"


# 11f. sessão de issue sem arquivo alterado (#115): sem PR, proposta na issue, ok do Bardi, resultado na issue
CASE=sem-pr; round "$CASE"
sw spawn 115-sempr "$WORKER_INSTR"
P="$STATE/115-sempr.prompt"
check "worker sem PR: código 0, com o prompt da sessão"  bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker sem PR: sem arquivo alterado, não abre PR (#115)" grep -qF -- '- **Issue sem arquivo alterado** (a entrega é só uma ação no GitHub: labels, comentários, fechar ou editar issue): não abra PR' "$P"
check "worker sem PR: proposta na issue, e para (#115)"  grep -qF 'Publique a proposta como comentário na issue #115 (o que vai aplicar, item por item) e pare, terminando com `BLOQUEADO #115: proposta em <url do comentário>, aplico com o ok do Bardi`.' "$P"
check "worker sem PR: aplica só depois do ok e registra o resultado na issue (#115)" grep -qF 'Só depois do ok do Bardi (dele ou repassado pelo dispatcher) aplique, registre o resultado em outro comentário na issue e termine com `PRONTO #115: <url do comentário com o resultado> — sem PR`.' "$P"
check "worker sem PR: não fecha a issue (#115)"          grep -qF 'Não feche a issue #115: quem fecha é o dispatcher, com o ok do Bardi.' "$P"
check "worker sem PR: o PRONTO com PR continua (#115)"   grep -qF 'termine com uma linha `PRONTO #115: <url do PR>`' "$P"
check "worker sem PR: sem placeholder no prompt"         [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]

# 11g. sessão de spike (#100): o pronto é o relatório no comentário final da issue, sem código de produção
CASE=spike; round "$CASE"
sw spawn 100-spike "$WORKER_INSTR"
P="$STATE/100-spike.prompt"
check "worker spike: código 0, com o prompt da sessão"   bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker spike: o pronto é o relatório, sem código de produção (#100)" grep -qF -- '- **Issue `spike`** (label `spike`: investigação): o pronto é o **relatório**, sem código de produção.' "$P"
check "worker spike: não altera código do repo (#100)"   grep -qF 'Não altere código, script, config nem teste do repo;' "$P"
check "worker spike: relatório no comentário final da issue (#100)" grep -qF 'Publique o relatório como comentário final na issue #100: a pergunta, o que foi conferido e como, os achados com evidência, a recomendação e o que ficou em aberto.' "$P"
check "worker spike: PRONTO com o comentário do relatório (#100)" grep -qF 'Termine com `PRONTO #100: <url do comentário com o relatório> — sem PR`.' "$P"
check "worker spike: sem proposta nem espera do ok (#100)" grep -qF 'Aqui não há proposta nem espera do ok (a regra acima): o relatório não aplica nada.' "$P"
check "worker spike: PR de doc quando a instrução pede arquivo (#100)" grep -qF 'entregue por PR de doc (só o doc e o fragmento do changelog), com as regras de PR acima, e o comentário final na issue leva o resumo e o link do PR.' "$P"
check "worker spike: não fecha a issue nem cria issue nova (#100)" grep -qF 'Não feche a issue #100 nem crie issue nova, salvo se a instrução do dispatcher mandar criar as issues do relatório' "$P"
check "worker spike: exceção para spike com critério (opção 1) (#356)" grep -qF 'salvo se a instrução do dispatcher mandar criar as issues do relatório' "$P"
check "worker spike: sem placeholder no prompt"          [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]

# 11h. regra de rm com variável protegida em teste e script (#358): evita prompt de permissão
CASE=rm-var; round "$CASE"
sw spawn 358-rmvar "$WORKER_INSTR"
P="$STATE/358-rmvar.prompt"
check "worker rm var: código 0, com o prompt da sessão"  bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker rm var: regra sobre rm com variável (#358)" grep -qF -- '- **Em teste e script, `rm` com variável usa `"${VAR:?}"/…` ou caminho literal**' "$P"
check "worker rm var: motivo da regra: não dispara prompt (#358)" grep -qF 'para não disparar o prompt de permissão' "$P"
check "worker rm var: exemplo rm -f com variável protegida (#358)" grep -qF 'Ex.: `rm -f "${FAKE:?}"/*.json`' "$P"
check "worker rm var: comportamento do prompt de permissão (#358)" grep -qF 'o Claude Code pede permissão e, sem resposta, nega o comando em ~1 min 35 s' "$P"
check "worker rm var: sem placeholder no prompt"         [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]

# 539. regra do rm com variável aparece na lista de conferência antes de rodar comando
CASE=539-rmvariavel; round "$CASE"
sw spawn 539-rmvariavel "$WORKER_INSTR"
P="$STATE/539-rmvariavel.prompt"
check "worker 539: código 0, com o prompt da sessão"  bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker 539: regra do rm antes de rodar comando (#539)" grep -qF 'Antes de rodar um comando que use `rm` com variável, confira a regra do `rm` com variável, acima' "$P"
check "worker 539: regra vale também na aba (#539)" grep -qF 'A regra vale também para comando que você roda na aba, não só para o que vai no arquivo de teste.' "$P"
check "worker 539: sem placeholder no prompt"         [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]

# 11i. sessão sem ação manual do Bardi (#373): diálogo de pergunta, esc do dispatcher, blocked na retrospectiva
CASE=sem-acao-manual; round "$CASE"
sw spawn 373-semacao "$WORKER_INSTR"
P="$STATE/373-semacao.prompt"
check "worker sem ação manual: código 0, com o prompt"   bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker sem ação manual: proíbe o diálogo de pergunta (#373)" grep -qF 'Não use o diálogo interativo de pergunta do harness' "$P"
check "worker sem ação manual: dúvida em texto BLOQUEADO (#373)" grep -qF 'termina o turno com texto: `BLOQUEADO #373: <pergunta>`, as opções numeradas (1, 2, …) e a sua recomendação' "$P"
check "worker sem ação manual: regra se prompt aparecer mesmo assim (#373)" grep -qF 'Se um prompt de permissão aparecer mesmo assim, a regra do `rm` com variável, acima, é o caso mais comum' "$P"
check "worker sem ação manual: rm com variável é caso mais comum (#373)" grep -qF 'a regra do `rm` com variável, acima, é o caso mais comum' "$P"
check "worker spike: escopo de teste em serviço compartilhado (#378)" grep -qF 'use um escopo de teste fixo, com `workspace` e `project` próprios e `oute.task.slug` identificável' "$P"
check "worker sem ação manual: sem placeholder no prompt" [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]
opn --max 2
D="$FAKE/oute-task.last"
check "dispatcher: §4.1 aponta para regra que existe no swarm-worker (#451)" grep -qF "acrescentar o comando à regra de prompt de permissão do \`docker/swarm-worker.md\`" "$D"
check "dispatcher: lê a tela da sessão blocked (#373)"   grep -qF '`herdr agent read <pane> --source visible`' "$D"
check "dispatcher: gatilho tell recusado (#373)"         grep -qF 'ou um `tell` recusado com `o campo de entrada não contém exatamente a mensagem`, leia a tela da sessão' "$D"
check "dispatcher: exceção do esc (#373)"                grep -qF '`herdr agent send-keys <pane> esc`' "$D"
check "dispatcher: esc nunca escolhe nem aprova (#373)"  grep -qF 'Nunca escolha opção, nunca aprove permissão, nunca digite resposta no diálogo' "$D"
check "dispatcher: pergunta do Bardi segue a ele (#373)" grep -qF 'o `esc` não substitui a decisão' "$D"
check "dispatcher: regra nunca digite no pane com exceção do esc (#373)" grep -qF 'nunca digite no pane por outro meio (a única exceção é o `esc` acima)' "$D"
check "dispatcher: retrospectiva lista blocked com causa (#373)" grep -qF -- '- **Sessões `blocked`:** liste-as com a causa de cada uma' "$D"
check "dispatcher: sem placeholder no prompt"            [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$D")" ]

# 11j. regra de check-lib quando altera testes (#401): rodar check-lib e dizer no corpo do PR
CASE=check-lib; round "$CASE"
sw spawn 401-checklib "$WORKER_INSTR"
P="$STATE/401-checklib.prompt"
check "worker check-lib: código 0, com o prompt da sessão" bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker check-lib: regra sobre check-lib (#401)"     grep -qF -- 'se o PR altera `tests/*.test.sh` ou `tests/lib/`' "$P"
check "worker check-lib: roda check-lib nos dois ambientes (#401)" grep -qF 'rode também `bash tests/check-lib.test.sh` (no ambiente da sessão e no limpo)' "$P"
check "worker check-lib: diz no corpo do PR (#401)"        grep -qF 'diga no corpo do PR que rodou' "$P"
check "worker check-lib: falha no check-lib é falha do PR (#401)" grep -qF 'falha ali é falha do PR' "$P"
check "worker check-lib: referência da issue (#401)"       grep -qF '#401' "$P"
check "worker check-lib: sem placeholder no prompt"       [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]

# 11j1. regra de parallel-lib quando altera testes (#450): rodar parallel-lib e dizer no corpo do PR
CASE=parallel-lib; round "$CASE"
sw spawn 450-parallellib "$WORKER_INSTR"
P="$STATE/450-parallellib.prompt"
check "worker parallel-lib: código 0, com o prompt da sessão" bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker parallel-lib: regra sobre parallel-lib (#450)" grep -qF -- 'rode também `bash tests/parallel-lib.test.sh`' "$P"
check "worker parallel-lib: nos dois ambientes (#450)"     grep -qF '(no ambiente da sessão e no limpo)' "$P"
check "worker parallel-lib: diz no corpo do PR (#450)"     grep -qF 'diga no corpo do PR que rodou' "$P"
check "worker parallel-lib: confere testes com serviço (#450)" grep -qF 'para conferir testes que sobem serviços em segundo plano' "$P"
check "worker parallel-lib: referência da issue (#450)"    grep -qF '#450' "$P"
check "worker parallel-lib: sem placeholder no prompt"     [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]

# 11k. conferência do diff contra SonarCloud antes de abrir PR (#540): evita gates reprovados
CASE=sonar; round "$CASE"
SCHEME="http"
sw spawn 540-sonar "$WORKER_INSTR"
P="$STATE/540-sonar.prompt"
check "worker sonar: código 0, com o prompt da sessão" bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker sonar: confere diff contra SonarCloud antes do PR (#540)" grep -qF 'confira o diff contra a lista do SonarCloud do `AGENTS.md`' "$P"
check "worker sonar: cita a seção Validar antes do PR (#540)" grep -qF 'seção "Validar antes do PR"' "$P"
check "worker sonar: lista função de shell nova com local (#540)" grep -qF 'função de shell nova com `local` e `return`' "$P"
check "worker sonar: lista sem http literal em arquivo novo (#540)" bash -c "grep -qF 'sem \`'\"$SCHEME\"'://\` literal em arquivo novo' \"\$1\"" _ "$P"
check "worker sonar: lista sem regex com quantificador aninhado (#540)" grep -qF 'sem regex com quantificador aninhado' "$P"
check "worker sonar: lista sem colchete aninhado (#540)" grep -qF 'sem `[x]` aninhado' "$P"
check "worker sonar: corrija antes de esperar o gate (#540)" grep -qF 'Corrija o que encontrar em vez de esperar o gate reprovado' "$P"
check "worker sonar: sem placeholder no prompt" [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]

# qa-pr-audit: decisão do Bardi no topo e forma curta (#482)
A="$ROOT/addons/skills/oute-aidlc-qa-pr-audit/SKILL.md"
R="$ROOT/addons/skills/oute-aidlc-qa-pr-audit/relatorio.md"   # modelo do relatório (passo 12), em arquivo próprio (#754)
check "audit: relatório abre com ação e decisão, antes do head (#482)" bash -c 'r=$(sed -n "/^<!-- oute-aidlc-qa-pr-audit -->/,/^### Gates/p" "$1" | head -12); a=$(grep -n "^\*\*Ação recomendada:\*\*" <<<"$r" | head -1 | cut -d: -f1); d=$(grep -n "^\*\*Decisão do Bardi:\*\*" <<<"$r" | head -1 | cut -d: -f1); h=$(grep -n "^\*\*Head auditado:\*\*" <<<"$r" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$d" ] && [ -n "$h" ] && [ "$a" -lt "$d" ] && [ "$d" -lt "$h" ]' _ "$R"
check "audit: decisão com opções numeradas e rótulo do autor (#482)" grep -qF '"recomendação do autor": opção N' "$R"
check "audit: sem decisão escreve 'Decisão do Bardi: nenhuma' (#482)" grep -qF 'Sem escolha para ele: escreva "Decisão do Bardi: nenhuma"' "$R"
check "audit: relatório não repete a ação no fim (#482)"   bash -c '! grep -qF "### Ação recomendada" "$1"' _ "$R"
check "audit: forma curta só com 5 contadores 0 e merge como está (#482)" grep -qF 'Vale só quando os cinco contadores dos achados são 0' "$R"
check "audit: forma curta mantém head, gates e Closes × Refs (#482)" bash -c 'sed -n "/^\*\*Forma curta\.\*\*/,/^Forma completa:/p" "$1" > "$2"; grep -qF "o head auditado (e a base)" "$2" && grep -qF "a tabela de gates, o CI no head, o SonarCloud" "$2" && grep -qF "a linha \`Closes × Refs\`" "$2"' _ "$R" "$TMP/curta.txt"
check "audit: forma curta lista cada seção conferida (#482)" grep -qF '**Conferido, sem achado:** superfície sensível e supply chain:' "$R"
check "audit: achado ou gate não rodado leva a forma completa (#482)" grep -qF 'Qualquer achado, ou um gate que não rodou, leva a forma completa.' "$R"
check "audit: forma completa mantém todas as seções (#482)" bash -c 'for t in "### Gates" "### Achados" "### Eixo Spec" "### Superfície sensível e supply chain" "### Eixo Standards" "### Registro de alegações" "### Checklist funcional" "### Prós e contras" "### Correção sugerida e limites"; do [ "$(grep -cF "$t" "$1")" -ge 1 ] || exit 1; done' _ "$R"
check "audit: cita o doc de PT controlado (#482)"          bash -c 'sed -n "/^\*\*Ordem do relatório/p" "$1" | grep -qF docs/pt-controlado.md' _ "$R"
check "audit: Refs troca para Closes e o Falta só de (ship) fica (#488)" grep -qF 'A correção é trocar para `Closes`; o `## Falta` com itens só de `(ship)` fica como está, com a marca, e sem item nenhum a seção sai.' "$A"
check "audit: sem o 'remover a seção ou manter como está' (#488)" bash -c '! grep -qF "remover a seção ou manter como está" "$1"' _ "$A"
# 501. função de shell nova com local e return (#501)
check "worker: função de shell nova leva local nos parâmetros (#501)" grep -qF -- '- **Função de shell nova** (em `docker/`, `scripts/` e `tests/`): parâmetro posicional vai para uma variável `local` (`local x="$1"`)' "$W"
check "worker: função de shell nova leva return explícito no fim (#501)" grep -qF 'e a função termina com `return` explícito' "$W"
# 501. Closes x Refs: critério de ship vai no Falta com marca (ship) (#501)
check "worker: Closes se cumpre todos menos os de ship (#501)" grep -qF 'se o PR cumpre todos os critérios de aceite da issue, exceto os de `ship`' "$W"
check "worker: Refs se algum critério de build, qa ou design faltar (#501)" grep -qF 'se algum critério de `build`, `qa` ou `design` ficar de fora' "$W"
check "worker: ship no Falta com marca (ship) (#501)"        grep -qF 'vai no `## Falta` com a marca `(ship)`, e o PR usa `Closes`' "$W"
check "worker: critério de ship é depois de entrar ou deploy ou release (#501)" grep -qF 'Critério de `ship` (com "depois de entrar", "depois do deploy" ou "medida após a release")' "$W"
# 585. conferir funções de shell novas com grep antes do PR e declarar o resultado (#585)
check "worker: lista funções novas do diff com grep antes do PR (#585)" grep -qF 'git diff --unified=0 origin/main...HEAD -- tests/*.test.sh tests/lib/ scripts/ docker/ | grep -E' "$W"
check "worker: grep identifica definições de função no diff (#585)" grep -qF 'function[[:space:]]+[[:alnum:]_]+|[[:alnum:]_]+[[:space:]]*[(][)][[:space:]]*[{]' "$W"
check "worker: confere local em cada função nova (#585)" grep -qF 'todo parâmetro posicional deve ser atribuído a uma variável `local`' "$W"
check "worker: confere return explícito em cada função nova (#585)" grep -qF 'deve haver um `return` explícito no fim' "$W"
check "worker: informa a contagem e o resultado no corpo do PR (#585)" grep -qF 'No corpo do PR, informe: `Funções novas: N; todas com local e return.`' "$W"
# 484. PR de prompt roda a regressão dos agentes antes de abrir; a recusa por cota vai no Falta
check "484: worker: PR que muda um dos 3 prompts roda oute-regression antes de abrir, por arquivo" grep -qF -- '- **PR que muda `docker/agent-notes.md`, `docker/swarm.md` ou `docker/swarm-worker.md` roda a regressão dos agentes só onde ela testa o arquivo (#484, #755).**' "$W"
check "755: worker: agent-notes.md, regressão completa" grep -qF '(a) muda `docker/agent-notes.md`, sozinho ou junto de outro: regressão completa' "$W"
check "755: worker: só swarm-worker.md, só a tarefa 12 nos dois modelos" grep -qF '(b) muda `docker/swarm-worker.md` e não o `docker/agent-notes.md`: só a tarefa 12, em Haiku e em Sonnet, chamada com a pasta das tarefas do checkout' "$W"
check "755: worker: a tarefa 12 lê o swarm-worker.md da worktree (OUTE_REGRESSION_DIR)" grep -qF 'OUTE_REGRESSION_DIR="$PWD/docker/regression" oute-regression --task closes-refs --baseline "$PWD/docker/regression/baseline.json"' "$W"
check "755: worker: só swarm.md, não exigida, com o motivo" grep -qF '(c) muda só `docker/swarm.md`: regressão não exigida, porque nenhuma tarefa carrega o arquivo e a suíte dá o mesmo resultado com ou sem a mudança' "$W"
check "755: o nome da tarefa 12 na regra existe na pasta das tarefas" test -f "$ROOT/docker/regression/12-closes-refs.sh"
check "755: oute-regression e AGENTS.md citam a regra por arquivo" bash -c 'grep -qF "só a tarefa 12" "$1" && grep -qF "só a tarefa 12 (\`--task closes-refs\`)" "$2"' _ "$ROOT/docker/oute-regression" "$ROOT/AGENTS.md"
check "484: worker: a saída inteira vai no corpo, na seção ## Regressão dos agentes" grep -qF 'na seção `## Regressão dos agentes`, com a linha `repetições:` que ela imprime' "$W"
check "484: worker: saída 3 = trava de cota; não sobe o limite e declara no ## Falta" grep -qF 'Saída 3 é a trava de cota (`OUTE_REGRESSION_MAX_PCT`, padrão 60%): não suba o limite e não rode de outro jeito. Declare no `## Falta` do PR que a regressão não rodou' "$W"
check "484: worker: o merge sem a regressão fica para o Bardi (decisão do Bardi)" grep -qF 'o merge fica para o Bardi decidir (a auditoria recomenda `decisão do Bardi`)' "$W"
check "484: skill de auditoria: confere a saída da regressão e recomenda decisão do Bardi sem ela" bash -c 'grep -qF "**Regressão dos agentes (#484, #755).**" "$1" && grep -qF "a ação recomendada é \`decisão do Bardi\`" "$1" && grep -qF -- "- \`decisão do Bardi\`: PR de prompt" "$1"' _ "$A"
check "484: skill de auditoria: a ação decisão do Bardi está no modelo do relatório" grep -qF 'perguntar ao autor | decisão do Bardi | não fazer merge' "$R"

# 11z. bloco "Antes de abrir o PR" no topo das regras e a regra do rm no texto que o spawn acrescenta (#578)
CASE=antes-pr; round "$CASE"
sw spawn 578-antespr "$WORKER_INSTR"
P="$STATE/578-antespr.prompt"
check "worker antes do PR: código 0, com o prompt da sessão" bash -c "$WORKER_PROMPT_CHECK" _ "$RC" "$P"
check "worker antes do PR: o bloco é a primeira regra da lista (#578)" bash -c 'grep -m1 -- "^- " "$1" | grep -qF -- "- **Antes de abrir o PR (#578):**"' _ "$P"
check "worker antes do PR: rm com variável, só \${VAR:?}, literal ou mktemp (#578)" grep -qF 'só `"${VAR:?}"/…`, caminho literal ou `mktemp -d` novo; nunca `rm -rf $VAR/*`.' "$P"
check "worker antes do PR: custo do prompt de permissão (#578)" grep -qF 'o prompt nega sozinho em cerca de 1 min 35 s.' "$P"
check "worker antes do PR: arquivo novo vazio e símbolo sem definição (#578)" grep -qF 'Nenhum arquivo novo está vazio (`git diff --stat`, 0 linhas num arquivo novo).' "$P"
check "worker antes do PR: definição no diff, por git grep (#578)" grep -qF 'tem definição no diff (`git grep` do nome).' "$P"
check "worker antes do PR: suíte inteira quando muda compose, esquema ou apoio de teste (#578)" grep -qF 'roda a suíte inteira (`tests/*.test.sh`, `xargs -P` até o `nproc`' "$P"
check "worker antes do PR: testes que citam o termo alterado (#578)" grep -qF '`git grep -l <termo> tests/`' "$P"
check "worker antes do PR: só arquivos da issue (#578)" grep -qF '`git diff --name-only origin/main...HEAD` só lista arquivos da própria issue; arquivo de runtime ou binário sai do PR.' "$P"
check "worker antes do PR: arquivo apagado ou revertido (#578)" grep -qF '`git diff origin/main --stat` não mostra arquivo apagado ou revertido que a issue não pediu.' "$P"
check "worker antes do PR: sem placeholder no prompt"      [ -z "$(grep -o "$NO_PLACEHOLDER_REGEX" "$P")" ]
check_end
