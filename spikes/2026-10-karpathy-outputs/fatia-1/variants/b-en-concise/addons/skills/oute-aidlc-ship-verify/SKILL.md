---
name: oute-aidlc-ship-verify
description: Post-deploy verification of the oute-agent on a host (oute-server or Mac) via the approval channel: version, services and telemetry presence. Use when asked to check, verify or validate a deploy, a release or an `oute update`.
---

# oute-aidlc-ship-verify

Phase: `ship` (AI-DLC, ADR-07) · Outcome: deploy verified on each host, with evidence · Gate: Bardi accepts the deploy (or orders a revert).

You **only read**. The deploy (`oute update`, `oute down/up`) is Bardi's; this skill does not restart, pull an image or fix anything on the host. A failure becomes a report and, if it is a bug, `oute-aidlc-ops-diagnose`.

Three things, per host: **version** (repo and running image), compose **services** (with `oute-agent-studio` and `oute-surrealdb` on the host that enables the `agent-studio` profile, the oute-server; on the others the script says it did not check) and **presence** of recent telemetry in the `oute-observability` bucket. Presence is only "a new object arrived in the last minutes". Analysis of what arrived (volume, errors) belongs to `oute-aidlc-ops-observe`; if it is not installed, report the presence and stop there.

## 1. Target

- **Expected version:** the one Bardi stated, or `VERSION` of `main` (`git fetch --tags origin && git show origin/main:VERSION`). Deploy without release (only `git pull`): the expected one is the same `VERSION`.
- **Image CI** (only with a release): `gh run list --workflow image --limit 5` shows the run of tag `v<esperada>` completed successfully. Without it the host has nothing to pull: report and stop.
- **Host:** the approval channel reaches the host **where this container runs** (`oute approve` runs on it). For the other host, the verification comes from a session in that host's container; tell Bardi which host was left unchecked.

Done when: expected version, image run and host are noted.

## 2. Propose the verification

The script is `scripts/verify-host.sh`, in this skill's folder (in the container: `/opt/oute/addons/skills/oute-aidlc-ship-verify/scripts/verify-host.sh`). Read it before proposing: it is what Bardi will approve. Send it without `--root`, with the version in front:

```bash
S=/opt/oute/addons/skills/oute-aidlc-ship-verify/scripts/verify-host.sh
{ printf 'EXPECTED=%q\n' '<esperada>'; cat "$S"; } \
  | OUTE_PROPOSE_AGENT=<claude|codex> oute-propose "ship: verificar deploy v<esperada>"
```

`WINDOW_MIN=<min>` on the same line as `EXPECTED` changes the telemetry window (default 60). Note the printed `id` and wait: `oute-inbox --wait <id>` (exit code 3 = still pending or expired: tell Bardi the request is in the `oute approve` queue and wait again).

Done when: a result with `# rc:` is in the inbox, or Bardi refused (rc 126: report and stop).

## 3. Read the result

Each line is `OK`, `AVISO` or `FALHA`; the last is the summary. Exit code 1 = some `FALHA`.

| Item | FALHA means | Next step suggested to Bardi |
|---|---|---|
| repo | host checkout not on the version | `git pull --tags` on the host (or `oute update`) |
| imagem rodando | container with the old image | `oute pull` + `oute down/up` (or `oute update`) |
| service | container stopped, absent or `unhealthy` | `oute logs <serviço>`; if not obvious, `oute-aidlc-ops-diagnose` |
| telemetry | no new object in any signal in the window | `oute logs otel-collector`; `oci-storage` credential; `oute-aidlc-ops-diagnose` |

`AVISO` does not fail the deploy, but goes in the report: container restart, one signal with no new object (host idle on that signal), export error in the collector log, `rclone` absent.

Done when: each `FALHA` and `AVISO` line has a reading and a next step.

**Agent regression (optional, no channel):** when the image or a CLI (claude, codex) changed, run `oute-regression` in the container of the verified host (level 1, #366: headless tasks on Haiku, ~2 min; does not go through the approval channel, uses doubles). Exit 0 = green; 1 = some task red (goes in the report as `FALHA`, with the task); 2 = did not run (quota ≥ 60% or no login: `AVISO`). The result also goes to the agent-studio as `oute.regression.run`. Skill without `oute-regression` in the image (old version): skip and say so in the report.

## 4. Report

One message per verified host:

1. **Host e versão:** `host=<origem> instance=<instância>`, expected × repo × image.
2. **Veredito:** `deploy verificado` (zero `FALHA`) or `deploy com falha`.
3. **Achados:** the `FALHA` and `AVISO` lines, with the next step from the table.
4. **Evidência:** the request `id` and the script's summary.
5. **Pendente:** unverified host (step 1), telemetry analysis (`oute-aidlc-ops-observe`).

In a swarm rodada, the report goes to the dispatcher. Whatever stays pending becomes an issue with `aidlc:ops` or `aidlc:ship`.
