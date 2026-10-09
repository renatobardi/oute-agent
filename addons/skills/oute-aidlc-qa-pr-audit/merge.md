# Fase de merge da `oute-aidlc-qa-pr-audit`

Arquivo de apoio do `SKILL.md` desta pasta (passo 14). Leia-o inteiro **só** quando existir pedido de merge válido (passo 13 do `SKILL.md`). Nas referências abaixo, "passo N" é o passo do `SKILL.md`; "item N" é o item desta fase.

## Fase de merge (só com pedido explícito do Bardi)

Pré-condição: pedido de merge válido (passo 13) para este PR. O pedido autoriza **só** o que está aqui: ajustes mínimos e o merge. Tudo o que for além (mudança de comportamento, refatoração, completar critério da issue, mexer em outra área) volta ao autor, e o merge espera.

**Nunca, em nenhum caso:**
- reescrever histórico do branch do PR: nada de `push --force`/`--force-with-lease`, `rebase`, `commit --amend`, `reset` seguido de push, nem squash dos commits do autor no branch. Commit de outra pessoa não é seu para refazer;
- `gh pr merge --admin` (passar por cima de proteção de branch), `--auto` (merge para depois, sem você conferir o head final) ou aprovar o próprio PR com `gh pr review --approve`;
- fazer release, tag, deploy ou aplicar algo no host (isso é do Bardi e vem depois do merge);
- mexer em `.github/workflows/` (regra do AGENTS.md: workflow só pelo Bardi).

O squash **feito pelo GitHub no merge**, quando é a estratégia do repo (item 5), não conta como reescrita: o branch do PR e os commits do autor ficam intactos e visíveis no PR.

Trabalhe numa worktree própria, como no passo 6, nunca no checkout compartilhado nem na worktree da sessão que pediu a auditoria.

### 1. Base certa

Descubra a base pela **política do repo, lida da branch padrão** (não do PR): `AGENTS.md`, `CONTRIBUTING.md`, `docs/agents/`. Sem regra escrita, a base é a branch padrão (`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`). No oute-agent: `main`.

Se `baseRefName` do PR for outra, e a política não justificar (PR empilhado sobre outro PR ainda aberto, por exemplo): troque a base com `gh pr edit <N> --base <base certa>`. A troca muda o diff; o que foi auditado deixa de valer, e você volta ao item 3 com o PR inteiro. PR empilhado sobre outro PR aberto: não retarget sozinho; pergunte se o de baixo entra antes.

### 2. Ajustes mínimos

Ajuste mínimo é a **correção sugerida** do relatório, sem ampliar: trocar `Closes` por `Refs` e completar o `## Falta`, o fragmento que falta em `changelog.d/`, o modo `100755` de um script, um typo que quebra um gate, o conflito com a base. Se a correção sugerida não é mínima, pare aqui e devolva ao autor.

