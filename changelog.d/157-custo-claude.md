### Fixed
- **agent-studio: custo real do Claude no `/v1/usage`, no `/v1/tray` e na tela** (#157). O span `claude_code.llm_request` chega sem `cost_usd`; agora o custo da chamada é o do span ou, sem ele, o do log `api_request` de mesmo `request_id` (uma regra só, `cost.spans_with_cost`, na consulta: sem mudar schema nem ingestão, vale para o que já está gravado). Log sem span não é chamada; log repetido conta uma vez; a chamada na borda da janela mantém o custo. **Precisa de release** (o agent-studio vai na imagem).

### Added
- **`/v1/usage`: `spans` em cada linha, nos totais e na série** (#157): todos os spans do grupo, o denominador da taxa de erro (`errors.spans`). Spans que não são chamada ao modelo caem na linha de `model` nulo. **Precisa de release**.
- **Preço de reserva dos modelos Claude no `config/agent-studio/config.toml`** (#157): `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-sonnet-5`, `claude-haiku-4-5-20251001` e `claude-fable-5-1`, só para a chamada que ficou sem o log `api_request` (estimado, marcado). A reserva `gpt-6-*` segue sem preço (`unpriced_models`) até haver fonte. Sem release (`git pull` + `oute down/up`).
