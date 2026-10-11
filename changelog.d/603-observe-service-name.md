### Changed
- **`oute-aidlc-ops-observe` nomeia o `service.name` do registro sem `oute.agent`** (#603). A anomalia `sem-oute.agent` agora diz qual `service.name` falta no `transform/agent`, e o `agent-studio` (serviço do oute, não agente) deixa de ser marcado. `service.name` entra na allowlist de metadados do bucket.
