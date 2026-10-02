# ADR-03 — Storage comum no OCI Object Storage (issue #1)

Status: **aceito · implantado no oute-server** (2026-09-24). Mac pendente (#3).

## Contexto
- `/data/shared` no container era `~/.oute/shared` local (remote `oci` nunca configurado).
- O mesmo OCI Object Storage recebe a observabilidade (#13): bucket de traces via API S3-compatível.
- Regras do projeto: segredos só no Vaultwarden; retenção = corrente + anterior; nenhuma porta pública fora do nginx.
- Backup do lab (restic → gdrive) **não cobre** os volumes do oute-agent (`oute-home`, `oute-workspace`, `oute-memory`) → candidato a usar este storage depois.

## Custo (2026-09)
Always Free: 20 GB (todas as classes somadas) + 50 mil requests/mês; egress 10 TB/mês.
Acima: Standard ~US$0,0255/GB·mês; Infrequent ~US$0,01 (+retrieval, retenção mínima); Archive ~US$0,0026 (mín. 90 dias).
Estimativa: US$0 no início; ~US$0,77 (50 GB) a ~US$2 (100 GB). Risco é request, não espaço → cache longo no rclone (`--dir-cache-time 5m`), batch no Collector. Budget US$1/mês com alertas ACTUAL + FORECAST (100%) → e-mail do Bardi.

## Estado implantado (tenancy)
- Região `sa-saopaulo-1`, namespace `<namespace>`, endpoint S3 `https://<namespace>.compat.objectstorage.sa-saopaulo-1.oraclecloud.com`.
- Tenancy usa **Identity Domains** (API IAM clássica funciona no Default domain, mas exige e-mail no usuário).
- Usuário de serviço `oute-agent-storage` com e-mail `<e-mail do usuário de serviço>`.

## Decisões
1. **Compartment** `oute-agent` (isolamento de IAM e custo).
2. **Buckets** privados:

   | bucket | classe | versionamento | lifecycle |
   |---|---|---|---|
   | `oute-shared` | Standard | on | apaga versões não-correntes > 30 dias (≈ corrente + anterior) |
   | `oute-observability` | Standard | off | → Infrequent 30d → Archive 90d (#13) |

3. **Identidades (menor privilégio)**
   - Admin: API key do Bardi no vault, pasta **`oute-admin`**, item `oci-admin` — **nunca exportada pro container** (a pasta `oute-agent` inteira vira env dos agentes). Só o bootstrap lê.
   - ~~Broadcast do OpenRouter (#13): chave própria, só escrita no `oute-observability` (definir na #13).~~ *(histórico: nunca foi criada; o ADR-04 ficou com o pull via API, e o OpenRouter saiu do stack na #218)*
   - Usuário de serviço `oute-agent-storage` (grupo homônimo; só Customer Secret Key). Policies na raiz: `read buckets` + `manage objects` só nos 2 buckets do compartment. Mais `Allow service objectstorage-sa-saopaulo-1 to manage object-family in compartment oute-agent` (lifecycle).
4. **Segredos** — item `oci-storage` (pasta `oute-agent`), **criado pelo bootstrap** (JSON → `bw encode` → `bw create item` por stdin; nada em log/argv): `OCI_S3_ACCESS_KEY`, `OCI_S3_SECRET_KEY`, `OCI_S3_ENDPOINT`, `OCI_S3_REGION`, `OCI_NAMESPACE`.
   rclone **só por env** (`RCLONE_CONFIG_OCI_TYPE=s3`, `PROVIDER=Other`, `FORCE_PATH_STYLE=true`, `NO_CHECK_BUCKET=true`) no host e no container → sem `rclone.conf` com segredo.
5. **Montagem** — `oute up` monta, `oute down` desmonta:
   - oute-server: `rclone mount` no host (rclone 1.60.1 do apt), `--allow-other` (`user_allow_other` habilitado em `/etc/fuse.conf`), `--vfs-cache-mode full`, `--vfs-cache-max-size ${OUTE_SHARED_CACHE:-2G}`, `--dir-cache-time 5m`, log em `~/.oute/rclone.log`.
   - **Mac: mount com FUSE-T** (userspace, sem kext; fallback macFUSE). rclone do rclone.org (o do Homebrew não tem `mount`).
   - Sem `bind.propagation` no compose: ordem mount → compose up / compose down → umount; se o rclone cair com o container rodando, `oute restart`.
6. **Provisionamento** — `oute oci-bootstrap` (`scripts/oci-bootstrap.sh`, oci-cli da imagem, idempotente, `DRY_RUN=1`). Confere policies (só atualiza se mudou), lifecycle, chave e alertas do budget em toda execução.
7. `oute storage [ls|lsl|about] [path]` lista o bucket direto no OCI (confere o que o mount enviou).

## Validação (2026-09-24, oute-server)
Host grava `~/.oute/shared/hello.txt` → container lê `/data/shared/hello.txt` → `oute storage lsl` mostra o objeto no bucket (38 bytes). Nenhum erro no `rclone.log` após a chave propagar.

## Lições
- Customer Secret Key leva **alguns minutos** para ativar: 403 `SignatureDoesNotMatch` ("secret key … could not be found") logo após criar é normal.
- Policy nova para o service principal do Object Storage leva ~15s para propagar (lifecycle falha na 1ª tentativa; script faz retry).
- PEM baixado do console termina com a linha `OCI_API_KEY` depois do `END`; custom field do Vaultwarden perde quebras de linha → reconstruir só o trecho BEGIN..END.
- Sessão `bw` em cache não sincroniza: pasta/item criado depois do último sync não aparece → `bw sync` antes de ler.
- oci-cli: budget é `oci budgets budget budget …` (o grupo se repete); `policy update` exige `--statements` + `--version-date` juntos; JMESPath sem resultado imprime `null`.

## Pendências
- Mac (#3): FUSE-T + Docker Desktop enxergar o mount; fallback `rclone bisync`.
- Rebuild da imagem para o container ter o remote `oci` no `rclone` (entrypoint novo).
- Backup dos volumes do oute-agent usando este storage (issue futura).
