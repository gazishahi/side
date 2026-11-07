# Tracks from git: every branch is a track

Status: built (2026-11-07: phases 1 to 3, switching in place included; pull requests through `gh`, `glab` or the public APIs, see phase 3). Agreed 2026-11-04,
with the retention period adjustable. Drafted overnight from the direction agreed on 2026-11-03.
Symbols: `GitRefsWatcher`, `GitBranches`, `BoardSessionRow`, `BranchPullRequest`.

**Phase 1 as built (2026-11-07):**
- Every local branch is a track (`TrackStore.applyGitBranches`): one Side never saw gets a record
  named for its branch, waiting when it's checked out somewhere, parked when it isn't, so a
  repository's old branches don't each claim attention. Ports wait until it's opened.
- A track's folder is where git has its branch checked out; the main checkout's branch has the
  main checkout.
- `GitRefsWatcher` watches the common git directory's `HEAD`, `refs/heads`, `packed-refs` and
  `worktrees`: a branch made, deleted or checked out in a terminal shows within a second.
- A checkout made outside Side makes its branch the active track, and a window on the main
  checkout follows it. A window on a track's own worktree stays where it is.
- A deleted branch's track is set aside (`goneAt`) and comes back if the branch does; kept 30
  days by default, Settings › General › Projects.
- Change Base also writes `branch.<name>.sideBase`; a branch that has one starts on that base.
- Changes on the base shows its own work: uncommitted changes (new files included) and commits
  not yet on its upstream.
**Phase 2, the board (2026-11-07):** under each branch's row in Branches, and under the base
row, what runs on it: each Terminal program working, waiting on you, finished or running (a shell
at its prompt isn't listed), with its program's mark. Show Beside moves the window to that branch
and docks the session beside the Editor (the companion); Open goes to its Terminal tab. The rows
already carried ahead/behind and uncommitted counts. The board redraws only when what it lists
changes, not on every terminal event.

**Phase 3, pull requests (2026-11-07):** one `gh pr list --state all` call gives every branch's
newest pull request, when Branches comes on screen and every five minutes while it's there;
never at launch. An open PR's base becomes its branch's base (a base Side has: the default
branch or a branch it has as a track, never one that makes a loop), and the row's hover and the
detail pane say "from PR #42". Rows show "PR #42", "draft PR #42", "PR #7 merged"; the detail
pane has the PR's line and a button to open it. Ahead/behind now counts against the branch's own
base (a stacked branch was counted against the default branch).

Where the answer comes from (`PullRequestSources`, widened the same day at the owner's question):
the host's own tool when it's installed and signed in (`gh` for GitHub, `glab` for GitLab), else
the host's public API with no credentials, which answers for a public repository (GitHub allows
60 unauthenticated requests an hour; one every five minutes fits). A private repository without
the tool shows nothing, and bases follow the rest of the order. Side never uses a token of its
own, nor the one git keeps for pushing. Still open: a GitHub sign-in in Settings (device flow,
token in the Keychain) for private repositories, which needs an OAuth app registered for Side.

**Switching in place (decision 4, 2026-11-07):** a branch checked out nowhere is checked out in
the main folder, as `git checkout` does. Only when that's safe, else it opens in a folder of its
own and Branches says why:
- the main folder has uncommitted changes to tracked files (nothing is carried across, stashed
  or lost; untracked files stay where they are, as with git, and one in the way makes git refuse);
- something runs there: a program in one of its terminals, or an agent turn on its branch.
A branch already checked out in a worktree opens there. Work on the base checks the default
branch out again under the same rules, and is refused, changing nothing, when it can't be.

## Why

The owner on 2026-11-03:
- Tracks should come from git.
- Their real workflow has a staging branch as the base, not `main`.
- Making a track for every branch by hand is tedious.

Last night's visual audit adds two findings from the screen:
- With two changed files on `main`, Changes says "Changes shows what a track has changed" and
  offers New Track. The stage named for changes doesn't show them.
- Branches is the one stage still built from stock AppKit, and it lists tracks Side made, not
  the branches the repository has.

Today a track is Side's own record (`Track` in `TrackStore`) that happens to own a branch.
Branches Side didn't create are invisible until adopted, and the base is always the default
branch. Someone who lives in git sees two models that disagree. Zed, the target to replace,
has no such layer: what's in git is what you see.

**The goal:** Side's tracks are the repository's branches and worktrees, as they are. Side adds
intent, agents, sessions and review on top, but never asks you to create anything git already
has.

## What the person sees

- **Branches lists every local branch and every worktree** as a track, with no adopting.
  - The current branch sits first.
  - Then the rest, by recent activity: the last commit, or the last time Side had it open.
  - Each row shows its base, ahead/behind against that base, whether it has uncommitted
    changes, its PR's state when there is one, and what's running on it (a Terminal agent
    working, an Agent turn, a check).
- **A track's name is its intent when Side knows one** ("Fix the login race"). Otherwise it's
  the branch name made readable (`fix/login-race` → "fix/login-race", left as is). Renaming a
  track gives it an intent and never touches the branch.
- **The base is the branch's real base,** found in this order:
  1. the base of its open PR (`gh pr view --json baseRefName`, when `gh` is signed in);
  2. what you chose for it (`git config branch.<name>.sideBase`, so other tools can read it);
  3. the branch it was created from, when Side created it;
  4. the repository's default branch.

  So a feature branch off `staging` shows its changes against `staging` with no setup once its
  PR exists.
- **Changes always has something to show on any branch, the base included:**
  - On a feature branch: what it changed against its base (the merge base to HEAD), plus
    uncommitted work.
  - On the base itself (`main`, `staging`): uncommitted work, and commits not yet on its
    upstream (`@{u}..HEAD`). The empty "New Track" state remains only for a repository with
    nothing changed anywhere.
- **New Track still exists.** It makes a branch, and a worktree if you want one, from the base
  you pick. Branches made in a terminal or another app show up on their own within a second.
- **Deleting a branch in git removes its track.** Side's overlay for it (intent, conversation,
  checkpoints) is kept in case the branch comes back (re-created, or fetched): 30 days by default,
  set in Settings (7 days, 30 days, 90 days, or Never delete).

