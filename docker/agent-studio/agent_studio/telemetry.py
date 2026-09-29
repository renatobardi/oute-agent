"""Telemetria própria do agent-studio (ADR-08 §4, #188): logs e métricas pelo SDK OTel ao otel-collector local.

Origem de sempre (`OTEL_RESOURCE_ATTRIBUTES`: host.name, oute.instance; ADR-04) + `service.name` próprio
(`OTEL_SERVICE_NAME`, padrão `agent-studio`). Sem `oute.agent`: o agent-studio não é agente, e o ADR-04 descarta
`oute.agent` fixo por ferramenta.

Sem laço: o que o agent-studio manda ao collector volta a ele pela ingestão (#155). Por isso:
- métricas são contadores agregados, exportados a cada `OTEL_METRIC_EXPORT_INTERVAL` (padrão 60 s): gravar um lote
  soma números, não cria registro novo;
- só WARNING ou pior sai como log OTel (recusa, gravação que falhou), e cada tipo de aviso sai no máximo uma vez
  por janela (`AGENT_STUDIO_LOG_EVERY`, padrão 60 s), com a contagem do que foi suprimido. O log de sucesso por
  requisição fica só no stderr do container.
Sem `OTEL_EXPORTER_OTLP_ENDPOINT`, nada é exportado (e os contadores viram no-op).
"""
import logging
import os
import threading
import time

log = logging.getLogger("agent_studio")


class Noop:
    def request(self, signal, status):
        pass

    def written(self, signal, n, dup, seconds, ok):
        pass

    def warn(self, kind, msg, *args, level=logging.WARNING):
        log.log(level, msg, *args)

    def shutdown(self):
        pass


class Telemetry(Noop):
    def __init__(self, meter, providers, every):
        self.providers = providers
        self.every = every
        self.last, self.suppressed = {}, {}
        self.lock = threading.Lock()
        self.c_requests = meter.create_counter(
            "agent_studio.requests", unit="{request}", description="requisições OTLP recebidas, por sinal e código HTTP")
        self.c_written = meter.create_counter(
            "agent_studio.records.written", unit="{record}", description="registros gravados no DuckDB (novos)")
        self.c_dup = meter.create_counter(
            "agent_studio.records.duplicate", unit="{record}", description="registros repetidos (dedupe)")
        self.h_write = meter.create_histogram(
            "agent_studio.write.duration", unit="s", description="duração da gravação (DuckDB + SurrealDB)")

    def request(self, signal, status):
        self.c_requests.add(1, {"signal": signal, "http.response.status_code": status})

    def written(self, signal, n, dup, seconds, ok):
        if ok:
            self.c_written.add(n, {"signal": signal})
            self.c_dup.add(dup, {"signal": signal})
        self.h_write.record(seconds, {"signal": signal, "result": "ok" if ok else "error"})

    def warn(self, kind, msg, *args, level=logging.WARNING):
        """Aviso com teto por tipo: no máximo um por janela; o próximo diz quantos foram suprimidos."""
        now = time.monotonic()
        with self.lock:
            if now - self.last.get(kind, -self.every) < self.every:
                self.suppressed[kind] = self.suppressed.get(kind, 0) + 1
                return
            self.last[kind] = now
            n = self.suppressed.pop(kind, 0)
        if n:
            msg += " (+%d suprimidos desde o último aviso)"
            args = (*args, n)
        log.log(level, msg, *args, extra={"agent_studio.warning": kind})

    def shutdown(self):
        for p in self.providers:
            try:
                p.shutdown()
            except Exception:  # noqa: BLE001 — sair nunca falha por causa da telemetria
                pass


def setup():
    if not os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return Noop()
    from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource

    # Resource.create lê OTEL_RESOURCE_ATTRIBUTES e OTEL_SERVICE_NAME
    os.environ.setdefault("OTEL_SERVICE_NAME", "agent-studio")
    resource = Resource.create()
    meters = MeterProvider(resource=resource, metric_readers=[PeriodicExportingMetricReader(OTLPMetricExporter())])
    logs = LoggerProvider(resource=resource)
    logs.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
    # só o logger do agent-studio, só WARNING+: o SDK e o uvicorn ficam no stderr (erro de export não vira log OTel)
    log.addHandler(LoggingHandler(level=logging.WARNING, logger_provider=logs))
    return Telemetry(meters.get_meter("agent_studio"), [meters, logs],
                     float(os.environ.get("AGENT_STUDIO_LOG_EVERY", "60")))
