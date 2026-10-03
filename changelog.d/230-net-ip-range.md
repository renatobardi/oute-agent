### Fixed

- `oute up` derivar e validar `OUTE_NET_IP_RANGE` quando a subnet muda (#230): com `OUTE_NET_SUBNET` definido e `OUTE_NET_IP_RANGE` vazio, deriva o range da metade alta da `/16` (ex.: `172.29.0.0/16` → `172.29.128.0/17`); valida se o range está dentro da subnet e se o IP fixo não cai no range dinâmico; subnets diferentes de `/16` exigem `OUTE_NET_IP_RANGE` explícito.
