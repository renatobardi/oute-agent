### Fixed
- agent-studio: o Dashboard (`/`) segurava a trava do DuckDB durante toda a consulta e parava as outras telas e a ingestão (504 no `agent-studio.oute.pro`, #504). Agora roda num cursor próprio, uma consulta por vez, com prazo de 20 s e cache de 60 s por janela.
