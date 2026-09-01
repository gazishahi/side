# SIDE Audit Report — 2026-09-01

**Audited state:** working tree at `a324fb0` (clean), branch `main`.
**Method:** ten parallel code audits (agent-safety/security; git-checkpoint-durability ×2;
editor/filesystem; terminal/process; LSP/language-intelligence; search/nav/tasks/verification;
product/IA/docs ×2; provider-network/tests/build/observability; visual-design/accessibility/keyboard/macOS;
Swift-concurrency/architecture/lifecycle/leaks/model-invariants). Clean Release-config build
captured (173 compiler warnings). No product code was changed by this audit.

This program deliberately re-tested every resolved item and every deferral from
[the 2026-08-30 audit](SIDE_AUDIT_REPORT_2026-08-30.md) and the carry-forward list, and
reconciled all claims against the constitution, design charter, launch-perf doc, concurrency
doc, and Phase-10 doc.

Two of the most severe findings were verified first-hand at the source (not only reported by an
agent): the `env` auto-run bypass (`CommandRiskClassifier.swift:77`) and the case-insensitive
`.git` write-guard bypass (`ProjectFileAccess.swift:92`).

---

## Executive summary

Side's core promises largely hold and the prior audit's fixes are **all confirmed still in place
and test-pinned** — the checkpoint isolated-index commit, three-layer `tool_use`/`tool_result`
protection, argv-style git invocation, path-traversal containment, atomic JSON persistence, the
allowlist-based auto-run redesign, and the closed TrackStore races were each re-verified by
reading current code. Test coverage is genuinely strong for an alpha (333 tests, 18 of 30 unit
files exercise real git/filesystem/subprocesses rather than mocks).

But the audit surfaced **1 Critical and ~18 High findings**, of which the most consequential are
**two independent unattended-code-execution paths** the previous hardening left open, **a corrupt-
store-overwrite and several silent data-loss / false-success paths** in the git and editor layers,
**a language-intelligence subsystem with a live data race and broken document-sync ordering**, and
**a verification loop (Phase 10) that is ~80% built but does not actually close in practice.**
Separately, a large **documentation-truthfulness** gap recurred: Phase 10 shipped on 2026-08-30
(commit `9ba8090`) yet its doc still says "Not started" — the same drift class the 2026-08-25
audit flagged for stacked tracks, whose recommended CI fix was never implemented.

**Release verdict: NOT release-ready.** The suggested release gates from the 2026-08-25 audit
("zero known auto-run destructive bypasses", "every pending proposal recoverable after SIGKILL",
"no data-loss defects") are not all met. See §"Release-readiness gate" for the blocking set.

### Severity rollup (deduplicated across streams)

| Severity | Count | Theme |
|---|---|---|
| Critical | 1 | `env`/`printenv` auto-run → arbitrary code execution |
| High | 18 | code-exec bypass, data loss, false success, LSP race/ordering, verification loop, a11y blockers, no-sandbox-for-distribution |
| Medium | ~35 | encoding/binary handling, misattribution windows, provider/billing blind spots, IME, macOS conventions, isolation debt |
| Low / Info | ~40 | token drift, minor lifecycle, doc drift, test-quality |

Owner is the same individual across the codebase (solo project); the "Owner" column below names
the responsible subsystem to route the work, not a second person.

---

## Part I — Critical & High findings (full schema)

