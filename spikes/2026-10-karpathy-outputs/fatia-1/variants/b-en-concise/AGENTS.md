# AGENTS.md — oute-agent repository

Instructions for agents (Claude Code, Codex) working **in this repository**. General rules (worktree per session, approval channel, memory scope, issues) come from the container's global notes; here only what is specific to oute-agent. Context and decisions: `CONTEXT.md`.

## What it is
Container runtime for coding agents (herdr + Claude Code, the primary, + Codex, the fallback; both by subscription, session model chosen by phase, ADR-02), shared memory (ai-memory), storage on OCI and observability (OCI bucket + agent-studio, ADR-08). Runs on `oute-server` (Oracle Cloud, arm64) and on the Mac (Apple Silicon).

## Repo map
- `docker/`: `Dockerfile`, `compose.yaml`, `entrypoint.sh` and the container commands (`oute-propose`, `oute-inbox`, `oute-emit` (operational events to the bucket and to agent-studio, ADR-04 and ADR-08), `oute-agents-install` (claude/codex in home, with auto-update, #195; input checked by sha256, #199), `oute-task`, `oute-select` (per-session model selector, ADR-02, #219; calls Jev on TypeSafe, #257), `oute-sonar` (reads from SonarCloud the gate, issues and hotspots of a PR or of `main`; GET only, #226), `oute-quota` (reads the quota of the Claude and Codex subscriptions, GET only and without touching the credential, ADR-02, #346), `oute-regression` + `regression/` (level 1 of agent regression: headless tasks on Haiku, on demand, with doubles of the approval channel; event `oute.regression.run`, #366), `oute-swarm` + `swarm.md`/`swarm-worker.md`, `comandos.md` (guide of `oute help`) + `oute-container`, `agent-wrap.sh`, `agent-notes.md`, `codex_config.py`). `docker/agent-studio/`: the agent-studio (ADR-08; Python, goes in the image, own compose service, oute-server only).
- `addons/<tipo>/`: addons (ADR-06). Today only `addons/skills/oute-*` (flow skill: `oute-aidlc-<fase>-<id>`, ADR-07) (`SKILL.md` with `name` = folder). Mounted read-only at `/opt/oute/addons`; `docker/addons-link` (called by the entrypoint) creates the links in `~/.claude/skills` and `~/.agents/skills`. A skill ships with `git pull` + `oute down/up`, no release.
- `tests/`: pure-bash tests (`tests/*.test.sh`), run by the `pr` workflow on every PR. `tests/lib/`: support shared between tests:
  - parallel (#336): `parallel.sh` (test cache built without a lock: `cache_publish` builds in a per-process path and enters by rename, `cache_download` with checksum; `free_port`, `spawn_wait`/`spawn_try` with the 60 s `STARTUP_TIMEOUT` deadline and the retry on another port; used by `agent-studio.sh`, `surreal.sh`, `otelcol.sh` and `otlp.sh`; checked by `tests/parallel-lib.test.sh`). Tests can run in parallel (`xargs -P "$(nproc)"`), each with its own port and directory; the cap is `nproc`, and CI stays serial;
  - general: `check.sh` (case counting: `check`/`ok`/`bad`/`jqe`/`die`/`has_pty`, cases coming from Python, summary and exit code; and the `$OUT` checks: `has`/`hasnt` with regex, `has_line`/`hasnt_str` without regex; a check of another target gets another name in the test, #246), `pycheck.py` (the `check` for Python snippets) and `check-lint.py` (finds `check` with a condition outside it; run by `tests/check-lib.test.sh`);
  - compose: `compose-config.sh` (wrapper of `docker compose config` with dummy variables and profiles, used by `tests/compose-config.test.sh` and `tests/agent-studio-auth.test.sh`);
  - rule: `check` only counts the command it receives; a compound condition goes entirely inside it (`check "…" bash -c '[ … ] && grep …' _ …`) or in separate `check`s, never `check "…" [ … ] && …` (#285).
  - model selector (#219, #257, #313): `fake-gh-issue.sh` (the fake `gh issue view <n> --json labels`: labels per issue, `gh` down and `gh` that does not respond), called by each test's fake `gh`; `typesafe.sh` + `fake-typesafe.py` (Jev's fake TypeSafe, with TLS: hit, low confidence, error, no response; key and certificate generated on the fly, by `openssl`, and reading of what arrived). A test that opens a session calls `ts_off` at the start, to never use the real key;
  - fallback (#258): `fake-agent.sh` (fake `claude`/`codex`: `claude auth status`/`codex login status` exit with `FAKE_CLAUDE_AUTH_RC`/`FAKE_CODEX_LOGIN_RC`, or sleep with `FAKE_AUTH_HANG`; the rest records environment, directory and arguments in `$FAKE/<agente>.*`), used by `oute-select`, `oute-task` and `oute-swarm`; every test that runs `oute-select` puts fake `claude` and `codex` on the PATH, to not depend on the claude of whoever runs it, and `fake-oute-quota.sh` (the fake `oute-quota` of the quota trigger, #355: `$FAKE/quota.json` or ample quota, `$FAKE_QUOTA_RC`/`$FAKE_QUOTA_SLEEP`), also on the PATH of every test that runs `oute-select`;
  - quota (#346): `fake-quota.py` (the fake quota endpoints of Claude and Codex, with TLS, any method, with what arrived in `requests.jsonl`), used by `tests/oute-quota.test.sh`; certificate generated on the fly, by `openssl`;
  - entrypoint (#365): `fake-ai-memory.sh` (the `ai-memory` double: writes `mcp_servers`, `hooks.state` with `trusted_hash` and Claude hooks like the real one, idempotent, with `.bak` or without, `FAKE_AI_MEMORY_BAK=0`; `run` (#367): writes the line to the log and executes the `--executable` with `AI_MEMORY_RUN_ID`), used by `tests/oute-task.test.sh` (shim section) and by `tests/entrypoint-config.test.sh` (the real `setup_agents` and `setup_ssh`, extracted from `docker/entrypoint.sh`, in a temporary `HOME`);
  - swarm (#425): `swarm.sh` (the doubles `herdr`/`gh`/`sleep`/`oute-task` on the PATH and the common functions: `round`, `sw`, `watch`, `log_events`, `opn`, `swc`…; to `source` after `ROOT`, `SWARM`, `TMP` and `check.sh`) and `swarm-otlp.sh` (fake OTLP receiver and `oute-emit` for the themes that check events; the `trap` of `rcv_stop` stays in the test itself, which `tests/parallel-lib.test.sh` checks). The `oute-swarm` cases live in **one file per theme**, `tests/oute-swarm-<tema>.test.sh` (today `watch`, `sessoes`, `eventos`, `agente`, `seletor`, `prompts`, `dispatcher`), which the `tests/*.test.sh` loop of the `pr` workflow already picks up, without editing the workflow. A PR that adds a case puts it in the theme's file; new theme = new file, never at the end of another theme; a double or function that two themes use moves up to `swarm.sh` (one that only one theme uses stays in it);
  - OTLP: `otlp.sh` + `otlp-receiver.py` (fake OTLP receiver and reading of what arrived), `otlp-send.py` (batch sending), `otlp-pb-decode.py` and `otlp-pb-metrics.py` (reading of the received protobuf), `otlp_json.py` (parts to build example batches);
  - collector: `otelcol.sh` (pinned `otelcol-contrib` binary; environment and config of the test collector, `jqp` over the printed config, startup of the fake S3 and of the collector, `otelcol_tally`/`wait_all` of accepted × received, `kill -9` scenario and the log at the end; checked by `tests/otelcol-lib.test.sh`) and `fakes3.py` (fake S3);
  - agent-studio: `agent-studio.sh` (venv, starts and stops the app, `post`/`code`/`hdr`/`data`/`enc`/`usd`, example prices, block of one compose service, `studio_oute_up` = the `agent_studio_up` of `scripts/oute` in a test-only environment) + `agent-studio-run.py` (app with injected failure), `surreal.sh` (pinned SurrealDB), `html-data.py` (HTML → JSON of the `data-*`) and `studio_asgi.py` (calls the app through ASGI; fake store and SurrealDB).
  - agent-studio prices (#339): `fake-price-sources.py` (fake models.dev and OpenRouter, with TLS: ok, 500, redirect, no response, too large, garbage; with what arrived in `requests.jsonl`) + `price-sources.sh` (starts the fake, generates the certificate on the fly by `openssl` and puts it in `SSL_CERT_FILE`; `ps_off` removes URLs and certificate from the environment) and `price_json.py` (example bodies in the format of the two sources).
- `scripts/oute`: **host** CLI (up/down/pull/approve/watch…; `oute studio replay` resends the telemetry bucket to the agent-studio ingestion, oute-server only, with `docker/agent-studio/agent_studio/replay.py` inside the service, #159; `oute studio rebuild-state` rebuilds SurrealDB from DuckDB, with `rebuild_state.py`, #345). `oute tray install|uninstall`: macOS only, builds the tray `.app`, the LaunchAgent and the table `~/.oute/tray-hosts` (#260; `tests/oute-tray.test.sh`, with fake `uname`, `swift`, `launchctl` and `codesign`). `oute memory-backup [--check <arquivo>]`: backup of the `oute-memory` volume to `oute-shared`, only calls the ai-memory CLI (#369). `scripts/release`: version bump + tag. `scripts/models-check`: checks the ids and efforts of the selector table against the installed CLIs, without calling a model (#220; runs in the container, item of step 6 of `oute-aidlc-ship-release`).
- `tray/`: the Mac tray (#260, ADR-08 §10), SwiftPM package. Belongs to the **host** (not in the image, not an addon): `oute tray install` compiles on the Mac. `Sources/TrayCore/` = the UI-less logic (decode `/v1/tray`, bar and row text, "há X", validate the request id, build the `oute approve` command from the table `~/.oute/tray-hosts`, new request, read the token from `agent.env`), with `swift test` in `Tests/TrayCoreTests/`, which also runs on Linux. `Sources/OuteTray/` = the app (`MenuBarExtra`), macOS only: the container does not compile it, so **a PR that touches `tray/` carries the output of `swift build && swift test` from the Mac**. `Tests/Fixtures/` = the `/v1/tray` fixtures (#344), checked by `tests/agent-studio-tray.test.sh`.
- `config/otel/`: collector pipelines (`collector.yaml` = bucket; `agent-studio.yaml` = agent-studio; `none.yaml` = extra pipeline off). `config/agent-studio/`: agent-studio prices and alerts. `config/select/models.toml`: the selector's phase → model table (ADR-02), mounted read-only at `/opt/oute/select` (in `agent`) and at `/etc/oute/select` (in `agent-studio`, which checks the prices of those models, #339); ships with `git pull` + `oute down/up`.
- `.github/ISSUE_TEMPLATE/aidlc.md`: issue template (AI-DLC).
- `VERSION`, `CHANGELOG.md` (Keep a Changelog, section `[Unreleased]`), `README.md`.

## Rules
- **Deliver by PR.** Release (`scripts/release x.y.z` + tag) and deploy to the hosts are Bardi's.
- **Needs a release:** change to the image (Dockerfile, entrypoint, copied files). **Does not:** `scripts/oute`, `config/`, `docker/compose.yaml`, which ship with `git pull` (+ `oute down/up`).
- Every visible change enters the changelog by **fragment** (#121): the PR creates `changelog.d/<issue>-<slug>.md` with the subsection (`### Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security`) and the entry, and **does not edit `CHANGELOG.md`**. Format in `changelog.d/README.md`; check with `scripts/changelog check`. `scripts/release` merges the fragments into the version's section and deletes them in the release commit. A line already in `[Unreleased]` (PR opened before #121) stays where it is and goes into the same section.
- `scripts/oute` also runs on **macOS bash 3.2**: no `mapfile`, `timeout`, `${var,,}`; empty array with `set -u` only as `${a[@]+"${a[@]}"}`.
- Agent configs (`~/.codex/config.toml`, `~/.claude/settings.json`, notes) only by **structural** editing (tomlkit, jq, managed block). Never `sed` on a file that another tool also writes.
- Executable scripts with mode `100755` (CI rejects otherwise).
- **Shared test support lives in `tests/lib/`:** a function, double or snippet used by more than one `tests/*.test.sh` stays there (and in the repo map above), never copied. Whoever needs a snippet embedded in another test moves the snippet to `tests/lib/` and replaces it in the source test **in the same PR** (no second copy, no new lib with the old copy still in place). **A test that every PR of an area extends** (e.g. `oute-swarm`) is split by theme, `tests/<nome>-<tema>.test.sh` with the support in `tests/lib/<nome>.sh`, so two sessions adding cases in different themes do not edit the same stretch and do not conflict on merge (#425; the CI's `tests/*.test.sh` loop already picks up the files).
- **CI workflows (`.github/workflows/`) only by Bardi.** The agents' `GH_TOKEN` lacks the `workflow` scope, on purpose: no agent creates or changes CI (GitHub rejects the push and, on the API, answers 404). The agent leaves the file ready and posts in the PR a link to the prefilled web editor (`https://github.com/<dono>/<repo>/new/<branch>?filename=<caminho>&value=<conteúdo url-encoded>`); Bardi commits through the web interface. The rest of the PR proceeds normally, with the workflow under `## Falta` until it lands. Do not ask for the `workflow` scope to work around it, and the approval channel does not help either (the host has no GitHub credential). A workflow triggered only on `pull_request` is validated by a throwaway PR (empty commit, closed without merge).
- **When CI runs** (#122): the `pr` workflow only on `pull_request`; `image` only on a `v*` tag (and manually, by `workflow_dispatch`). A push to `main` runs no workflow: a change's CI state is checked on the PR (`gh pr checks <n>`), not on the `main` commit.
- **Approval channel and `agent` restart:** a proposed script may run `oute down`/`up`/`restart` (#210, with the host's `scripts/oute` updated: the result stays on the host and is delivered when the container comes back). The session that proposed dies with the container: its `oute-inbox --wait` does not return; whoever continues reads the result later (`oute-inbox <id>`). One such request at a time, and last in the queue.
- **Never** publish a container port on `0.0.0.0`. Secrets only through Vaultwarden, read by the host. No BW_* in the container. A service secret (only one service uses it, or it grants write to something Bardi reads to decide) goes in the vault's `oute-services` folder and never reaches `agent` (ADR-01, addendum #256; `secrets/README.md`).
- Telemetry in the `oute-observability` bucket **is never deleted**. A new tool only gets in if it sends usage to the bucket + agent-studio (ADR-08 §11).
- **ai-memory** behavior does not change without an explicit decision by Bardi. Server and client always on the same version.
- Changes to the oute-server host (users, sudoers, nginx, firewall, systemd) belong to the `renatobardi/lab` repo, not here.

## AI-DLC flow (ADR-07)
All work follows the ADR-07 phases. Each phase has a **human gate** by Bardi: an agent does not close a gated phase. New issue by the `aidlc` template and with the label `aidlc:<fase>`; on a phase change, swap the label.

| Phase | Primitives and skills |
|---|---|
| `strat` | `oute-aidlc-strat-opportunity`, `oute-aidlc-strat-research`, `oute-aidlc-strat-wayfinder` |
| `intent` | `oute-aidlc-intent-grill` (base: `oute-aidlc-intent-grilling`) |
| `spec` | issue by the `aidlc` template, `oute-aidlc-spec-issue` |
| `arch` | `docs/adr/`, `CONTEXT.md`, `oute-aidlc-arch-grill`, `oute-aidlc-arch-deepen` |
| `design` | `oute-aidlc-design-modules`, `oute-aidlc-design-prototype` |
| `plan` | `oute-swarm` §1 (triage + Bardi's ok), `oute-aidlc-plan-tickets`, `oute-aidlc-plan-triage`, `oute-aidlc-plan-refactor` |
| `build` | `oute-task`, swarm worker, `oute-aidlc-build-implement`, `oute-aidlc-build-tdd`, `oute-aidlc-build-conflicts` |
| `qa` | `oute-aidlc-qa-pr-audit` (calls `oute-aidlc-qa-security-audit`), `tests/`, CI `pr` |
| `ship` | `oute-aidlc-ship-release` (checklist before the release), `scripts/release` + deploy to the hosts (Bardi), `oute-aidlc-ship-verify` (post-deploy through the approval channel) |
| `ops` | telemetry ADR-04 and ADR-08 (bucket + agent-studio, the two sources that `ops-observe` reads), approval channel, `oute-aidlc-ops-observe`, `oute-aidlc-ops-diagnose` |
| `learn` | `oute-swarm` §4.1 (kaizen, per rodada), `oute-aidlc-learn-insights` (closes the cycle: insights across rodadas and sources → lessons and improvements), `oute-aidlc-learn-feedback` |
| `iter` | `oute-aidlc-iter-roadmap` (opens the next cycle: focus, issues and backlog cleanup), end-of-session issues |
| `ctx` | `CONTEXT.md`, `AGENTS.md`, ai-memory, `oute-aidlc-ctx-router`, `oute-aidlc-ctx-domain`, `oute-aidlc-ctx-setup`, `oute-aidlc-ctx-sync` (checks the summaries against the ADRs) |

A new flow skill enters this table in the same PR. Where to start: `oute-aidlc-ctx-router`. Utility: `oute-skill-writing` (write and edit skills).

## Validate before the PR
- `bash -n` on every changed script.
- `docker compose config` (gate in CI by the test `tests/compose-config.test.sh`, not in the container).
- Addons linker: `tests/addons-link.test.sh`.
- Collector: `otelcol-contrib validate --config=config/otel/collector.yaml --config=config/otel/agent-studio.yaml` (both pipelines together, as on the host with agent-studio on).
- Host script: consider the Mac path (bash 3.2, no `timeout`, Docker Desktop).
- **SonarCloud is a PR gate** (#192): the head's `SonarCloud Code Analysis` check (`gh pr checks <n>`) is part of "green CI", which only holds with it completed successfully; pending is not green. The reason for a failed gate (condition, issues, hotspots) comes from `oute-sonar pr <n>` (#226; exit 1 = gate failed; needs `SONAR_TOKEN`). **An agent never calls a SonarCloud write endpoint** (accept issue, mark hotspot, change gate or configuration): `oute-sonar` only does `GET`, and the agent proposes the justification in the PR; the decision is Bardi's, in the UI. What usually lowers the security rating on new code:
  - literal credential, including in tests (generate a random one);
  - client-supplied data in a log or in an error response;
  - SQL or command built with input (use parameters);
  - download without checksum;
  - dependency without a pinned version;
  - `npm install` without `--ignore-scripts`;
  - literal `http://` in a new file, including in tests, even for an internal compose service name (the test compares with the `docker/compose.yaml` line or builds the address from parts: scheme, service and port).
- **New shell function** (in `docker/`, `scripts/` and `tests/`): a positional parameter goes to a `local` variable (`local x="$1"`) and the function ends with an explicit `return` (`return 0`, or `return $?` when it returns the last command's status). SonarCloud rules: S7679 ("Assign this positional parameter to a local variable") and S7682 ("Add an explicit return statement at the end of the function"). Applies only to new functions; do not rewrite existing ones. Minimal example:
  ```bash
  foo_new() {
    local input="$1"
    # corpo
    return 0
  }
  ```
- **Internal `http://` exception:** `http://` for a compose service name on the `oute` network (docker-internal only, e.g. `http://agent-studio:8430`) is not fixed in code: the agent declares the finding in the PR body and `oute-aidlc-qa-pr-audit` treats it as non-blocking. Does not apply to an external host. Scope: the line that already exists in config (`docker/compose.yaml`, `config/`); in a new file the literal is not repeated (list item above). If the gate fails anyway, the agent fixes it (#295).
- Gate failed outside the exception: the agent fixes it. Waiving the gate or marking a finding in SonarCloud (false positive, accepted) is Bardi's only, recorded in the PR.

## Agent skills

### Issue tracker

GitHub Issues of `renatobardi/oute-agent`, via `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Defaults, except ready-for-agent → `ready` (label already exists). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the root. See `docs/agents/domain.md`.
