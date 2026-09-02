# Strict concurrency — enabled vs. adopted

Status: in progress — `TrackStore` adopted; `LanguageServerRegistry` caches locked 2026-09-01 (audit H9); the remaining warnings are tracked in this document.

*Measured and begun 2026-08-30.*

> "Highly recommend investing in adopting swift strict concurrency now and cleanly
> separating view models from business logic via actors or other combine based
> message passing" — Mitchell Hashimoto

## The distinction is real, and Side was on the wrong side of it

Side's app target already builds with `SWIFT_VERSION = 6.0` and
`SWIFT_STRICT_CONCURRENCY = complete` — verified in the build log as
`-swift-version 6`. That is *enabled*, at the strongest setting.

It was not *adopted*. A clean build produced **118 concurrency warnings in
first-party code** (a figure worth stating because an incremental build shows
zero — it recompiles nothing, which is how a build can look clean and be
anything but).

## Why the checker was quiet about the code that mattered

Two reasons, and the first is the interesting one.

**1. The concurrency is written in GCD, which the checker does not model.**

```
DispatchQueue.main / .global   107 uses
@MainActor                      14 uses
```

Strict concurrency checks values crossing *isolation boundaries*. A
`DispatchQueue.global().async` from a type that declares no isolation isn't a
boundary — there is no actor on either side. The compiler was quiet because it
had been given nothing to check.

**2. Twelve explicit opt-outs.** Eight `@unchecked Sendable`, three
`nonisolated(unsafe)`, one `@preconcurrency`. Several are justified and
documented; `LanguageServerRegistry`'s three static caches are commented as
*not* thread-safe while being reachable from two queues, which is a hatch over a
known problem rather than a considered exemption.

`TrackStore` was in neither list. It was a plain class that never crossed a
boundary the compiler modelled, so nothing fired — while containing two genuine
unsynchronized reads that the 2026-08-30 audit had already found by hand.

## What the second half of the advice diagnoses

`TrackStore` holds the state the Tracks ledger renders *and* spawns git and
mutates worktrees. There was no answer to "which thread owns this" because it was
two objects wearing one name. That is precisely "view model and business logic
not separated," and the ambiguity is what let the races exist.

## What was done

**`TrackStore` is now `@MainActor`** — the view-model half, stated rather than
assumed. Adding the annotation alone produced **zero errors** and turned the
silence into 21 named diagnostics, including nine of the form *"call to main
actor-isolated `runGit` in a synchronous nonisolated context."* That is the
adoption gap becoming visible: the same code, the same races, now described.

**The business half is `nonisolated`.** `runGit`, `checkIsGitRepo`,
`currentBranchName`, `addWorktree`, `materializeWorktree`, `performPull`,
`existingWorktreesByBranch`, and `directorySizeBytes` are pure I/O over immutable
inputs and now say so. Where a git operation genuinely needed main-actor state,
that state is passed in as a parameter (`materializeWorktree(for:defaultBranch:)`)
rather than reached for.

**`defaultBranchName()` split in two.** The cached accessor stays main-actor,
because the cache is mutable state the launch probe writes; `resolveDefaultBranchFromGit()`
is nonisolated. Background refreshes now use the latter deliberately — consulting
the cache from the code refreshing it was both circular and a cross-boundary read.

**Both real races are closed.**

- `availableBranchesToAdopt` read `self.tracks` inside its background block. It
  now snapshots on the main actor and captures by value.
- `TracksWorkspaceViewController.refreshGitSummariesIfNeeded` captured the store
  and called into it from a background queue. `gitSummary` now takes a `Sendable`
  `GitSummaryInputs` struct, gathered on the main actor by `gitSummaryInputs(for:)`.

**Ten completion handlers are `@escaping @Sendable`**, since they cross a queue
hop — which the compiler said nine times once it could see the boundary.

### Result

| | Before | After |
|---|---|---|
| TrackStore concurrency warnings | 21 | **0** |
| Known unsynchronized reads | 2 | **0** |
| Build errors | 0 | 0 |
| Tests | 230 | 230 |

## What remains, and the honest order

Roughly 145 first-party concurrency warnings remain, concentrated in the view
controllers:

```
41  TracksWorkspaceViewController    16  DesignSystem
36  MakeWorkspaceViewController      13  ChromeBackground
22  ShellViewController              11  ThinkWorkspaceViewController
                                     10  DiffView
```

Most are the mirror image of what was just fixed: `NSViewController` subclasses
are main-actor by inheritance, and their GCD blocks touch main-actor state from
nonisolated closures. The remedy is the same one applied here — snapshot on main,
carry values, hop back — repeated per site.

The order that makes sense:

1. **`DesignSystem` and `ChromeBackground` first** (29 warnings). They are leaf
   utilities with no state; annotating them is nearly mechanical and removes
   noise that currently hides real findings in the view controllers.
2. **`ShellViewController` and `TracksWorkspaceViewController` next.** Both own
   real cross-thread work.
3. **`MakeWorkspaceViewController` last**, and probably not before the file is
   split — 3,300 lines is too large to reason about isolation in, and Alloy will
   change its shape anyway.
4. **Audit the twelve opt-outs**, starting with `LanguageServerRegistry`'s three
   caches, which are documented as unsafe.

**The general lesson**: a build setting is a request for the compiler to check
your work; it can only check work you have described. Until a type declares its
isolation, `complete` checking has nothing to say about it — which is why "we
have it enabled" and "we have adopted it" are different sentences.
