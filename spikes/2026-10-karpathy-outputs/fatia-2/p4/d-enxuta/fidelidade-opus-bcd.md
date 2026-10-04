# Fidelidade P4 (spike #458): `docker/agent-notes.md` × variantes b, c, d

Revisor: Opus (independente). Original: `docker/agent-notes.md` (pt-BR, 48 linhas). Artefatos:
b = `fatia-1/variants/b-en-concise/docker/agent-notes.md`, c = `fatia-1/variants/c-en-ste80/docker/agent-notes.md`,
d = `scratchpad/out/p4-d/agent-notes.md`. O `rastreio.md` de d não foi usado como fonte.

## Resumo

| Variante | Veredito | Mantidas | Perdidas | Mudou de sentido | Inventadas | Ambiguidade nova (não muda a regra) |
|---|---|---|---|---|---|---|
| b (concisa) | **fiel** | 53/53 | 0 | 0 | 0 | 0 |
| c (STE 80%) | **fiel com ressalvas** | 53/53 | 0 | 0 | 0 | 3 (R21, R30/R31, R43) |
| d (enxuta) | **fiel com ressalvas** | 53/53 | 0 | 0 | 0 | 2 (R10, R37) |

Conferência mecânica: o conjunto de trechos em crase (`` `…` ``) das três variantes é **idêntico** ao do original
(comandos, caminhos, flags, placeholders, nomes de variáveis), e o bloco `oute-propose` de exemplo é igual byte a byte
nas três, com título e `echo` em pt-BR. Nenhum valor literal mudou. Nenhum "must/never" virou "should": a única
modalidade fraca nova é permissiva onde o original já era ("pode ser feito" → "may be done"/"You can run").

## Regras do original (numeradas)

Canal de aprovação
- R1 Container sem privilégio no host.
- R2 `ssh oute-server` entra como `oute-ops`: só leitura + allowlist de sudo (backup, `nginx -t`/reload, `certbot certificates`, `nft list ruleset`, `lab-journal`).
- R3 Não tente contornar.
- R4 Gatilho: rodar no host como o usuário dele ou com sudo/root.
- R5 Não peça ao usuário para copiar comandos; escreva script e proponha.
- R6 Forma: `OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "título" [--root] <<'SH' … SH`.
- R7 Imprime o `id`.
- R8 `--root` = sudo; sem ele, usuário do host.
- R9 Usuário lê o script inteiro e aprova/recusa no host com `oute approve`.
- R10 Espere e leia o resultado com `oute-inbox --wait <id>`.
- R11 Saída 3 = pendente/expirou.
- R12 Script em bash com `set -euo pipefail`.
- R13 Idempotente.
- R14 Um objetivo por pedido.
- R15 `echo` antes de cada passo.
- R16 Sem segredos no texto.
- R17 Nada interativo.
- R18 Leia o estado antes, via `ssh oute-server`.
- R19 Proponha só o necessário.
- R20 Pedido que remove/recria/para recurso: lista dependentes no próprio script e para sem alterar se achar dependente inesperado; OU vem precedido de ensaio (`--dry-run`/só leitura).
- R21 Pedido pendente obsoleto: avisar o usuário para recusá-lo ANTES de propor o substituto.
- R22 Título do substituto diz que substitui (ex.: "substitui <id>: …").
- R23 Mudança permanente no oute-server: fluxo do repo `lab` (issue → inventário → script → PR).
- R24 Canal serve para diagnóstico, ajustes pontuais e deploy de PR já mergeado.

Memória
- R25 Sempre passar `workspace` e `project` nas ferramentas do ai-memory.
- R26 Valores do `.ai-memory.toml` na raiz do repo (vale em worktree).
- R27 Sem o arquivo: `workspace = "default"`, `project` = basename do `--git-common-dir` sem `/.git`.
- R28 Fora de repo: perguntar ao usuário antes de gravar.
- R29 Motivo: sem escopo, "projeto ativo" compartilhado, talvez de outra sessão/repo.
- R30 `OUTE_MEMORY_RUN=1`: opt-in, desligado por padrão, vale só com ele; sessão interativa da worktree sob `ai-memory run`.
- R31 Cota estourou: sair do claude, `ai-memory run codex` na mesma worktree; recebe o contexto.
- R32 A regra de `workspace`/`project` explícitos continua valendo.