### C1 (Critical) — `env` / `printenv` in the auto-run allowlist → unattended arbitrary code execution
- **Scope:** `CommandRiskClassifier.swift:77` (`readOnlyCommands`), consumed at `AgentRunner.swift:1374-1375`.
- **Invariant:** auto-run only when *every part* of a command is affirmatively recognized read-only (the file's own rule, `CommandRiskClassifier.swift:57-64`; awk/sed/node were removed for exactly this).
- **Threat model:** prompt-injection payload in a repo file / tool result / model output, on a track the user set to Guarded or Full.
- **Evidence (VERIFIED first-hand):** `"env": [], "printenv": []` are listed as flagless read-only. `disqualifyingSyntax` (lines 68-70) contains no `(`, `)`, `'`, or `"`. So `env node evil.js`, `env sh -c id`, `env python -c '…'` tokenize cleanly, no argument escapes the project, no forbidden flag matches → `isAutoRunnable == true` → typed into the live PTY with no click and no warning. `env` then execs its argument as a program — the launcher class the allowlist premise cannot vouch for.
- **Affected workflows:** any Guarded/Full track; `run_task` with a `.side/tasks.json` command of the form `env …` (not acknowledgement-gated like `AGENTS.md`).
- **Remediation:** remove `env` and `printenv` from `readOnlyCommands` entirely.
- **Regression test:** assert `isAutoRunnable` is false for `["env python -c 'print(1)'","env node x.js","env sh -c id","env FOO=bar rm x","env","printenv","printenv PATH"]` (mirror `testInterpretersNeverAutoRun`).
- **Owner:** Heron / command-safety. **Disposition: NEW.**

### H1 (High) — `.git` / `.side` write-guard is case-sensitive → `.GIT/hooks` bypass → code execution
- **Scope:** `ProjectFileAccess.isWritable` (`:87-92`), `isReadable` (`:70-74`); enforced by `ToolExecutor`.
- **Invariant:** the file states it — a write into `.git/config` or `.git/hooks/` "turns an edit into code execution … escapes the approval boundary entirely."
- **Threat model:** agent-supplied write path on default (case-insensitive) APFS.
- **Evidence (VERIFIED first-hand):** `return firstComponent != ".git" && firstComponent != ".side"` — exact string compare. `.GIT/hooks/post-checkout` or `.Side/…` passes the guard and writes into the real directory; Side runs `git status` unattended while checkpointing, so a planted `core.hooksPath`/`core.fsmonitor` executes without approval. Auto-applies without a click under Full autonomy. `isReadable`'s `.git/side/` prefix check has the same casing hole (`.GIT/side/` becomes readable — cross-track conversation leak).
- **Remediation:** case-fold the component comparison, or resolve the candidate and compare against the real `.git`/`.side` inodes; reject any component equal case-insensitively.
- **Regression test:** on APFS, `isWritable(".GIT/config")` and `isReadable(".GIT/side/x")` must be false.
- **Owner:** Heron / ProjectFileAccess. **Disposition: NEW.** (Critical under Full autonomy.)

### H2 (High) — API key follows cross-host HTTP redirects
- **Scope:** `SSEHTTPClient` (delegate-less `URLSession`, `:35-54`); keys set in `AnthropicMessagesProvider.swift:40` (`x-api-key`) and `OpenAICompatibleChatProvider.swift:40` (`Authorization: Bearer`).
- **Invariant:** a credential must never be replayed to a host the user didn't authorize.
- **Threat model:** a BYOK base URL, a compromised/misconfigured endpoint, or an intercepting proxy returns a 30x to an attacker host.
- **Evidence:** URLSession's default redirect policy re-issues the original request — including custom headers — to the redirect target. SSE streaming never legitimately redirects.
- **Remediation:** add a `URLSessionTaskDelegate` that refuses redirects (or strips auth headers on host/scheme change).
- **Regression test:** loopback server returns 302 to a second server; assert the second never receives `x-api-key`/`Authorization`.
- **Owner:** Heron / networking. **Disposition: NEW.**

### H3 (High) — A corrupt store file is overwritten by the very next save (no quarantine/backup)
- **Scope:** `JSONStore.write` (`:68-78`); loaders in `TrackStore.load` (`:779-781`), `AgentSessionStore.load` (`:356-357`), `UsageStore.load` (`:228-230`).
- **Invariant:** corruption must be isolated, not compounded; a reported read failure must not destroy the evidence.
- **Failure model:** `tracks.json`/`checkpoints.json`/`index.json` is corrupted; `JSONStore.read` correctly reports and returns nil; loaders substitute `[]`; the first mutation (a reconcile-triggered `save()` can fire seconds after launch, `TrackStore.swift:204/215/229`) writes the empty array over the corrupt file. One alert, then permanent loss. Corrupt `index.json` additionally makes every conversation invisible while the `.jsonl` files still exist on disk.
- **Remediation:** on read failure for an existing file, rename it aside (`*.corrupt-<ts>`) before permitting any write; rebuild `index.json` by scanning `sessions/*.jsonl` headers rather than treating a missing index as "no sessions."
- **Regression test:** write garbage to `tracks.json`, construct the store, `save()`, assert the original bytes survive under a quarantine name.
- **Owner:** Heron / persistence. **Disposition: STILL-OPEN, escalated** (2026-08-30 "no backups on corruption" — it is not merely missing backup; the evidence is actively overwritten).

### H4 (High) — Promote into a detached-HEAD merge root reports false success
- **Scope:** `ReviewWorkspaceViewController.performMerge` (`:715-718`).
- **Invariant:** "no failure can falsely report user work"; "`main` is canonical."
- **Failure model:** the merge root (canonical checkout or parent worktree) has a detached HEAD (user inspecting an old commit, mid-rebase with a clean tree). `symbolic-ref --short HEAD` fails, the `checkout baseRef` step is skipped, `git merge` runs against the detached commit, Side prints "✓ Promoted to main (sha)" and marks the track completed. The base branch never moved; the merge commit is reachable only via reflog.
- **Remediation:** treat `symbolic-ref` failure as a hard refusal; after any checkout, verify `HEAD == baseRef` before merging.
- **Regression test:** detach HEAD in the merge root, promote, assert refusal and that the base ref did not move.
- **Owner:** Review / promotion. **Disposition: NEW.**

### H5 (High) — Delete Track destroys uncommitted work via `worktree remove --force`
- **Scope:** `TrackStore.deleteTrack` (`:624`, `:645`); dialog copy `TracksWorkspaceViewController.swift:1067`.
- **Invariant:** "work is durable" / the codebase's own rule (`TrackStore.swift:666-668`, applied only to `removeWorkingCopy`).
- **Failure model:** a track worktree holds uncommitted edits (agent's un-checkpointed work or the user's). Delete with "Also delete branch" **unchecked** — the user reasonably believes the work survives. `--force` obliterates every uncommitted/untracked file. Dialog says only "This removes the track from the list."
- **Remediation:** probe `status --porcelain` first; if dirty, name the count of changes to be destroyed and require explicit consent, or refuse (mirroring `removeWorkingCopy`).
- **Regression test:** dirty worktree, `deleteTrack(alsoDeleteBranch:false)`, assert refusal/consent path and file survival.
- **Owner:** TrackStore. **Disposition: NEW.** (Independently found by both git-durability passes.)

### H6 (High) — Stale adopted-branch worktree path binds a new track to the wrong branch
- **Scope:** `TrackStore.applyReconciliation` (`:222`, `:228` update `untrackedBranch` without clearing `untrackedBranchWorkingDirectoryPath`); `promoteCurrentBranch` (`:293`) transfers the stale path.
- **Invariant:** every operation stays attached to the correct track; no misattribution.
- **Failure model:** "Switch to Existing Branch…" → branch A (worktree materialized, path stored). Without promoting, user `git checkout B` in the main tree. Reconcile sets `untrackedBranch = "B"` but keeps A's path. "Turn Into a Track" for B creates a track whose working directory is A's worktree on branch A; every subsequent edit, checkpoint, terminal session, and promote for "track B" operates on branch A. Permanent misattribution.
- **Remediation:** clear `untrackedBranchWorkingDirectoryPath` when `untrackedBranch` changes; on promote, verify the worktree's checked-out branch equals the branch being promoted.
- **Regression test:** adopt→external-checkout→turn-into-track sequence; assert the new track's worktree is on the right branch.
- **Owner:** TrackStore. **Disposition: NEW.**

### H7 (High) — Binary / non-UTF-8 files open as Latin-1 and save-corrupt irreversibly
- **Scope:** `ProjectFileAccess.decodeText` (`:44-49`), save path `MakeWorkspaceViewController.swift:3016`, `ProposedEditApplier.swift:37`.
- **Invariant:** saving an unmodified region must not change bytes; a file that can't be faithfully round-tripped must not be silently rewritable.
- **Evidence (VERIFIED first-hand):** the decode ladder ends in `.isoLatin1`, which never returns nil for any byte sequence, so the "not a text file" alert (`MakeWorkspaceViewController.swift:1390`) is unreachable. Any binary file without an image extension opens as mojibake; one keystroke + ⌘S rewrites it as UTF-8, destroying it with no warning and no undo. Non-UTF-8 text (CP1252/UTF-16) is silently transcoded to UTF-8 on save; CRLF files gain mixed line endings on typed newlines.
- **Remediation:** NUL/control-density sniff before decoding text; record per-tab encoding + dominant line ending and write them back; require a BOM for the UTF-16 branch.
- **Regression test:** open a file containing `0x00` → refused; open CP1252 fixture, edit line 1, save, assert untouched bytes unchanged.
- **Owner:** Make / ProjectFileAccess. **Disposition: NEW.**

### H8 (High) — No file watching anywhere; open buffers and indexes go silently stale
- **Scope:** whole editor/index/LSP layer (grep: zero `FSEvents`/`DispatchSource`/`NSFilePresenter`/`kqueue`; no `windowDidBecomeKey` observer).
- **Invariant:** "attention is explicit" — an open buffer should reflect or warn about external modification.
- **Failure model:** in an agentic IDE this is acute — the user's terminal (`git pull`, a script) or the agent's own applied `write_file` rewrites a file under a clean tab; the editor shows stale content indefinitely, and Heron's read tools serve *disk* content for clean tabs while the user reads the old buffer, so the two discuss different code. Think's `@`-mention index is frozen at first attach (`ProjectFileIndex.refresh` early-returns on unchanged root), so a file the agent just created cannot be `@`-mentioned for the life of the track.
- **Remediation:** one FSEvents watcher per project root feeding editor + both indexes + LSP; cheap first step: mtime sweep on `windowDidBecomeKey`, and drop the same-root early-return.
- **Regression test:** modify a file externally, pump the run loop, assert buffer/flag and index updated.
- **Owner:** Make / indexing. **Disposition: NEW.**

### H9 (High) — LanguageServerRegistry static caches are a live data race
- **Scope:** `resolutionCache` (`:141`), `loginShellPATHCache` (`:86`), `globalNpmRootCache` (`:55`) — all `nonisolated(unsafe) static var`.
- **Invariant:** an unsynchronized static mutable value must be confined to one isolation domain.
- **Race model:** `LSPManager.spawnOrReuseClient` resolves on a **concurrent** global queue (`LSPManager.swift:191-194`) while `XcodeBuildServerSetup.ensureConfigured` calls `resolveExecutable` on the **main** thread (`:27`), and `invalidateResolution` runs on main during install-retry. Opening a `.swift` and `.ts` back-to-back, or two windows/projects, mutates the same process-global `Dictionary` concurrently → corruption/crash. The window is large (`$SHELL -lic` is hundreds of ms). The comment "callers are expected to serialize access" is factually false.
- **Remediation:** make the registry a caching actor, or guard all three caches with one `NSLock`; delete the false comment.
- **Regression test:** open `.swift` + `.ts` back-to-back under TSan; assert no race and one entry per binary.
- **Owner:** LSP. **Disposition: STILL-OPEN, upgraded** (2026-08-30 called it "a hatch over a known problem"; confirmed live). **This should be step 1 of the concurrency remediation, ahead of the doc's ordering** — it is the only opt-out that is a genuine memory-safety race; the other 158 warnings are compiler-unproven-but-runtime-correct main-queue hopping.

### H10 (High) — LSP document sync is unordered, and a crashed server never gets `didOpen` replayed
- **Scope:** `LSPClient.notify`/`request` (`:86-101`, each enqueues via a separate unstructured `Task`); `LSPManager.completion` flush (`:91-104`); crash eviction `setOnTerminate` (`:229-234`) without clearing `documentVersions`.
- **Invariant:** diagnostics/completions must apply to the correct buffer version; `didOpen` precedes `didChange`; versions monotonic per opened doc.
- **Failure model:** (a) two `didChange` notifications can reach the server transposed (v5 before v4), leaving the server's mirror permanently stale → diagnostics underline wrong lines, completions answer old text; the "flush didChange before completion" fix is racy by construction. (b) After a server crash, the respawn receives a bare `didChange` for a URI it never opened, and `documentVersions` still holds the pre-crash counter → strict servers (pyright) drop everything → no diagnostics/completions for every open file for the rest of the session, silently.
- **Remediation:** serialize all sends through one pipeline; on terminate clear `documentVersions` and replay `didOpen` for open tabs of that language; send `didClose`/`didOpen` on Save-As.
- **Regression test:** mock transport recording order; 100 interleaved didChange/completion → monotone versions, completion-after-flush; kill server, type, assert didOpen precedes didChange on the replacement.
- **Owner:** LSP. **Disposition: NEW.**

### H11 (High) — Terminal 60 KB cap drops the OSC-133 start mark → agent command wedges to timeout on verbose builds
- **Scope:** `TerminalViewController.handleAgentCommandData` marks path (`:488-518`), `boundedAppend` (`:134-140`).
- **Invariant:** a completed command must resolve its `completion` exactly once (a dropped result is the dangling-`tool_use` shape).
- **Failure model:** the buffer keeps only the last 60 000 chars; a command emitting more output between its `C` and `D` marks loses the `C` mark off the front, so completion is never detected and the command reports the 30 s timeout "still running" message though it finished. This breaks precisely on `swift test`/`npm test`/`xcodebuild test` — the verbose case the cap was added for, and the exact tasks Phase 10 verification depends on. (Marks path only; sentinel path is immune.)
- **Remediation:** latch "output started" when `C` is first seen and resolve on `D` alone; track the start offset separately from the ring buffer; raise/remove the timeout for task-tagged commands (visible in the terminal; wait on `D` with a heartbeat).
- **Regression test:** synthetic stream with >60 KB between C and D → resolves with correct exit code.
- **Owner:** Run / terminal. **Disposition: NEW.** (Independently found in terminal, LSP/search, and tasks streams.)

### H12 (High) — Sentinel-mode queue clobber drops a command's tool_result → wedged conversation
- **Scope:** `TerminalViewController.handleAgentCommandData` sentinel path (`:546-579`); the `defer` at `:546-549` overwrites the freshly-installed next-command tuple with the old completed one.
- **Invariant:** every `run_shell_command` gets exactly one truthful `tool_result`.
- **Failure model:** bash (or any shell where OSC-133 integration isn't confirmed), Guarded/Full, a batch of ≥2 auto-runnable commands: the first resolves via sentinel and immediately starts the second; the `defer` then clobbers the second's tuple, so its sentinel is never matched, its timeout never fires, its completion never runs — the conversation hangs on a missing tool_result.
- **Remediation:** make the defer generation-aware (capture the generation at entry) or resolve after the defer scope ends.
- **Regression test:** drive two queued sentinel commands in one stream; assert both completions fire exactly once.
- **Owner:** Run / terminal. **Disposition: NEW.**

### H13 (High) — Interrupt / shell-exit drops *queued* agent-command completions → unresolved tool batch
- **Scope:** `interruptAgentCommand` (`:456-467`) and `processTerminated` (`:735-743`) call `queuedAgentCommands.removeAll()` without invoking the removed completions.
- **Invariant:** every `tool_use` answered (`AgentRunner.swift:1265-1267`).
- **Failure model:** auto-run batch of ≥2, Stop during the first: queued entries' completions never fire → `batch.unresolvedToolUseIds` never empties → `finishBatchIfReady` never runs → results never persisted, runner stuck in `.awaitingApproval` until window-close teardown or the load-time repair synthesizes rejections.
- **Remediation:** drain the queue by invoking each completion with a "cancelled before running" message, then clear.
- **Regression test:** 3-command auto-run batch, Stop during the first; assert all 3 ids resolved and phase leaves `.awaitingApproval`.
- **Owner:** Run / terminal + Heron. **Disposition: NEW.**

### H14 (High) — The Phase-10 verification loop does not close in practice
- **Scope:** verification capture (`TerminalViewController` 30 s/60 KB limits — see H11), attachment (`AgentSessionStore.attachVerification:145` targets the latest *existing* checkpoint), promote staleness (`ReviewWorkspaceViewController` `latestVerified:637`).
- **Invariant:** a verified checkpoint should gate promotion; verification evidence must be fresh and attached to the change it verifies.
- **Failure model:** (a) real test tasks exceed 30 s / 60 KB → no verification recorded (H11). (b) In the common "edit then test in one batch" shape, the verdict is stamped on the *previous* batch's checkpoint (or dropped if none exists); the checkpoint containing the change is born "Unverified." (c) If checkpoint N passed and N+1…N+3 landed unverified, the promote dialog shows *no* warning — stale pass treated as current; `ranAt` is stored but never compared. Together the flagship "verified gates promotion" story works only for small, fast, single-batch cases.
- **Remediation:** fix the capture limits (H11); carry the pending verification into the batch's own checkpoint creation; gate the promote warning on the *newest* checkpoint's verification and surface "verified N checkpoints ago."
- **Regression test:** `edit_file`+`run_task` batch → verification lands on the checkpoint whose `changedFilePaths` contains the edit; stale-pass fixture → promote dialog carries the caveat.
- **Owner:** Heron / Review. **Disposition: NEW** (feature is built but ineffective).

### H15 (High) — WorkGroupView (now holding the agent's reasoning) is not operable by VoiceOver
- **Scope:** `ThinkWorkspaceViewController.swift:1808-2008` — toggles via `mouseDown`/`hitTest` only; sets a label but no role, no `accessibilityPerformPress`, no expanded state.
- **Invariant:** WCAG 4.1.2; the reasoning render landed *inside* this group (commit `a324fb0`), so reasoning is now mouse-gated.
- **Remediation:** mirror `HeaderClickView` — `isAccessibilityElement`, `.disclosureTriangle` role, `isAccessibilityExpanded`, `accessibilityPerformPress { toggle() }`, `.valueChanged` post.
- **Regression test:** extend `WorkGroupViewTests` with role/press assertions.
- **Owner:** Think / accessibility. **Disposition: NEW.**

### H16 (High) — No VoiceOver announcement for agent state changes
- **Scope:** grep `announcementRequested`/`.announcement` → zero; state rides in stage-switcher glyphs (`ShellViewController.swift:313-331`) read literally by VoiceOver.
- **Invariant:** live-region equivalence; a VoiceOver user working in Make gets no audible signal when a track flips to `needsYou`.
- **Remediation:** post `.announcementRequested` in `runnerActivityChanged()`; give the segmented control real per-segment AX labels instead of `●`/`◑` glyphs in the visible string.
- **Regression test:** unit-assert the segment AX labels; announcement itself requires a live pass.
- **Owner:** Shell / accessibility. **Disposition: NEW.**

### H17 (High) — Formatter subprocess pipes never drained → save deadlock
- **Scope:** `MakeWorkspaceViewController.runFormatterIfNeeded` (`:3040-3043`); same shape at `XcodeBuildServerSetup.swift:54-58`.
- **Invariant:** never `waitUntilExit()` while an attached pipe is undrained (the exact class the 2026-08-30 audit fixed in 11 sites).
- **Failure model:** a formatter emitting >64 KB blocks writing; `waitUntilExit` never returns; `tab.isSaving` stays true forever; every subsequent ⌘S is silently ignored; quit/close report failure.
- **Remediation:** read handles to end (or `FileHandle.nullDevice`) before waiting; reset `isSaving` on all paths.
- **Regression test:** formatter stub writing 128 KB → save completes within a deadline.
- **Owner:** Make. **Disposition: REGRESSION of a fixed class.**

### H18 (High) — `descendantPIDs` waits before reading the pipe → teardown deadlock, orphaned shells
- **Scope:** `TerminalViewController.descendantPIDs` (`:695-701`) — `waitUntilExit()` before `readDataToEndOfFile()` on `ps -eo pid,ppid`.
- **Invariant:** read before wait (documented at `GitPaths.swift:87-90`).
- **Failure model:** `ps` output exceeding ~64 KB (busy Mac) blocks writing → the enumeration hangs on a global-queue block → the shell and its descendants never receive SIGTERM → the exact orphaned-process leak `terminateProcessTree` exists to prevent, plus a leaked thread per close.
- **Remediation:** swap the two lines; mark `descendantPIDs` `nonisolated`. Consolidate the four duplicated `runGit`/`runShell` helpers onto `GitPaths.runGit` (this bug is what the duplication invites).
- **Regression test:** static check "no `waitUntilExit` before reading an attached pipe"; unit-test `descendantPIDs` against a child printing >64 KB.
- **Owner:** Run / terminal. **Disposition: NEW / regression class.** (Independently found in both git passes and the concurrency pass.)

### H19 (High, for distribution) — No App Sandbox, Hardened Runtime, entitlements, or notarization
- **Scope:** no `.entitlements`/`Info.plist` in the tree; pbxproj has no `ENABLE_APP_SANDBOX`/`ENABLE_HARDENED_RUNTIME`/`CODE_SIGN_ENTITLEMENTS`; `CODE_SIGN_STYLE = Automatic` only; no updater/notarization pipeline.
- **Invariant:** an agentic app executing model-proposed shell commands ships with zero OS-level containment; every defense is application-layer.
- **Remediation:** decide and document the sandbox posture; at minimum Hardened Runtime + Developer ID + notarization before any distribution; scope Keychain access groups.
- **Owner:** build/release. **Disposition: STILL-OPEN** (2026-08-25). Acceptable for a personal dev build; blocking for distribution.

---

## Part II — Disposition by audit family (all 40)

Legend: **Pass** (verified conformant), **Partial**, **Fail**, **Built-not-verified**, **Runtime-required** (needs a live/instrumented pass this program flagged rather than fabricated).

### 1. Product & workflow audits
| # | Audit | Disposition | Key result |
|---|---|---|---|
| 1 | Product-constitution compliance | Partial | 5 built stages pass canvas/tracks-first/promote tests; 2 present-tense IA claims unimplemented ("opens at the stage that best matches state"; "search retrieves archived work") — P-F4. Full autonomy is the one documented exception, correctly checkpointed. |
| 2 | End-to-end developer journey | Partial | Happy path works; gaps at *verify* (H14), *diagnose* (no project-wide diagnostics UI), *recover* (no autosave/crash recovery for dirty buffers), and *publish* (no push/PR; promote-conflict is an in-app dead end). |
| 3 | Feature-completeness / missing-capability | Partial | Integration & Library correctly absent+labeled planned. Genuine gaps not on the v1 non-goal list: no user-facing project text search, no rename/refactor, no human task-chip row, no diagnostics aggregate view. |
| 4 | Competitive workflow | **Runtime-required** | Needs installed/licensed Cursor/Xcode/Zed/VS Code, a fixed task, and a timing protocol. Not fabricated. Methodology in §Runtime-required. |
| 5 | User-research / usability | **Runtime-required** | Needs recruited novice/intermediate/expert + accessibility users on unfamiliar repos. Static signal: hover-only row actions are likely poor for keyboard/VoiceOver (H-a11y). |
| 6 | Information architecture & attention | Partial | Attention machinery is the strongest surface (pinned needsYou, badges, notifications) — but **failed runs are invisible** (finish as `.idle`→`.none`), so a background rate-limit/transport error shows no chip/badge/notification. |

### 2. Core IDE correctness
| # | Audit | Disposition | Key result |
|---|---|---|---|
| 7 | Editor correctness & data integrity | **Fail** | H7 (binary/encoding corruption), H8 (no file watch), H17 (formatter deadlock); plus Save-As duplicate-tab identity, case-insensitive tab dedupe, directory rename/delete strands tabs, no autosave. Prior #15/#16 fixes hold. |
| 8 | Filesystem & project boundary | Partial | Path containment strong (11-escape suite holds); **H1** casing bypass; symlink-in-repo couples membership to targets; extensionless/hidden files invisible and dropped from restore; packages (`.xcassets`) explode the index. |
| 9 | Git / worktree / checkpoint / promotion | Partial→Fail | H4 (detached-HEAD false success), H5 (delete force-loss), H6 (branch misattribution); commit sequence itself is SIGKILL-safe (isolated index + CAS update-ref); undo/promote/pull-from-parent conflict handling sound. Manual edits in the approval window get committed as agent work (Med). |
| 10 | Terminal & process management | Partial | H11/H12/H13/H18; exit-status *forgeable* by repo output via fake OSC-133 `D;0` (Med); OSC-52 clipboard read/write enabled by default (Med); descendant kill SIGTERM-only. Cancellation/exit *honesty* (never fabricates success) is exemplary. |
| 11 | Language intelligence | **Fail** | H9 (live race), H10 (ordering + no didOpen replay); no request timeout/`$/cancelRequest`; full-document didChange every keystroke; diagnostics applied without version gating; extensionless files invisible to LSP too. |
| 12 | Build/task/test/diagnostics/debugging | Built-not-verified | Phase 10 is ~80% built (see H14); approval boundary for tasks *holds at every autonomy level*; honest unknown-exit handling; cheap-80% debugging (clickable `file:line`) present; no human task surface. |
| 13 | Search / navigation / indexing | Partial | Quick Open race hygiene, FuzzyMatcher, SymbolIndexer all sound (prior quadratic fixes intact); **no project-wide text search for the human**; ignore rules hardcoded (not `.gitignore`) and the two ignore sets disagree; 25k truncation silent; stale completion range on accept. |

### 3. Agent, security, privacy
| # | Audit | Disposition | Key result |
|---|---|---|---|
| 14 | Agent authority & tool boundary | Partial | Scope enforced at dispatch (confirmed-fixed); autonomy not clamped to `.manual` in read-only scope at the enforcement layer (Low, exploitable with C1). |
| 15 | Command-execution threat model | **Fail** | **C1** (`env`); auto-run containment doesn't resolve symlinks (planted `creds→~/.aws/credentials` auto-reads, Med). git-config/`-C`/path-qualified/tab-join all correctly blocked. |
| 16 | Proposed-edit & apply pipeline | Pass | Staleness/overlap/new-file-collision refused; disk-first ordering; single apply funnel; content stripped after resolution. Confirmed-fixed. |
| 17 | Prompt injection / untrusted repo | Partial | Per-content acknowledgement for `AGENTS.md`/`CLAUDE.md`/`SIDE.md` holds and de-authorizes on rewrite; `.side/tasks.json` is *not* acknowledgement-gated (feeds C1/F-5 xcodeproj-name injection); exit-status forgeable (audit 10). |
| 18 | Secrets & privacy | Partial | Keychain sound; `ANTHROPIC_API_KEY` confirmed *not* inherited by PTY children (SwiftTerm curates env) but *is* passed to LSP servers and git; `.netrc`/`.pgpass` unredacted; user/assistant message text never redacted (both still-open); **`CheckpointVerification.outputExcerpt` persists raw test output to `checkpoints.json` unredacted** — a second on-disk path around the `SecretRedactor` choke point (Med, new — run `SecretRedactor.redacting` before building the excerpt). |
| 19 | Network & provider | Partial | **H2** (redirect key leak); OpenAI-compatible usage never requested (budget blind); truncated-with-partial-text finishes as success; endpoint validation is scheme-non-nil only. Stop-never-rebills and budget-before-every-request confirmed clean. |
| 20 | Application & platform security | Partial | **H19** (no sandbox/notarization); `JSONRPCTransport` traps on negative Content-Length; supply chain clean (1 pinned dep, no build scripts, no bundled binaries, permissive licenses). |

### 4. Reliability & engineering
| # | Audit | Disposition | Key result |
|---|---|---|---|
| 21 | Swift concurrency & state ownership | Partial | **H9** the one live race; 158 concurrency warnings reconciled to the doc (no regression); every `@unchecked Sendable`/`nonisolated(unsafe)` judged (LaunchSignposts/DiagnosticsSnapshot/SummaryCollector exemplary; LanguageServerRegistry unsafe; the rest main-confined-by-convention). AgentSessionStore/UsageStore/ProviderRegistryStore should be `@MainActor`. |
| 22 | Persistence, migration, recovery | Partial | **H3** corrupt-store clobber; archived conversations never expire despite retention (Med); migration idempotency & tolerant decoding sound; JSON atomic writes confirmed. |
| 23 | Lifecycle & multi-window | Pass-with-notes | Single-context-per-project, background-run survival, cross-window edit routing all verified sound; per-window LSP managers duplicate servers (Med); reopen-with-no-windows no-op; stale dock badge on window close. |
| 24 | Performance & scalability | **Runtime-required** | Launch signposts exist; `PerformanceTests` baselines exist. No new benchmark run here; terminal output flooding is all-main-thread with O(n²) allocation (Med) — flagged for measurement. |
| 25 | Resource leaks & teardown | Pass-with-notes | Observers/timers/monitors/undo-stacks/URLSession/memory-ceilings all verified clean; fire-and-forget LSP stop; H18 leaks a thread on the deadlock path. Full Instruments pass is **Runtime-required**. |
| 26 | Fault injection & resilience | Partial | Static: stall watchdog, transport timeout, persistence-failure reporting, checkpoint SIGKILL-safety all sound. Live kill-at-awkward-moments matrix is **Runtime-required**. |
| 27 | Architecture & maintainability | Partial | Heron AppKit-free except 3 view files misplaced in `Heron/`; two 3.5k-line VCs (Make/Think); 4 duplicated spawn helpers (one already wrong — H18); dependency direction sound; hidden global state enumerated and mostly locked/main-confined. |
| 28 | Model invariants | Pass-with-gaps | Checkpoint "success⇔commit" made unrepresentable; `tool_use`/`tool_result` triple-protected; ProposedEdit "proposed≠applied" structural; **gaps:** two-`.active`-tracks representable from a torn file; Checkpoint decode fabricates a fresh `agentSessionId`. |

### 5. Native Mac quality
| # | Audit | Disposition | Key result |
|---|---|---|---|
| 29 | Visual design system | Pass-with-drift | Token migration dramatically improved (24→2 `NSColor(white:)`, ~60→5 raw `ofSize:`, 8→4 numeric radius); new drift: diff/gutter colors are two disagreeing hardcoded palettes; MarkdownRenderer headers ignore the scale (+bold below 15); terminal font fixed and its "set separately" setting doesn't exist; Preferences window isn't forced dark. |
| 30 | Accessibility | **Fail** | **H15/H16**; editor gutter marks invisible to AX + 3-pt targets; SlidingSegmentedControl/composer/mention-popup unlabeled; reduced-motion never consulted; hover-only actions have no keyboard/AX path. Diff a11y stack is exemplary. Prior terminal/diff fixes confirmed. Full VoiceOver pass **Runtime-required**. |
| 31 | Keyboard / focus / input | Partial | ⌘M collision & Open-Project stranding confirmed-fixed; **⌃1–⌃5 collide with Mission Control Spaces**; concrete IME `hasMarkedText` bug in Quick Open; async agent updates yank the scroll (unconditional `scrollToBottom`); Make restores no focus after stage switch. |
| 32 | macOS conventions | Partial | Open Recent app-private (not in Dock/Apple menu); no system window restoration; no Help menu, no Services; "Preferences" vs "Settings" window title; one `runModal` outlier (undo checkpoint). Sheets/drag-drop/termination otherwise conventional. |
| 33 | Content & terminology | Pass-with-leaks | Destructive-action copy is exemplary; engine vocabulary narrowed to 2 strings ("tool round-trips", "Git worktree operation failed"); a "Review" button opens Think; delete-refusal message names remedies that don't satisfy the guard; "Plan is read-only" contradicts Plan's `run_task`. |

### 6. Test, release, operational
| # | Audit | Disposition | Key result |
|---|---|---|---|
| 34 | Test strategy & coverage | Partial | 333 tests; 18/30 unit files use real infrastructure (unusually high). **Missing high-value:** AgentRunner stop-invariant, truncated-stream, SSEHTTPClient (untested transport shared by all providers), OpenAICompatibleChatProvider (structurally untestable — `private`), JSONRPCTransport fuzz, checkpoint-excludes-staged-manual-edit. UI tests hang headless (Accessibility permission). No CI. |
| 35 | Compatibility matrix | **Runtime-required** | Deployment target macOS 15.0; design uses `NSGlassEffectView` gated to macOS 26. Needs Intel/AS, low-memory, case-sensitive volume, shell/git/Xcode/LSP version matrix. |
| 36 | Build / dependency / supply chain | Partial | Locked deps, no build scripts, permissive licenses (clean). No warnings-as-errors ratchet over 158 deferred warnings; `SWIFT_STRICT_CONCURRENCY = minimal` on BOTH test targets (tests get no strict-concurrency checking); no shared scheme / no CI; no sanitizer runs; no version stamping. |
| 37 | Distribution & update | **Fail / Runtime-required** | No notarization/updater/signing-for-distribution (H19); first-launch/upgrade/uninstall flows unbuilt. |
| 38 | Observability & supportability | Partial | Signposts good; persistence-failure reporting and recovery messaging notably good; only logging is 8 `print()` (lost for a Finder-launched app); no crash/hang diagnostics, no support-bundle, no visible app version. No telemetry (correct privacy posture). |
| 39 | Documentation & truthfulness | **Fail** | **Phase 10 doc says "Not started" for a shipped phase** (P-F1); landing page sells "contexts" while the product is "tracks" (P-F7); design doc contradicts itself on token status; constitution Heron tool list stale; checkpoint doc claims `gitCommitSHA nil ⇔ zero changes` but command-only batches also produce nil. The 2026-08-25 recommendation (machine-checkable status + CI) was never implemented — which is why the drift recurred. |
| 40 | Release-readiness & regression | **Fail** | See §Release-readiness gate. |

---

## Part III — Carry-forward retest results (mandatory)

| Carry-forward item (from 2026-08-30 + list) | Verdict |
|---|---|
| Remaining Swift concurrency warnings / unsafe sendability exemptions | **Still-open.** 158 concurrency warnings (reconciled to the doc's ~145 + 9 untabled files; no regression). LanguageServerRegistry's 3 caches are a **live race (H9)**, not just latent. Other opt-outs judged individually (Part II §21). Test targets build with `minimal` strict-concurrency. |
| Transcript view retention / duplicated conversation memory | Partly addressed. Session residency LRU=3, proposal content stripped after resolution. Think still retains one live `NSView` per entry and `entries` duplicates `session.turns` (the cheap half — drop duplication — remains). |
| Unbounded checkpoint & usage history | **Still-open.** `checkpoints.json` grows O(agent batches ever) with O(n) write amplification per append (the pattern SessionLog was built to kill). `UsageStore.records` bounded per month, slow. **Archived conversations never expire despite the retention setting (new).** |
| Secret-redaction limitations / API keys inherited by child processes | Mixed. **PTY children do NOT inherit `ANTHROPIC_API_KEY`** (SwiftTerm curates the child env — confirmed-mitigated, though it rests on the library contract). LSP servers and git subprocesses **do** inherit the full app env. `.netrc`/`.pgpass` and user/assistant message text **still unredacted**. |
| `git init` creating conflicting project contexts | **Substantially resolved.** The non-repo fallback state dir coincides with the post-init common git dir, so the ledger is continuous — one store, no orphan. Residual: one optimistic "not a repo" frame on the next launch (cosmetic); init doesn't refresh the probe cache. |
| Stacked-track archival & reconciliation behavior | Mixed. `applyReconciliation` worktree-immunity under hierarchy **now audited — clean.** Parent-archival policy **still open** (constitution admits it); archiving/deleting a parent silently rebases a child onto `main` in Review and offers to promote the parent's whole history — concrete misreporting path documented. |
| Unfinished verification loop (Phase 10) | **Built (2026-08-30, `9ba8090`), not "unfinished-unstarted" — but ineffective (H14).** Doc must be corrected; the loop's capture/attach/staleness bugs must be fixed for it to close. |

---

## Part IV — Runtime-required audits (scoped, not fabricated)

These cannot be completed by reading code; "no findings" would be dishonest without the run. Each
has a defined protocol so it can be executed and recorded next.

- **(4) Competitive workflow:** fixed repo + fixed task (open → track → agent edit → review → run tests → promote); versioned Cursor/Xcode/Zed/VS Code+Copilot/Windsurf with matched models; record time-to-first-edit, interaction count, recoverability, keyboard-only completion, trust clarity — not feature counts.
- **(5) User research / usability:** 3 novice + 3 intermediate + 3 expert + ≥2 accessibility/keyboard-only participants on unfamiliar repos; measure discoverability of the alpha loop, whether "tracks" beats "branches + chat", terminology comprehension.
- **(24) Performance & scalability:** run the existing signposts + `PerformanceTests` on fixtures — 10 MB file, 25k-file repo, 100-track ledger, 4 concurrent runners, 100k-token transcript, terminal flood — against written budgets. First target from static analysis: terminal output flooding (all-main, O(n²) alloc).
- **(25) Resource leaks:** Instruments Leaks/Allocations across repeated open/close of projects, tracks, tabs, conversations, windows; confirm LSP server counts under two windows (H-adjacent 23.4).
- **(26) Fault injection:** kill git/LSP/shell/formatter/model-stream/Side at each write boundary; confirm each failure is visible, retryable, nondestructive. Static review found the machinery sound; the live matrix remains.
- **(30) Accessibility (VoiceOver/FKA):** full VoiceOver workflow pass (the static audit found H15/H16 and several unlabeled controls; live confirms reading order, double-announcement fix, tab-strip containment).
- **(35) Compatibility matrix:** Intel + Apple silicon, low-memory, case-sensitive volume, shell/git/Xcode/LSP-version grid; macOS 15 vs 26 (Liquid Glass path).
- **(37) Distribution & update:** once H19 is addressed — notarization, install, upgrade, rollback, uninstall/data-cleanup, bad-release recovery.

---

## Part V — Consolidated regression-test backlog (net-new)

Highest value first, each mapped to a finding above:

1. `isAutoRunnable` false for the `env`/`printenv` corpus (C1).
2. `isWritable`/`isReadable` case-folded on APFS (H1).
3. Redirect drops auth headers (H2).
4. Corrupt store quarantined, not overwritten (H3).
5. Detached-HEAD promote refuses; base ref unmoved (H4).
6. Dirty-worktree deleteTrack requires consent (H5).
7. `applyReconciliation` clears adopted-worktree path on branch change (H6).
8. Open `0x00` file refused; CP1252 round-trip preserves untouched bytes (H7).
9. External modify → buffer/index refresh (H8).
10. LSP resolution under TSan; ordered didChange; didOpen-before-didChange after respawn (H9/H10).
11. >60 KB-between-marks command resolves with correct exit code (H11); two queued sentinel commands each resolve once (H12); Stop drains queued completions (H13).
12. `edit_file`+`run_task` verification lands on the right checkpoint; stale-pass promote caveat (H14).
13. WorkGroupView role/press; segment AX labels (H15/H16).
14. Formatter stub >128 KB → save completes (H17); static "no waitUntilExit before read" lint (H18).
15. AgentRunner stop-invariant (no continuation request after Stop); truncated-stream → failure; SSEHTTPClient framing/redirect/cancellation; OpenAI adapter parse (make `internal`); JSONRPCTransport negative/oversized Content-Length; checkpoint excludes a pre-staged manual edit; `CheckpointVerification.outputExcerpt` redacts an AWS-key-shaped string; `.side/tasks.json` with only `name`+`command` still overrides detection (tolerant decode).
16. Doc-status CI: every `docs/*.md` gets a `Status:` line; built-claims must resolve to a named symbol, planned-claims must not (would have caught Phase 10 and stacked-tracks drift both times).

---

## Part VI — Release-readiness gate (audit 40)

Against the 2026-08-25 suggested gates, the current blocking set:

- ❌ **Zero known auto-run code-execution bypasses** — C1 (`env`) and H1 (`.git` casing) are open.
- ❌ **No data-loss defects** — H5 (delete force-remove), H3 (corrupt-store overwrite), H7 (binary/encoding corruption) are open.
- ❌ **No false-success / misattribution** — H4 (detached-HEAD promote), H6 (branch misattribution) are open.
- ❌ **Accessibility not blocking** — H15/H16 gate the agent's reasoning and state from VoiceOver.
- ❌ **Provider failure semantics** — H2 (redirect key leak); truncated-with-text finishes as success.
- ⚠️ **Verification loop** — built but ineffective (H14); the promise "promotion refuses unverified work" is not reliably kept.
- ⚠️ **Documentation truthfulness** — Phase-10 and landing-page drift (P-F1/P-F7).
- ✅ **Prior fixes hold** — every 2026-08-30 fix re-verified and test-pinned; no regression in the closed set.
- ✅ **Supply chain / persistence atomicity / checkpoint SIGKILL-safety / attention machinery** — verified sound.

**Recommended fix order:** C1 → H1 → (H3, H5, H4, H6 — the git/persistence data-integrity cluster) →
(H9, H10 — LSP correctness) → (H11–H14 — terminal/verification) → (H2, H17, H18) →
(H15, H16 — accessibility) → doc-truthfulness CI → H19 before distribution.

---

## Method note

Findings marked **VERIFIED first-hand** were confirmed by direct source reads during
consolidation. All others cite `file:line` and a concrete trigger; where two independent
audit streams reached the same finding (delete-track force-loss, the pipe-deadlock class, the
LSP registry race, the binary-corruption path, the verification-loop gaps), that agreement is
noted and raised confidence. "No findings" areas are recorded in Part II with the evidence that
produced the clean result, per the audit requirement.
