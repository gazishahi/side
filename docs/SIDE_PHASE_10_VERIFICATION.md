# Phase 10 — Closing the loop: tasks, verification, and diagnostics

*Scoped 2026-08-30. **Status: built** — shipped 2026-08-30 in `9ba8090`; the capture/attachment/staleness gaps that kept the loop from closing in practice (2026-09-01 audit, H11 and H14) were fixed 2026-09-01.*

Symbols: `ProjectTasks`, `CheckpointVerification`, `DiagnosticsSnapshot`.

## The problem

Side is good at *proposing* changes and blind to whether they *worked*. The agent
writes code, you approve it, a checkpoint records it — and nothing in the system
ever establishes that it compiles, let alone passes. The agent's central failure
mode is claiming a fix works without evidence, and today nothing structurally
prevents that.

The constitution already names the missing piece. Integration's four operational
concerns are base, checkpoint, **verification**, and integration; Review is
supposed to own "checkpoints, diffs, rationale, **test evidence**, and promotion
decisions." Verification is the one that was never built — the phrase "test
evidence" appears in the codebase exactly once, in a doc comment.

This phase is not a test-runner UI. It is the feedback loop: give the agent a way
to *see* whether its work is sound, and give promotion a reason to refuse work
that isn't.

## Three parts, in dependency order

### 10a — Tasks (the substrate)

A project's known commands as first-class named things, rather than strings
everyone re-types.

- `ProjectTasks` reads a task list from the project (`SIDE.md` frontmatter or a
  small `.side/tasks.json`; *as built: `.side/tasks.json` only; the debugger
  separately reads `.vscode/tasks.json` for a launch's `preLaunchTask`*), with sensible auto-detection: `Package.swift` →
  `swift build` / `swift test`; `package.json` → its `scripts`; `Makefile` →
  its targets; `*.xcodeproj` → `xcodebuild`.
- Tasks run through the **existing** `run_shell_command` path — the track's real
  visible terminal, OSC 133 delimited output, the same approval rules. No new
  execution machinery, no hidden processes.
- Surfaced in Run (a task chip row) and to the agent as a tool, `run_task`,
  which can only run *named* tasks. That is strictly narrower than
  `run_shell_command` and therefore safe to allow in scopes where arbitrary
  commands are not.

**Why first:** verification needs a noun for "the thing that checks this
project," and "whatever string the model guessed" is not it.

### 10b — Verification attached to checkpoints (the payoff)

- `Checkpoint` gains a `verification` record: task name, exit status, a bounded
  output excerpt, and when it ran.
- After a batch is applied, the agent may run a task; its result is recorded on
  the checkpoint that batch produced. A checkpoint is therefore one of:
  **verified**, **failed verification**, or **unverified**.
- Review renders that state beside each checkpoint's diff, and Promote treats a
  failing or absent verification as something to warn about — refusing outright
  for a *failed* one, warning for an *unverified* one. This is what turns "agents
  propose; people promote" from a principle into a mechanism.
- The overlap banner from 8a and this share a home: both are "what does the human
  need to know before promoting."

**The important constraint:** verification must never run automatically without
passing through the same approval boundary as any other command. A task that
runs itself is a command that runs itself.

### 10c — Diagnostics as a surface, and as agent input

- A project-wide diagnostics list (Make already receives LSP diagnostics per
  file; nothing aggregates them).
- A `read_diagnostics` tool so the agent can see compiler and linter errors —
  including errors *its own edit just introduced*. This is the single largest
  quality lever in the phase: an agent that reads the compiler is categorically
  better than one that guesses, and it closes the loop within a single turn
  instead of waiting for the user to paste an error back.

**Ordering note:** 10c is independently valuable and could ship first if 10a/10b
prove larger than expected. 10b depends on 10a; 10c depends on neither.

## Explicitly out of scope

*Since built: the debugger (`SIDE_RFC_DEBUGGER.md`, DAP under `SIDE/Debug/`), so the first
item below is history, not scope.*

- **A real debugger.** Breakpoints, stepping, variable inspection — this means
  DAP (which Side's `LSP/` architecture is already shaped for: a `DAP/`
  directory would mirror it almost exactly) and it is a multi-week initiative on
  its own. It is also the least differentiated thing Side could build; nobody
  switches IDEs for an adequate debugger. The cheap 80% — running the project
  under its normal debug command as a task, plus clickable `file:line` links in
  terminal output — falls out of 10a for free.
- **CI integration.** Verification here means "run it locally and record what
  happened," not "wait for a remote pipeline."
- **A test-results explorer** (per-test navigation, history, flakiness). Exit
  status and output excerpt first; the richer surface only if the plain version
  proves insufficient.

## Why this before the Integration stage

Integration is the natural next stage, and its verification concern is precisely
what this phase builds. Shipping Integration *without* verification would mean
building the stage around a hole. Do this first, and Integration becomes mostly
assembly: promote/undo already exist in Review, overlap exists from 8a, and
verification would be the last missing piece.
