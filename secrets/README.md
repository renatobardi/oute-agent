# Segredos — Vaultwarden (vault.oute.pro) é a única fonte

Nenhum valor real vive neste repo. Estrutura esperada no vault, pasta `oute-agent`:

| item        | tipo | campos (custom fields)                                                       |
|-------------|------|-------------------------------------------------------------------------------|
| openrouter  | Note | OPENROUTER_API_KEY                                                            |
| github      | Note | GH_TOKEN                                                                      |
| oci         | Note | OCI_USER_OCID, OCI_TENANCY_OCID, OCI_FINGERPRINT, OCI_REGION, OCI_KEY_PEM     |
| aws         | Note | AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION                  |
| gcp         | Note | GCP_SA_JSON (service account, cobre gcloud + firebase)                        |
| ai-memory   | Note | AI_MEMORY_AUTH_TOKEN (opcional)                                               |
| anthropic   | Note | ANTHROPIC_API_KEY (só se quiser ai-memory consolidando com LLM)               |

No host (Mac / LXC), só dois arquivos fora do repo:

```
~/.oute/bw_client.env     # BW_CLIENTID=user.xxx  BW_CLIENTSECRET=xxx   (chmod 600)
~/.ssh/id_ed25519.pub     # chave que entra no container
```

Master password é pedida no `oute up` (ou `BW_PASSWORD` no ambiente).
