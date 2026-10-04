### Fixed
- agent-studio: `/uso` e `/conversas` deixam de levar ~30 s em janelas de 7 dias (#504). A junção dos spans com os logs `api_request` de custo (`cost.spans_with_cost`) comparava cada span com cada log (laço aninhado, quadrático) e agora é por igualdade (hash join), com o mesmo resultado; o `/v1/usage` também lê o DuckDB uma vez só e reagrupa os cortes em memória (eram cinco leituras).
