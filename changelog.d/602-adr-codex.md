### Changed
- **ADR-08: o custo estimado do Codex não lê `cache_write_input_tokens` nem `reasoning_output_tokens`** (#602). Decisão do Bardi de 2026-10-05, registrada em "Consulta agregada de uso". Na medição de 46 spans, o primeiro campo vale 0 e o segundo já está dentro do `output_tokens`. Só documento: a ingestão e o custo não mudam. **Não precisa de release.**
