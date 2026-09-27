---
name: oute-aidlc-build-implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Fase: `build` (AI-DLC, ADR-07) · Outcome: commits com código e testes · Gate: Bardi revisa no PR.

Implement the work described by the user in the spec or tickets.

Use /oute-aidlc-build-tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, self-review the diff on two axes before committing: **Spec** (does it do what the issue asked, nothing more?) and **Standards** (the rules in `AGENTS.md`). The full audit is `oute-aidlc-qa-pr-audit`, run on the PR in the `qa` phase.

Commit your work to the current branch.
