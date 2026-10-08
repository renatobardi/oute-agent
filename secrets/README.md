# Segredos — Vaultwarden (vault.oute.pro) é a única fonte

Nenhum valor real vive neste repo. Três pastas no vault, cada uma com um destino:

| pasta | vai para | quem recebe |
|---|---|---|
| `oute-agent` | `~/.oute/agent.env` → `/run/secrets/agent_env` | o container `agent` (agentes em yolo) |
| `oute-services` | `~/.oute/services.env` | só os serviços do compose (`agent-studio`, `surrealdb`, `otel-collector`, `llm-proxy`); **nunca o `agent`** |
| `oute-admin` | nada em disco | só o `oute oci-bootstrap` |

**Segredo novo: em que pasta?** (ADR-01, adendo #256) Pergunte "o agente usa?". Se só um serviço usa, ou se o valor dá **escrita** em algo que o Bardi lê para decidir (telemetria, estado de pedido), é `oute-services`. Na dúvida, `oute-services`. Nome que existe na `oute-services` nunca entra no `agent.env`, mesmo repetido na `oute-agent`.

Pasta `oute-agent`:

| item        | tipo | campos (custom fields)                                                       |
|-------------|------|-------------------------------------------------------------------------------|
| github      | Note | GH_TOKEN; GHCR_TOKEN (token clássico só `read:packages` — `oute pull` da imagem privada no ghcr) |
| oci         | Note | OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM — opcional, usuário **restrito** p/ os agentes (nunca o admin) |
| oci-storage | Note | OCI_S3_ACCESS_KEY, OCI_S3_SECRET_KEY, OCI_S3_ENDPOINT, OCI_S3_REGION, OCI_NAMESPACE — **criado pelo `oute oci-bootstrap`**, não à mão |
| aws         | Note | AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION                  |
| gcp         | Note | GCP_SA_JSON (service account, cobre gcloud + firebase)                        |
| ai-memory   | Note | AI_MEMORY_AUTH_TOKEN (opcional)                                               |
| anthropic   | Note | ANTHROPIC_API_KEY (só se quiser ai-memory consolidando com LLM)               |
| typesafe    | Note | OUTE_TYPESAFE_API_KEY (opcional): chave da API da TypeSafe, com que o seletor chama o Jev para classificar a fase de sessão sem label (ADR-02, #257). Sem ela o `oute up` sobe igual e a sessão sem label abre no Sonnet, com aviso. Só o `oute-select` a usa, no cabeçalho da chamada: nunca em argumento, log ou evento. O prefixo `OUTE_` é o que a leva ao ambiente dos logins (allowlist do `entrypoint.sh`) |
| zai         | Note | OUTE_ZAI_API_KEY (opcional; campo oculto): chave da API do GLM Coding Plan da Z.ai (assinatura `zai`, ADR-02 e ADR-01, adendos de 2026-10-05). Só o ambiente do processo da sessão `zai` (`oute-task`, shim, `oute-swarm`) e do `oute-regression --subscription zai` a usa, como `ANTHROPIC_AUTH_TOKEN`; o `oute-quota` e o seletor também a leem do ambiente. Nunca em argv, log, marca ou evento. Sem ela, `--subscription zai` sai com erro e a sessão abre nas outras assinaturas. |
| sonar       | Note | SONAR_TOKEN (opcional; campo oculto), OUTE_SONAR_ORG (opcional; hoje `renatobardi`): o `oute-sonar` lê com eles o gate, as issues e os hotspots do SonarCloud (#226). Só leitura (`GET`); a chave do projeto sai do repo (ou `OUTE_SONAR_PROJECT`). Token de uma conta técnica com `Browse` + `See Source Code`; no plano Free ele herda do grupo Members o `Administer Issues` (risco aceito, ADR-01 adendo #226). Sem ele o `oute up` sobe igual e o `oute-sonar` sai com 3. O prefixo `SONAR_` (e `OUTE_`) é o que o leva ao ambiente dos logins (allowlist do `entrypoint.sh`). Nunca em argumento, log ou saída |
| agent-studio | Note | AGENT_STUDIO_READ_TOKEN: credencial **só de leitura** do agent-studio (`GET /v1/usage`, `/v1/alerts`, `/v1/tray` e a tela; na ingestão = 403). Valor próprio: igual à de ingestão, o `oute up` não entrega ao `agent` |

Pasta **`oute-services`** (#256; nunca vai ao `agent`):

| item         | tipo | campos (custom fields) |
|--------------|------|------------------------|
| agent-studio | Note | AGENT_STUDIO_INGEST_TOKEN (credencial de ingestão: só o collector manda com ela, nos dois hosts); AGENT_STUDIO_SURREAL_PASS (root do SurrealDB, só no oute-server); AGENT_STUDIO_JEV_KEY (#749, opcional; campo oculto: a chave da TypeSafe com que o agent-studio chama o Jev para dar a fase às conversas sem sinal forte; é o mesmo valor da `OUTE_TYPESAFE_API_KEY` do `agent`, posto aqui porque só o serviço a usa nessa chamada. Sem ela o Jev não é chamado e a conversa fica de baixa confiança; nunca em argumento, log, issue ou saída); AGENT_STUDIO_MARK_TOKEN (#510, opcional; campo oculto: credencial de **marcação**, a terceira, com que o Bardi marca uma ação da página da rodada como feita, `POST /rodada/acao`. Valor próprio, diferente da de ingestão e da de leitura (igual a uma delas, o agent-studio a descarta). Só o serviço `agent-studio` a recebe; **nunca o `agent`**, que tem a de leitura e alcança o studio pela rede docker. Sem ela o `oute up` sobe igual e a rota não existe: as caixas ficam só para leitura. O Bardi a cola uma vez por aparelho em `/marcar`, depois de entrar com a de leitura (Mac e celular); o cookie dela é `HttpOnly`, `Secure`, `SameSite=Strict`. Nunca em argumento, log, issue ou saída) |
| openrouter-memoria | Note | OPENROUTER_MEMORY_API_KEY (#459): chave **nova** do OpenRouter, só para o LLM do ai-memory, com teto de gasto definido no OpenRouter. Só o serviço `llm-proxy` a recebe (profile `llm-proxy`, nos dois hosts): nem o `agent`, nem o `ai-memory`, nem o collector. Não confundir com `OPENROUTER_API_KEY`, que segue no `agent` e no `agent-studio`. Sem ela o `oute up` sobe igual, sem o proxy, e o ai-memory segue sem LLM. Nunca em argumento, log, span ou saída de erro |

Transição: sem a pasta `oute-services`, o `oute up` sobe, tira do `agent.env` os nomes de serviço conhecidos (`AGENT_STUDIO_SURREAL_PASS`, `AGENT_STUDIO_INGEST_TOKEN`, `AGENT_STUDIO_MARK_TOKEN` e o `AGENT_STUDIO_TOKEN` de antes da #256), guarda-os no `services.env` e avisa. O `AGENT_STUDIO_TOKEN` antigo segue valendo como ingestão até a credencial nova existir.

### Rotação da senha root do SurrealDB (oute-server)

A senha só vale na criação do volume do SurrealDB, então trocar o campo no vault não basta: o volume é recriado e o estado, remontado do DuckDB (ADR-08 §7). Rodada de 2026-10-03 (#256, #427). Tudo no oute-server, sem escrever a senha em comando, arquivo, issue ou log.

0. Antes de começar, rode `oute studio rebuild-state` e guarde a linha `depois:` da saída (rodadas, workers, sessoes, pedidos, conversas). É a referência do passo 5.
1. Senha nova em `AGENT_STUDIO_SURREAL_PASS`, no item `agent-studio` da pasta `oute-services` do vault.
2. `oute up --refresh-secrets` (grava o `services.env`; pede a master password).
3. Libere o volume `oute-agent_oute-surrealdb`:
   - `docker stop oute-agent-studio`;
   - `docker rm -f oute-surrealdb oute-volume-init`: o one-off `oute-volume-init`, mesmo parado, também segura o volume, e sem remover os dois o `docker volume rm` falha (sem apagar nada);
   - `docker volume rm oute-agent_oute-surrealdb`.
4. `oute up`. Com o `oute-surrealdb` saudável (`docker ps`), rode `oute studio rebuild-state`. Enquanto o agent-studio está parado, o collector guarda a ingestão na fila em disco.
5. Confira a linha `antes:` (deve ser zerada: volume novo) e compare a `depois:` com a do passo 0: rodadas e o resto não podem ser menores; a diferença a mais é o que entrou no intervalo (em 2026-10-03: 35/130/118/55/158 antes, 35/132/120/58/160 depois). Confira também o studio sem alertas e as telas respondendo.

Se o `rebuild-state` falhar, rodar de novo termina (o que já entrou fica). Não apague a telemetria do bucket `oute-observability` em nenhum passo.

Pasta **`oute-admin`** (separada, NUNCA exportada pro container; só o `oute oci-bootstrap` lê):

| item      | tipo | campos |
|-----------|------|--------|
| oci-admin | Note | OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM (API key do seu usuário OCI; o PEM pode ser colado numa linha só — é reconstruído) |

No host (Mac / LXC), só dois arquivos fora do repo:

```
~/.oute/bw_client.env     # BW_CLIENTID=user.xxx  BW_CLIENTSECRET=xxx   (chmod 600)
~/.ssh/id_ed25519.pub     # chave que entra no container
```

`~/.oute/agent.env` e `~/.oute/services.env` (0600, gerados pelo host) são o cache: `oute up`, `pull` e `sync-shared`/`storage` leem só eles, sem vault e sem senha. Uma senha abre as duas pastas. A master password é pedida só quando o vault é aberto — `oute secrets refresh` (ou `up --refresh-secrets`, ou `up` sem `agent.env`) e `oute oci-bootstrap` — e a sessão é trancada (`bw lock`) logo depois; nada de sessão em disco. Mudou um segredo no vault? `oute secrets refresh` e `oute restart`. `BW_PASSWORD` no ambiente pula o prompt.
