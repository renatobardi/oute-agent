# Rastreio p4-d (linhas = agent-notes.md da variante d)

| # | Regra do original (linha orig.) | Linha em d |
|---|---|---|
| 1 | Container sem privilégio no host (3) | 3 |
| 2 | `ssh oute-server` entra como `oute-ops`, só leitura + allowlist sudo (5 itens) (3) | 3 |
| 3 | Não tentar contornar (3) | 3 ("Never bypass") |
| 4 | Ação como usuário do host ou sudo/root dispara o fluxo (5) | 5 |
| 5 | Não pedir para o usuário copiar comandos; escrever script e propor (7) | 7 |
| 6 | Bloco `oute-propose` (8-14) | 8-14, idêntico |
| 7 | Imprime `id` do pedido (15) | 15 |
| 8 | `--root` = sudo; sem ele, usuário do host (15) | 15 |
| 9 | Usuário lê script inteiro, aprova/recusa com `oute approve` (16) | 16 |
| 10 | Ler resultado (saída + código) com `oute-inbox --wait <id>` (17) | 17 |
| 11 | Saída 3 = pendente/expirou (17) | 17 |
| 12 | Script: bash, `set -euo pipefail`, idempotente, um objetivo por pedido, `echo` antes de cada passo, sem segredos, nada interativo (19) | 19 |
| 13 | Ler o estado antes via `ssh oute-server`, propor só o necessário (19) | 19 |
| 14 | Remove/recria/para recurso: lista dependentes no script (20) | 20 |
| 15 | ...e para sem alterar nada se achar dependente inesperado (20) | 20 |
| 16 | ...ou vem precedido de pedido de ensaio (`--dry-run`/só leitura) (20) | 20 |
| 17 | Pedido obsoleto: avisar usuário para recusar antes de propor substituto (21) | 21 |
| 18 | Título do substituto diz que substitui, ex. "substitui <id>: …" (21) | 21 |
| 19 | Mudança permanente no oute-server segue fluxo do repo `lab` (issue → inventário → script → PR) (23) | 23 |
| 20 | Canal serve para diagnóstico, ajustes pontuais, deploy de PR já mergeado (23) | 23 |
| 21 | Ferramentas ai-memory: sempre passar `workspace` e `project` (27) | 27 |
| 22 | Valores do `.ai-memory.toml` na raiz do repo, vale em worktree (28) | 28 |
| 23 | Sem arquivo: `workspace = "default"`, `project` = repo principal via `basename` de git-common-dir sem `/.git` (29) | 29 |
| 24 | Fora de repo: perguntar antes de gravar (30) | 30 |
| 25 | Motivo: sem escopo usa "projeto ativo" compartilhado, talvez de outra sessão/repo (31) | 31 |
| 26 | Com opt-in `OUTE_MEMORY_RUN=1` (padrão desligado, só com ele) sessão roda sob `ai-memory run` (32) | 32 |
| 27 | Cota estourou: sair do claude, `ai-memory run codex` na mesma worktree, recebe contexto (32) | 32 |
| 28 | Regra workspace/project continua valendo (32) | 32 |
| 29 | Toda sessão em worktree própria, caminho e branch `sessao/<slug>`, `<space>`/`_sem-space`, aberta por `oute-task` (37) | 37 |
| 30 | Shell do container já faz isso ao digitar `claude`/`codex` no checkout principal (37) | 37 |
| 31 | Nunca editar/trocar branch no checkout principal; fica na branch padrão (38) | 38 |
| 32 | Se nele (git-dir = git-common-dir): não alterar, avisar, sugerir `oute-task <slug>` (38) | 38 |
| 33 | Exceção: `git pull --ff-only` na padrão, sem mudança local, sem perguntar (`oute-task clean --yes` faz) (38) | 38 |
| 34 | Antes do 1o push renomear branch `<tipo>/<issue>-<slug>`; 6 tipos (39) | 39 |
| 35 | Commits pequenos, convencionais (40) | 40 |
| 36 | Entrega por PR `gh pr create` (40) | 40 |
| 37 | Merge só quando o usuário pedir (40) | 40 |
| 38 | Pós-merge: `oute-task clean` lista, `--yes` remove (41) | 41 |
| 39 | Agem só no space atual; `--space <nome>` outro; `--all` todos incl. formato antigo (41) | 41 |
| 40 | Backlog = issues do repo via `gh` (4 comandos) (45) | 45 |
| 41 | Pendente no fim da tarefa vira issue (45) | 45 |
| 42 | Antes de `gh issue create` buscar issue aberta (comando `gh issue list`) (45) | 45 |
| 43 | Se existe: evidência em comentário (`gh issue comment <n>`), não issue nova (45) | 45 |
| 44 | Ler `AGENTS.md` e `CONTEXT.md` da raiz antes de começar, se existirem (46) | 46 |
| 45 | ADRs em `docs/adr/` canônicos; `CONTEXT.md` resumo com glossário (46) | 46 |
| 46 | Falta/conflito: perguntar, não supor (46) | 46 |
| 47 | Trabalho segue AI-DLC (ADR-07), fases `strat` → `iter`, gate humano, skills `oute-aidlc-<fase>-<id>` (47) | 47 |
| 48 | Não fechar fase com gate sem ok do usuário (47) | 47 |
| 49 | Nunca segredos em arquivo/commit/issue/PR/saída; vêm pelo ambiente (48) | 48 |

Fusões: nenhuma regra fundida; apenas encurtadas. Títulos de seção traduzidos (sem backticks).

## Backticks
`diff` dos conjuntos de `...` entre original e d: **vazio** (idêntico). Blocos de código idênticos.

## Medidas (palavras / bytes)
- original: 805 / 5336
- b: 799 / 5287
- d: 609 / 4418 (76% das palavras de b, 84% dos bytes). Não chega a 60%: o resto é literal protegido (comandos, caminhos, bloco de código), sem como cortar sem violar a regra 1/2.
