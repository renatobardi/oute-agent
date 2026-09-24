# Segredos — Vaultwarden (vault.oute.pro) é a única fonte

Nenhum valor real vive neste repo. Estrutura esperada no vault, pasta `oute-agent`:

| item        | tipo | campos (custom fields)                                                       |
|-------------|------|-------------------------------------------------------------------------------|
| openrouter  | Note | OPENROUTER_API_KEY                                                            |
| github      | Note | GH_TOKEN; GHCR_TOKEN (token clássico só `read:packages` — `oute pull` da imagem privada no ghcr) |
| oci         | Note | OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM — opcional, usuário **restrito** p/ os agentes (nunca o admin) |
| oci-storage | Note | OCI_S3_ACCESS_KEY, OCI_S3_SECRET_KEY, OCI_S3_ENDPOINT, OCI_S3_REGION, OCI_NAMESPACE — **criado pelo `oute oci-bootstrap`**, não à mão |
| aws         | Note | AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION                  |
| gcp         | Note | GCP_SA_JSON (service account, cobre gcloud + firebase)                        |
| langfuse    | Note | LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_HOST (opcional; default `https://cloud.langfuse.com`) — liga o painel de metadados (#13) |
| ai-memory   | Note | AI_MEMORY_AUTH_TOKEN (opcional)                                               |
| anthropic   | Note | ANTHROPIC_API_KEY (só se quiser ai-memory consolidando com LLM)               |

Pasta **`oute-admin`** (separada, NUNCA exportada pro container; só o `oute oci-bootstrap` lê):

| item      | tipo | campos |
|-----------|------|--------|
| oci-admin | Note | OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM (API key do seu usuário OCI; o PEM pode ser colado numa linha só — é reconstruído) |

No host (Mac / LXC), só dois arquivos fora do repo:

```
~/.oute/bw_client.env     # BW_CLIENTID=user.xxx  BW_CLIENTSECRET=xxx   (chmod 600)
~/.ssh/id_ed25519.pub     # chave que entra no container
```

Master password é pedida no primeiro `oute up`; a sessão desbloqueada fica em `~/.oute/bw_session` (0600) e é reutilizada até `oute lock` ou expirar. `BW_PASSWORD` no ambiente pula o prompt.
