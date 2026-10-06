"""Telemetria própria do agent-studio (ADR-08 §4, #188): logs e métricas pelo SDK OTel ao otel-collector local.

Origem de sempre (`OTEL_RESOURCE_ATTRIBUTES`: host.name, oute.instance; ADR-04) + `service.name` próprio
(`OTEL_SERVICE_NAME`, padrão `agent-studio`). Sem `oute.agent`: o agent-studio não é agente, e o ADR-04 descarta
`oute.agent` fixo por ferramenta.

Sem laço: o que o agent-studio manda ao collector volta a ele pela ingestão (#155). Por isso:
- métricas são contadores agregados, exportados a cada `OTEL_METRIC_EXPORT_INTERVAL` (padrão do SDK 60 s; o compose põe 5 min, #570): gravar um lote
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
        pass  # sem endpoint OTLP: não há o que contar

    def written(self, signal, n, dup, seconds, ok):
        pass  # sem endpoint OTLP: não há o que contar

    def price_run(self, changes, failures):
        pass  # sem endpoint OTLP: não há o que contar

    def phase(self, phase, seconds, label=None):
        pass  # sem endpoint OTLP: não há o que medir

    def warn(self, kind, msg, *args, level=logging.WARNING):
        log.log(level, msg, *args)

    def shutdown(self):
        pass  # nada a exportar


# fases longas por natureza: vão ao histograma, mas não viram aviso de "lento" (a cópia de segurança leva dezenas de
# segundos e cresce com o banco, que não tem retenção)
LONG_PHASES = frozenset({"backup"})


class Telemetry(Noop):
    def __init__(self, meter, providers, every, slow=5.0):
        self.providers = providers
        self.every = every
        self.slow = slow
        self.last, self.suppressed = {}, {}
        self.lock = threading.Lock()
        self.c_requests = meter.create_counter(
            "agent_studio.requests", unit="{request}", description="requisições OTLP recebidas, por sinal e código HTTP")
        self.c_written = meter.create_counter(
            "agent_studio.records.written", unit="{record}", description="registros gravados no DuckDB (novos)")
        self.c_dup = meter.create_counter(
            "agent_studio.records.duplicate", unit="{record}", description="registros repetidos (dedupe)")
        self.c_price_checks = meter.create_counter(
            "agent_studio.prices.checks", unit="{check}",
            description="conferências diárias de preço (#339), por resultado: ok, parcial (uma fonte falhou) ou falha")
        self.c_price_changes = meter.create_counter(
            "agent_studio.prices.changes", unit="{change}", description="preços trocados pela conferência (#339)")
        self.c_price_failures = meter.create_counter(
            "agent_studio.prices.failures", unit="{failure}",
            description="falhas da conferência de preço, por fonte e código (#339)")
        self.h_write = meter.create_histogram(
            "agent_studio.write.duration", unit="s", description="duração da gravação (DuckDB + SurrealDB)")
        self.h_phase = meter.create_histogram(
            "agent_studio.phase.duration", unit="s",
            description="duração de cada fase (#570): parse, lock_wait, existing, insert, surreal, commit, read_wait, read; "
                        "`label` = tabela ou leitura")

    def request(self, signal, status):
        self.c_requests.add(1, {"signal": signal, "http.response.status_code": status})

    def written(self, signal, n, dup, seconds, ok):
        if ok:
            self.c_written.add(n, {"signal": signal})
            self.c_dup.add(dup, {"signal": signal})
        self.h_write.record(seconds, {"signal": signal, "result": "ok" if ok else "error"})

    def phase(self, phase, seconds, label=None):
        """Tempo de uma fase (#570): vai ao histograma e, passado `slow`, sai como aviso (com teto por tipo)."""
        self.h_phase.record(seconds, {"phase": phase, **({"label": label} if label else {})})
        if seconds > self.slow and phase not in LONG_PHASES:
            self.warn("slow-" + phase, "lento: %s levou %.1f s%s", phase, seconds, f" ({label})" if label else "")

    def price_run(self, changes, failures):
        """Uma conferência de preço: `failures` = {fonte: código} (`rotina` = falha interna)."""
        result = "ok"
        if failures:
            result = "falha" if len(failures) >= 2 or "rotina" in failures else "parcial"
        self.c_price_checks.add(1, {"result": result})
        if changes:
            self.c_price_changes.add(changes)
        for source, code in failures.items():
            self.c_price_failures.add(1, {"source": source, "reason": code})

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
                     float(os.environ.get("AGENT_STUDIO_LOG_EVERY", "60")),
                     float(os.environ.get("AGENT_STUDIO_SLOW_S", "5")))
