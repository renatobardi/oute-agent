---
name: oute-aidlc-ops-observe
description: Reads the telemetry of ADR-04 and ADR-08 in read-only mode. The sources are the agent-studio (through the usage API and the alerts API) and the oute-observability bucket. Gives a summary of health, cost and anomalies for each agent and each host. The summary includes an agent or a host without telemetry. Use when someone asks for a summary of the usage, cost or health of the agents. Use for "o que está gastando" and "a telemetria está chegando?". Use to examine the observability after a deploy or an agent upgrade.
---

# oute-aidlc-ops-observe

Phase: `ops` (AI-DLC, ADR-07) · Outcome: a summary of health, cost and anomalies for each host × agent, with evidence · Gate: Bardi decides what becomes an issue.

You **read** the telemetry. You do not change anything. Do not write to the agent-studio or to the bucket (no one deletes the bucket, ADR-04). Do not write to `config/otel` or `config/agent-studio`. A finding becomes an issue proposal, not a correction.

## Rules

- **Read only, metadata only.** The bucket and the agent-studio hold content (prompts, responses, commands, `user.email`).
  - From the agent-studio, read only the aggregates of `GET /v1/usage` and of `GET /v1/alerts`. Use the script to read them.
  - Do not open the screen or a different route.
  - From the bucket, read only names, counts, dates, sizes and the keys of the `observe.sh` allowlist.
  - Do not print, quote or copy a content value.
  - Do not run free-form `jq` on the batches.
  - If you need a new field, add the key to the allowlist of the script, in a PR.
- **Secrets come only from the environment.**
  - agent-studio: use `AGENT_STUDIO_READ_TOKEN`, the **read credential** (`GET` only). The address is in `AGENT_STUDIO_URL`. The address is the docker network on the oute-server and the tailnet vhost on the Mac. The compose passes it.
  - The ingestion credential does not go to the `agent`. Do not look for it.
  - Bucket: use the `oci` remote of rclone (`RCLONE_CONFIG_OCI_*`). The entrypoint makes it from the `oci-storage` item.
  - Do not write a key in a file, a command, an issue or a report.
  - Do not pass a credential in the argv. The script sends the agent-studio credential through the stdin of `curl`.
- **If a credential is absent in the container:** tell which variable is absent. Stop for that source (the other source stays valid). Do not look for the credential in a different location. Use the host (`ssh oute-server`, as `oute-ops`) only to read. If you need something there as the host user or with sudo, use the **approval channel** (`oute-propose` → `oute-inbox --wait <id>`). Use the approval channel only for diagnosis.

## Steps

1. **Run the script.** The script is in the folder of this skill. `--help` shows the options.
   ```bash
   "$HOME/.claude/skills/oute-aidlc-ops-observe/observe.sh" all            # Claude
   "$HOME/.agents/skills/oute-aidlc-ops-observe/observe.sh" all            # Codex
   ```
   The defaults are:
   - a window of 24 h (`--hours`);
   - a baseline of the 7 days before the window (`--baseline-days`, `0` = no baseline);
   - the metadata of the last 6 h of the bucket (`--content-hours`, `0` = list only).

   Use `studio` or `bucket` as an alternative to `all` to run only one source. An exit code ≠ 0 means that the script could not read a source. The `ERRO` line tells which source and why:
   - a variable is absent;
   - `HTTP 401` = the credential is wrong;
   - `HTTP 500` or a connection failure = the agent-studio is down, or this host cannot reach it.
2. **Read the sections.**
   - agent-studio, for each host (`host.name`) × agent (`oute.agent`), by the event time. The columns are: model calls, spans, span errors and log errors, **real cost** and **estimated cost** (in different columns), calls without a price, tokens, p95 latency and the average cost per day of the baseline. Do not add the two costs into one number unless you tell it. The p95 latency is the highest of the models of the group. After these columns, the section gives the cost for each model.
   - The pipeline alerts (`ALERTA`) and the last data of each host in the agent-studio. The alerts are those that `GET /v1/alerts` gives now: `queue`, `destination_refusing`, `host_no_data`, `spool`, `quota`. `AVISO config` = an entry in `config/agent-studio/config.toml` is not valid.
   - Bucket: the last batch for each signal (`traces`, `logs`, `metrics`) × host × instance, with the age and the volume in the window. After that, for each host × agent (`oute.agent`): spans, spans with an error, logs, error logs and cost (the `cost_usd` of the `api_request` of Claude).
