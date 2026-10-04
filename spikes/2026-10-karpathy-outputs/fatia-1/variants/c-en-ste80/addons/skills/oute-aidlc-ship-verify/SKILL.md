---
name: oute-aidlc-ship-verify
description: Verification of the oute-agent on a host (oute-server or Mac) after a deploy, through the approval channel. It examines the version, the services and the presence of telemetry. Use when someone asks you to examine, verify or validate a deploy, a release or an `oute update`.
---

# oute-aidlc-ship-verify

Phase: `ship` (AI-DLC, ADR-07) · Outcome: a verified deploy on each host, with evidence · Gate: Bardi accepts the deploy (or tells you to revert it).

You **only read**. The deploy (`oute update`, `oute down/up`) is the task of Bardi. This skill does not restart, does not pull an image and does not correct anything on the host. A failure becomes a report. If the failure is a bug, use `oute-aidlc-ops-diagnose`.

Examine three things for each host:
- the **version** (the repo and the image that runs);
- the **services** of the compose;
- the **presence** of recent telemetry in the `oute-observability` bucket.

The services include `oute-agent-studio` and `oute-surrealdb` on the host that enables the `agent-studio` profile (the oute-server). On the other hosts, the script tells that it did not examine them. Presence is only "a new object arrived in the last minutes". The analysis of what arrived (volume, errors) is the task of `oute-aidlc-ops-observe`. If that skill is not installed, report the presence and stop there.

## 1. Target

- **Expected version:** the version that Bardi gave, or the `VERSION` of `main` (`git fetch --tags origin && git show origin/main:VERSION`). For a deploy without a release (only `git pull`), the expected version is the same `VERSION`.
- **Image CI** (only with a release): `gh run list --workflow image --limit 5` shows that the run of the tag `v<esperada>` completed with success. Without this run, the host has nothing to pull. Report and stop.
- **Host:** the approval channel goes to the host **where this container runs** (`oute approve` runs on that host). For the other host, a session in the container of that host does the verification. Tell Bardi which host you did not examine.

Done when: you have a record of the expected version, the image run and the host.

## 2. Propose the verification

The script is `scripts/verify-host.sh`, in the folder of this skill (in the container: `/opt/oute/addons/skills/oute-aidlc-ship-verify/scripts/verify-host.sh`). Read the script before you propose it: Bardi approves this script. Send the script without `--root`. Put the version before the script:

```bash
S=/opt/oute/addons/skills/oute-aidlc-ship-verify/scripts/verify-host.sh
{ printf 'EXPECTED=%q\n' '<esperada>'; cat "$S"; } \
  | OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "ship: verificar deploy v<esperada>"
```

`WINDOW_MIN=<min>` on the same line as `EXPECTED` changes the telemetry window (the default is 60). Record the `id` that the command prints. Then wait: `oute-inbox --wait <id>`. Exit code 3 = the request is not approved yet, or it expired. In that case, tell Bardi that the request is in the queue of `oute approve`. Then wait again.

Done when: the inbox has a result with `# rc:`, or Bardi refused the request (rc 126: report and stop).

## 3. Read the result

Each line is `OK`, `AVISO` or `FALHA`. The last line is the summary. Exit code 1 = there is a `FALHA`.

| Item | FALHA means | Next step to suggest to Bardi |
|---|---|---|
| repo | The checkout of the host is not at the version. | `git pull --tags` on the host (or `oute update`) |
| imagem rodando | The container uses the old image. | `oute pull` + `oute down/up` (or `oute update`) |
| service | The container is stopped, absent or `unhealthy`. | `oute logs <serviço>`. If the cause is not clear, use `oute-aidlc-ops-diagnose`. |
| telemetry | No signal has a new object in the window. | `oute logs otel-collector`; the `oci-storage` credential; `oute-aidlc-ops-diagnose` |

`AVISO` does not fail the deploy, but put it in the report. These cause an `AVISO`:
- a container restart;
- one signal without a new object (the host is idle for that signal);
- an export error in the collector log;
- `rclone` is absent.

Done when: each `FALHA` line and each `AVISO` line has an interpretation and a next step.

**Agent regression (optional, without the channel):** when the image or a CLI (claude, codex) changed, run `oute-regression` in the container of the verified host. This is level 1 (#366): headless tasks in Haiku, ~2 min. It does not go through the approval channel. It uses doubles. The exit codes are:
- 0 = green;
- 1 = a task is red (put it in the report as `FALHA`, with the task);
- 2 = it did not run (quota ≥ 60% or no login: `AVISO`).

The result also goes to the agent-studio as `oute.regression.run`. If the skill runs on an image without `oute-regression` (old version), skip this step and tell it in the report.

## 4. Report

Write one message for each verified host:

1. **Host e versão:** `host=<origem> instance=<instância>`, expected × repo × image.
2. **Veredito:** `deploy verificado` (zero `FALHA`) or `deploy com falha`.
3. **Achados:** the `FALHA` lines and the `AVISO` lines, with the next step from the table.
4. **Evidência:** the `id` of the request and the summary of the script.
5. **Pendente:** a host that you did not verify (step 1), the telemetry analysis (`oute-aidlc-ops-observe`).

In a swarm rodada, send the report to the dispatcher. Each item that stays open becomes an issue with `aidlc:ops` or `aidlc:ship`.
