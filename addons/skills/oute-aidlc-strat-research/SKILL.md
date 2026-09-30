---
name: oute-aidlc-strat-research
description: Investigate a question against high-trust primary sources and capture the findings as a Markdown file in the repo. Use when the user wants a topic researched, docs or API facts gathered, or reading legwork delegated to a background agent.
---

Fase: `strat` (AI-DLC, ADR-07) · Outcome: achados citados em Markdown · Gate: Bardi decide o que vira trabalho.

Sem subagente ou agente em segundo plano: faça o mesmo trabalho em sequência, nesta sessão.

Spin up a **background agent** to do the research, so you keep working while it reads.

Its job:

1. Investigate the question against **primary sources** — official docs, source code, specs, first-party APIs — not a secondary write-up of them. Follow every claim back to the source that owns it.
2. Write the findings to a single Markdown file, citing each claim's source.
3. Save it where the repo already keeps such notes; match the existing convention, and if there is none, put it somewhere sensible and say where.