## How

### The model

`TrackStore` stops being the source of truth for which tracks exist and becomes an overlay:

- **Git says what exists.** One `git for-each-ref --format=… refs/heads` and one
  `git worktree list --porcelain` per refresh give every branch, its HEAD, its upstream, and
  the worktree it's checked out in.
- **Side's records are keyed by branch name** (`branchName` already is the key every stage
  uses: tabs, terminals, conversations, the tab memory). A record holds what git can't: intent,
  agent settings, mode, ports, parent, status (parked, review-ready). A branch with no record
  gets a default one, made lazily and not written until something changes.
- **The active track is the branch HEAD is on** in the project's main worktree. Switching to a
  track that lives in another worktree opens that worktree, as today.

### Refresh

- An FSEvents watch on `.git/HEAD`, `.git/refs/heads`, `.git/packed-refs` and `.git/worktrees`
  (the common git dir, so linked worktrees are covered). The refresh is debounced to 250 ms.
  `GitLaunchProbe`'s one-process-at-launch rule still holds: the first list comes from the probe.
- Ahead/behind and dirty state come from `git status --porcelain=v2 --branch` per worktree,
  only for rows on screen, and are cached until that worktree's index or HEAD changes.
- PR state from `gh` is fetched on demand: when Branches is shown, and every 5 minutes while
  it is. It's never on the launch path, and never a wait.

### Base resolution

`TrackBase.resolve(branch)` returns the base and where it came from (PR, chosen, created-from,
default). Rows say where their base came from on hover ("base: staging, from PR #42"). Changing
a track's base writes `branch.<name>.sideBase`. The existing "Change Base" alert keeps its
place.

### Changes on any branch

`ReviewWorkspaceViewController` gets its diff from `TrackDiff.ranges(for:)`. That's merge-base
to HEAD for a track, and `@{u}..HEAD` plus the working tree for a base. Checkpoints and
verification stay per track, as today. A base has none, so its Changes is a plain diff with the
working changes on top.

### Branches, rebuilt

Branches becomes the "live sessions/branches board" from the direction list. It's built from
Side's components (cards, status labels, capsule toggles), with nothing stock, and each row
links to its terminals and agents through the activity center (`ActivityCenter`). This is also
where the audit's Branches findings get fixed.

### Migration

Existing `Track` records keep their branch names, so each matches its branch on first refresh.
A record whose branch is gone is kept for the retention period (Settings, 30 days by default),
then swept, like the overlay of a deleted branch.

## The constitution

Articles 6 and 7 change:

> 6. **Git is the model.** A track is a branch or a worktree, exactly as git has it. SIDE adds
> intent, agents and review on top and never keeps a second list of what exists.
>
> 7. **The base is the branch's own.** A track's changes are measured against its real base:
> its pull request's, the one chosen for it, or the default branch. `main` is the default, not
> the only possibility.

## Measures

| Measure | Target |
|---|---|
| A branch made in a terminal appears in Branches | ≤ 1 s |
| Refresh cost, 200 branches, 5 worktrees | ≤ 30 ms of git time, off the main thread |
| Launch | unchanged: no extra process before the first frame |
| Changes on `main` with uncommitted work | shows it |

## Phases

1. **The overlay:** branches and worktrees from git, records keyed by name, the FSEvents
   refresh, and the base order without the PR step. Changes on any branch.
2. **Branches, rebuilt** as the board: status per row, sessions and agents per branch.
3. **PRs:** the base from the PR, PR state on rows, opening a PR from a track.

## Decisions (2026-11-04)

1. **Remote branches:** local branches and worktrees only, plus a "Check out…" picker for remote
   ones. A busy remote can have hundreds of branches.
2. **Where a chosen base lives:** `git config branch.<name>.sideBase`, visible to other tools
   and kept with the repository's config.
3. **How long a deleted branch's overlay is kept:** 30 days by default. Adjustable in Settings
   (the owner): 7, 30 or 90 days, or Never delete. The Library's archive can keep a conversation
   past it.
4. **Auto-worktrees:** a switch checks the branch out in place, as git does. A worktree comes
   from "Open in New Window", or for a track with running sessions a checkout would interrupt.
