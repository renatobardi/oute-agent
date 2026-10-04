### Fixed
- agent-studio: `mem_limit` sobe de 2g para 6g (`OUTE_AGENT_STUDIO_MEM`). Com o DuckDB em 1,2 GB, o limite de 2g esgotava a memória (`OutOfMemoryException`): a ingestão respondia 503 e as telas não abriam (#504). Entra com `git pull` + `oute up`, sem release.
- agent-studio: `OUTE_SURREALDB_MEM` sobe de 1g para 2g, pela mesma folga (#504). Os demais serviços (agent, ai-memory, collector) não têm `mem_limit`.
