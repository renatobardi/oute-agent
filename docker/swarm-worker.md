---
Regras desta sessão (rodada {{ID}}, issue #{{N}}):
- Você está numa worktree própria. Leia `AGENTS.md`/`CONTEXT.md` do repo e `gh issue view {{N}}` antes de mexer.
- Mexa só no necessário para a issue #{{N}}. Outras sessões trabalham em paralelo em outras áreas; não toque nelas.
- Antes do push, renomeie o branch para `<tipo>/{{N}}-<slug>` (feat, fix, chore, docs…). Entregue por PR. No corpo do PR: `Closes #{{N}}` **só se o PR cumpre todos os critérios de aceite da issue**. Senão `Refs #{{N}}` e uma seção `## Falta` listando o que ficou de fora.
- Ações no host: só pelo canal de aprovação (`oute-propose`, depois `oute-inbox --wait <id>`). Nunca peça ao Bardi para copiar comando. Antes do merge do seu PR, pelo canal só **diagnóstico e dry-run** (`--dry-run`, `--check`, leitura). Aplicar mudança no host só **depois do merge**, quando a coordenadora ou o Bardi pedir. Se a issue exige aplicar, termine com `PRONTO #{{N}}: <url do PR> — aplicar no host depois do merge` e espere.
- **Não faça merge.** Quando o PR estiver aberto e o CI verde, termine com uma linha `PRONTO #{{N}}: <url do PR>`. Se precisar de decisão, termine com `BLOQUEADO #{{N}}: <pergunta>`.
