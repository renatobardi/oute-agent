---
name: oute-aidlc-spec-issue
description: Turn the current conversation into a spec and publish it to the project issue tracker — no interview, just synthesis of what you've already discussed.
disable-model-invocation: true
---

Fase: `spec` (AI-DLC, ADR-07) · Outcome: issue com critérios de aceite · Gate: Bardi aprova o escopo.

This skill takes the current conversation context and codebase understanding and produces a spec (you may know this document as a PRD). Do NOT interview the user — just synthesize what you already know.

The issue tracker and triage label vocabulary should have been provided to you — run `/oute-aidlc-ctx-setup` if not.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout the spec, and respect any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. Existing seams should be preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better - the ideal number is one.

Check with the user that these seams match their expectations.

3. Write the spec using the template below, then publish it to the project issue tracker. Apply the `ready-for-agent` triage label - no need for additional triage.

## Acceptance criteria: post-deploy goes in its own item

Whenever the spec lists acceptance criteria (the "Critérios de aceite" section of the `aidlc` issue template, or criteria inside the spec below), check each one for **when** it can be verified:

- **build**: verifiable in the PR, before merge (tests, CI, a local or fake receiver, reading the diff).
- **post-deploy**: only verifiable after the release and the deploy on the hosts (something that must show up in the real bucket, on the oute-server or on the Mac).

A post-deploy criterion gets **its own item**, marked `(ship)`. Never put it on the same line as a build criterion. A criterion with both parts is split in two. Otherwise the build session ticks the whole line after checking only the local half, and the post-deploy half never reaches the `## Falta` of the PR.

## Acceptance criteria: criteria that assert existing code or CLI behavior must be verified

When a spec lists a criterion that **asserts the behavior of existing code or an external CLI** (e.g., "setting X does Y", "running command Z outputs W"), verify the claim **before the spec goes to the gate**:

- **Read the code** or **run the CLI** (`--help`, a dry-run, or inspection) to check that the behavior exists as stated.
- If the behavior is **not possible** with current code, **different from what the criterion claims**, or **contradicts an ADR or prior decision**, then:
  - Remove the false criterion from the spec, or
  - Reword it to match the actual behavior, or
  - If uncertain, turn it into a question to the Bardi in the spec body — never let a false claim pass as-is.

**Evidence goes in the spec**: a line reference (e.g., `docker/codex_config.py:26`), a `--help` snippet, or a link to the ADR that contradicts it.

<criterion-verification-example>
**Example from #365 (kaizen):** The spec criterion stated that `OUTE_AGENT_YOLO=0` would prevent `sandbox_mode` from being set to `"danger-full-access"`. Reading `docker/codex_config.py:26` shows that `sandbox_mode` is **always** set to that value, regardless of the YOLO flag (line 28–31 only control `approval_policy`, not `sandbox_mode`). **False criterion detected.** The PR #372 removed the claim from the spec and declared the divergence in `## Falta`, citing the code line as evidence.

**How to avoid this:** before committing the spec, spot-check assertions about existing behavior. Even a 30-second skim of the relevant file or CLI output catches most cases.
</criterion-verification-example>

<acceptance-criteria-example>
Mixed (wrong):

- [ ] Codex conferido: marca presente no bucket, ou lacuna registrada no ADR-04 com issue

Split (right):

- [ ] Codex conferido num receptor OTLP local: a marca chega no evento, ou a lacuna fica registrada no ADR-04 com issue
- [ ] (ship) depois da release e do deploy, a marca do Codex aparece no bucket
</acceptance-criteria-example>

<spec-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this spec.

## Further Notes

Any further notes about the feature.

</spec-template>
