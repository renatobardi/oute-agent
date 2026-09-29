#!/usr/bin/env python3
"""Lê métricas OTLP em protobuf (o que o receptor falso grava) sem biblioteca: só o wire format (#162).
O exporter da telemetria interna do collector só fala protobuf (grpc | http/protobuf).
Uso: otlp-pb-metrics.py <arquivo>...   Saída: um JSON por ponto: {"name": ..., "value": n, "attrs": {k: v}}."""
import json
import struct
import sys


def fields(b):
    """(número do campo, wire type, valor) de uma mensagem; valor = bytes (tipo 2) ou int."""
    i = 0
    while i < len(b):
        key, i = varint(b, i)
        n, t = key >> 3, key & 7
        if t == 0:
            v, i = varint(b, i)
        elif t == 1:
            v, i = b[i:i + 8], i + 8
        elif t == 2:
            ln, i = varint(b, i)
            v, i = b[i:i + ln], i + ln
        elif t == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f"wire type {t}")
        yield n, t, v


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if not c & 0x80:
            return r, i


def any_value(b):  # AnyValue: 1 string, 2 bool, 3 int, 4 double
    for n, _, v in fields(b):
        if n == 1:
            return v.decode()
        if n in (2, 3):
            return v
        if n == 4:
            return struct.unpack("<d", v)[0]
    return None


def point(b):  # NumberDataPoint: 4 as_double, 6 as_int, 7 attributes
    attrs, value = {}, None
    for n, _, v in fields(b):
        if n == 7:
            kv = dict((k, x) for k, _, x in fields(v))
            attrs[kv.get(1, b"").decode()] = any_value(kv.get(2, b""))
        elif n == 4:
            value = struct.unpack("<d", v)[0]
        elif n == 6:
            value = struct.unpack("<q", v)[0]
    return attrs, value


for path in sys.argv[1:]:
    data = open(path, "rb").read()
    for n1, _, rm in fields(data):            # MetricsData.resource_metrics = 1
        if n1 != 1:
            continue
        for n2, _, sm in fields(rm):          # ResourceMetrics.scope_metrics = 2
            if n2 != 2:
                continue
            for n3, _, m in fields(sm):       # ScopeMetrics.metrics = 2
                if n3 != 2:
                    continue
                name, pts = "", []
                for n4, _, v in fields(m):    # Metric: 1 name, 5 gauge, 7 sum (data_points = 1)
                    if n4 == 1:
                        name = v.decode()
                    elif n4 in (5, 7):
                        pts += [point(p) for n5, _, p in fields(v) if n5 == 1]
                for attrs, value in pts:
                    print(json.dumps({"name": name, "value": value, "attrs": attrs}))
