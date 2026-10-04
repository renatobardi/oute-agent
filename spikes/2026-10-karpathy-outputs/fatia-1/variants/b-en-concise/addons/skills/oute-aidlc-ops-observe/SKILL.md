---
name: oute-aidlc-ops-observe
description: Reads ADR-04 and ADR-08 telemetry (the agent-studio, via the usage and alerts API, and the oute-observability bucket), read-only, and summarizes health, cost and anomalies per agent and per host, including agents or hosts with no telemetry. Use when asked for a usage, cost or health summary of the agents, "o que está gastando", "a telemetria está chegando?", or to check observability after a deploy or agent upgrade.
---

# oute-aidlc-ops-observe

Phase: `ops` (AI-DLC, ADR-07) · Outcome: health, cost and anomaly summary per host × agent, with evidence · Gate: Bardi decides what becomes an issue.

You **read** the telemetry; you change nothing. Write nothing to the agent-studio or the bucket (the bucket is never deleted, ADR-04), nor to `config/otel` or `config/agent-studio`. A finding becomes an issue proposal, not a fix.

## Rules

- **Read-only, metadata only.** The bucket and the agent-studio hold content (prompts, responses, commands, `user.email`). From the agent-studio, read only the aggregates of `GET /v1/usage` and `GET /v1/alerts`, via the script; do not open the UI or any other route. From the bucket, read only names, counts, dates, sizes and the keys in the `observe.sh` allowlist. Never print, quote or copy a content value; do not run free-form `jq` on the batches. Need a new field: add the key to the script's allowlist, in a PR.
- **Secrets only via the environment.** agent-studio: `AGENT_STUDIO_READ_TOKEN`, the **read credential** (`GET` only), with the address in `AGENT_STUDIO_URL` (docker network on the oute-server, tailnet vhost on the Mac; compose passes it). The ingestion credential never reaches the `agent`: do not look for it. Bucket: the rclone `oci` remote (`RCLONE_CONFIG_OCI_*`), which the entrypoint builds from the `oci-storage` item. Do not write a key in a file, command, issue or report; do not pass a credential in argv (the script sends the agent-studio one via `curl`'s stdin).
- **Credential missing in the container:** say which variable is missing and stop on that source (the other still counts). Do not look for the credential elsewhere. The host (`ssh oute-server`, as `oute-ops`) is read-only; anything needed there as its user or with sudo goes through the **approval channel** (`oute-propose` → `oute-inbox --wait <id>`), diagnosis only.

## Steps

1. **Run the script** (in this skill's folder; `--help` shows the options):
   ```bash
   "$HOME/.claude/skills/oute-aidlc-ops-observe/observe.sh" all            # Claude
   "$HOME/.agents/skills/oute-aidlc-ops-observe/observe.sh" all            # Codex
   ```
   Defaults: 24 h window (`--hours`), baseline of the 7 days before it (`--baseline-days`, `0` = no baseline) and metadata of the bucket's last 6 h (`--content-hours`, `0` = listing only). `studio` or `bucket` instead of `all` runs one source only. Exit code ≠ 0 = a source could not be read: the `ERRO` line says which and why (variable missing, `HTTP 401` = wrong credential, `HTTP 500` or connection failure = agent-studio down or unreachable from this host).
2. **Read the sections.**
   - agent-studio, per host (`host.name`) × agent (`oute.agent`), by event time: model calls, spans, span and log errors, **real cost** and **estimated cost** in separate columns (never add the two into one number without saying so), unpriced calls, tokens, p95 latency (the highest among the group's models) and the baseline's average cost per day. Then, cost per model.
   - pipeline alerts (`ALERTA`, those of `GET /v1/alerts` now: `queue`, `destination_refusing`, `host_no_data`, `spool`, `quota`) and each host's last data in the agent-studio. `AVISO config` = invalid entry in `config/agent-studio/config.toml`.
   - Bucket: last batch per signal (`traces`, `logs`, `metrics`) × host × instance, with age and volume in the window; then, per host × agent (`oute.agent`), spans, spans with error, logs, error logs and cost (`cost_usd` of Claude's `api_request`).
3. **Handle each `ANOMALIA`** (the script flags; you confirm):

   | Flag | Meaning | Check before reporting |
   |---|---|---|
   | `sem-telemetria` | a call or span existed in the agent-studio baseline (or it is a bucket signal) and nothing in the window | host off or agent idle? Compare with the other source and with known activity (swarm, sessions). A failure only if there was usage. |
   | `sinal-faltando` | the host sent some signal, but not all three | Codex emits no `metrics` (ADR-04); Claude without traces: check `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` and `OTEL_TRACES_EXPORTER` in the agent environment of that host (`docker/compose.yaml`) and the image version. |
   | `agente-sem-telemetria` | agent in this host's `OUTE_AGENTS` with no record in the bucket in the hours read | idle is normal; if there was usage, it is a failure. |
   | `sem-oute.agent` | record without `oute.agent` | new `service.name`, outside `transform/agent` (ADR-04 rule for new agent and upgrade). |
   | `erro-alto` | > 5 % errors (min. 5): in the agent-studio, spans with error status over all spans of the host × agent; in the bucket, error logs over the logs | the script only counts; do not open the error text (it is content). Cause → `oute-aidlc-ops-diagnose`. |
   | `custo-alto` | window cost **per day** (real + estimated, ÷ window days = `--hours` ÷ 24) > 3 × the baseline's daily average (baseline cost ÷ baseline days with data), with more than US$ 1 in the window. A window shorter than 24 h counts as one day (its cost is not extrapolated). Only with usage in the baseline: with no history, read the cost columns | swarm rodada, more expensive model, loop? See the cost per model. The line carries the window total, the cost per day and the baseline per day. A one-day peak is diluted in a long window: when in doubt, rerun with `--hours 24`. |
   | `sem-preço` | calls with no real cost and no price in the table: excluded from both cost sums | the named model is missing from `config/agent-studio/config.toml` (or it is a span with no model). Propose the issue to add the price, with the source; do not edit the table. |

   Each `ALERTA` also goes in the report, with host, value, limit and since when. `host_no_data` exists only for an always-on host (the oute-server); a closed Mac does not alert.

   No flag does not mean all is well: also check for a host that vanished (only in the baseline, or stopped for long in "último dado por host"), abnormal p95, the two sources disagreeing on the same host × agent, and `(legado)` (bucket batches older than 0.7.5, without `host=`; not an anomaly).
4. **Report** in the conversation, short:
   - window and sources read (and those that failed, with the reason);
   - table per host × agent: usage, errors, real and estimated cost;
   - active pipeline alerts;
   - confirmed anomalies, each with the evidence (script line, number) and a hypothesis;
   - what you discarded and why (e.g. host off).
   Use the vocabulary of ADR-04 and `CONTEXT.md`: **origem** = machine + instance, agent = `oute.agent`.
5. **Propose issues**, numbered, one per confirmed problem (labels `observabilidade` and `aidlc:<fase>`; `aidlc:ops` if the fix is to operate, `aidlc:spec` if it is to change something). Open the issue only with Bardi's ok. A fix in the collector, compose, agent-studio or host is not this skill's job.

## Reading reminders

- **Claude and Codex cost is API list price**, not spend: both run on a subscription (ADR-04). **Real** = the value that came in the call (Claude Code sends it in the `api_request` log); **estimated** = tokens × the table in `config/agent-studio/config.toml` (all of Codex, and Claude without the log). `-` in the column = no call of that type, not zero.
- `oute.agent=pi` and `oute.agent=router` appear only in records up to 2026-09-30 (#217, #218): they are not expected agents, and the script does not flag their absence.
- The agent-studio aggregates by **event time** (stored in UTC; the days of the summary and of the cost per day follow the agent-studio's time zone, which the `fuso_dos_dias` line states, #415), and keeps everything (no day limit); the bucket is the cold archive and the backup. The bucket writes 5 min batches per host; no activity = no batch. A large age alone is not a failure.
- The two sources count different things: the agent-studio counts model calls and spans of all hosts; the bucket metadata section reads only the last hours (`--content-hours`). A volume difference between them is not an anomaly; a host × agent present in one and absent in the other, in the same hour, is.
