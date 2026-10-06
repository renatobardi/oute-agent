### Added
- **agent-studio: ack ("visto") de alerta e de decisão pendente pela tela** (#537, ADR-08 §10). **Precisa de release** (o código do agent-studio vai na imagem).
  - Cada item das faixas ganha o botão "Visto", só para o navegador com o cookie de marcação. O item sai da faixa e fica na lista recolhida "vistos", com a hora e a validade.
  - `POST /ack` só reconhece: não resolve alerta, não responde pergunta e não faz o host rodar nada. Usa a credencial de marcação, `Origin` igual ao `Host` e o campo `csrf`; com a credencial de leitura (a do agente) a resposta é 403, e sem a credencial de marcação a rota não existe.
  - O ack vale 24 horas por ocorrência, contadas no servidor, ou até a ocorrência acabar ou mudar; depois o item volta à faixa. Repetir o envio não renova o prazo.
  - Tabela `ack_marks` no DuckDB, só de acréscimo e separada da `action_marks`; a marca não vai ao bucket (com o volume do DuckDB perdido, os itens ativos voltam à faixa). O `oute studio rebuild-state` remonta o `ack` do SurrealDB e imprime uma quarta linha, `vistos: marcas=<n> antes=<n> depois=<n>`.
  - O `GET /v1/alerts` e o `GET /v1/tray` não mudam.

### Changed
- **agent-studio: o cookie de marcação passa de `Path=/rodada` para `Path=/`** (#537), mantendo `HttpOnly`, `Secure` e `SameSite=Strict`. A entrada de marcação apaga o cookie antigo. Quem já tinha entrado para marcar ações cola a credencial de novo em `/marcar` para o botão "Visto" aparecer. **Precisa de release.**
