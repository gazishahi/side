# SIDE Audit Report — 2026-09-30

**Audited state:** `60fb521` on `main` (clean apart from the untracked `SIDE.xcodeproj/xcshareddata/`).

**Method:**
- Nine parallel code audits:
  - security, in two passes;
  - git and data durability;
  - Heron's conversation and runner;
  - the editor, language servers and debugger;
  - concurrency, processes and performance;
  - UX, accessibility and whether the docs are true;
  - providers, release and tests;
  - a carry-forward of every Critical and High in [the 2026-09-01 audit](SIDE_AUDIT_REPORT_2026-09-01.md).
- Most findings were confirmed by running something against the real code: throwaway git repositories, a SwiftPM probe that links Heron, the fake model server, and small `swiftc` programs.
- The rest were confirmed by reading, and each finding says which.
- These were checked again at the source by the lead auditor before they went in: both Criticals, the SIGPIPE crash, HER-1, HER-4, EDT-1, UX-1, PRV-2, and the `waitUntilExit` correction.
- A clean Release build was captured: it succeeded with 287 unique warnings.
- No product code was changed.

**Scope:** the 143 commits since 2026-09-01. They include:
- Make on Alloy;
- IDE essentials (language features, grammars, keymaps, themes);
- the DAP debugger;
- outside agents over ACP, and multi-agent coordination;
- Library and Integration;
- the Heron efficiency RFC (prompt caching, the stale sweep, compaction with Undo, streaming, the checkpoint rewrite).

---

## Executive summary

The previous audit's fixes hold. All nineteen of its Highs are fixed or partly fixed:
- the case-insensitive `.git` guard;
- the isolated-index checkpoint;
- the LSP ordering and registry lock;
- binary-file protection;
- the verification loop;
- the VoiceOver fixes.

None was reverted, and their regression tests survived.

The new checkpoint path also held up empirically. Linked worktrees, split and sparse indexes, index v4 with fsmonitor and the untracked cache, intent-to-add entries, empty repositories, and the user's own staged changes were each exercised against real git and came out right.

But the new surface area brought new failures of the same classes as before:
- **Two Criticals:**
  - `rg --pre`, `find -okdir`, `sort --compress-program` and git's `--output=` auto-run without a click. `rg --pre` executes a program, and `--output=` writes a file. This is C1's class again.
  - Undoing a checkpoint destroys the user's staged work, then says "Nothing was modified."
- **About fifteen Highs:**
  - one app-wide crash (SIGPIPE);
  - runaway billed loops after teardown, overload errors and output-limit cuts;
  - a compaction bug that makes Undo unrecoverable;
  - a checkpoint that can report success while the next commit silently reverts it;
  - a first run in which a new user can't create their first track;
  - a monthly budget that outside agents and unpriced models walk straight past.

A notable share of the Highs are in work from the last week: the efficiency RFC, the debugger and multi-agent. Their tests covered the happy path and missed the interactions.

One earlier claim is corrected here:
- `Process.waitUntilExit()` costs about 65 ms **only on the main thread**: 67 ms on main, 3 ms on a background queue, re-measured.
- The efficiency RFC measured its step-5 checkpoint numbers inside XCTest, which runs on the main thread. So "875 ms → 121 ms" overstates the real gain.
- The process count (10 → 5) and the removal of `read-tree` stand.

**Release verdict: not release-ready.** Launch gate 3 (this audit) is done; its blocking set is below.

### Severity rollup (deduplicated)

| Severity | Count | Themes |
|---|---|---|
| Critical | 2 | unattended code execution through allowlisted readers; staged work destroyed by Undo |
| High | 15 | crash on SIGPIPE; runaway billing loops; unrecoverable compaction; silent checkpoint reversal; first run broken; budget bypass; IME text loss; debugger launches after Stop; CPU spin; outside agents unlabelled |
| Medium | ~45 | consent hash, key leaks by redirect and environment, language servers running repo code, index durability, collapsed untracked dirs, LSP reply order and stale edits, leaks, lock contention, accessibility gaps, docs that claim unbuilt things |
| Low / Info | ~40 | messages slightly untrue, Mac conventions, installer pinning, test hygiene, stale docs |

---

## Part I — Critical and High

### C1 (Critical) — Allowlisted readers that execute or write: `rg --pre`, `find -okdir`, `sort --compress-program`, `git … --output=`
- **Scope:** `Packages/Heron/Sources/Heron/CommandRiskClassifier.swift:85-88` (`rg` has no forbidden flags; `sort` forbids only `-o`/`--output`; `find` lacks `-okdir`), and the git subcommand rules (no `--output`).
- **Evidence:** a scratch build of the current classifier returned `isAutoRunnable == true` for:
  - `rg --pre sh x evil.txt`
  - `rg --pre=./run.sh foo`
  - `sort --compress-program=sh big.txt`
  - `find . -okdir …`
  - `git diff --output=src/a.swift`
  - `git log --output=x.txt`

  Re-verified at the source.
- **Failure scenario:** a cloned repository holds `evil.txt` and a prompt-injection line. On a Guarded or Full track the agent proposes `rg --pre sh TODO evil.txt`. It is typed into the terminal with no click, and ripgrep runs `sh evil.txt`. Separately, `git diff --output=src/main.swift` overwrites an uncommitted file with diff text, bypassing edit approval.
- **Fix:**
  - Forbid `--pre`/`--pre-glob` (rg), `--compress-program` (sort), `-okdir` (find) and `--output` (git), and add each to the must-not-auto-run table test.
  - Better: make the allowlist affirmative per flag for the readers that take programs, or drop `rg` from auto-run.
