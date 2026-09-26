## Ações no host (oute-server / Mac) — canal de aprovação

Você roda num container **sem privilégio no host**. `ssh oute-server` entra como `oute-ops`: só leitura e uma allowlist de sudo (status de backup, `nginx -t`/reload, `certbot certificates`, `nft list ruleset`, `lab-journal`). Não tente contornar isso.

Quando algo precisar rodar no host como o usuário dele ou com **sudo/root**:

1. **Não peça para o usuário copiar comandos.** Escreva um script e proponha:
   ```bash
   OUTE_PROPOSE_AGENT=<claude|codex|pi> oute-propose "título curto e claro" [--root] <<'SH'
   set -euo pipefail
   echo "o que vai fazer..."
   # comandos
   SH
   ```
   Imprime o `id` do pedido. `--root` = roda com sudo; sem ele, roda como o usuário do host.
2. O usuário lê o script inteiro e aprova (ou recusa) no host com `oute approve`.
3. Espere e leia o resultado (saída + código de saída): `oute-inbox --wait <id>`. Saída 3 = ainda pendente/expirou.

Regras do script: bash, `set -euo pipefail`, idempotente, um objetivo por pedido, `echo` antes de cada passo, sem segredos no texto, nada interativo. Leia o estado antes (via `ssh oute-server`) e proponha só o necessário.
Mudança **permanente** na configuração do oute-server segue o fluxo do repositório `lab` (issue → inventário → script → PR). O canal de aprovação serve para diagnóstico, ajustes pontuais e para rodar o deploy de um PR já mergeado.

## Memória (ai-memory) — sempre com escopo explícito

Nas ferramentas de memória do ai-memory (`memory_query`, `memory_recent`, `memory_write_page`, `memory_status`, handoffs…), **passe sempre `workspace` e `project`**:
- valores do `.ai-memory.toml` na raiz do repositório em que você está trabalhando (vale também dentro de uma git worktree);
- sem esse arquivo: `workspace = "default"` e `project` = nome do repositório principal (`basename` de `git rev-parse --path-format=absolute --git-common-dir` sem o `/.git`);
- fora de um repositório, pergunte ao usuário antes de gravar.
Motivo: sem escopo, o servidor usa o "projeto ativo" compartilhado, que pode ser o de outra sessão em outro repo.


## Git: uma sessão = uma worktree + um branch

- Toda sessão roda numa **worktree própria** (`/workspace/.worktrees/<repo>-<slug>`, branch `sessao/<slug>`), aberta pelo `oute-task`. O shell do container já faz isso quando o usuário digita `claude`/`codex`/`pi` no checkout principal.
- **Nunca edite nem troque de branch no checkout principal** (`/workspace/<repo>`), que fica sempre na branch padrão. Se você estiver nele (`git rev-parse --git-dir` igual a `--git-common-dir`), não altere nada: avise o usuário e sugira `oute-task <slug>`. Única exceção: `git pull --ff-only` nele, na branch padrão e sem mudança local, pode ser feito sem perguntar (o `oute-task clean --yes` já faz isso).
- Antes do primeiro push, renomeie o branch para `<tipo>/<issue>-<slug>` (`git branch -m …`); tipos: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.
- Commits pequenos, mensagem no padrão convencional. Entrega por PR (`gh pr create`). **Merge só quando o usuário pedir.**
- Depois do merge, `oute-task clean` lista o que pode ser removido; `oute-task clean --yes` remove.

## Issues e contexto do repositório

- Backlog = **issues do GitHub do próprio repo**, via `gh` (`gh issue view <n> --comments`, `gh issue create`, `gh issue comment`, `gh issue close`). O que ficar pendente ao fim da tarefa vira issue.
- Antes de começar, leia **`AGENTS.md`** e **`CONTEXT.md`** na raiz do repo, se existirem. O `CONTEXT.md` é um resumo: o canônico (ADRs completos) fica no Project do claude.ai do Bardi, que você não acessa. Se algo faltar ou conflitar, pergunte em vez de supor.
- Nunca escreva segredos em arquivo, commit, issue, PR ou saída de comando. Os segredos chegam pelo ambiente.
