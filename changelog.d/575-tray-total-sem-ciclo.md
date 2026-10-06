### Fixed
- **Total de etapas do tray sem o resumo do ciclo** (#575). O `steps.total` do `GET /v1/tray` deixa de contar a etapa `ciclo`, que contava como etapa de rodada aberta para sempre; as linhas e o aviso de etapa nova não mudam, nem o contrato do tray. **Precisa de release** (o `etapas.py` vai na imagem).