- **Confirmed by:** running (carry-forward stream) and reading (lead).

### C2 (Critical) — Undo destroys the user's staged work, then reports "Nothing was modified"
- **Scope:** `Packages/Heron/Sources/Heron/CheckpointRestore.swift:92,101,129-137`; `SIDE/CheckpointSheet.swift:34`.
- **Evidence:** on a failed revert, `abandon()` restores every path in `git diff --name-only --cached`. That list includes whatever the user had staged before the undo. It then runs `reset HEAD --` and `checkout HEAD --` on those paths. On success, `git commit -m` commits the whole index.
- **Failure scenarios (ran them):**
  - The user stages `user.txt` and undoes a checkpoint whose file changed later. The revert conflicts, and `user.txt` is reset to HEAD in both the index and the working tree. Only a dangling blob remains, and the sheet says "Nothing was modified."
  - The same wipe happens when the final commit fails (a pre-commit hook, signing).
  - When the undo succeeds, the user's staged change is committed as "Undo agent checkpoint".
- **Fix:**
  - Refuse or stash when the index differs from HEAD.
  - Restore only `git diff --name-only <sha>^ <sha>`.
  - Revert in a private `GIT_INDEX_FILE` and commit with `commit-tree`, as the checkpoint does.
- **Confirmed by:** running (git stream) and reading (lead).

### H1 — SIGPIPE kills Side: Format Document on a file over 64 KB; writes to an exited language server, stdio debug adapter or outside agent
- **Scope:**
  - `SIDE/MakeWorkspaceViewController.swift:5029-5050` and `:4918-4927`;
  - `SIDE/LSP/JSONRPCTransport.swift:81-88` (also used for stdio DAP);
  - `Packages/Heron/Sources/Heron/ACPConnection.swift:91-99`.
  - Nothing in `SIDE/` or Heron ignores SIGPIPE (lead grep). Only the DAP socket sets `SO_NOSIGPIPE`.
- **Evidence:**
  - A Dock-launched app has launchd's PATH, so `prettier`'s `#!/usr/bin/env node` shim exits 127 without reading stdin. Writing 200 KB to it killed the writer 10 of 10 times (exit 141).
  - The `isRunning` guard races a crashing child: the writer died in 2 of 6 runs.
