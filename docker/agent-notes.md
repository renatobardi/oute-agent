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
