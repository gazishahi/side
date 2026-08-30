# Side audit — 2026-08-30

Four parallel audits (correctness, security/agent-safety, performance, product/UX)
run against the codebase after Phases 7–9 landed. This file records what was
found and what was done, so nothing gets lost.

**Status: all findings resolved or explicitly deferred.** 195 tests green.

## Fixed

### Critical

| # | Finding | Commit |
|---|---|---|
| 1 | **Git pipe deadlock in all 11 subprocess sites.** `waitUntilExit()` before `readDataToEndOfFile()` hangs forever once git fills the ~64KB pipe buffer. Reproduced against a 175KB blob; the worst path is on the main actor, so an agent proposing a large-file rewrite hard-locked the app. | `e9cbb0e` |
| 2 | **Failed checkpoint undo destroyed uncommitted work.** `abandon()` ran `git reset --hard HEAD` — the exact mistake the file's own header rules out — then reported "nothing was modified." | `f4c6671` |
| 3 | **Arbitrary code execution via the auto-run allowlist.** `awk 'BEGIN{system(…)}'`, `sed`'s `e` command, and `node script.js` auto-ran with no approval card under Guarded/Full. | `e9cbb0e` |
| 4 | **Allowlist constrained the executable but not its arguments.** `cat ~/.ssh/id_rsa`, `grep -r AKIA /Users`, `find / -name id_rsa` all auto-ran, undoing `ProjectFileAccess`'s containment. | `e9cbb0e` |
| 5 | **`write_file(".git/config")` was accepted.** A `core.fsmonitor` entry executes on git's next run — and Side runs `git status` unattended while checkpointing — turning an edit into command execution. | `e9cbb0e` |
| 6 | **Checkpoints reported failure as success.** Six git failures returned `nil` indistinguishably from a legitimate no-op, producing "✓ Checkpoint … (no file changes)" for work that was never committed and could not be undone. | `5d5b9a5` |
| 7 | **A non-ASCII filename broke every checkpoint.** `git status --porcelain` quotes such paths; the quotes went straight into `git add`, which matched nothing. Plus up to 15s of main-thread `Thread.sleep`. | `5d5b9a5` |
| 8 | **Approved edits into an open tab never reached disk.** The checkpoint then committed the *old* bytes, and "Don't Save" discarded the change while Review claimed it happened. | `8e42a5a` |

### Significant

| # | Finding | Commit |
|---|---|---|
| 9 | `appendTurn` quadratic: 100× write amplification (409MB to persist a 4MB conversation). Now an append-only log; benchmark 6.47s → 1.02s. | `74330ad` |
| 10 | A malformed record discarded the whole conversation, and the next append overwrote the file. | `74330ad` |
| 11 | Branches `feat/x` and `feat-x` shared one conversation file and silently merged. | `74330ad` |
| 12 | Tool scope enforced only in the spec list, not at dispatch — a BYOK/local model emitting `write_file` in Ask mode produced a real edit proposal. | `c2a62f0` |
| 13 | `read_file` could read `.git/side/`: every other track's full conversation, including the user's own unredacted messages. | `c2a62f0` |
| 14 | Project rules (`AGENTS.md`/`CLAUDE.md`, which arrive with any clone) were folded into the system prompt with no consent or preview. Now requires acknowledgement per file *and contents*. | `c2a62f0` |
| 15 | Format-on-save discarded keystrokes typed during the formatter run and marked the tab clean. | `2e2956e` |
| 16 | HEAD content was stamped onto a captured tab *index*, so a close/reorder mid-fetch put one file's content on another tab permanently. | `2e2956e` |
| 17 | Think's stream indices survived a track switch, stripping markdown off an unrelated conversation's message. | `2e2956e` |
| 18 | Stop didn't stop: tool results still submitted and a new billed request went out. | `2e2956e` |
| 19 | Syntax highlighting: 113ms on the main thread every typing pause (no `begin/endEditing`). | `8c73bb5` |
| 20 | Session cache never evicted — memory scaled with tracks *ever visited*. Now LRU, 3 resident. | `8c73bb5` |
| 21 | Proposal diffs computed on main: ~0.5s freeze on a ten-file batch. | `8c73bb5` |
| 22 | Terminal command buffer unbounded and rescanned quadratically. | `8c73bb5` |
| 23 | `SymbolIndexer` quadratic line numbering per keystroke; regexes recompiled each call. | `8c73bb5` |
| 24 | LSP's three `$SHELL -lic` probes on the main thread on first open. | `8c73bb5` |
| 25 | Unlimited undo stacks; `which` spawned a process per ⌘S. | `8c73bb5` |
| 26 | A message that couldn't be sent (no API key) vanished from the composer. | `811f77a` |
| 27 | Tracks with no project: enabled New Track button that silently did nothing. | `811f77a` |
| 28 | Run with no project spawned a shell in the user's home directory. | `811f77a` |
| 29 | Review never consulted `repoState`, advising an impossible remedy. | `811f77a` |
| 30 | Move to Trash swallowed failures and closed the tab anyway. | `811f77a` |
| 31 | `update-ref` moved HEAD unconditionally, orphaning a commit made from the Run terminal mid-checkpoint. | `5d5b9a5` |
| 32 | Stray `default.profraw` tracked in git. | `2ce42de` |

## Deferred, with reasons

- **131 Swift 6 concurrency warnings** (35 non-Sendable captures, ~50 main-actor
  properties touched from nonisolated contexts; concentrated in Make, TrackStore,
  DesignSystem). They compile today. Worth a dedicated pass, not a scattered one.
- **Think retains one live `NSView` per transcript entry**, and `entries` duplicates
  `session.turns`. ~10–15MB per long conversation. The cheap half (drop the
  duplication) is worth doing; virtualizing the stack is a larger change.
- **`checkpoints` and `UsageStore.records` grow monotonically** over a project's
  lifetime. Bounded growth, slow.
- **Secret redaction gaps**: space-delimited credential formats (`.netrc`,
  `.pgpass`) aren't matched, and user/assistant message text is never redacted.
  The file is honest about not being a boundary.
- **`ANTHROPIC_API_KEY` is inherited by every shell command.** Mitigated by the
  argument containment fix, not eliminated.
- **`git init` from Tracks orphans the ProjectContext**, producing two stores on
  one project after a close/reopen.
- **8b/8c cross-track awareness** — deliberately unbuilt pending real use of 8a.

## Verified strong

`ProjectFileAccess.resolveInsideProject` survived 11 escape attempts including
symlinks. Redaction has one correct choke point with no bypass. Git is always
invoked argv-style, so model-controlled text can't inject. Checkpoints use an
isolated `GIT_INDEX_FILE` that can't steal the user's staged work. Tracks is the
best-instrumented surface in the app. Think's streaming path is well-built.
No `try!`, `as!`, or force unwraps of consequence anywhere in the codebase.
