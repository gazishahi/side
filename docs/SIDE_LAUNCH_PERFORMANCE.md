# Launch performance — what Mitchell Hashimoto's advice means for Side

*Measured and implemented 2026-08-30.*

> "At the earliest point in the lifecycle do non main actor necessary tasks in
> tasks to prep a single frame SwiftUI or AppKit frame render. That's the big
> architectural thing. Easier said than done but that's what you need to do."

Short answer: **yes, achievable, and now largely done** — but the measurement
changed which half of the advice mattered most.

## What was actually wrong

Side's `applicationDidFinishLaunching` ordered the window front and *then*
called `restoreLastSessionIfAvailable()` synchronously. AppKit commits a frame
at the end of a run-loop iteration, and that method never returned, so the loop
never turned. The result was the worst possible combination: a window on screen
in half a bounce, held blank for the duration of the restore. **The launch
looked fast and felt slow.**

## The measurement that changed the plan

Instrumenting the blocking sequence on a developer machine:

```
  91.6 ms  git rev-parse --git-common-dir
   0.3 ms  read tracks.json
  87.6 ms  git rev-parse --is-inside-work-tree
  93.3 ms  git symbolic-ref HEAD
  81.2 ms  git symbolic-ref refs/remotes/origin/HEAD
  85.4 ms  git show-ref main
  81.3 ms  git show-ref master
   0.1 ms  read think/index.json
   0.0 ms  read think/checkpoints.json
  ------
 520.8 ms  TOTAL blocking the first frame
```

The JSON reads — the thing "load state before rendering" implies you should
worry about — cost **0.4ms combined**. Everything else was `git`.

So the obvious next question was whether git was slow. It isn't:

```
  72.6 ms  /bin/echo               ← the cheapest possible spawn
  80.9 ms  /usr/bin/env git --version
  78.3 ms  git --version (direct path)
  78.4 ms  git rev-parse --git-common-dir
  82.1 ms  git rev-parse (four queries combined)
```

**A bare process spawn costs 72.6ms on this machine.** Git contributes about
six milliseconds; the other seventy-two are the OS's per-`exec` cost, almost
certainly endpoint-security scanning — which is the normal condition on machines
this ships to, not an anomaly.

That inverts the optimization. Making git do less work is pointless. Making git
run *concurrently* helps the frame but not the second-long wait. **The only thing
that matters is spawning fewer processes**, and the launch path was spawning six
where one would do.

## What was implemented

Three changes, in ascending order of how much they actually bought:

**1. `GitLaunchProbe` — six spawns become one.** `git rev-parse` accepts several
queries per invocation, so git-dir, work-tree, and HEAD are answered together;
the default-branch probes collapse into a single `for-each-ref`. Cold open went
**520ms → 166ms**.

Two hard-won parsing details, both found against a repository with no commits:
`rev-parse` exits 128 there *despite printing every value asked for*, so a
`guard success` discarded a perfectly good answer; and `runGit` merges stderr
into stdout, so git's `fatal: ambiguous argument 'HEAD'` arrived ahead of the
real output and shifted every positional read. The probe therefore parses by
*shape* — a path, a boolean, a ref — never by position or exit status.

**2. A probe cache — one spawn becomes zero.** The resolved facts are
slow-moving, so they're cached per project. **Reopen is now 0ms and 0 spawns.**
The cache is optimistic and never authoritative: it renders immediately, a real
probe runs off the main thread regardless, and any disagreement is corrected via
`TrackStore.applyProbe`. A stale cache costs one frame of a wrong branch name,
never a wrong decision — everything that *acts* on git state re-reads it then.

**3. The frame is committed before the restore.** `restoreLastSessionIfAvailable`
is deferred one run-loop turn. The first frame is Side's real, already-shipping,
already-tested no-project state, and the project arrives into a live window.

Point 3 is the piece Mitchell was describing, and it is only honest *because* of
points 1 and 2. Deferring slow main-thread work by a turn trades a blank window
for a hitching one; deferring work that now costs 0–166ms is a genuine fix.

**4. `LaunchSignposts`** — `os_signpost` intervals around `firstFrame` and
`restoreSession`, so future claims are measured rather than asserted. The
2026-08-30 audit flagged their absence as the reason no launch claim could be
made. Debug builds also print the numbers to the console.

## Results

| | Before | After |
|---|---|---|
| Blocking the first frame | ~520ms | **0ms** (deferred a run-loop turn) |
| Cold open, project resolution | 520ms, 6 spawns | **166ms, 2 spawns** |
| Cached reopen | 520ms, 6 spawns | **~0ms, 0 spawns** |

## What is deliberately *not* done

The full version of the advice is "every surface has an honest zero-state and a
reactive path from async completion to view update." Side is most of the way
there by construction — stages load lazily, `show(.make)` already runs before any
restore, and the no-project state is real and shipping — but three things remain:

- **`TrackStore` is still constructed synchronously.** It is now *fast*
  (0–166ms rather than 500), which removes the urgency, but a true two-phase
  "construct empty, hydrate async" init is the shape that would survive a much
  larger project being opened.
- **A known data race predates this work.** `gitSummary` and
  `availableBranchesToAdopt` read `TrackStore.tracks` from background queues
  while main mutates it, unsynchronized. Adding more concurrency on top of that
  compounds a bug rather than fixing one, so it should be resolved before any
  further launch restructuring.
- **Review's blank-first-render bug** is evidence that at least one stage does
  not yet handle "no data yet" gracefully. Full frame-first rendering requires
  that every stage does.

Also worth repeating: **these numbers are from a Debug build.** Measure Release
before making any public claim.

## The general lesson

The instinct was "launch is slow because it loads too much state." The data said
launch was slow because it *spawned too many processes*, and the state loading
was free. On a machine where `exec` costs 72ms, process count is the unit of
performance — which is worth remembering anywhere else Side shells out.