3. **Examine each `ANOMALIA`.** The script sets the mark. You confirm it.

   | Mark | What it means | Examine before you report |
   |---|---|---|
   | `sem-telemetria` | The baseline of the agent-studio had a call or a span (or this is a bucket signal). The window has nothing. | Is the host off or the agent idle? Compare with the other source and with the known activity (swarm, sessions). It is a failure only if there was usage. |
   | `sinal-faltando` | The host sent some signal, but not all three signals. | Codex does not send `metrics` (ADR-04). For Claude without traces, examine `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` and `OTEL_TRACES_EXPORTER` in the agent environment of that host (`docker/compose.yaml`). Examine the image version also. |
   | `agente-sem-telemetria` | An agent in the `OUTE_AGENTS` of this host has no record in the bucket in the hours that the script read. | An idle agent is normal. If there was usage, it is a failure. |
   | `sem-oute.agent` | A record does not have `oute.agent`. | A new `service.name` is not in the `transform/agent` (the ADR-04 rule for a new agent and for an upgrade). |
   | `erro-alto` | The error rate is > 5 % (minimum 5). In the agent-studio: spans with an error status divided by all the spans of the host × agent. In the bucket: error logs divided by the logs. | The script only counts. Do not open the error text (it is content). Cause → `oute-aidlc-ops-diagnose`. |
   | `custo-alto` | The cost **per day** of the window is > 3 × the daily average of the baseline, with more than US$ 1 in the window. Cost per day of the window = (real + estimated) ÷ window days. Window days = `--hours` ÷ 24. Daily average of the baseline = baseline cost ÷ baseline days with data. A window shorter than 24 h counts as one day (the script does not extrapolate its cost). The mark applies only when the baseline has usage. Without history, read the cost columns. | Was there a swarm rodada, a more expensive model or a loop? Examine the cost for each model. The line gives the window total, the cost per day and the baseline per day. A long window dilutes a peak of one day. If you are not sure, run the script again with `--hours 24`. |
   | `sem-preço` | Calls have no real cost and no price in the table. The two cost sums do not include them. | The model in the line is absent from `config/agent-studio/config.toml` (or the span has no model). Propose the issue to add the price, with the source of the price. Do not edit the table. |

   Put each `ALERTA` in the report also. Give the host, the value, the limit and the start time. `host_no_data` exists only for a host that is always on (the oute-server). A closed Mac does not cause an alert.

   No mark does not mean that all is correct. Examine these items also:
   - a host that disappeared (it is only in the baseline, or it stopped a long time ago in the "último dado por host");
   - a p95 that is not normal;
   - the two sources that disagree about the same host × agent;
   - `(legado)` (bucket batches before 0.7.5, without `host=`; this is not an anomaly).
4. **Report** in the conversation. Make it short:
   - the window and the sources that you read (and those that failed, with the cause);
   - a table for each host × agent: usage, errors, real cost and estimated cost;
   - the active pipeline alerts;
   - the confirmed anomalies, each with the evidence (script line, number) and one hypothesis;
   - what you rejected and why (for example: the host is off).
   Use the vocabulary of ADR-04 and of `CONTEXT.md`: **origem** = machine + instance, agent = `oute.agent`.
5. **Propose issues.** Give each issue a number. Propose one issue for each confirmed problem. Use the labels `observabilidade` and `aidlc:<fase>`: `aidlc:ops` if the correction is an operation, `aidlc:spec` if the correction is a change. Open the issue only with the ok of Bardi. A correction in the collector, the compose, the agent-studio or the host is not a task of this skill.

## Reminders for the read

- **The cost of Claude and Codex is the API list price**, not money spent. The two agents run on a subscription (ADR-04). **Real** = the value that came in the call (Claude Code sends it in the `api_request` log). **Estimated** = tokens × the table of `config/agent-studio/config.toml` (all of Codex, and Claude without the log). `-` in the column = no call of that type, not zero.
- `oute.agent=pi` and `oute.agent=router` are only in records until 2026-09-30 (#217, #218). They are not expected agents. The script does not set a mark when they are absent.
- The agent-studio aggregates by the **event time**. It records this time in UTC. The days of the summary and of the cost per day use the time zone of the agent-studio. The `fuso_dos_dias` line gives this time zone (#415). The agent-studio keeps everything (no limit of days). The bucket is the cold archive and the backup. The bucket writes batches of 5 min for each host. Without activity, there is no batch. A large age alone is not a failure.
- The two sources count different things. The agent-studio counts the model calls and the spans of all the hosts. The metadata section of the bucket reads only the last hours (`--content-hours`). A difference of volume between the two sources is not an anomaly. A host × agent that is in one source and absent from the other, in the same hour, is an anomaly.
