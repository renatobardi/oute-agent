"""Rateio do plano no custo pago (#748, ADR-08, adendo "Custo pago rateado"): a mensalidade da assinatura vira custo das chamadas.

Regra (decisão do Bardi, 2026-10-08):
- o plano vira um valor por dia: mensalidade ÷ dias do mês do dia, pela linha do `plan_history` que valia **naquele dia** (`planos.py`);
- dentro do dia local (o fuso do `config.toml`), o valor é dividido entre **todas** as chamadas daquela assinatura, na proporção do
  custo de lista de cada uma (o informado pela fonte ou o calculado pela tabela; chamada sem custo e sem preço pesa 0). Se o dia
  inteiro pesa 0, divide por número de chamadas;
- dia com plano e sem nenhuma chamada da assinatura é o **"sem uso"** (`NO_USE`): o valor do dia entra no total do período, numa
  linha própria (a soma do mês fecha com a soma das mensalidades);
- assinatura sem plano naquele dia = **"sem plano"**: a chamada conta 0 e é contada à parte (`no_plan_calls`); nunca US$ 0 de
  plano. Plano de US$ 0 conta 0.

O denominador do dia é sempre o dia inteiro e todas as chamadas da assinatura, sem filtro de repositório nem de janela:
por isso a parte de cada grupo (conversa, repositório, fase, papel…) não muda com o filtro, e as partes fecham com o valor do dia.
Este módulo é só conta; a leitura do DuckDB é do `usage.py`.
"""
import bisect
import calendar
from datetime import datetime, time, timedelta

from . import planos
from .cost import SUBSCRIPTIONS

NO_USE = "sem uso"
NS = 1_000_000_000


class Plan:
    """O `plan_history` em memória: valor mensal por assinatura e dia (`None` = sem plano)."""

    def __init__(self, rows):
        self.by_sub = {}
        for r in sorted(rows, key=lambda r: (r["start_date"], r["registered_unix_nano"])):
            self.by_sub.setdefault(r["subscription"], []).append(r)
        self.starts = {s: [r["start_date"] for r in lst] for s, lst in self.by_sub.items()}

    @classmethod
    def load(cls, con):
        n = con.execute("SELECT count(*) FROM information_schema.tables WHERE table_name = 'plan_history'").fetchone()[0]
        return cls(planos.history_rows(con) if n else [])

    def monthly(self, sub, day):
        """Mensalidade (USD) que valia em `day` (`date`), ou `None`. Mesmo desempate do `planos.lookup`: a registrada por último."""
        starts = self.starts.get(sub)
        if not starts:
            return None
        i = bisect.bisect_right(starts, day.isoformat())
        return self.by_sub[sub][i - 1]["monthly_usd"] if i else None

    def daily(self, sub, day):
        """Valor do dia: mensalidade ÷ dias do mês de `day`; `None` = sem plano."""
        monthly = self.monthly(sub, day)
        if monthly is None:
            return None
        return monthly / calendar.monthrange(day.year, day.month)[1]


def local_days(from_ns, to_ns, tz):
    """Os dias locais que a janela [from_ns, to_ns) toca, do primeiro ao último; vazio se a janela é vazia."""
    if to_ns <= from_ns:
        return []
    first = datetime.fromtimestamp(from_ns // NS, tz).date()
    last = datetime.fromtimestamp((to_ns - 1) // NS, tz).date()
    return [first + timedelta(days=i) for i in range((last - first).days + 1)]


def day_bounds(from_ns, to_ns, tz):
    """[início, fim) em ns dos dias inteiros que a janela toca (`None` se vazia): o intervalo do denominador do dia."""
    days = local_days(from_ns, to_ns, tz)
    if not days:
        return None
    start = datetime.combine(days[0], time(), tz)
    end = datetime.combine(days[-1] + timedelta(days=1), time(), tz)
    return int(start.timestamp()) * NS, int(end.timestamp()) * NS


class Alloc:
    """Pesos por (dia, assinatura) e a conta do rateio."""

    def __init__(self, plan):
        self.plan = plan
        self.weight = {}  # (dia, assinatura) -> [custo de lista, chamadas]

    def add_weight(self, day, sub, cost, calls):
        w = self.weight.setdefault((day, sub), [0.0, 0])
        w[0] += cost
        w[1] += calls

    def share(self, day, sub, cost, calls):
        """Parte do valor do dia de um grupo de `calls` chamadas e custo de lista `cost`; `None` = sem plano."""
        value = self.plan.daily(sub, day)
        if value is None:
            return None
        total_cost, total_calls = self.weight.get((day, sub), (0.0, 0))
        if total_cost > 0:
            return value * cost / total_cost
        return value * calls / total_calls if total_calls else 0.0

    def idle(self, from_ns, to_ns, tz, only=None):
        """[(dia, assinatura, USD)] dos dias da janela com plano de valor > 0 e nenhuma chamada da assinatura (o dia inteiro)."""
        out = []
        for day in local_days(from_ns, to_ns, tz):
            for sub in SUBSCRIPTIONS:
                if only is not None and sub != only:
                    continue
                value = self.plan.daily(sub, day)
                if value and (day, sub) not in self.weight:
                    out.append((day, sub, value))
        return out