Git
- R33 Sessão em worktree própria (`/workspace/.worktrees/<space>/<repo>-<slug>`, branch `sessao/<slug>`, `<space>`/`_sem-space`), aberta pelo `oute-task`.
- R34 O shell do container já faz isso ao digitar `claude`/`codex` no checkout principal.
- R35 Nunca editar nem trocar de branch no checkout principal; ele fica na branch padrão.
- R36 Se estiver nele (`--git-dir` = `--git-common-dir`): não alterar nada, avisar, sugerir `oute-task <slug>`.
- R37 Única exceção: `git pull --ff-only`, na branch padrão, sem mudança local, sem perguntar.
- R38 Antes do primeiro push, `git branch -m` para `<tipo>/<issue>-<slug>`; tipos feat/fix/chore/docs/refactor/test.
- R39 Commits pequenos, mensagem convencional.
- R40 Entrega por PR (`gh pr create`).
- R41 Merge só quando o usuário pedir.
- R42 `oute-task clean` lista; `--yes` remove; só o space atual; `--space <nome>` outro; `--all` todos, inclusive formato antigo.

Issues e contexto
- R43 Backlog = issues do GitHub do próprio repo, via `gh` (comandos listados).
- R44 Pendência no fim da tarefa vira issue.
- R45 Antes de `gh issue create`, procurar issue aberta (`gh issue list --state open --search …`).
- R46 Se existe, evidência num comentário nela, não issue nova.
- R47 Ler `AGENTS.md` e `CONTEXT.md` na raiz, se existirem.
- R48 Canônico = ADRs em `docs/adr/`; `CONTEXT.md` = resumo com glossário.
- R49 Falta/conflito: perguntar em vez de supor.
- R50 Trabalho segue o AI-DLC (ADR-07), fases `strat` → `iter` com gate humano; skills `oute-aidlc-<fase>-<id>`.
- R51 Não fechar fase com gate sem o ok do usuário.
- R52 Nunca escrever segredos em arquivo, commit, issue, PR ou saída de comando.
- R53 Segredos chegam pelo ambiente.

## Conferência contra as fontes (passo 3 e 5)

| Afirmação (presente nas 4 versões) | Fonte | Resultado |
|---|---|---|
| `oute-propose` imprime o id; `--root` = sudo, senão usuário do host; lê o script do stdin (heredoc) | `docker/oute-propose` (cabeçalho, `as=root`, `echo "$id"`, recusa tty) | fonte confere |
| `OUTE_PROPOSE_AGENT` define o agente | `docker/oute-propose` (`agent="${OUTE_PROPOSE_AGENT:-}"`) | fonte confere |
| `oute-inbox --wait <id>` devolve saída + código; 3 = pendente/expirou | `docker/oute-inbox` (`show` devolve o rc do `# rc:`; `exit 3` ao expirar; `return 3` pendente) | fonte confere |
| Worktree `/workspace/.worktrees/<space>/<repo>-<slug>`, branch `sessao/<slug>`, `_sem-space` | `docker/oute-task` l.15-16, `NO_SPACE=_sem-space` | fonte confere |
| `clean` lista, `--yes` remove, só o space atual; `--space`, `--all` com formato antigo; ff do checkout principal | `docker/oute-task` l.8-13, l.17-18, l.301 | fonte confere |
| Shell abre worktree ao digitar `claude`/`codex` no checkout principal | `docker/entrypoint.sh` l.238 | fonte confere |

Nada nas três variantes contradiz os comandos. Nenhuma afirmação sem fonte além das do próprio original.

## Variante b (tradução concisa)

Tradução praticamente frase a frase. As 53 regras estão presentes, na mesma ordem, com a mesma força ("Never",
"Do not", "only", "always" nos mesmos lugares do original) e com as exceções e condições intactas (R20 com as duas
alternativas; R21 com "before"; R30 com "applies only with it"; R37 com as três condições).

Defeitos: nenhum.

Veredito: **fiel.** Nenhuma regra perdida, invertida ou nova; literais idênticos.

## Variante c (inglês simplificado STE 80%)

As 53 regras estão presentes. A quebra em frases curtas (exigida pelo STE) não muda nenhuma regra, mas solta três
condicionais da frase que as governava, o que um modelo pequeno pode ler de outro jeito:

