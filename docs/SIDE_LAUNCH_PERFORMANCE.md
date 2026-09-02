# Launch performance — what Mitchell Hashimoto's advice means for Side

Status: built — one probe spawn at launch, cached; signposted.

Symbols: `GitLaunchProbe`, `LaunchSignposts`.

*Measured and implemented 2026-08-30.*

> "At the earliest point in the lifecycle do non main actor necessary tasks in
> tasks to prep a single frame SwiftUI or AppKit frame render. That's the big
> architectural thing. Easier said than done but that's what you need to do."

Short answer: **achievable, and the user-visible half is done — but we did not
actually follow the architecture he described.** The measurement both moved the
bottleneck and made the gap between "the window paints immediately" and "the app
is structured the way he means" precise. See the scorecard below.

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
made. Reporting is gated on `-SideLaunchReport YES` rather than the build configuration, so the shipping build is measurable — `#if DEBUG` reporting is how you end up quoting Debug numbers.

## Results (Release, measured)

Debug numbers were replaced with Release ones — the earlier figures came from an
unoptimized build and were not claimable. Reporting is now gated on a launch
argument rather than `#if DEBUG`, so the shipping configuration can be measured:

```
Side.app/Contents/MacOS/Side -SideLaunchReport YES
```

Three warm samples plus one with the probe cache cleared:

| Interval | Warm | Cold probe |
|---|---|---|
| `makeWindow` (window + ShellViewController + `show(.make)`) | 107–115 ms | 106 ms |
| `orderFront` (`makeKeyAndOrderFront` + `activate`) | 64–78 ms | 59 ms |
| `firstFrame` (to the frame actually committed) | **216–228 ms** | 201 ms |
| `restoreSession` (open the project) | **51 ms** | 92 ms |

Before this work the same launch was roughly 220 ms of frame construction *plus*
520 ms of blocking git — about 740 ms, with the window on screen and **blank** for
the last 520 ms of it. The blank-window time is now zero, and the project lands
~51 ms after the frame.

The measurement also relocated the bottleneck. Project state is no longer the
expensive part; the expensive part is now **building the frame itself** — 107 ms
in `makeWindow` (which constructs `ShellViewController` and runs `show(.make)`,
building Make's view tree) plus ~70 ms ordering the window front, plus roughly
another 50 ms of AppKit's own first layout and Core Animation commit inside the
run-loop turn.

## Did we actually follow the advice? Partly — and the honest answer matters

The advice was: *"At the earliest point in the lifecycle do non-main-actor-necessary
tasks in tasks to prep a single frame render."* Scored precisely:

| Claim | Status |
|---|---|
| "prep a single frame" | **Yes.** The first frame no longer waits on project state, and the state it renders is a real, shipping empty state rather than a skeleton. |
| "at the earliest point in the lifecycle" | **No.** The work was *deferred to after* the frame, not *started earlier and overlapped with* AppKit's own startup. His shape pays `max(frame, restore)`; ours pays `frame + restore`. |
| "in tasks" | **No.** `DispatchQueue.main.async` is a main-thread hop, not structured concurrency and not off-main. The restore still runs on the main thread — just after the frame instead of before it. |

So the *user-visible* win is real and the *architecture* is not his. The 51–92 ms
of `restoreSession` is time that would simply disappear under his design, because
it would overlap the 220 ms of frame construction that is happening anyway.

And the reason it can't move yet is the second half of his advice, not the first.
`restoreSession` is main-thread because `ProjectContext`, `TrackStore`, and
`AgentSessionStore` are all constructed synchronously; moving them off-main needs
the two-phase async init described below. **The two pieces of advice are one
piece of work**, and what shipped is the easy half of each: the frame ordering
without the concurrency, and the isolation on one type without the actors.

See `SIDE_CONCURRENCY_ADOPTION.md` for the same accounting on the concurrency half.

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

## Postscript: profiling dissolved the planned fix

The next step was going to be two-phase async init for
`ProjectContext`/`TrackStore`/`AgentSessionStore`. Signposting the restore
instead of assuming showed that plan was aimed at the wrong thing:

```
retarget              0.9 ms
probeResolve          0.0 ms
trackStoreInit        0.4 ms      ← the stores everyone assumed were expensive
sessionStoreInit      0.5 ms
acquireContext       27.2 ms      ← the actual cost
projectOpened        19.8 ms
restoreSession       21.0 ms
```

`acquireContext` was `ProjectContextRegistry.key(for:)` calling
`GitPaths.projectIdentity` **purely to build a dictionary key** — and that
spawned a whole `git rev-parse --git-common-dir` for a value `GitLaunchProbe`
had already resolved and cached at launch. One more instance of the same lesson:
on this machine the unit of performance is process count.

With the cache consulted first, `acquireContext` is **1.1 ms** and
`restoreSession` is **21 ms** — down from ~520 ms of *frame-blocking* work when
this started.

**That retires two-phase async init as a performance change.** At 21 ms of
post-frame main-thread work there is nothing left worth moving off the main
thread, and it would be dishonest to do a multi-file refactor and describe the
result as a speed win. The architectural argument survives — Alloy will be
designed against whatever shape this app has, and a synchronous-launch app
teaches it synchronous habits — but that is a design decision to make on its own
merits, not a performance one.

## What is left, in the order the measurement argues for

1. **`makeWindow`'s ~105 ms** — now much the largest interval, and the only one
   the user actually waits on. `show(.make)` builds Make's entire view tree
   before the first frame; most of it is invisible in the empty state.
2. **Two-phase async init**, if and only if the reason is architecture rather
   than speed.

## The general lesson

The instinct was "launch is slow because it loads too much state." The data said
launch was slow because it *spawned too many processes*, and the state loading
was free. On a machine where `exec` costs 72ms, process count is the unit of
performance — which is worth remembering anywhere else Side shells out.
