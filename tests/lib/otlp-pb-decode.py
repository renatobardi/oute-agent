#!/usr/bin/env python3
"""OTLP/HTTP protobuf gravado pelo receptor falso -> OTLP JSON, um por linha (#188). Roda com o python do venv do
agent-studio (o opentelemetry-proto vem com o exporter). Uso: otlp-pb-decode.py <dir> <logs|metrics|traces>"""
import glob
import os
import sys

from google.protobuf import json_format
from opentelemetry.proto.collector.logs.v1 import logs_service_pb2
from opentelemetry.proto.collector.metrics.v1 import metrics_service_pb2
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2

KIND = {"logs": logs_service_pb2.ExportLogsServiceRequest,
        "metrics": metrics_service_pb2.ExportMetricsServiceRequest,
        "traces": trace_service_pb2.ExportTraceServiceRequest}
d, sig = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob(os.path.join(d, "*.json"))):
    with open(f[:-5] + ".path") as p:
        if p.read().rstrip("/") != f"/v1/{sig}":
            continue
    msg = KIND[sig]()
    with open(f, "rb") as b:
        msg.ParseFromString(b.read())
    print(json_format.MessageToJson(msg, indent=None, use_integers_for_enums=True))