- **Failure scenario:** the whole app dies and every unsaved buffer is lost (there's no autosave, see M-list).
- **Fix:** `signal(SIGPIPE, SIG_IGN)` at launch, plus `try write(contentsOf:)` with the error handled (the legacy `write(_:)` raises an exception instead). Spawn formatters with `environmentForSpawning()`.
- **Confirmed by:** running (concurrency and editor streams).

### H2 — A manual compaction re-compacts on the next send and overwrites Undo: the original conversation becomes unrecoverable
- **Scope:** `Packages/Heron/Sources/Heron/AgentRunner.swift:1147-1152` (clears `lastReportedInputTokens` in memory only); `AgentSessionStore.swift:129-135,150-154,201-207`.
- **Evidence:**
  - The stored count survives `replaceTurns` and is read back by `hydrateFromSession`.
  - After compacting at 90%, the gauge still read 0.906 and the next send compacted again.
  - `compactTurns` then overwrote `<track>.compacted.jsonl` with a summary-only conversation. Undo restored 3 turns of 14.
- **Related:**
  - UX-4: after an automatic compaction, Undo brings the conversation back at 85% or more, so the next send compacts it again. `lastCompactionWasAutomatic` is written and never read.
  - HER-3: Stop does nothing during automatic compaction, and its request has no stall watchdog.
- **Fix:**
  - `recordReportedInputTokens(nil)` in `compact`.
  - Never overwrite the sidecar when the current conversation is only a summary.
  - Skip auto-compaction for the send after an Undo.
  - Put the compaction task in `streamTask` with the watchdog, and skip `sendNow` when stopped.
  - Add tests that send after compacting and after Undo.
- **Confirmed by:** running (Heron stream, fake server) and reading (lead).

### H3 — Teardown while tools run doesn't stop the loop: billed requests continue after the window closes or the track is deleted
- **Scope:** `AgentRunner.swift:505-522` (`teardown` sets no stop flag); `:1615-1633` (`runTools` holds `self`); `:1771-1793`.
- **Evidence:** teardown at `.runningTools` produced 4 requests instead of 1, and the turn finished.
- **Failure scenario:**
  - Up to 12 round trips bill after the last window closes.
  - For a deleted track, `appendTurn` recreates its conversation file.
  - A later approval waits forever.
- **Fix:** an `isTornDown` flag, set in `teardown` and checked in `handleToolOutcomes`, `runTurn` and the compaction completion. Hold `self` weakly in `runTools`.
- **Confirmed by:** running.

### H4 — A checkpoint can report success while the real index stages the reverse of the agent's change
- **Scope:** `AgentRunner.swift:2054-2072`; `GitPaths.swift:271-283`.
- **Evidence:** if `replaceIndex` fails, the fallback `git add`'s result is ignored and `.committed` is returned. It fails whenever `index.lock` is held, for example by an open `git commit` editor, a shell prompt's git, or the app's own polling (see M-CON-4). A crash between `update-ref` and the index write leaves the same state.
- **Failure scenario (ran it, with `index.lock` held):** the outcome was committed and the status `MM agent.txt`. The user's next `git commit` for their own file also silently reverted the agent's checkpoint in history.
- **Fix:**
  - Return "committed, index not refreshed" and say so in the transcript.
  - Retry the refresh on the next checkpoint or status read.
  - At startup, detect index entries that match `HEAD^` but not HEAD for the last checkpoint's paths.
- **Confirmed by:** running. This regression came with the efficiency RFC's step 5.

### H5 — After an overload error or an output-limit cut mid-tool-call, the partial call runs and the runner continues on its own
- **Scope:** `AgentRunner.swift:1524` (`willRunTools = transportError == nil && !toolCalls.isEmpty`); `:2142-2147` (bad JSON becomes `{}`); `:1563-1577` (the error and stop-reason flags are consulted only when nothing was produced).
- **Evidence (parser probe):**
  - A `tool_use`, a partial `input_json_delta`, then `overloaded_error` gives the start, a delta and an error, with no `messageEnd`.
  - A `max_tokens` stop mid-input gives `toolUseEnd` plus `messageEnd(.maxTokens)`.
  - In both cases the call runs with `{}` and `runTurn(roundTrip + 1)` fires.
- **Failure scenario:**
  - A 529 during `write_file` sends another full-context request to an overloaded API.
  - A `max_tokens` cut retries the same large write up to 12 times, about $0.40 of output each on Fable 5.1.
  - Carried from 09-01, still open: a text reply cut off at `max_tokens` finishes as `.completed`.
- **Fix:**
  - On a provider error or `maxTokens`, answer the pending calls with `is_error` results and don't auto-continue.
  - Finish a truncated text turn as truncated.
- **Confirmed by:** running (parser) and reading (loop).

### H6 — Claude 5 requests cap output at 8,192 tokens, shared with thinking that is on by default
- **Scope:** `Packages/Heron/Sources/Heron/Providers/AnthropicMessagesProvider.swift:24` and `:113-124`; `ProviderRegistryStore.swift:216` (no `maxTokens` passed).
- **Evidence:**
  - For Claude 5 the default ceiling of 8,192 is never raised, even at high effort. Re-verified at the source.
  - Omitting `thinking` doesn't disable it: Claude 5 models think adaptively by default, and Opus 5.5 and Fable 5.1 can't disable it at all. The `.standard` effort therefore isn't "no thinking".
  - The default thinking display on these models is `omitted`, so Think's reasoning group streams empty. The code comment at `:190` assumes summarized.
  - `ping` events aren't forwarded as progress. Whether a long silent think can trip the 90 s stall watchdog is unconfirmed without a live request.
- **Failure scenario:** any file write longer than about 8k tokens (minus thinking) can never succeed, and it feeds H5's retry loop.
- **Fix:**
  - Raise `max_tokens` for Claude 5 (streaming allows up to 128K).
  - Map `.standard` to an explicit low effort.
  - Send `display: "summarized"`.
  - Treat `ping` as a keepalive.
- **Confirmed by:** reading, against the current API reference.

### H7 — A child that exits on its own leaves its pipe handler spinning: 1–2 cores until quit
- **Scope:** `ACPConnection.swift:41-48,138-141` (`didExit` doesn't clear the handlers, and `terminate()` returns early); `SIDE/LSP/JSONRPCTransport.swift:51-65` (handlers cleared only in `stop()`, which does nothing after `handleTermination`).
- **Evidence:**
  - At end of file, Foundation calls the handler repeatedly with empty data: about 400,000 calls a second per handle, 1.6 cores for two.
  - The ACP handler posts a main-queue block per call: 854,423 in 2 s.
- **Failure scenario:** a language server crashes, or an outside agent exits (a bad sign-in, a crash). Side then burns heat and battery until it quits, and the idle-wakeup budget is gone.
- **Fix:** set the handler to nil on empty data, as `DAPSocketTransport.swift:166-170` already does.
- **Confirmed by:** running (a copy of the pattern) and reading.

### H8 — Stop or Restart during the debugger's pre-launch build stops nothing; the program launches anyway
- **Scope:** `SIDE/Debug/DebugSession.swift:368-376` (no `isActive` check after the build); `:652-653`; `:711-727` (the build `Process` is local and never terminated); `MakeDebugger.swift:473-485`.
- **Failure scenario:**
  - Stop during a 60 s `swift build`: the ended session revives and launches when the build finishes.
  - With Restart, the old session's callbacks are already gone, so it launches a debuggee no one can see or stop. Two builds contend for `.build`.
  - The orphan survives quit.
- **Fix:** keep the build `Process` and terminate it in `stop()`/`end()`, and `guard isActive` after every await in `start()`.
- **Confirmed by:** reading (editor stream and lead).

### H9 — Input-method composition survives a tab switch or undo; the next keystroke deletes unrelated text
- **Scope:** `Packages/Alloy/Sources/AlloyAppKit/AlloyTextView.swift:352-385,601-604`; `AlloyEditorView.swift:164-176`.
- **Evidence (probe tests):**
  - Composing in A, switching to B (`0123456789`) and committing gave `012中56789`.
  - In `abcdef`, compose, ⌘Z, commit gave `abc日本f`.
- **Failure scenario:** a Chinese or Japanese user clicks another tab with a candidate showing, and characters vanish from the other file, often off-screen.
- **Fix:** `inputContext?.discardMarkedText()` and clear `composingRange` on `setBuffer`, undo, redo, and any replace-reason change.
- **Confirmed by:** running.

### H10 — A new user can't create a first track: New Track fails in a new project, and the first-run step is enabled for a non-repository
- **Scope:** `SIDE/TrackStore.swift:351-355,963-972`; `MakeWorkspaceViewController.swift:1481-1504` (New Project runs `git init` with no commit); `TrackStore.swift:242-253` (Initialize Git); `FirstRunSheet.swift:77`; `ShellViewController.swift:293-296,895`.
- **Evidence:**
  - In an unborn repository, `baseRef = "HEAD"` and `git worktree add -b <slug> <path> HEAD` fails with `fatal: invalid reference: HEAD` (exit 128). Reproduced by the lead.
  - The code comment claims the case is handled.
  - The first-run "Create a track" step is enabled as soon as any folder is open, and gives a raw "not a git repository" for a plain folder.
- **Failure scenario:** gate 6's first run fails at step 3 with raw git text and no next step.
- **Fix:**
  - Offer an initial commit (asked) or use `worktree add --orphan`.
  - Make the step "Initialize Git…" for a non-repository.
  - Add a test.
- **Confirmed by:** running.

### H11 — The monthly budget doesn't stop outside agents or unpriced models
- **Scope:** `UsageBudget.status()` is enforced only at `AgentRunner.swift:1237`, which reads `UsageStore.shared` rather than the injected store. `ACPHarness` never checks it. `UsageBudget.swift:45-51` ignores `hasUnpricedModels`. `UsageStore.swift:308-321` prices by exact model id. `ProviderRegistryStore.swift:105` merges every id `/v1/models` returns.
- **Evidence:** `isPriced` is false for `claude-haiku-4-5`, `claude-fable-5`, `claude-opus-4-8` and dated ids (ran it).
- **Failure scenario:**
  - Past the limit, Heron stops, but Claude Code or Codex tracks and their subtracks keep spending.
  - Selecting a refreshed model such as `claude-opus-4-8` means unlimited spend while the budget reads $0.
  - The multi-agent RFC promises that spend counts against the budget.
- **Fix:**
  - Check the budget in `ACPHarness.send`, or say plainly that it covers Heron only.
  - Refuse, or require an explicit opt-in, when a budget is set and the model has no price.
  - Price by model family.
- **Confirmed by:** running and reading.

### H12 — Outside agents aren't labelled experimental (launch gate 4), and the copy overclaims
- **Scope:** `SIDE/AgentsPreferencesViewController.swift:26,36-37`; `docs/SIDE_RFC_BYO_HARNESS.md:137,215-217`.
- **Evidence:**
  - The RFC says Codex, Gemini CLI and Pi are "not yet verified", yet they appear exactly like Claude Code, and "experimental" is nowhere in the code.
  - The footer says any ACP agent works, naming OpenCode, Qwen Code and Goose, none of which was verified.
- **Fix:** an Experimental badge, and a softer footer. Or verify them live.
- **Confirmed by:** reading.

### H13 — Checkpoints and tool results from the efficiency RFC that don't do what the RFC says
- **HER-4 (the 16,000-character ceiling):** it applies only when something was redacted. `toolResult` returns the raw `content` in the unredacted branch (`AgentRunner.swift:1316-1325`). Command and task output (up to 60,000 characters) and coordination reports enter unbounded. Ran: a 60,000-character command output was stored at 60,000. The step-3 test called `headAndTail` directly. Re-verified at the source. Medium on its own, but it makes a "built" budget row false.
- **The `waitUntilExit` numbers (DOC-4):** the step-5 numbers were measured on the main thread; see the summary.
- **Fix:** bound in both branches, with a runner-level test, and correct the RFC's step-5 table and its "What remains".
- **Confirmed by:** running and reading.

### H14 — Undo, Save As and other flows around data that were Medium last time and remain open
Carried forward, grouped because together they decide whether a crash loses work:
- There is still no autosave or crash recovery for dirty buffers (none found in `SIDE/`). With H1, a crash loses every unsaved buffer.
- Save As switches the tab's URL before writing and keeps the old encoding (`Make:4736`), so the refusal's advice, "Save As a new file to keep it as UTF-8" (`:4807`), can't work.
- A child track whose parent was deleted promotes the parent's history into main (`ReviewWorkspaceViewController.swift:1067-1079`).
- **Confirmed by:** reading.

### H15 — The app's own tests have no CI, and some race on the owner's real settings
- Only Heron and Alloy have CI (`Packages/*/.github/workflows/ci.yml`). The app's suite holds most of the regression tests for the 09-01 Highs and the DocStatus checks, and nothing runs it on a push.
- Parallel app tests do a read-modify-write of `SideACPCustomAgents` in the owner's real `com.shahi.side` defaults (`ACPAgent.swift:73-91`, from four test classes). This can make agents vanish mid-test, and it leaves test agents in the owner's Side.
- `DebugServerSessionTests.testALauncherSessionItsTerminalAndItsChild` "failed in 0 s": its runner process hung or died. Hazards:
  - `zsh -lic` runs on the main actor with no timeout (`DebugSession.swift:380`);
  - an unguarded `fulfill` (`DebugAdaptersTests.swift:165`);
  - a non-atomic dump from two threads.
- **Fix:**
  - An app CI workflow, or at least a pre-push script.
  - A volatile defaults domain under XCTest.
  - Test timeouts on, and the xcresult kept.
- **Confirmed by:** reading and the log.

---

## Part II — Medium

**Security**
- **SEC-10:** under Guarded, `fetch_url` auto-runs, and the URL path can carry data out. The query and fragment are refused; the path isn't. (`AgentRunner.swift:1716-1720`, `URLFetcher.swift:5-38`.) Ask below Full, or allow only previously approved hosts.
- **SEC-11:** language servers run repository code when a file is opened, with no trust step:
  - the project's own `node_modules/typescript/lib/tsserver.js` is preferred on purpose (`LanguageServerRegistry.swift:37-40`);
  - rust-analyzer runs `build.rs` and proc macros by default (`LSPManager.swift:486-500`).

  Add a per-project trust prompt; until trusted, use the global tsserver and turn off build scripts and proc macros.
- **SEC-12 / R2 / PRV-7:** the model-list refresh sends `x-api-key` on `URLSession.shared`, which follows redirects. A loopback 302 delivered `sk-ant-SECRET` to the second host. It runs daily, unasked (`ProviderRegistryStore.swift:79-96`). Its local-server URL is also `…/v1/v1/models`, so local lists never refresh. Share the SSE client's redirect refuser.
- **SEC-13:** consent fingerprints are FNV-1a-64 (`ProjectRules.swift:56-60`) for rules, `.side/tasks.json`, `.vscode/launch.json` and `.vscode/tasks.json`. Three full collisions were found in about 25 minutes on one core. A benign file accepted, then a colliding malicious preLaunchTask pulled, runs without asking again. Switch to SHA-256 and re-ask.
- **SEC-14 (open since 09-01):** Side's whole environment reaches every child: language servers, adapters, debuggees, git, gh, builds, installers and other vendors' ACP agents (`LanguageServerRegistry.environmentForSpawning`). With `ANTHROPIC_API_KEY` in Side's environment, which is supported, they all get it. Keychain values never reach a child (verified). Use one scrubbed environment for every spawn.
- **UX-14:** `ACPAgent.launchEnvironment` strips every agent's key variables, so a Codex or Gemini user in Subscription mode whose only credential is an exported key loses it. The BYO RFC describes a different design.

**Git and data**
- **GIT-3:** status without `--untracked-files=all` reports a new directory as a single entry, which breaks the checkpoint's set arithmetic:
  - a user-saved `newdir/notes.md` is committed with the agent's `newdir/x.swift` (the F4 fix bypassed);
  - a baseline `gen/` hides the agent's new `gen/agent.txt`;
  - with `status.showUntrackedFiles=no`, new files are never checkpointed;
  - delete-track's dirtiness check reports clean, so `--force` deletes untracked files.
- **GIT-4:** a staged rename's source is dropped, so a `git mv` inside a batch is checkpointed as a copy and leaves `D a.txt` staged.
- **GIT-5 / R3 / GIT-7 (index durability):**
  - A crash within the 1 s index delay hides a new track's conversation, and the next message appends to the old file, merging two conversations.
  - A corrupt `index.json` leaves checkpoints and archives unloaded, so the next checkpoint overwrites `checkpoints/<track>.json` with one entry.
  - The `checkpoints.json` migration deletes the legacy file even when its writes failed.
  - Fix: write immediately on entry add or remove, rebuild the index from `sessions/` at load, load checkpoints independently, and delete the legacy file only after every write succeeds.
- **GIT-6:** changes inside a submodule give "✓ Checkpoint … (no file changes)".
- **R5 / GIT-11:** a failed `git status` is treated as a clean tree. Three callers act on that: the approval baseline, promotion's cleanliness check, and delete-track's `--force`. Ignored files are skipped by delete-track's check.

**Heron**
- **HER-5:** a coordinator reads an idle subtrack whose transcript was dropped as "not started", with no reply (`TrackCoordinator.swift:110-112,203` read `existingRunner(...).entries`). Read from the session instead.
- **HER-6 / PRV-3:** usage is recorded only at `messageEnd`, so stopped, stalled and errored turns add $0 to Usage and the budget, although the input count is known at `message_start`.
- **PRV-5:** local providers default to a 128k window, while Ollama's default context is a few thousand tokens. The prompt is silently truncated while the gauge reads about 10%.

**Editor, language servers, debugger**
- **EDT-4:** inbound LSP and DAP messages are re-ordered one layer above the fixed transport: one `Task` per message (`LSPClient.swift:64`, `DAPClient.swift:60`). A mirror of the pattern had 6–181 adjacent swaps in 2,000 messages. Stale diagnostics overwrite fresh ones, and DAP stopped/continued events can swap.
- **EDT-5:** malformed server replies crash the app. Full-document formatting edits aren't checked for overlap (`Make:5012-5021` → `TextBuffer.swift:147-149` precondition; a release build trapped). Negative signature-help offsets also crash.
- **EDT-6:** rename, quick fixes and `workspace/applyEdit` apply at stale offsets if the person typed meanwhile; versions are ignored.
- **EDT-7:** Save As and untitled files cut the document off from its language server and from breakpoint following. The 09-01 close/reopen item was never done.
- **EDT-8:** an external replacement with an older modification time (`mv`, `cp -p`, `rsync -a`, `unzip`) is ignored, and the next save overwrites it.
- **EDT-9:** pasted CRLF text makes breakpoints drift, and a lone `\r` desyncs LSP lines.

**Concurrency and processes**
- **CON-3:** every language server leaks, with 3 file descriptors: `onTerminate` captures the client strongly (`LSPManager.swift:551-559`), and a new manager is made on every track switch. With a soft limit of 256 descriptors, eventually spawns fail.
- **CON-4:** the app's `git status` calls take `index.lock` (`TrackStore.swift:620,801,995`, `ShellViewController.swift:1402`, `FileExplorer.swift:407`). 11 of 60 of the user's `git add` runs failed under a status loop. Add `--no-optional-locks`.
- **CON-5:** every agent phase change re-runs `rev-list`, `status` and `du -sk` for every track, even when Tracks is off screen: about 32 spawns per phase change with 10 tracks. Requests during a refresh are dropped, so counts go stale.
- **CON-6:** `ProjectFileAccess.scanCache` never evicts: about 15 MB per 20,000-file worktree, and deleted tracks stay. A root over 25,000 files is never cached and re-walks on every call.
- **CON-7:** the caret blink keeps Alloy's display link running about 94% of the time in a focused, idle editor (about 57 wakeups a second). Foreground battery only.
- **Main-thread `waitUntilExit` (5 sites):** New Project's `git init`, `which` on first save, login-shell PATH resolution (220–270 ms, no timeout), and TrackStore's `runGit` from promote and branch naming. They also re-enter pending main-queue blocks mid-call (CON-8).

**Release**
- **REL-1:** `release.sh` deletes every earlier release build, dSYMs included, if the version lookup comes back empty (`scripts/release.sh:23-35`), then builds `Side-.dmg`.
- **REL-2:** nothing handles a Mac without the Command Line Tools. Every folder reads as a non-repository, and the system install dialog appears unexplained.

**UX and accessibility**
- **UX-5:** Compact fails silently after its confirmation (on outside-agent tracks, with no key, or while busy).
- **UX-6:** the debugger inspector is mouse-only (`clickedRow`, no keyboard or custom actions).
- **UX-7:** VoiceOver is silent while arrowing through the palette, mention and completion lists. Replies and failures aren't announced.
- **UX-8 (gate 5):** text size doesn't reach Preferences, Library, the debugger or the shell chrome, although Appearance's copy promises "this window".
- **UX-9:** Increase Contrast is ignored; dark surfaces are about 1.1:1.
- **UX-10:**
  - Remove Provider (which deletes the Keychain key), Remove key and Remove agent don't confirm.
  - Add Provider with a missing field adds nothing, silently.
  - Saved keys are never validated.

**Documentation**
- **DOC-2:** docs marked built claim unbuilt things:
  - Direction 02's "How do you work?" first-run step;
  - IDE Essentials' `didChangeWatchedFiles` and indexing progress;
  - the editor plan's fold shortcuts and column growth;
  - Phase 10's `SIDE.md` frontmatter tasks, and its debugger listed as out of scope;
  - the navigation ledger's 4-agent ceiling and "queued" caption.
- **DOC-4:** the efficiency RFC's step-5 figures (see the summary).

---

## Part III — Low and Info

- **SEC-1:** under Full autonomy an outside agent can create subtracks with no card, bounded by `spawnRefusal`'s child limit.
- **SEC-2:** outside agents' `terminal/create` follows the agent's own permissions, not Side's mode. By design, but unsaid in the UI.
- **SEC-15:** installers take the latest version with no checksum: js-debug's latest release through `curl | tar`, unpinned `pip`, `@latest`, `npm -g`.
- **SEC-16:** Library's Acknowledge accepts the file as it is on disk at click time, not as previewed.
- **SEC-17:** project prompts silently replace the user's prompts of the same name.
- **SEC-18:** Xcode project names get space-only quoting in task commands.
- **GIT-8:** checkpoint paths can be stored C-quoted: the `diff --cached` fallback lacks `-z`.
- **GIT-9:** a project opened at a repository's subdirectory fails every checkpoint.
- **GIT-10:** the first commit in an empty repository moves HEAD with no expected old value.
- **EDT-10:** the format-on-save read-back ignores the file's encoding and line endings.
- **EDT-11:** mixed line endings are normalized on any save.
- **EDT-12:** main-thread reads: Find References reading unopened files, and a clean tab re-decoded on every FSEvents batch.
- **EDT-13:** server lifecycle gaps:
  - a paused queue retained for an uninstalled server;
  - no `initialize` timeout;
  - no respawn backoff.
- **CON-9:** quit races the terminal's process-tree kill, and it sends SIGTERM only.
- **R4:** commands queued during the 3 s shell probe aren't cancelled by Stop.
- **UX-11:** the verification line can name a checkpoint that wasn't made.
- **UX-12:** messages that are slightly untrue:
  - "Every change waits for your approval";
  - "Nothing lands without you promoting it";
  - the relaunch compaction line;
  - the "Cleared N" count.
- **UX-13:** no Help or Services menu; the Settings window is titled "Preferences"; debugger fields have no focus ring; `.white` on accent.
- **PRV-6:** Claude 5's window is hard-coded at 200k, though the real window is 1M, so compaction fires at 170k. Conservative.
- **PRV-8:** no 429/529 backoff.
- **REL-3:** the build number is never checked against the appcast.
- **TST-3:** the benchmark's $3 cap can't trip for unpriced models; `heron-bench.sh` exits 0 on failure and puts the key in curl's argv.
- **TST-4:** `think.cpu` passes if the app died.
- **Tests:** H12 and H13 from 09-01 have no regression tests, and the process-hygiene scan skips Alloy.
- **Archives:** archived conversations never expire.
- **DOC-3:** stale status lines and details across the constitution, BYO, Library, Launch Performance, Direction 02 and the navigation ledger.
- **Build:** 287 unique warnings, up from 173.
  - About 260 are Swift 6 main-actor isolation, mostly in `MakeWorkspaceViewController` (108) and `TracksWorkspaceViewController` (57).
  - 12 are deprecations and 12 are hygiene.
  - None are in Heron or Alloy.

---

## Part IV — The 2026-09-01 findings

| ID | Verdict | Where it's fixed |
|---|---|---|
| C1 `env` auto-run | Fixed; its class reopened as C1 above | `CommandRiskClassifier.swift:74-98`; `CommandAutoRunPolicyTests` |
| H1 case-sensitive `.git` guard | Fixed | `ProjectFileAccess.swift:113-151`; `ProjectFileAccessGuardTests` |
| H2 key follows redirects | Fixed for streaming; reopened in the model refresh (SEC-12) | `SSEHTTPClient.swift:40-61`; `SSERedirectTests` |
| H3 corrupt store overwritten | Partly: quarantined, but the index isn't rebuilt (GIT-5/R3) | `JSONStore.swift:43-93` |
| H4 promote onto a detached HEAD | Fixed | `ReviewWorkspaceViewController.swift:1107-1130` |
| H5 delete-track `--force` | Fixed; gaps in GIT-3 and R5 | `TrackStore.swift:703-709` |
| H6 stale adopted worktree | Fixed | `TrackStore.swift:295-317` |
| H7 binary as Latin-1 | Fixed, and survived Alloy | `TextFileCodec.swift:43-94`; `FileIntegrityTests` |
| H8 no file watching | Fixed | `ProjectWatcher.swift` |
| H9 LSP registry race | Fixed | `LanguageServerRegistry.swift:56-191` |
| H10 LSP sync order | Fixed outbound; inbound re-ordered (EDT-4); Save As item open (EDT-7) | `LSPManager.swift:369-557` |
| H11 60 KB cap drops the start mark | Fixed | `TerminalViewController.swift:740-782` |
| H12 sentinel overwrite | Fixed, no test | `TerminalViewController.swift:683-686` |
| H13 Stop drops completions | Fixed, no test; residual R4 | `:516-523,608-617,1064-1070` |
| H14 verification loop | Fixed | `ProposedCommand.swift:81-88`; `AgentRunner.swift:719-725` |
| H15 activity group VoiceOver | Fixed | `WorkGroupViewTests` |
| H16 agent-state announcements | Fixed | `AccessibilityTests` |
| H17 formatter pipes | Fixed | `ProcessHygieneTests` |
| H18 wait before read | Fixed; all app sites read first | `TerminalViewController.swift:948-965` |
| H19 hardened runtime, notarization | Partly: Release only; notarization awaits credentials | `release.sh:60-94` |

Mediums from 09-01:
- **Fixed:** the forged OSC-133 exit (a nonce now), the symlink auto-run, `.side/tasks.json` consent, manual edits attributed to the agent (for Make saves), the negative Content-Length crash, the unredacted verification excerpt, and invisible failed runs.
- **Still open:** truncated replies reported as success (H5), autosave (H14), Save As encoding (H14), orphaned-child promotion (H14), and archives never expiring.

---

## Release-readiness gate

| Condition | Verdict |
|---|---|
| Zero known unattended code-execution paths | **Not met:** C1 |
| No data loss | **Not met:** C2, H1 with no autosave, H2, H4, GIT-5/R3 |
| No false success or misattribution | **Not met:** H4, H5, GIT-6, UX-11 |
| Spend is bounded as promised | **Not met:** H3, H5, H11 |
| Accessibility not blocking (gate 5) | **Not met:** UX-6, UX-7, UX-8 (by reading; a live VoiceOver pass is still needed) |
| A clean first run (gate 6) | **Not met:** H10 |
| Outside agents verified or labelled (gate 4) | **Not met:** H12 |
| Documentation is true | **Not met:** DOC-2, DOC-4, H13 |
| Prior fixes hold | **Met** (H12 and H13 of 09-01 untested) |

**Suggested order:**
1. The two Criticals.
2. H1, the SIGPIPE crash: one line at launch, plus the write calls.
3. The runaway-billing Highs: H3, H5, H6, H11.
4. The data Highs: H2, H4, and GIT-5 with R3.
5. H10, the first run.
6. H7, H8 and H9.
7. The Mediums, by stream.

Each fix should come with the test that would have caught it; several of these bugs shipped beside a test that passed.

---

## Fixes

- **C1, fixed 2026-09-30.** `CommandRiskClassifier`:
  - `rg` forbids `--pre`, `--pre-glob` and `--hostname-bin`.
  - `sort` forbids `--compress-program`.
  - `find` forbids `-okdir` and `-fprint0`.
  - `file` forbids `-C`/`--compile`.
  - One-letter forbidden flags also match inside clusters (`sort -uo out`).
  - git refuses every global option except `--no-pager`/`-P` (so `-c`, `--exec-path=`, `--git-dir=` and `--work-tree=` are refused).
  - The read-only git subcommands forbid `--output`, `--ext-diff`, `--textconv` and `--filters`.
  - 22 new rows in the must-not-auto-run table and 9 in the must-still-auto-run list.
- **C2, fixed 2026-09-30.** `CheckpointRestore.perform` refuses while anything is staged (`.stagedChanges`), and the sheet says what's staged and that nothing was changed. After a failed revert or commit, the unwind is limited to the checkpoints' own files. Tests: `testStagedWorkIsNeverTakenIntoOrWipedByAnUndo` and `testAFailedUndoCommitUnwindsOnlyTheCheckpointsFiles` (a pre-commit hook that refuses).
- **H1, fixed.** `PipeWriting` sets `F_SETNOSIGPIPE` on each pipe and writes with `write(contentsOf:)`, for the formatter, the LSP/DAP stdio transport and ACP. Side also ignores SIGPIPE at launch. Formatters get the login shell's PATH. Tests: a 300 KB write to an exited child in a process that doesn't ignore SIGPIPE (a control without the flag died); a formatter that exits without reading.
- **H2, HER-1, HER-3, UX-4, UX-5, fixed.**
  - The stored token count is cleared after compacting.
  - A summary-only conversation is never compacted again, which would overwrite Undo's copy.
  - The send after an Undo doesn't auto-compact.
  - Compaction is the stream task, watched by the stall watchdog and cancelled by Stop. A stopped automatic compaction keeps the message, unsent.
  - A manual Compact that can't run says why.
- **H3, fixed.** `teardown` sets `isTornDown`: results of tools already running are written, and nothing more is sent.
- **HER-4, fixed.** The ceiling applies whether or not anything was redacted.
- **H5, fixed.** A reply that hit the output limit, reported an error, or never ended doesn't run its tool calls, doesn't continue, and doesn't report success. An OpenAI-compatible stream that closes after its finish reason counts as ended.
- **H6, fixed.** Claude 5 gets `max_tokens` 64,000 and `thinking.display: "summarized"`. "Standard" effort is still the model's own default (see the open question below).
- **H11, fixed.**
  - Prices match dated and variant ids, and the table has rows for the published models the picker can list.
  - Under a budget, an unpriced remote model is refused.
  - The runner and compaction read their own usage store.
  - Outside agents stop at the limit, and Usage says their spend isn't in the estimate.
- **H4, fixed.** The index refresh falls back to `git reset -q HEAD -- <paths>` (not `add`, which would stage the person's own later edit), with a 10 s retry. If that fails too, `.committedIndexStale` puts the fix command in the transcript.
- **GIT-5, R3, GIT-7, fixed.**
  - An index entry being added or removed is written at once.
  - At load, the index is reconciled with the session files, and checkpoints and archives load regardless.
  - The legacy ledger is merged in by id, and removed only after every write succeeds (the same for `think.json`).
- **H10, fixed.** New Project and Initialize Git… make an empty initial commit (off the main thread). New Track in a repository with no commits offers Make Initial Commit. The first-run step says "Initialize Git…" for a plain folder.
- **H7, fixed.** ACP's and LSP's read handlers remove themselves at end of file. Test: an exited agent's next second cost 3.7 s of CPU before, under 0.2 s after.
- **H8, fixed.** The debugger's build runs through `posix_spawn` in its own process group, with the signal mask and dispositions reset. Stop signals the group. `start()` checks the session is live after every await. Test: 15 of 15 serial runs stop at once, leaving no process.
- **H9, fixed in Alloy (unreleased).** `endComposition()` on `setBuffer`, undo, redo and a `.replace` change. Test: both audit reproductions (they failed on the old code: `012中6789`).
- **H12, fixed.** Agents other than Claude Code are badged Experimental in Settings and labelled in the picker, and the footer no longer claims that any ACP agent works.
- **H13 / DOC-4, fixed.** The efficiency RFC's step-5 figures are corrected.
- **H9, released** in Alloy 0.7.1.
- **H14, crash recovery, fixed.** Unsaved buffers are copied outside the project every 2 s and offered back (Restore or Discard) when the project next opens.
- **H15, test isolation, fixed.** Under XCTest the Keychain is in memory and outside agents' settings live in a per-process defaults suite.
- **CON-4, CON-5, fixed.** Status calls pass `--no-optional-locks`; Tracks refreshes only on screen, coalesces requests and caches `du` for 60 s.
- **SEC-12, PRV-7, fixed.** The model-list refresh has its own session that refuses redirects, and takes none from callers. A local server's list is `models` under its base URL. Test: a loopback 302 no longer reaches the second host (it did before).
- **R5, GIT-11, fixed.** `GitPaths.dirtyPaths` is nil when status fails. An unknown baseline checkpoints only the known edits; Promote refuses and says why; Delete asks. Ignored files, which `git worktree remove` deletes with or without `--force`, are named and asked about by Delete and Remove Working Copy (`TrackStore.WorkAtRisk`); Library's bulk removal keeps those copies.
- **GIT-3, fixed.** Status passes `--untracked-files=all` (overriding `status.showUntrackedFiles=no`) and `--ignored=matching`. Checkpoint budget unchanged: 20,000 files, 91 ms, 5 git processes.
- **EDT-8, fixed.** Tabs keep a `DiskStamp` (date, size and inode, symlinks followed), taken before the read; any difference is an outside change.
- **EDT-5, fixed.** Format Document checks edits with `nonOverlapping`; completion's additional edits use `CompletionEdits.conflict`, which counts an insertion inside another edit; negative signature-label offsets are ignored.
- **Open:**
  - H14: Save As encoding, orphaned-child promotion.
  - H15: CI for the app's tests.
  - The other Mediums and Lows.
  - Seen once while fixing GIT-11: `CheckpointCostTests.testACheckpointInALargeRepository` reported `nothingToCommit` for a round of three edited files, then passed alone and three times together. Not reproduced; possibly racy stat data in the copied index.
