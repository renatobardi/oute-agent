# AGENTS.md — oute-agent repository

These instructions are for agents (Claude Code, Codex) that work **in this repository**. The general rules (worktree for each session, approval channel, memory scope, issues) come from the global notes of the container. This file contains only the rules that are specific to oute-agent. For context and decisions, read `CONTEXT.md`.

## What it is
This repository is a container runtime for code agents. The runtime has these parts:
- herdr + Claude Code (the primary agent) + Codex (the fallback agent). The two agents use a subscription. The phase selects the model of the session (ADR-02).
- Shared memory (ai-memory).
- Storage in OCI.
- Observability (OCI bucket + agent-studio, ADR-08).

The runtime runs on `oute-server` (Oracle Cloud, arm64) and on the Mac (Apple Silicon).

## Repo map
- `docker/`: This directory contains `Dockerfile`, `compose.yaml`, `entrypoint.sh` and the container commands:
  - `oute-propose`.
  - `oute-inbox`.
  - `oute-emit`: It sends operational events to the bucket and to the agent-studio (ADR-04 and ADR-08).
  - `oute-agents-install`: It installs claude/codex in the home, with auto-update (#195). A sha256 check examines the input (#199).
  - `oute-task`.
  - `oute-select`: It is the model selector for each session (ADR-02, #219). It calls Jev on TypeSafe (#257).
  - `oute-sonar`: It reads from SonarCloud the gate, the issues and the hotspots of a PR or of `main`. It uses only GET (#226).
  - `oute-quota`: It reads the quota of the Claude and Codex subscriptions. It uses only GET and does not touch the credential (ADR-02, #346).
  - `oute-regression` + `regression/`: This is level 1 of the agent regression. It runs headless tasks in Haiku, on demand, with fakes of the approval channel. The event is `oute.regression.run` (#366).
  - `oute-swarm` + `swarm.md`/`swarm-worker.md`.
  - `comandos.md` (the guide of `oute help`) + `oute-container`.
  - `agent-wrap.sh`, `agent-notes.md`, `codex_config.py`.

  `docker/agent-studio/`: This directory contains the agent-studio (ADR-08). The agent-studio is Python and goes into the image. It has its own compose service and runs only on the oute-server.
- `addons/<tipo>/`: This directory contains the addons (ADR-06). Today there is only `addons/skills/oute-*` (flow skill: `oute-aidlc-<fase>-<id>`, ADR-07) (`SKILL.md` with `name` = folder). The directory is mounted read-only at `/opt/oute/addons`. The entrypoint calls `docker/addons-link`, which makes the links in `~/.claude/skills` and `~/.agents/skills`. A skill goes in with `git pull` + `oute down/up`, without a release.
- `tests/`: This directory contains tests in pure bash (`tests/*.test.sh`). The `pr` workflow runs them on each PR. `tests/lib/`: This directory contains the support that the tests share:
  - parallel (#336): `parallel.sh` contains these parts:
    - The test cache, which is built without a lock. `cache_publish` builds in a path of the process and goes in by rename. `cache_download` uses a checksum.
    - `free_port`.
    - `spawn_wait`/`spawn_try`, with the `STARTUP_TIMEOUT` time limit of 60 s and a new try with a different port.

    `agent-studio.sh`, `surreal.sh`, `otelcol.sh` and `otlp.sh` use `parallel.sh`. `tests/parallel-lib.test.sh` examines it. The tests can run in parallel (`xargs -P "$(nproc)"`). Each test has its own port and its own directory. The maximum is `nproc`. The CI continues to run the tests in series.
  - general:
    - `check.sh`: It counts the cases (`check`/`ok`/`bad`/`jqe`/`die`/`has_pty`, cases that come from Python, summary and exit code). It also examines `$OUT`: `has`/`hasnt` with regex, `has_line`/`hasnt_str` without regex. An examination of a different target gets a different name in the test (#246).
    - `pycheck.py`: It is the `check` for the Python snippets.
    - `check-lint.py`: It finds a `check` that has a condition outside it. `tests/check-lib.test.sh` runs it.
  - compose: `compose-config.sh` is a wrapper of `docker compose config` with fictitious variables and profiles. `tests/compose-config.test.sh` and `tests/agent-studio-auth.test.sh` use it.
  - rule: `check` counts only the command that it receives. Put a compound condition fully inside it (`check "…" bash -c '[ … ] && grep …' _ …`) or in separate `check`s. Never write `check "…" [ … ] && …` (#285).
  - model selector (#219, #257, #313):
    - `fake-gh-issue.sh`: It is the fake `gh issue view <n> --json labels`. It gives labels for each issue, a `gh` that is down and a `gh` that does not answer. The fake `gh` of each test calls it.
    - `typesafe.sh` + `fake-typesafe.py`: This is the fake TypeSafe of Jev, with TLS. The cases are: hit, low confidence, error, no answer. `openssl` makes the key and the certificate at run time. The fake also lets the test read the data that arrived.

    A test that opens a session calls `ts_off` at the start. Thus the test never uses the real key.
  - fallback (#258):
    - `fake-agent.sh`: It is the fake `claude`/`codex`. `claude auth status`/`codex login status` exit with `FAKE_CLAUDE_AUTH_RC`/`FAKE_CODEX_LOGIN_RC`, or sleep with `FAKE_AUTH_HANG`. All other commands write the environment, the directory and the arguments to `$FAKE/<agente>.*`. `oute-select`, `oute-task` and `oute-swarm` use it. Each test that runs `oute-select` puts the fake `claude` and `codex` on the PATH. Thus the test does not depend on the claude of the person who runs it.
    - `fake-oute-quota.sh`: It is the fake `oute-quota` of the quota trigger (#355). It has `$FAKE/quota.json` or a quota with margin, and `$FAKE_QUOTA_RC`/`$FAKE_QUOTA_SLEEP`. It is also on the PATH of each test that runs `oute-select`.
  - quota (#346): `fake-quota.py` is the fake quota endpoints of Claude and Codex, with TLS. It accepts all methods and writes the data that arrived to `requests.jsonl`. `tests/oute-quota.test.sh` uses it. `openssl` makes the certificate at run time.
  - entrypoint (#365): `fake-ai-memory.sh` is the fake `ai-memory`. It writes `mcp_servers`, `hooks.state` with `trusted_hash`, and the Claude hooks, as the real one does. It is idempotent, with `.bak` or without (`FAKE_AI_MEMORY_BAK=0`). `run` (#367) writes the line to the log and executes the `--executable` with `AI_MEMORY_RUN_ID`. These tests use it:
    - `tests/oute-task.test.sh` (the shim section).
    - `tests/entrypoint-config.test.sh` (the real `setup_agents` and `setup_ssh`, extracted from `docker/entrypoint.sh`, in a temporary `HOME`).
  - swarm (#425):
    - `swarm.sh`: It contains the fakes `herdr`/`gh`/`sleep`/`oute-task` on the PATH and the common functions (`round`, `sw`, `watch`, `log_events`, `opn`, `swc`…). Use `source` on it after `ROOT`, `SWARM`, `TMP` and `check.sh`.
    - `swarm-otlp.sh`: It contains a fake OTLP receiver and `oute-emit` for the themes that examine events. The `trap` of `rcv_stop` stays in the test itself. `tests/parallel-lib.test.sh` examines this.

    The `oute-swarm` cases are in **one file for each theme**, `tests/oute-swarm-<tema>.test.sh`. The themes today are `watch`, `sessoes`, `eventos`, `agente`, `seletor`, `prompts`, `dispatcher`. The `tests/*.test.sh` loop of the `pr` workflow already gets these files, with no edit to the workflow. Obey these rules:
    - A PR that adds a case puts the case in the file of the theme.
    - A new theme = a new file. Never put a new theme at the end of a different theme.
    - Move a fake or a function that two themes use to `swarm.sh`. A fake or a function that only one theme uses stays in that theme.
  - OTLP:
    - `otlp.sh` + `otlp-receiver.py`: a fake OTLP receiver, and the read of the data that arrived.
    - `otlp-send.py`: It sends batches.
    - `otlp-pb-decode.py` and `otlp-pb-metrics.py`: They read the received protobuf.
    - `otlp_json.py`: It has the parts to make example batches.
  - collector:
    - `otelcol.sh`: It contains these parts:
      - the pinned binary of `otelcol-contrib`;
      - the environment and the config of the test collector;
      - `jqp` on the printed config;
      - the start of the fake S3 and of the collector;
      - `otelcol_tally`/`wait_all` of the accepted × received items;
      - the `kill -9` scenario and the log at the end.

      `tests/otelcol-lib.test.sh` examines it.
    - `fakes3.py`: It is a fake S3.
  - agent-studio:
    - `agent-studio.sh`: It contains these parts:
      - the venv;
      - the start and the stop of the app;
      - `post`/`code`/`hdr`/`data`/`enc`/`usd`;
      - example prices;
      - the block of one compose service;
      - `studio_oute_up` = the `agent_studio_up` of `scripts/oute` in an environment that only the test uses.
    - `agent-studio-run.py`: It is the app with an injected failure.
    - `surreal.sh`: It is the pinned SurrealDB.
    - `html-data.py`: HTML → JSON of the `data-*`.
    - `studio_asgi.py`: It calls the app through ASGI. It has a fake store and a fake SurrealDB.
  - agent-studio prices (#339):
    - `fake-price-sources.py`: It is the fake models.dev and the fake OpenRouter, with TLS. The cases are: ok, 500, redirect, no answer, too large, garbage. It writes the data that arrived to `requests.jsonl`.
    - `price-sources.sh`: It starts the fake. It makes the certificate at run time with `openssl` and puts it in `SSL_CERT_FILE`. `ps_off` removes the URLs and the certificate from the environment.
    - `price_json.py`: It has example bodies in the format of the two sources.
- `scripts/oute`: This is the CLI of the **host** (up/down/pull/approve/watch…).
  - `oute studio replay` sends the telemetry bucket again to the ingestion of the agent-studio. It runs only on the oute-server, with `docker/agent-studio/agent_studio/replay.py` inside the service (#159).
  - `oute studio rebuild-state` builds the SurrealDB again from the DuckDB, with `rebuild_state.py` (#345).

  `oute tray install|uninstall`: This command runs only on macOS. It builds the `.app` of the tray, the LaunchAgent and the `~/.oute/tray-hosts` table (#260; `tests/oute-tray.test.sh`, with fake `uname`, `swift`, `launchctl` and `codesign`). `oute memory-backup [--check <arquivo>]`: This command makes a backup of the `oute-memory` volume in `oute-shared`. It only calls the CLI of ai-memory (#369). `scripts/release`: version bump + tag. `scripts/models-check`: This script compares the ids and the efforts of the selector table with the installed CLIs. It does not call a model (#220). It runs in the container and is an item of step 6 of `oute-aidlc-ship-release`.
- `tray/`: This is the tray of the Mac (#260, ADR-08 §10), a SwiftPM package. It belongs to the **host**. It does not go into the image and it is not an addon. `oute tray install` compiles it on the Mac. `Sources/TrayCore/` = the logic without a screen:
  - decode `/v1/tray`;
  - the text of the bar and of the lines;
  - "há X";
  - validate the request id;
  - build the `oute approve` command from the `~/.oute/tray-hosts` table;
  - new request;
  - read the token from `agent.env`.

  It has `swift test` in `Tests/TrayCoreTests/`, which also runs on Linux. `Sources/OuteTray/` = the app (`MenuBarExtra`), only on macOS. The container does not compile the app. Thus **a PR that changes `tray/` includes the output of `swift build && swift test` from the Mac**. `Tests/Fixtures/` = the fixtures of `/v1/tray` (#344). `tests/agent-studio-tray.test.sh` examines them.
- `config/otel/`: This directory contains the collector pipelines (`collector.yaml` = bucket; `agent-studio.yaml` = agent-studio; `none.yaml` = extra pipeline off). `config/agent-studio/`: This directory contains the prices and the alerts of the agent-studio. `config/select/models.toml`: This file is the phase → model table of the selector (ADR-02). It is mounted read-only at `/opt/oute/select` (in the `agent`) and at `/etc/oute/select` (in the `agent-studio`). The `agent-studio` examines the prices of these models (#339). The file goes in with `git pull` + `oute down/up`.
- `.github/ISSUE_TEMPLATE/aidlc.md`: the issue template (AI-DLC).
- `VERSION`, `CHANGELOG.md` (Keep a Changelog, `[Unreleased]` section), `README.md`.

## Rules
- **Deliver by PR.** The release (`scripts/release x.y.z` + tag) and the deploy on the hosts belong to Bardi.
- **A release is necessary:** for a change in the image (Dockerfile, entrypoint, copied files). **A release is not necessary:** for `scripts/oute`, `config/`, `docker/compose.yaml`. These go in with `git pull` (+ `oute down/up`).
- Each visible change goes into the changelog as a **fragment** (#121). The PR creates `changelog.d/<issue>-<slug>.md` with the subsection (`### Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security`) and the entry. The PR **does not edit `CHANGELOG.md`**. The format is in `changelog.d/README.md`. Examine the fragment with `scripts/changelog check`. `scripts/release` puts the fragments together in the section of the version and deletes them in the release commit. A line that was already in `[Unreleased]` (PR opened before #121) stays in its position and goes into the same section.
- `scripts/oute` also runs on the **bash 3.2 of macOS**. Do not use `mapfile`, `timeout`, `${var,,}`. With `set -u`, write an empty array only as `${a[@]+"${a[@]}"}`.
- Change the agent configs (`~/.codex/config.toml`, `~/.claude/settings.json`, notes) only with a **structural** edit (tomlkit, jq, managed block). Never use `sed` on a file that a different tool also writes.
- Executable scripts have mode `100755` (the CI rejects them without it).
- **Shared test support stays in `tests/lib/`:**
  - A function, a fake or a snippet that more than one `tests/*.test.sh` uses stays there (and in the repo map above). Never copy it.
  - If you need a snippet that is embedded in a different test, move the snippet to `tests/lib/`. Replace it in the source test **in the same PR**. Do not make a second copy. Do not make a new lib while the old copy is still in its position.
  - **A test that each PR of an area extends** (for example `oute-swarm`) is divided by theme: `tests/<nome>-<tema>.test.sh` with the support in `tests/lib/<nome>.sh`. Thus two sessions that add cases in different themes do not edit the same part and do not conflict in the merge (#425). The `tests/*.test.sh` loop of the CI already gets the files.
- **Only Bardi changes the CI workflows (`.github/workflows/`).**
  - The `GH_TOKEN` of the agents does not have the `workflow` scope, on purpose. No agent creates or changes CI. GitHub rejects the push and, in the API, answers 404.
  - The agent prepares the file. Then the agent publishes in the PR a link to the web editor with the content already filled in (`https://github.com/<dono>/<repo>/new/<branch>?filename=<caminho>&value=<conteúdo url-encoded>`). Bardi commits through the web interface.
  - The remainder of the PR continues as usual, with the workflow in `## Falta` until it goes in.
  - Do not ask for the `workflow` scope as a bypass. The approval channel also does not help, because the host has no GitHub credential.
  - A workflow that only `pull_request` triggers is validated by a throwaway PR (empty commit, closed without merge).
- **When the CI runs** (#122): The `pr` workflow runs only on `pull_request`. The `image` workflow runs only on a `v*` tag (and manually, through `workflow_dispatch`). A push to `main` runs no workflow. Examine the CI state of a change in the PR (`gh pr checks <n>`), not in the commit of `main`.
- **Approval channel and restart of the `agent`:**
  - A proposed script can run `oute down`/`up`/`restart` (#210). This needs the updated `scripts/oute` on the host. The result stays on the host and is delivered when the container comes back.
  - The session that proposed the script dies together with the container. Its `oute-inbox --wait` does not return. The session that continues reads the result later (`oute-inbox <id>`).
  - Send only one such request at a time, and put it last in the queue.
- **Never** publish a container port on `0.0.0.0`. Secrets come only through Vaultwarden, and the host reads them. Do not put BW_* in the container. A service secret is a secret that only one service uses, or that gives write access to something that Bardi reads to decide. A service secret goes in the `oute-services` folder of the vault and never gets to the `agent` (ADR-01, addendum #256; `secrets/README.md`).
- Telemetry in the `oute-observability` bucket **is never deleted**. A new tool goes in only if it sends its usage to the bucket + agent-studio (ADR-08 §11).
- The behavior of **ai-memory** does not change without an explicit decision of Bardi. The server and the client always have the same version.
- Changes on the oute-server host (users, sudoers, nginx, firewall, systemd) belong to the `renatobardi/lab` repo, not to this repo.

## AI-DLC flow (ADR-07)
All work obeys the phases of ADR-07. Each phase has a **human gate** of Bardi. An agent does not close a phase that has a gate. Create a new issue with the `aidlc` template and with the label `aidlc:<fase>`. When the phase changes, change the label.

| Phase | Primitives and skills |
|---|---|
| `strat` | `oute-aidlc-strat-opportunity`, `oute-aidlc-strat-research`, `oute-aidlc-strat-wayfinder` |
| `intent` | `oute-aidlc-intent-grill` (base: `oute-aidlc-intent-grilling`) |
| `spec` | an issue with the `aidlc` template, `oute-aidlc-spec-issue` |
| `arch` | `docs/adr/`, `CONTEXT.md`, `oute-aidlc-arch-grill`, `oute-aidlc-arch-deepen` |
| `design` | `oute-aidlc-design-modules`, `oute-aidlc-design-prototype` |
| `plan` | `oute-swarm` §1 (triage + the ok of Bardi), `oute-aidlc-plan-tickets`, `oute-aidlc-plan-triage`, `oute-aidlc-plan-refactor` |
| `build` | `oute-task`, the worker of the swarm, `oute-aidlc-build-implement`, `oute-aidlc-build-tdd`, `oute-aidlc-build-conflicts` |
| `qa` | `oute-aidlc-qa-pr-audit` (it calls `oute-aidlc-qa-security-audit`), `tests/`, CI `pr` |
| `ship` | `oute-aidlc-ship-release` (the checklist before the release), `scripts/release` + the deploy on the hosts (Bardi), `oute-aidlc-ship-verify` (after the deploy, through the approval channel) |
| `ops` | telemetry of ADR-04 and ADR-08 (bucket + agent-studio, the two sources that `ops-observe` reads), approval channel, `oute-aidlc-ops-observe`, `oute-aidlc-ops-diagnose` |
| `learn` | `oute-swarm` §4.1 (kaizen, for each rodada), `oute-aidlc-learn-insights` (it closes the cycle: insights between rodadas and sources → lessons and improvements), `oute-aidlc-learn-feedback` |
| `iter` | `oute-aidlc-iter-roadmap` (it opens the next cycle: focus, issues and backlog cleanup), the issues of the session end |
| `ctx` | `CONTEXT.md`, `AGENTS.md`, ai-memory, `oute-aidlc-ctx-router`, `oute-aidlc-ctx-domain`, `oute-aidlc-ctx-setup`, `oute-aidlc-ctx-sync` (it compares the summaries with the ADRs) |

Add a new flow skill to this table in the same PR. To start, use `oute-aidlc-ctx-router`. The utility skill is `oute-skill-writing` (write and edit skills).

## Validate before the PR
- Run `bash -n` on each changed script.
- Run `docker compose config`. This is a gate in the CI through the test `tests/compose-config.test.sh`, not in the container.
- Addons linker: run `tests/addons-link.test.sh`.
- Collector: run `otelcol-contrib validate --config=config/otel/collector.yaml --config=config/otel/agent-studio.yaml`. This validates the two pipelines together, as on the host when the agent-studio is on.
- Host script: think about the Mac path (bash 3.2, no `timeout`, Docker Desktop).
- **SonarCloud is a gate of the PR** (#192).
  - The `SonarCloud Code Analysis` check of the head (`gh pr checks <n>`) is a part of the "green CI". The CI is green only when this check completed with success. A pending check is not green.
  - `oute-sonar pr <n>` gives the cause of a failed gate (condition, issues, hotspots) (#226; exit 1 = failed gate; it needs `SONAR_TOKEN`).
  - **An agent never calls a write endpoint of SonarCloud** (accept an issue, mark a hotspot, change the gate or the configuration). `oute-sonar` only does `GET`. The agent proposes the justification in the PR. The decision belongs to Bardi, in the UI.

  These items usually decrease the security rating of the new code:
  - a literal credential, also in a test (generate a random one);
  - data that comes from the client in a log or in an error response;
  - SQL or a command that is built with input (use parameters);
  - a download without a checksum;
  - a dependency without a pinned version;
  - `npm install` without `--ignore-scripts`;
  - a literal `http://` in a new file, also in a test, and also for the name of an internal compose service. The test compares with the line of `docker/compose.yaml`, or builds the address from parts: scheme, service and port.
- **New shell function** (in `docker/`, `scripts/` and `tests/`): Put each positional parameter in a `local` variable (`local x="$1"`). End the function with an explicit `return` (`return 0`, or `return $?` when it returns the status of the last command). The SonarCloud rules are S7679 ("Assign this positional parameter to a local variable") and S7682 ("Add an explicit return statement at the end of the function"). This applies only to a new function. Do not write the existing functions again. Minimum example:
  ```bash
  foo_new() {
    local input="$1"
    # corpo
    return 0
  }
  ```
- **Exception for the internal `http://`:**
  - Do not correct in the code an `http://` for the name of a compose service on the `oute` network (only internal docker, for example `http://agent-studio:8430`). The agent declares the finding in the PR body, and `oute-aidlc-qa-pr-audit` treats it as not blocking.
  - The exception does not apply to an external host.
  - Scope: the line that already exists in config (`docker/compose.yaml`, `config/`). In a new file, do not repeat the literal (item of the list above).
  - If the gate fails anyway, the agent corrects the finding (#295).
- If the gate fails outside the exception, the agent corrects the finding. Only Bardi can waive the gate or mark a finding in SonarCloud (false positive, accepted). The PR records this decision.

## Agent skills

### Issue tracker

GitHub Issues of `renatobardi/oute-agent`, through `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the defaults, except ready-for-agent → `ready` (a label that already exists). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the root. See `docs/agents/domain.md`.
