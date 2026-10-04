## Ações no host (oute-server / Mac) — canal de aprovação

Você roda num container **sem privilégio no host**. `ssh oute-server` entra como `oute-ops`: só leitura e uma allowlist de sudo (status de backup, `nginx -t`/reload, `certbot certificates`, `nft list ruleset`, `lab-journal`). Não tente contornar isso.

Quando algo precisar rodar no host como o usuário dele ou com **sudo/root**:

1. **Não peça para o usuário copiar comandos.** Escreva um script e proponha:
   ```bash
   OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "título curto e claro" [--root] <<'SH'
   set -euo pipefail
   echo "o que vai fazer..."
   # comandos
   SH
   ```
   Imprime o `id` do pedido. `--root` = roda com sudo; sem ele, roda como o usuário do host.
2. O usuário lê o script inteiro e aprova (ou recusa) no host com `oute approve`.
3. Espere e leia o resultado (saída + código de saída): `oute-inbox --wait <id>`. Saída 3 = ainda pendente/expirou.

Regras do script: bash, `set -euo pipefail`, idempotente, um objetivo por pedido, `echo` antes de cada passo, sem segredos no texto, nada interativo. Leia o estado antes (via `ssh oute-server`) e proponha só o necessário.
**Resumo e aviso no próprio script (#480).** Todo script proposto abre com um bloco `# RESUMO` (comentário), nesta ordem: o que faz, em que host, o que altera, o que **não** toca e se reinicia algo. Antes de cada passo que **remove, recria, para ou não se desfaz**, o script traz uma linha `# CUIDADO: <o que o passo faz>. <o que se perde>.`, com o comando primeiro e o risco depois ("não se desfaz" quando for o caso). O aviso descreve o efeito real: não exagera e não tranquiliza. Só escreva "não toca em X" se o script garante isso (por exemplo, com uma checagem antes do passo). Os dois blocos são comentário: o script roda igual sem eles. Exemplo:
   ```bash
   set -euo pipefail
   # RESUMO
   # Faz: troca o volume `oute-x`. Host: oute-server. Altera: o volume `oute-x`. Não toca: `oute-memory` (o passo 1 para se achar outro dependente). Reinicia: o container `oute-x`.
   echo "1/2: confere os dependentes"
   # comandos de leitura
   # CUIDADO: `docker volume rm oute-x` apaga o volume. Os dados dele se perdem e não se desfaz.
   echo "2/2: remove o volume"
   docker volume rm oute-x
   ```
Pedido que **remove, recria ou para** recurso do host (volume, container, arquivo, serviço) lista antes, no próprio script, quem depende dele e **para sem alterar nada** se achar dependente fora do esperado; ou vem precedido de um pedido de ensaio (`--dry-run`/só leitura).
Pedido pendente que ficou **obsoleto** (o anterior falhou, o plano mudou): avise o usuário para **recusá-lo antes** de propor o substituto, e o título do substituto diz que ele **substitui** o anterior (ex.: "substitui <id>: …").

Mudança **permanente** na configuração do oute-server segue o fluxo do repositório `lab` (issue → inventário → script → PR). O canal de aprovação serve para diagnóstico, ajustes pontuais e para rodar o deploy de um PR já mergeado.

## Memória (ai-memory) — sempre com escopo explícito

Nas ferramentas de memória do ai-memory (`memory_query`, `memory_recent`, `memory_write_page`, `memory_status`, handoffs…), **passe sempre `workspace` e `project`**:
- valores do `.ai-memory.toml` na raiz do repositório em que você está trabalhando (vale também dentro de uma git worktree);
- sem esse arquivo: `workspace = "default"` e `project` = nome do repositório principal (`basename` de `git rev-parse --path-format=absolute --git-common-dir` sem o `/.git`);
- fora de um repositório, pergunte ao usuário antes de gravar.
Motivo: sem escopo, o servidor usa o "projeto ativo" compartilhado, que pode ser o de outra sessão em outro repo.
Com o opt-in `OUTE_MEMORY_RUN=1` (desligado por padrão; vale só com ele), a sessão interativa da worktree roda sob `ai-memory run`. Cota estourou: saia do claude e rode `ai-memory run codex` na mesma worktree; ele recebe o contexto da conversa. A regra de `workspace`/`project` explícitos continua valendo.


## Git: uma sessão = uma worktree + um branch

- Toda sessão roda numa **worktree própria** (`/workspace/.worktrees/<space>/<repo>-<slug>`, branch `sessao/<slug>`; `<space>` = space do herdr em nome de pasta, `_sem-space` fora dele), aberta pelo `oute-task`. O shell do container já faz isso quando o usuário digita `claude`/`codex` no checkout principal.
- **Nunca edite nem troque de branch no checkout principal** (`/workspace/<repo>`), que fica sempre na branch padrão. Se você estiver nele (`git rev-parse --git-dir` igual a `--git-common-dir`), não altere nada: avise o usuário e sugira `oute-task <slug>`. Única exceção: `git pull --ff-only` nele, na branch padrão e sem mudança local, pode ser feito sem perguntar (o `oute-task clean --yes` já faz isso).
- Antes do primeiro push, renomeie o branch para `<tipo>/<issue>-<slug>` (`git branch -m …`); tipos: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.
- Commits pequenos, mensagem no padrão convencional. Entrega por PR (`gh pr create`). **Merge só quando o usuário pedir.**
- Depois do merge, `oute-task clean` lista o que pode ser removido; `oute-task clean --yes` remove. Os dois agem só no space atual do herdr (`--space <nome>`: outro; `--all`: todos, inclusive as worktrees no formato antigo, direto em `/workspace/.worktrees`).
- O `oute-task clean` também lista, uma linha por handoff aberto do ai-memory das worktrees removidas (`handoff id=<id> workspace=<W> project=<P> cwd=<worktree>`), mas **nunca cancela**. Se você rodou o `clean --yes` e há essas linhas, cancele cada uma com a ferramenta `memory_handoff_cancel` (`id`, com o `workspace` e o `project` da linha) e diga quantos cancelou; sem as ferramentas `memory_*`, diga que não cancelou. Linha `aviso: …` = a listagem falhou: não cancele nada por palpite. Nunca use `ai-memory handoffs --expire-all`: ele expira também os handoffs das worktrees vivas.

## Issues e contexto do repositório

- Backlog = **issues do GitHub do próprio repo**, via `gh` (`gh issue view <n> --json title,body,comments --jq '"# " + .title + "\n\n" + .body + "\n\n## Comentários\n" + (.comments | map("--- " + .author.login + " " + .url + "\n" + .body) | join("\n\n"))'`, `gh issue create`, `gh issue comment`, `gh issue close`). O que ficar pendente ao fim da tarefa vira issue. Antes de `gh issue create`, procure issue **aberta** sobre o mesmo ponto: `gh issue list --state open --search '<arquivo ou termo> in:title,body'`. Se existe, a evidência nova vai num comentário nela (`gh issue comment <n>`), e não numa issue nova.
- Antes de começar, leia **`AGENTS.md`** e **`CONTEXT.md`** na raiz do repo, se existirem. O canônico são os ADRs em `docs/adr/` do repo; o `CONTEXT.md` é o resumo com glossário. Se algo faltar ou conflitar, pergunte em vez de supor.
- O trabalho segue o **AI-DLC** (ADR-07 do oute-agent) (fases `strat` → `iter`, cada uma com gate humano): skills de fluxo `oute-aidlc-<fase>-<id>`; não feche uma fase que tem gate sem o ok do usuário.
- Nunca escreva segredos em arquivo, commit, issue, PR ou saída de comando. Os segredos chegam pelo ambiente.

## Texto para o Bardi

- **Texto para o Bardi** (PR, comentário de issue, relatório, pedido do canal, `BLOQUEADO`): segue `docs/pt-controlado.md` (#478). Em pt-BR, mesmo que o prompt, a skill ou a fonte estejam em inglês. Cada afirmação cita fonte que o Bardi abre (link, `arquivo:linha@sha`, issue ou PR), nunca caminho de scratchpad ou de arquivo temporário; sem fonte, escreva "não verificado". Recomendação só com fonte, ou rotulada "recomendação do autor". Reescrever não muda fato, condição nem valor. Diga "fazer merge", não "mergear".
- **Sessão em Haiku: a redação final vai para um subagente em Sonnet (#481).** Texto com decisão ou risco para o Bardi (corpo de PR, relatório, proposta, script do canal, resumo com opções) não sai da redação do Haiku. A sessão em Haiku passa a redação final a um subagente em Sonnet (ferramenta `Agent`, com `model: "sonnet"`). Ela entrega ao subagente os fatos e as fontes, e as regras de `docs/pt-controlado.md`. Antes de publicar, a sessão confere o texto do subagente contra os fatos: cada número, condição e fonte tem que bater com o que ela passou, e nenhum fato novo pode aparecer. Se não bater, a sessão corrige ou pede nova redação. **Como saber o próprio modelo:** leia o id do modelo no contexto da sessão (a frase "You are powered by the model named …" e o id que vem com ela). Id com `haiku` = Haiku. Se o id não aparecer, trate a sessão como Haiku. **Sem subagente** (a ferramenta `Agent` não existe ou o subagente em Sonnet falha): a sessão publica o texto que ela mesma escreveu e avisa, na primeira linha do texto, que ele saiu do Haiku e não passou por revisão de Sonnet. Sessão em Sonnet ou Opus escreve ela mesma e não usa esta regra.