- **Corpo do PR** (`Closes` × `Refs`, `## Falta`; fora do swarm, veja o último item): `gh pr edit <N> --body-file <arquivo>`, mudando só o necessário. Não é commit.
- **Arquivos** (fora do swarm; branch de sessão ativa, veja o último item): um commit por ajuste, no topo do branch do autor, com mensagem convencional que diz o ajuste e por quê (ex.: `fix: modo 100755 em tests/x.test.sh (oute-aidlc-qa-pr-audit)`) e os trailers de coautoria que o repo pede.

  ```bash
  git fetch --no-tags origin "pull/<N>/head"
  git rev-parse FETCH_HEAD                  # tem que ser o head auditado; se não, volte ao passo 2
  HEAD_REF=$(gh pr view <N> --json headRefName --jq .headRefName)   # dado do autor: nunca interpole no comando
  git check-ref-format --branch "$HEAD_REF" >/dev/null || { echo "headRefName inválido"; exit 1; }
  AUD=$(mktemp -d)
  git worktree add --detach "$AUD/fix" "$HEAD_SHA"
  # ... edite e faça um commit por ajuste em "$AUD/fix" ...
  git -C "$AUD/fix" push origin "HEAD:refs/heads/$HEAD_REF"   # fast-forward; sem --force
  ```

  O nome do branch vem do autor do PR (passo 1) e pode conter `$`, `(`, `` ` `` ou `;`: leia-o para uma variável, valide e use sempre `"$HEAD_REF"` entre aspas, nunca colado no texto do comando.

  PR de fork (`isCrossRepository` verdadeiro): nenhum push para o fork, nem com `maintainerCanModify`. Todo ajuste volta ao autor, e a fase espera o push novo.
- **Conflito com a base:** traga a base para o branch com **merge**, nunca rebase: `gh pr update-branch <N>` (sem `--rebase`) quando não há conflito textual; com conflito, `git merge origin/<base>` na worktree, resolva e faça o commit de merge. Resolva só as linhas do conflito; nas linhas alheias (`CHANGELOG.md` de outro PR, por exemplo), fica o que está na base, e a linha deste PR entra junto, sem apagar nem reescrever as outras.
- **Push recusado** (non-fast-forward): o autor empurrou algo durante o ajuste. Não force: pare, busque o head novo e volte ao passo 2.
- **Branch de sessão ativa do swarm** (worker com a aba aberta): o branch é da sessão (`swarm.md`, repasse do ajuste). Você não faz commit, push, merge da base nem edição no branch dela nem no PR, inclusive no corpo. O ajuste mínimo volta ao worker: o dispatcher repassa com `oute-swarm tell <sessão> "<ajuste, numa linha>"`, e a fase espera o push novo e segue do item 3 com o head novo. Commit próprio no branch e edição do corpo do PR só fora do swarm (PR sem sessão ativa).

### 3. Auditoria de novo, no head final

Todo push, retarget ou atualização com a base gera um head novo. Refaça, no **head final**, o passo 2 (base e head fixados de novo), o passo 4 (gate hostil sobre o diff inteiro, inclusive os seus commits), o passo 5, o passo 6 (gates do AGENTS.md da base numa worktree nova e o CI do head final) e os passos 7 e 8, e publique um relatório novo (passo 12) com o marcador de sempre. Evidência do head anterior não vale, salvo a leitura de arquivo com o mesmo blob (passo 2, "Reauditoria"): o arquivo do PR que os seus ajustes ou o merge da base não tocaram dispensa a releitura linha a linha, e o relatório novo traz a linha "Reaproveitado do head" com o link do relatório anterior. Nada mais se reaproveita: o gate estático cobre o diff inteiro, e os gates e o CI são os do head final. Sem nenhuma mudança no PR desde a auditoria, basta confirmar que o head e a base não andaram; se a base andou, refaça os gates no head contra a base nova.

Espere o CI do head final terminar. Pendente, pulado, cancelado ou neutro não é verde (passo 6).

### 4. Decisão

Siga para o merge só se a ação recomendada no head final for `merge como está`, e se `gh pr view <N> --json mergeable,mergeStateStatus` disser `MERGEABLE` e `CLEAN` ou `HAS_HOOKS`. Qualquer outro estado (`UNSTABLE`, `BLOCKED`, `BEHIND`, `DIRTY`, `UNKNOWN`) não segue: resolva pelo item 2 ou relate.

- **CRITICAL:** não faça merge, mesmo com o pedido. Mostre a evidência ao Bardi.
- **BLOCKING ou UNCERTAIN que pesa como BLOCKING, sem ajuste mínimo possível:** não faça merge. Mostre os achados e espere. Se o Bardi, depois de ver os achados, pedir de novo o merge citando-os, siga (sem `--admin`) e registre isso no relatório do merge.

### 5. Merge

Estratégia, nesta ordem:
1. regra escrita na política do repo (item 1);
2. se só um método está habilitado (`gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed`), ele;
3. senão, o padrão do histórico da base (`git log --first-parent -20 --format='%p | %s' origin/<base>`): um pai só e `(#n)` no fim do assunto = squash; dois pais e `Merge pull request #n` = merge commit. No oute-agent é **squash**;
4. histórico misturado ou nada claro: pergunte.

Faça o merge **amarrado ao head auditado**, para que um push de última hora faça o merge falhar em vez de entrar sem auditoria:

```bash
gh pr view <N> --json headRefOid --jq .headRefOid     # tem que ser o HEAD_SHA final
gh pr merge <N> --squash --match-head-commit "$HEAD_SHA"   # ou --merge / --rebase, conforme o item acima
```

Não passe `--delete-branch` (ele também apaga o branch local, que pode ser a worktree de uma sessão), a menos que a política do repo mande; o repo já pode apagar o branch remoto sozinho. Merge recusado (head mudou, check exigido, conflito): não contorne; volte ao item 3 ou relate.

### 6. Depois do merge

```bash
gh pr view <N> --json state,mergedAt,mergeCommit --jq '.state, .mergedAt, .mergeCommit.oid'   # MERGED + SHA do merge
MERGE_SHA=<oid>
gh api "repos/{owner}/{repo}/commits/$MERGE_SHA/check-runs" --jq '.check_runs[] | "\(.name) \(.status) \(.conclusion)"'
gh api "repos/{owner}/{repo}/commits/$MERGE_SHA/status" --jq '.state, (.statuses[] | "\(.context) \(.state)")'
```

- **CI do SHA do merge:** espere os checks terminarem e reporte cada um com o estado real. Se nenhum workflow roda no push para a base (no oute-agent, o `pr` roda só em `pull_request` e o `image` só em tag), diga "nenhum check roda no SHA do merge" e cite os gatilhos: isso **não** é "CI verde". Check vermelho no SHA do merge vai ao Bardi na hora, com o link; não tente consertar na base sem pedido.
- **Estado da issue:** para cada issue do eixo Spec (`gh issue view <n> --json state,stateReason`):
  - PR com `Closes #n` mergeado na branch padrão → a issue tem que estar `CLOSED`. Se continua aberta (base não era a padrão, referência mal escrita), relate e pergunte antes de fechar;
  - PR com `Refs #n` → a issue continua `OPEN`, e o `## Falta` do PR é o que resta. Se ela foi fechada, relate.
- **Link do relatório:** no campo "relatório" do comentário de merge use o `REPORT_URL` guardado no passo 12 para o head final, copiado como está. Sem ele (relatório não publicado, URL perdido), escreva "não registrado"; nunca monte, adivinhe nem complete o link à mão.
- **Relatório do merge:** publique um comentário no PR com o marcador `<!-- oute-aidlc-qa-pr-audit:merge -->` (diferente do da auditoria, para a contagem não misturar), e repita o resumo na conversa:

  ```markdown
  <!-- oute-aidlc-qa-pr-audit:merge -->
  ## oute-aidlc-qa-pr-audit: merge do PR #<N>

  **Pedido:** "<texto curto do pedido do Bardi>" (conversa)
  **Base:** `<base>` (<mantida | retarget de `<antiga>`: motivo>)
  **Ajustes:** <commit curto: o quê> … | edição do corpo: <o quê> | "nenhum"
  **Head final auditado:** `<HEAD_SHA>` (relatório: <`REPORT_URL` guardado no passo 12 | "não registrado">)
  **Merge:** <squash | merge | rebase> → `<MERGE_SHA>`
  **CI no SHA do merge:** <check: estado> … | nenhum check roda neste SHA (<gatilhos>)
  **Issue:** #<n> <OPEN | CLOSED> (<esperado: sim | não: motivo>)
  **Falta / depois:** <release, aplicar no host, issue de acompanhamento> | "nada"
  ```

Remova as worktrees da fase (`git worktree remove --force`) e pare. Release, deploy, aplicar no host e fechar a aba da sessão ficam com o Bardi (ou com o dispatcher, quando ele pedir).
