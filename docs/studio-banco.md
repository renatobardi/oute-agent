# Leitura do banco do agent-studio (#829)

Padrão para ler os dados do DuckDB do agent-studio (tabelas `logs` e `spans`) quando a pergunta é de dados: contagem,
lista de eventos, uma janela de dias. Leia antes de propor script de leitura no canal de aprovação. O que está aqui
já falhou sem isso: o `python3` do sistema não tem o `duckdb` (`ModuleNotFoundError`), e filtrar a coluna de data com
fuso dá a janela errada.

## Onde está

- Arquivo: `/data/agent-studio/agent-studio.duckdb` dentro do container `oute-agent-studio` (`AGENT_STUDIO_DB` em
  `docker/compose.yaml`). No host, a pasta é `OUTE_AGENT_STUDIO_DIR` (no `.env`).
- Python: `/opt/agent-studio/venv/bin/python`, o venv da imagem, que tem o `duckdb`. Não use o `python3` do sistema.

## Janela pelo tempo do fato

- Filtre pela coluna `time_unix_nano` (inteiro, nanossegundos desde 1970), não pela coluna `time` (com fuso). É a hora
  do fato, como no ADR-08 (janela pela hora do fato).
- Converta as datas de entrada em nanossegundos no próprio Python, em inteiro: `int(datetime(...).timestamp()) * 10**9`.

## Comando pronto

Pedido de leitura pelo canal (`oute-propose`, no host). Só lê: `read_only=True`, nenhuma escrita.

```bash
set -euo pipefail
# RESUMO
# Faz: conta os logs do agent-studio por host num dia (UTC). Host: oute-server. Altera: nada (leitura). Não toca: o DuckDB nem o serviço. Reinicia: nada.
echo "1/1: conta os logs de 2026-10-11 (UTC) por host"
docker exec -i oute-agent-studio /opt/agent-studio/venv/bin/python - <<'PY'
import duckdb
from datetime import datetime, timezone
ini = int(datetime(2026, 10, 11, tzinfo=timezone.utc).timestamp()) * 10**9
fim = int(datetime(2026, 10, 12, tzinfo=timezone.utc).timestamp()) * 10**9
con = duckdb.connect("/data/agent-studio/agent-studio.duckdb", read_only=True)
for host, n in con.execute("SELECT host_name, count(*) FROM logs WHERE time_unix_nano >= ? AND time_unix_nano < ? GROUP BY 1 ORDER BY 1", [ini, fim]).fetchall():
    print(host, n, sep="\t")
PY
```

Não verificado: abrir o DuckDB com o serviço no ar (ele é o escritor único). Se o `duckdb.connect` recusar por lock, a
leitura para aí e o relatório diz isso. Não copie o arquivo nem pare o serviço para ler sem o pedido do Bardi.