| # | Tipo | Trecho de c | Original | Risco para Haiku |
|---|---|---|---|---|
| R21 | ambiguidade nova (mantida) | "A pending request can become **obsolete** (…). Tell the user to **reject it before** you propose the replacement request." | "Pedido pendente que ficou **obsoleto** (…): avise o usuário para **recusá-lo antes**…" | A condição virou constatação ("can become") seguida de ordem solta; o "it" depende da frase anterior. Baixo: o sentido segue recuperável. |
| R30/R31 | ambiguidade nova (mantida) | "…is off by default, and the next rule applies only with it. With the opt-in, …runs under `ai-memory run`. If the quota is exhausted, exit claude and run `ai-memory run codex`…" | "Com o opt-in `OUTE_MEMORY_RUN=1` (desligado por padrão; vale só com ele), a sessão… Cota estourou: …" | "the next rule" não diz qual (a frase seguinte? as duas?). O original também não deixa explícito se a troca por cota depende do opt-in; c não piora o escopo, mas introduz uma referência solta. Baixo. |
| R43 | ambiguidade nova (mantida) | "GitHub issues of the **same** repo" | "issues do GitHub do **próprio** repo" | "same" pede um antecedente que não existe; "own"/"this" seria o literal. Muito baixo. |

Nenhuma ordem de passo mudou (R10 mantém "Wait and read"); R20 ganhou "must obey one of these two rules", que só
explicita a alternativa do original (não é condição nova). R37: "without a question" vem antes das condições
("on the default branch and with no local change"), mas as condições continuam todas lá.

Veredito: **fiel com ressalvas.** Nenhuma regra muda de sentido; três pontos de ambiguidade nova, todos de risco baixo.

## Variante d (reescrita enxuta)

As 53 regras estão presentes, inclusive todos os literais e as alternativas de R20, o "before" de R21 e o "Only with"
de R30, que fica até mais claro que o original. Cortes de artigo e verbo não removeram condição. Dois pontos onde a
compressão deixa margem de leitura:

| # | Tipo | Trecho de d | Original | Risco para Haiku |
|---|---|---|---|---|
| R10 | ambiguidade nova (mantida) | "3. Read result (output + exit code): `oute-inbox --wait <id>`." | "3. **Espere** e leia o resultado…" | O verbo "esperar" sumiu da prosa; fica só no `--wait` do comando. Um modelo que parafraseia pode trocar por `oute-inbox <id>` (sem espera, devolve 3 na hora) e concluir "pendente". Baixo-médio. |
| R37 | ambiguidade nova (mantida) | "Only exception: `git pull --ff-only` there, on default branch, no local change, no asking" | "…pode ser feito sem perguntar" | A permissão ficou implícita e "no asking" está na mesma lista das condições: pode ser lido como mais uma condição, ou como "não pergunte". Baixo (o efeito prático é o mesmo). |

Outros cortes conferidos e sem efeito na regra: "Never bypass" (orig. "Não tente contornar": mesma proibição);
"Container shell does it" (sem o "já"); título "Memory (ai-memory): explicit scope" sem o "always", que segue no corpo
em negrito; "(…; always default branch)" em R35 continua descritivo.

Veredito: **fiel com ressalvas.** Nenhuma regra perdida nem invertida; vale devolver o "Wait" de R10.

## Risco comum às três (fora da contagem: não é regra escrita no original)

- **Idioma do texto para o Bardi.** O original não manda escrever em pt-BR; o sinal é implícito (as notas inteiras
  estão em pt-BR). As três variantes mantêm em pt-BR só os exemplos (`"título curto e claro"`, `echo "o que vai
  fazer..."`, `"substitui <id>: …"`, placeholders `<tipo>`, `<nome>`, `<arquivo ou termo>`). Com as notas em inglês,
  um modelo pequeno tende a escrever título de `oute-propose`, `echo` do script, issue, comentário e PR em inglês. Se
  o comportamento esperado é pt-BR, nenhuma das três o garante; isso pede uma regra explícita, ou medição.
- Consumidores do arquivo: `swarm.md` (kaizen, nível `agentes`) e a skill `oute-aidlc-ctx-sync` leem este arquivo pelo
  caminho, não pelos títulos de seção; os títulos traduzidos não quebram referência encontrada por `grep`
  (`docker/comandos.md` tem a própria seção "Memória (ai-memory)", independente).

## O que não consegui conferir

- O comportamento real de um Haiku diante das ambiguidades marcadas: a classificação de risco é leitura, não medição.
- Se o "pt-BR para o Bardi" é requisito: o original não o diz, e não há issue nem PR como fonte aqui.
- `oute approve` (no `scripts/oute` do host) não foi aberto: R9 só foi conferido como texto igual ao original.
