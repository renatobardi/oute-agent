# Segredos — Vaultwarden (vault.oute.pro) é a única fonte

Nenhum valor real vive neste repo. Três pastas no vault, cada uma com um destino:

| pasta | vai para | quem recebe |
|---|---|---|
| `oute-agent` | `~/.oute/agent.env` → `/run/secrets/agent_env` | o container `agent` (agentes em yolo) |
| `oute-services` | `~/.oute/services.env` | só os serviços do compose (`agent-studio`, `surrealdb`, `otel-collector`); **nunca o `agent`** |
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
| langfuse    | Note | LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_HOST (opcional; default `https://cloud.langfuse.com`) — liga o painel de metadados (#13) |
| ai-memory   | Note | AI_MEMORY_AUTH_TOKEN (opcional)                                               |
| anthropic   | Note | ANTHROPIC_API_KEY (só se quiser ai-memory consolidando com LLM)               |
| typesafe    | Note | OUTE_TYPESAFE_API_KEY (opcional): chave da API da TypeSafe, com que o seletor chama o Jev para classificar a fase de sessão sem label (ADR-02, #257). Sem ela o `oute up` sobe igual e a sessão sem label abre no Sonnet, com aviso. Só o `oute-select` a usa, no cabeçalho da chamada: nunca em argumento, log ou evento. O prefixo `OUTE_` é o que a leva ao ambiente dos logins (allowlist do `entrypoint.sh`) |
| sonar       | Note | SONAR_TOKEN (opcional; campo oculto), OUTE_SONAR_ORG (opcional; hoje `renatobardi`): o `oute-sonar` lê com eles o gate, as issues e os hotspots do SonarCloud (#226). Só leitura (`GET`); a chave do projeto sai do repo (ou `OUTE_SONAR_PROJECT`). Token de uma conta técnica com `Browse` + `See Source Code`; no plano Free ele herda do grupo Members o `Administer Issues` (risco aceito, ADR-01 adendo #226). Sem ele o `oute up` sobe igual e o `oute-sonar` sai com 3. O prefixo `SONAR_` (e `OUTE_`) é o que o leva ao ambiente dos logins (allowlist do `entrypoint.sh`). Nunca em argumento, log ou saída |
| agent-studio | Note | AGENT_STUDIO_READ_TOKEN: credencial **só de leitura** do agent-studio (`GET /v1/usage`, `/v1/alerts`, `/v1/tray` e a tela; na ingestão = 403). Valor próprio: igual à de ingestão, o `oute up` não entrega ao `agent` |

Pasta **`oute-services`** (#256; nunca vai ao `agent`):

| item         | tipo | campos (custom fields) |
|--------------|------|------------------------|
| agent-studio | Note | AGENT_STUDIO_INGEST_TOKEN (credencial de ingestão: só o collector manda com ela, nos dois hosts); AGENT_STUDIO_SURREAL_PASS (root do SurrealDB, só no oute-server) |

Transição: sem a pasta `oute-services`, o `oute up` sobe, tira do `agent.env` os nomes de serviço conhecidos (`AGENT_STUDIO_SURREAL_PASS`, `AGENT_STUDIO_INGEST_TOKEN` e o `AGENT_STUDIO_TOKEN` de antes da #256), guarda-os no `services.env` e avisa. O `AGENT_STUDIO_TOKEN` antigo segue valendo como ingestão até a credencial nova existir.

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
