# RFC — Cross-project work, background execution, and the shape of Review

*2026-09-03; recommendations accepted by the implementing agent's review the same day. Status: **accepted as recommended below, pending owner confirmation.** Companion to `SIDE_DESIGN_DIRECTION_02.md`
(which is agreed and implementable without any of this).*

Everything here changes architecture or product structure and needs a decision
before an agent builds it. Each item states the recommendation, the cost, and
what to decide.

---

## R1. Multi-project: v1 vs v2

**Problem.** One project per window; no view of work across projects.

**v1 — recommended now.** Multiple windows (already supported), one per project.
The **track pill popover** (Direction 02 §3.2) gains a second section, *Other
projects*, listing needs-you tracks from every **open** window's project, and
the dock badge/notifications keep aggregating across windows. Cost: small; no
architecture change. Gives the "what needs me, everywhere" view without a
ledger.

**v2 — decide later, after v1 use.** A true cross-project **Tracks** ledger:
- An app-level `WorkspaceLedger` (`@MainActor`, owned by `AppDelegate`) that
  **retains** a `ProjectContext` for every known project (recents ∪ open), so
  project lifetime decouples from window lifetime and background runners
  survive their window closing.
- The ledger observes every `TrackStore` and `AgentRunnerManager` and composes
  `(project, track, activity)` rows. No new store: each project's state stays
  in its own `.git/side`. Known roots persist in a small `ledger.json`.
- A window shows one track and may switch to a track in any project
  (`switchToTrack` gains a project; stages already retarget per worktree).
- Tracks groups **by state** by default (Needs you aggregated across projects;
  project as a caption suffix only when ≥2 projects), with a by-project toggle
  (a project with nothing needing you collapses to one line) and the header
  search.
- Launch: hydrate each project from its `GitLaunchProbe` cache; zero git
  spawns before first frame; sessions lazy; summaries for non-front projects
  refresh off-main on a timer, visible rows only.
- Edge cases: dedupe by common git dir (registry does); non-git folder → "no
  tracks" + init affordance; missing root → "missing" with Remove/Locate, no
  state deleted.

**Hard scope rule in both versions:** the canvas is always **one track's
worktree**. Make's files/explorer/Quick Open/symbols/`@`-mentions and every
agent tool scope to `track.workingDirectoryPath`; Run launches in it; there is
no multi-project file explorer and no cross-project file search. The only
cross-project search is over track metadata. This rule is what keeps the ledger
from becoming a sidebar.

**Decision:** ship v1 with the pill in Direction 02 step 3; revisit v2 after two weeks of real use.

## R2. Terminal sessions owned by the project (required for v2, useful now)

**Problem.** Agent loops survive switching (runners live on `ProjectContext`,
headless; Think only observes). Terminal sessions do not: PTYs are owned by
`RunWorkspaceViewController` inside a window, so a background track's running
command has no host if no window shows that track.

**Recommendation.** Move PTY ownership to a `TerminalSessionManager` on
`ProjectContext`, keyed per track — shaped like `AgentRunnerManager` — with Run
as a view that attaches/detaches (the Heron/Think split, applied to terminals).
Output buffers in the session; the unseen-output dot appears on return; window
close no longer kills a running command (it still terminates on project
release or explicit close). Also fixes audit D-4 (interrupt targets the wrong
session) by giving each agent command a stable session identity.

**Cost:** medium; touches `RunWorkspaceViewController`, `TerminalViewController`,
`ProjectContext`, `WorkspaceBridge`. **Decision:** yes — and **before** Direction
02 step 4, so Run's new tab strip, task row and status line are built once on
project-owned PTYs rather than rebuilt.

## R3. Runner concurrency ceiling

No ceiling today (audit). **Recommendation:** soft ceiling of **4 concurrently
streaming runners** per app; further sends queue, the track shows `queued` as a
caption, and the ledger/pill shows it. `UsageBudget` stays the spend bound.
**Decision:** fixed at 4, not a setting, until someone hits it.
*As built: narrower.* `TrackCoordinator.concurrencyLimit` (4) holds back only the messages the
coordinator delivers between a project's tracks; tracks a person starts by hand all stream at
once, and nothing shows `queued`.

## R4. Cross-track awareness — structural, not conversational

**Recommendation.** Two read-only tools, **same project only**:
- `read_track_overlap` (Plan + Build): the changed-path intersection with
  sibling tracks (8a, already computed for Review's banner).
- `list_tracks` (Plan + Build): intent, status, base, changed paths of the
  other tracks in the project.
Dependency is expressed as a stacked track, never as a message between agents.
No agent-to-agent channel; no cross-project awareness (rarely useful, costly,
a privacy widening). Consistent with the v1 non-goal "parallel background
agents mutating one live checkout" — each track has its own worktree, so
background agents never collide on files.
**Decision:** both tools approved; no swarm feature. Do now — the overlap computation already exists.

## R5. Is "Review" the right name?

Model settled in Direction 02: **Think = proposals, pre-apply; Review =
checkpoints and promotion, post-apply.** The stage's primary action is
*Promote*, and the audit found a "Review" button that opens Think — the name
invites confusion. Options: keep **Review** (matches the constitution table;
least churn); rename to **Land** or **Promote** (names the action; requires
constitution, menu, shortcut, and copy changes). **Recommendation:** keep
"Review" for now; fix the verbs (Direction 02 §4.1) which removes the concrete
confusion; revisit naming with the Integration work, since that is when the
stage's job grows to include push/PR.

## R6. Integration and Library as non-stages

Recorded as agreed: **Integration** is Review's publishing half (push, PR,
remote verification land in the decision header when remote support exists);
**Library** (prompts, skills, instruction files, templates, archive management)
is a separate window (⇧⌘L), also reachable from Think's "+" and Preferences.
`ShellViewController.Stage` gains no cases. **Integration's publishing half built 2026-09-23** (`Publishing`, Review › Publish…: push, open a pull request with `gh` or on the host's page, check the remote for new commits). **Decision:** do now — a table edit;
`DocStatusTests` already asserts the two are not `Stage` cases, so constitution
and code stay in agreement mechanically.

## R7. Remote and mobile (architecture first)

Not designed here; recorded for sequencing. The unit of remote access is the
**track** (intent, state, needs-you, checkpoints, promote). R1-v2 + R2 produce
a headless project/track engine that a thin read-and-approve client can attach
to. Design the client only after R2 exists.
