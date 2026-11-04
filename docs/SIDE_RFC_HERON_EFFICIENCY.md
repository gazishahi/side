# RFC: Heron, efficient

*2026-09-26. Status: **reference**: built on 2026-09-26 (the owner took each recommendation), and removed with Heron's agent on 2026-11-04 (`SIDE_RFC_HERON_RETIREMENT.md`). Kept for the record.
Stale content is pruned in one sweep at half the window. Compaction is automatic at 85%, with
Undo. An opt-in benchmark runs on the real API. The cache lives five minutes. The build order is
the plan below. The owner asked for this (2026-09-25): Heron should be "a highly efficient
harness, not just a harness", in the tokens it spends as much as in CPU, memory and battery.*
Symbols: `StreamEventCoalescer`, `HistorySweep`, `ContextBudget`, `JSONStore`, `GitPaths`, `AgentRunnerManager`, `ProjectFileAccess` (Heron); `TextBlockView` (Side).
*Companion to `SIDE_RFC_MULTI_AGENT.md` (the runner and coordination this touches),
`SIDE_RFC_BYO_HARNESS.md` (outside agents over ACP, which share the Think path) and
`SIDETests/Budgets.swift` (where the new budgets go).*

## Why

Heron works. It doesn't yet economize, and it can't show what it spends.

### Tokens

A turn is the person's message plus up to 12 round trips of tool calls
(`maxToolRoundTrips`, `AgentRunner.swift:183`). Every round trip re-sends everything
(`runTurn`, `AgentRunner.swift:1091-1179`). The request contains:

- **The fixed part:** the system prompt and tools, measured in Build scope at 1,749 + 6,241
  characters (about 2,000 tokens), with 13 tools. Ask sends 6 tools, Plan 10, and Build with a
  coordinator 18. This part is small.
- **The whole conversation, verbatim, every time** (`session.turns.map`, `:1138`). This is the
  spend:
  - Tool results are kept forever as they were: "Sessions hold every tool result verbatim"
    (`HistoryRetention.swift:5-6`).
  - A file read twice is in history twice, line-numbered (`ToolExecutor.swift:416`).
  - Every `write_file` body and every `old_string`/`new_string` stays in the replayed tool
    calls.
  - Images go back as base64 on every turn after they're attached (`:295-296`).
- **No prompt caching.** No request carries `cache_control`
  (`AnthropicMessagesProvider.swift:68-104`), although the provider declares
  `supportsPromptCaching: true` (`:29`) and nothing reads that. So the history is billed at the
  full input price on every round trip. With caching, a repeated prefix costs a tenth of that.
  - A twelve-round-trip turn over a 60,000-token history pays for about 720,000 input tokens.
  - Cached, the same turn pays for about 60,000 + 11 × 6,000 plus what's new in each round:
    roughly a fifth of the cost.
- **What would break a cache today:**
  - The request JSON is built from Swift dictionaries without `.sortedKeys`
    (`AnthropicMessagesProvider.swift:43`, `OpenAICompatibleChatProvider.swift:43`). Key order
    is seeded per process, so a tool's schema or a replayed tool call can serialize differently
    after a relaunch. OpenAI's automatic prefix caching is lost the same way.
  - The @-mention note sits on the typed message in the first round trip, then drops off it in
    the next (`:1139-1140`). The history's prefix changes within a single send.
  - The coordination tools' description embeds the live list of agents
    (`Coordination.swift:171, 178`).
- **Unbounded results:**
  - `run_shell_command` and `run_task` output go back raw (`AgentRunner.swift:615`), up to the
    terminal's 60,000 characters.
  - `search_files` isn't truncated, and a matched line isn't length-capped
    (`ToolExecutor.swift:448-450`): one minified file can fill it.
  - `read_track` and `wait_for_tracks` return every track's report without a bound
    (`:487-490`).
  - The ceiling everything else gets is 60,000 characters (`:23`), about 15,000 tokens a
    result. That stays in history for good.
- **Compaction is manual only** (`compact`, `:985-1051`). The context gauge warns at 70% and
  90% of the window (`ContextBudget.swift:17-18`), and nothing acts on it.
- **The spend isn't fully counted:**
  - Anthropic's `cache_creation_input_tokens` is never read.
  - OpenAI streams don't report usage without `stream_options.include_usage`, which isn't sent
    (`OpenAICompatibleChatProvider.swift:161`), so real OpenAI calls aren't metered at all.
  - Cached tokens aren't parsed there either.
  - Claude Opus 5.5 and Fable 5.1 have no price (`UsageStore.swift:282-286`), so the monthly
    budget can't see them.

### The machine

- **Streaming is quadratic in the message.** Each text delta appends to `pendingAssistantText`
  and stores it in the transcript entry (`AgentRunner.swift:1213-1219`). The entry keeps a
  reference, so the next append copies the whole string: O(n) a delta, O(n²) a message.
  - Every SSE line hops to the main thread on its own (`:1169`) and notifies every observer
    (`:1680-1684`).
  - A streaming edit re-parses its whole partial JSON on every delta (`:1279`), before the 80 ms
    throttle decides whether to draw (`:1283`).
  - Think coalesces to one flush per 35 ms, but each flush lays out the whole transcript and
    re-measures the whole message (`ThinkWorkspaceViewController.swift:1689-1700, 2342-2354`).
  - Outside agents (ACP) rebuild the message string per chunk (`ACPHarness.swift:660-670`) and
    shift their read buffer from the front per line (`ACPConnection.swift:104-107`).
- **On the main thread:** `git status --porcelain` runs there when a batch pauses for approval
  (`AgentRunner.swift:1579`). In a large repository that's a visible hitch.
- **A checkpoint** costs about nine git processes. One of them reads the whole tree into a fresh
  index (`read-tree HEAD`, `:1805-1863`), O(files tracked) every time.
- **Files rewritten whole:**
  - `index.json`, pretty-printed, on every turn (`JSONStore.swift:30`, `AgentSessionStore.swift:114`);
  - `usage.json` on every round trip (`UsageStore.swift:126-147`);
  - `checkpoints.json`, which holds every checkpoint in the project, two or three times per
    checkpoint (`AgentSessionStore.swift:149-199`). Retention never prunes it, so it grows
    without end.
- **Memory:** `AgentRunnerManager` keeps a runner, with its whole transcript, for every track
  visited, until the project closes (`AgentRunnerManager.swift:29, 98-137`). The session store
  keeps three sessions resident (`AgentSessionStore.swift:327-339`), but the runners hold their
  own copy, so that limit doesn't bound anything.
- **The file index walks the tree too often:**
  - Think rescans the project on every change anywhere: it listens with `object: nil`, visible
    or not (`ThinkWorkspaceViewController.swift:393-395, 1068-1083`), so a build walks it
    again.
  - `search_files` and `list_files` walk the whole tree on every call (`ProjectTextSearch.swift:68-72`).
- **Already sound:**
  - Nothing is written per delta; the session log appends a line per turn.
  - The stall watchdog is one pending timer (the 2026-09 fix: 156 → 68 MB and 85 → 50 s of CPU
    over 60 turns).
  - Idle Heron doesn't wake.
  - Markdown renders once per message.
- **Unmeasured:** the Think budgets (`think.memory`, `think.cpu`) drive a fake *ACP* agent. No
  budget runs Heron's own SSE path.

## What "efficient" means here

1. **Tokens:**
   - Pay the full price only for what's new in a request, and a tenth for what the model has
     already seen.
   - Keep what's no longer useful out of the history.
   - Never let one tool result or one command's output crowd the window.
2. **The machine:** a streamed message costs O(its length) once, not per delta. Nothing Heron
   does blocks the main thread, and nothing it keeps grows without a bound.
3. **Shown:** the person can see what a turn cost (new, cached, written to the cache, output)
   and what caching saved. Every model has a price.
4. **Measured:** each goal is a row of `Budgets.table`, with a baseline taken before the change
   and the number after.

## Decisions (the owner's answers, 2026-09-26; each recommendation was chosen)

- **Q1. Content that's gone stale in the history** (a file read again later, a file read before
  an edit that replaced it, long command output from turns ago).
  - **Recommended: prune in one sweep, at a threshold.** When the context passes half the
    window, older superseded results are replaced with a one-line stub ("read again at turn 14",
    "output elided: 12,400 characters, exit 0"), all at once. Then the cache rebuilds from that
    point and stays warm until the next sweep. It saves the most tokens for the fewest cache
    rebuilds.
  - Or: never alter the history, only compact (simplest and most faithful, but the most tokens).
  - Or: prune on every turn (each request is smallest, but every prune invalidates the cache
    after it, which usually costs more than it saves).
- **Q2. Near the window.**
  - **Recommended: compact automatically at 85%,** with a line in the transcript saying so and an
    Undo that restores the full history for the next send.
  - Or: ask each time.
  - Or: keep it manual.
- **Q3. A benchmark on the real API.** Budgets for tokens need real requests to measure cache
  hits.
  - **Recommended: yes, opt-in.** A script (`scripts/heron-bench.sh`) runs a few fixed tasks on a
    fixture project with the person's own key, at about $1 a run. It records input, cached,
    cache-write and output tokens, and the dollar cost, per task.
  - Or: fake-server measurements only: request sizes and prefix stability, but no cost or hit
    rates.
- **Q4. How long the cache lives.**
  - **Recommended: Anthropic's 5-minute cache by default,** refreshed by every request (a tool
    round trip is seconds apart).
  - Or: the 1-hour cache. Writes cost twice as much, and it pays off only when the person
    regularly leaves more than five minutes between messages in one conversation.

## Design (subject to the answers above)

- **D1. A cacheable request.**
  - Serialize with `.sortedKeys`, so identical content is byte-identical across launches.
  - Anthropic breakpoints:
    - one after the tools and system prompt (stable within a mode);
    - one on the last message of every request, so each round trip reads everything before it
      from the cache and writes only its own addition.
  - The @-mention note becomes part of the typed message once and stays there. The coordination
    tools' agent list moves out of their description and into `list_tracks`' result.
  - OpenAI-compatible: a stable prefix gets automatic caching where the server offers it, plus
    `prompt_cache_key` where OpenAI supports it.
- **D2. Bounds on what enters the history,** by the same rule for every tool:
  - Command and task output is kept as head plus tail, up to 16,000 characters, with the elided
    count between.
  - `search_files` lines are capped at 300 characters, and the whole result is bounded.
  - Coordination results are bounded.
  - `read_file` with no range reads the first 600 lines of a larger file and says how to read
    more. The limits are constants in `ToolExecutor` with tests.
- **D3. Stale content** (per Q1): the sweep replaces what a later read or edit superseded, and
  command output older than a few turns, with stubs. It never touches the last turn or anything
  the model hasn't been answered about yet.
- **D4. Compaction** (per Q2): the threshold and Undo. The summary keeps the file paths and
  decisions made, which the current `compactionInstruction` asks for.
- **D5. Accounting:**
  - Anthropic's cache-write tokens are read, and OpenAI gets `include_usage` and its
    `cached_tokens`.
  - Every model in the registry has a price, and a test fails if one doesn't.
  - `UsageStore` records cache writes, and Settings → Usage shows a turn's split and the saving
    from caching.
- **D6. Streaming:**
  - Deltas are gathered off the main thread and applied once per display frame, one main-thread
    hop and one notification per frame instead of per SSE line.
  - The message is built in a buffer that's appended to, not copied.
  - A streaming edit's preview parses only when its throttle is due.
  - Think's flush lays out the streaming bubble, not the transcript.
  - ACP's line buffer and message string get the same treatment.
- **D7. Background work:**
  - The approval-time `git status` moves off the main thread.
  - A checkpoint copies the real index file instead of `read-tree`, and batches its git calls.
  - `index.json` is written compactly and debounced; `usage.json` is debounced.
  - `checkpoints.json` becomes one file per track, pruned with the same retention as sessions.
  - Idle tracks' runners drop their transcripts (least recently used, kept for three, like the
    session store) and rebuild them on the next visit.
  - Think's file index listens only to its own project, and only rescans when an @ query needs
    it.
  - `search_files` and `list_files` share that index instead of walking the tree per call.

## Budgets (new rows of `Budgets.table`)

| Measure | Budget |
|---|---|
| A 20-round-trip scripted session (fake server): requests whose cached prefix is byte-identical to the previous one's | 100% |
| The same session: characters re-sent past the last cache breakpoint, per round trip | ≤ what the round trip added + 2,000 |
| One tool result entering the history | ≤ 16,000 characters (60,000 today) |
| Benchmark (opt-in, real API): a task's input tokens billed at the full price, against the baseline | ≤ 35% of the baseline |
| Streaming a 50,000-character message in 10-character deltas: Side's work (Heron and Think) | ≤ 50 ms in all, O(n) |
| Heron's own path streaming for 20 s (fake SSE server): main-thread hops | ≤ 60 a second |
| The same: CPU | ≤ 15% of a core (`think.cpu`, on ACP, allows 25%) |
| A checkpoint in a 20,000-file repository | ≤ 250 ms, ≤ 5 git processes |
| Main-thread time in Heron's git calls during a turn | 0 ms |
| Memory: 10 visited tracks of 200 turns each, 3 resident | ≤ 3 transcripts' worth (+ 10 MB) |

## Plan

1. **Measure first.**
   - A fake SSE server for Heron's own providers (Anthropic and OpenAI formats) that records the
     request bodies.
   - The accounting fixes (D5).
   - The benchmark (per Q3) and the baseline numbers, before anything changes.
2. **Caching:** D1, with the prefix-stability budget. The benchmark before and after.
3. **The history:** D2's bounds, D3 (per Q1) and D4 (per Q2), each with its budget and the
   benchmark again.
4. **Streaming:** D6, with Heron's own streaming budgets, ACP's and Think's.
5. **Background work:** D7, the checkpoint, main-thread and memory budgets. `Budgets.table`
   complete, and the audit of what remains.

Out of scope: choosing a cheaper model for a task, prompt wording beyond what D1 needs, and
outside agents' own token use (they build their own requests).

## Built

**Step 1, 2026-09-26.**

- **Isolation:** `AgentRunner` takes its `providerRegistry` and `usageStore` (the app's by default),
  so a test or the benchmark never touches the person's `providers.json` or `usage.json`.
- **A headless Heron** (`HeadlessHeron`, in the tests):
  - the real runner on a project on disk, with a registry and usage store of its own;
  - edits applied at full autonomy, and commands refused.
- **A fake model server** (`FakeModelServer`): Anthropic's streaming format on the loopback,
  scripted replies (tool calls or text), and every request body recorded.
- **The baseline, measured** (`HeronRequestMeasurementTests`): two messages of ten `read_file`
  round trips each over a twelve-file project, 22 requests in all.
  - They sent 3,370,213 bytes (about 840,000 tokens). Each request re-sent everything before it
    plus about 15 KB of new file: from 5 KB to 301 KB.
  - The part of each request identical to the previous one's start was 0 to 21 bytes, apart
    from one stretch of 1,988: **0% of what was sent**.
  - The JSON's key order differs between serializations even within one run, so a prompt cache
    couldn't hit even if one were asked for. D1's sorted keys are the first thing step 2 needs,
    before the breakpoints.
- **Accounting (D5):**
  - Anthropic's `cache_creation_input_tokens` is read, from `message_start` and again from
    `message_delta` when the API repeats its counts.
  - `TokenUsage` separates input at the full price, cache reads and cache writes;
    `promptTokens` is their sum, which is what the context gauge counts.
  - OpenAI-compatible hosted providers are asked for usage (`stream_options.include_usage`),
    and `prompt_tokens_details.cached_tokens` is split out of the prompt count. Local servers
    aren't sent the field.
  - `UsageTotals.cacheWriteInputTokens` is recorded; rows written before it load (tolerant
    decoding).
  - **Prices corrected** to Anthropic's published table (read 2026-09-26):

    | Model | Input | Output | Cache hit | 5-min write |
    |---|---|---|---|---|
    | Fable 5.1 | $10 | $50 | $0.25 (0.025x) | $12.50 |
    | Opus 5.5 | $4 | $20 | $0.20 (0.05x) | $5 |
    | Opus 5 | $5 | $25 | $0.50 | $6.25 |
    | Sonnet 5 | $2 | $10 | $0.20 | $2.50 |
    | Haiku 4.5 | $1 | $5 | $0.10 | $1.25 |

    Opus 5 had been listed at $15/$75 and Sonnet 5 at $3/$15, and Opus 5.5 and Fable 5.1 had no
    price, so the monthly budget couldn't see them. A test now fails if a seeded model has no
    price.
  - Settings → Usage shows cache reads and writes per model, and what caching saved.
- **The benchmark** (`scripts/heron-bench.sh`, `HeronBenchmarkTests`): three fixed tasks on a
  small order-service fixture (`Tests/HeronTests/Fixtures/BenchProject`, a git repository per
  run):
  - explaining the order flow (Ask);
  - reasoning through the discount rules (Ask);
  - adding `cancelOrder` (Build, applied).

  It records requests, input, cache reads and writes, output and dollars per task, stops past
  $3, and writes `build/heron-bench/<date>-<model>.json`. The key is `ANTHROPIC_API_KEY` if the
  API accepts it, else the one Side keeps in the Keychain (macOS asks first).
  - The first attempt spent nothing: the key in the environment was refused (401). The owner's
    new key then needed a workspace (the API asks an unscoped key for `anthropic-workspace-id`),
    and a workspace-scoped key worked.
  - **Baseline, Sonnet 5, 2026-09-26** (standard effort, nothing cached):

    | Task | Requests | Input | Cached | Output | Cost |
    |---|---|---|---|---|---|
    | explain | 4 | 19,986 | 0 | 2,305 | $0.063 |
    | discounts | 3 | 12,778 | 0 | 3,324 | $0.059 |
    | cancel | 11 | 105,435 | 0 | 5,228 | $0.263 |
    | **All three** | **18** | **138,199** | **0** | **10,857** | **$0.385** |

    - `cancel` ran again on its own after a first attempt stalled. The model had proposed a
      command, and the headless driver's refusal used the command's id where `resolve` takes the
      transcript entry's, so the turn waited out its 600 s. The driver is fixed and tested with
      a refused command.
    - `cancel`'s eleven requests re-sent 105,000 input tokens for a change touching one file.
      Input is 72% of the cost across the three tasks ($0.28 of $0.39), and all of it at the full price: step 2's
      target.

Tests: the accounting (Anthropic's cache fields, OpenAI's usage and cached split, every model
priced, costs at the published rates, the saving, old rows loading), the headless driver
applying an edit, the baseline measurement, and the existing budget and pricing tests moved
to the corrected prices.

**Step 2, 2026-09-26: caching (D1).**

- **The same request is the same bytes.** Both providers serialize with sorted keys, tool
  arguments included; unsorted, consecutive requests had shared nothing a cache could match.
- **Anthropic breakpoints** (`AnthropicMessagesProvider.requestBody`, 5-minute cache per Q4):
  - one on the system prompt, now a block, covering the tools before it. Compaction's request
    has no system prompt, so the last tool carries it there;
  - one on the last block of the last message. Each round trip reads the whole history the
    previous one wrote and writes only what it added. The previous breakpoint is a few blocks
    back, well inside the API's 20-block lookback.
- **Notes are stored with the typed message** (`AgentTurn.notes`): what the `@`-mentions
  resolved to, and the note after a branch. Before, they were recomputed per request, rode on
  the first request of a turn only, and so changed the history's bytes on the next one. The
  bubble still shows only what was typed; turns saved before this load with no notes.
- **The agent list moved into `list_tracks`' result.** `create_subtrack`'s description had
  named the installed agents, so installing one changed the tools, which come first. Side's
  tool server for outside agents keeps the list inline; their caching isn't ours.
- **OpenAI:** a `prompt_cache_key` on requests to api.openai.com, a hash of the model, the system
  prompt and the tool names. Other OpenAI-compatible servers get nothing new; some refuse an
  unknown field.
- **Measured** (fake server, the step 1 session plus an `@`-mention): 21 of 21 requests repeat
  the one before and add to the end; each carries two breakpoints; nothing lies past the last
  one. Held on every run by `HeronRequestMeasurementTests`, and rows `heron.prefix.changed` and
  `heron.prefix.uncached` of `Budgets.table`.
- **The benchmark after, Sonnet 5, 2026-09-26** (`build/heron-bench/2026-09-26-2244-claude-sonnet-5.json`):

    | Task | Requests | Input | Cached | Written | Output | Cost |
    |---|---|---|---|---|---|---|
    | explain | 4 | 8 | 10,669 | 9,309 | 2,526 | $0.051 |
    | discounts | 4 | 8 | 14,730 | 5,465 | 1,463 | $0.031 |
    | cancel | 8 | 16 | 52,721 | 10,370 | 5,016 | $0.087 |
    | **All three** | **16** | **32** | **78,120** | **25,144** | **9,005** | **$0.169** |

  - $0.385 → $0.169 (−56%); the input's share $0.276 → $0.079 (−72%). Input billed at the full
    price: 32 tokens against the baseline's 138,199, where the budget was ≤ 35%.
  - 76% of the prompt tokens were cache reads. Writes are now most of the input's cost
    ($0.063): each round trip's own addition, and each mode's system prompt and tools once.
    `discounts` read what `explain` wrote (both Ask); `cancel` (Build) has other tools.
  - One run: `cancel` took 8 requests where the baseline's took 11, so part of the difference
    is the model's path. The split between full price and cache doesn't depend on it.
- **Left for step 3:** compaction's summary request sends no system prompt or tools, so it
  reads nothing the conversation cached. D4 reworks it (done in step 3).

Tests: the breakpoints and their placement, byte-identical serialization, OpenAI's key (only
for OpenAI, stable as the conversation grows), notes sent and stored but not shown, old turns
loading, and the session measurement above.

**Step 3, 2026-09-26: the history (D2, D3, D4).**

- **Bounds (D2).** Nothing enters the history past 16,000 characters
  (`ToolExecutor.maxResultCharacters`, about 4,000 tokens; it was 60,000):
  - The runner's `toolResult`, where every result enters the conversation, keeps the head and
    the tail with the elided count between. That's the rule for command and task output, where
    what ran is at the start and the errors and summary are at the end. Coordination results
    and anything else long meet the same ceiling there.
  - `read_file` without a range returns the first 600 lines, whole lines up to the ceiling, and
    ends "lines 1–600 of 2000; read on with start_line 601".
  - `search_files` clips a matched line at 300 characters, and the whole result at the ceiling;
    `list_files` too, on a line boundary. `fetch_url` keeps its head.
  - The transcript still shows a command's full output; only the history is bounded.
- **The stale sweep (D3, `HistorySweep`).** At a send, once the context is past half the
  window, one sweep replaces with a stub that says how to get it back:
  - a `read_file` result read again later, or of a file edited or written since;
  - command and task output with three typed messages since, the one being sent included;
  - the long strings of older `write_file` and `edit_file` calls (the file holds them).

  It never touches the last typed message or anything after it, and results under 600
  characters stay. A sweep that finds nothing leaves the history, and so the cache, alone. The
  transcript says what was cleared and about how many tokens.
- **Compaction (D4).**
  - A send past 85% of the window (`ContextBudget.autoCompactFraction`) compacts first, then
    sends. If compaction fails, the message is sent anyway, and the failure is in the
    transcript.
  - The summary request sends the conversation's own system prompt, tools and history, then the
    instruction, so it reads the whole history from the cache. It used to send neither system
    prompt nor tools, and paid for everything again. The instruction asks for text without a
    tool call, and only text is kept.
  - Undo: the conversation before a compaction is kept beside the session
    (`<track>.compacted.jsonl`), written before anything is replaced. The line "Conversation
    compacted… Undo" restores it with whatever was said since, the summary dropped, for the
    next message. The line comes back after a relaunch while Undo is possible, and starting a
    new conversation or deleting the track discards it. The manual Compact's alert no longer
    says it can't be undone.
- **Measured** (fake server, `HistoryEfficiencyTests`):
  - reads, searches and command output stay within the ceiling;
  - a sweep replaces two superseded reads in the third message's first request, which is
    smaller than the one before it, and the requests after it repeat it;
  - past 85%, the compaction request repeats the previous request's tools, system prompt and
    history exactly, and Undo restores the original turns followed by the new ones.
  - New row `heron.result.max` in `Budgets.table`.
- **The benchmark isn't rerun for this step:** its three tasks stay far below half of Sonnet 5's
  window and read no file over 600 lines, so the sweep, compaction and read bound never fire
  there. Their effect is on long conversations, which the fake-server tests cover. A long-task
  benchmark would need a long real session, at several dollars a run.
- Not visually checked in Side yet: the Undo line in Think.

Tests: the bounds (a long file in part and how to go on, whole lines at the ceiling, clipped
search lines, a command's head and tail), the sweep (superseded and edited reads, the protected
last message, old command output and write bodies, a second sweep finding nothing), and the
runner's sweep, automatic compaction and Undo on the fake server.

**Step 4, 2026-09-26: streaming (D6).**

- **One hop a frame** (`StreamEventCoalescer`): the provider's events gather under a lock on
  its own thread, consecutive deltas of one kind merge (in place, one owner, no copy), and a
  single main-thread hop delivers them, no sooner than a frame after the last. Order is kept,
  and the stream's end delivers what's left before the turn finishes. It had been one hop, and
  one transcript notification, per SSE line.
- **The message grows in place:** the runner lets go of the entry's copy before appending, and
  so does the ACP harness. Each had copied the whole message per delta.
- **A streaming edit's preview** checks its 80 ms throttle before parsing the partial JSON, and
  a call whose path gets no preview isn't parsed again.
- **Think's bubble:** the new text is found by UTF-8 offset (the prefix comparison and the drop
  by characters were each linear in the message, per flush); only the lines from the last one
  on are measured; and the transcript is laid out only when the bubble's size changed.
- **ACP's read buffer** is cut once per read, after every complete line in it, not once per line.
- **Measured:**

  | Budget | Before | After |
  |---|---|---|
  | Heron: 50,000 characters in 10-character deltas, as fast as they come: main-thread work | a hop per delta | 1.0–1.8 ms in 3 hops (`stream.heron` ≤ 20 ms) |
  | Heron: the same over 2 s (2,500 deltas a second) | ~2,000 hops a second | 55 a second, 2.6 ms |
  | Heron: 20 s of streaming, 100 writes a second: hops | ~250 a second | 55 a second (≤ 60) |
  | The same: CPU, the fake server included | 3.9% | 3.5% (≤ 15%) |
  | Think: a streaming bubble's flush, mean over a 50,000-character message | 0.34 ms, 2.94× for twice the text | 0.11 ms, 2.04× (`stream.think` ≤ 0.25 ms) |

  - Heron's CPU barely moved: with nothing on screen its copies were cheap next to the
    network. What's gone is the hop per SSE line, and its notification per observer, which is
    what Think paid for.
  - The RFC's "50 ms in all" holds when deltas come fast: Heron delivers them in a handful of
    hops, so Think flushes a handful of times. For a slow stream, Think's cost is its flushes
    (at most one per 35 ms), each 0.11 ms however long the message is, so the budget is
    restated per flush.
  - A single 50,000-character paragraph still costs more per flush: text layout redoes the
    paragraph being appended to. The test uses paragraphs of 400 characters, as replies have.
- Not visually checked in Side yet: the streaming bubble's growth animation, now run only when
  its size changes.

Tests: merging and order, the fast and paced streams through the real runner (every delta
arrives, in order), the 20 s budget (opt-in), and Think's per-flush budget (opt-in,
`StreamingBudgetTests`, in `scripts/budgets.sh`).

**Step 5, 2026-09-26: background work (D7).**

- **Waiting on git cost more than git.** `Process.waitUntilExit()` added about 65 ms to every
  process, measured: 69 ms to run `/usr/bin/true`, against 2 ms waiting on a
  `terminationHandler`. `GitPaths` and `GitDiffComputer` now wait on the handler. On its own
  that took a checkpoint in a 20,000-file repository from 875 ms to 215 ms.
  - **Corrected by the 2026-09-30 audit:** the 65 ms is paid **only on the main thread**,
    where `waitUntilExit` polls the run loop (re-measured: 67 ms on main, 3 ms on a
    background queue). These measurements ran inside XCTest, which runs tests on the main
    thread; real checkpoints run on a background queue, where the old code cost roughly
    10 processes × a few milliseconds each. The main-thread figures below overstate the
    real gain. What stands is the process count (10 → 5), the removed `read-tree`, and the
    main-thread budget.
- **A checkpoint in five git processes** (it was ten, counting the baseline status):
  - one `git --no-optional-locks status --porcelain=v2 --branch` gives the dirty paths, HEAD's
    commit, and whether the user has anything staged. `--no-optional-locks` keeps status from
    rewriting the index, which also stops it contending with the user's own git;
  - with nothing staged, the private index starts as a copy of the real one (read before and
    after the status, so it's the index the status described) instead of `read-tree HEAD`;
  - `add -v` names the paths it changed, which replaces `diff --cached` (asked only when its
    output is anything else);
  - `write-tree`, `commit-tree`, and `update-ref` with the expected old HEAD, as before;
  - afterwards the private index goes back in place under git's own `index.lock`, and only if
    nothing wrote the index meanwhile. That replaces the final `git add`.
  - With the user's change staged it takes the old steps (seven processes), and their staged
    change stays staged and out of the commit.
- **No git on the main thread in a turn:** the baseline status taken when a batch pauses for
  approval now runs in the background. Nothing in the batch runs until it's known, and a
  decision made in those milliseconds waits for it. `GitPaths.metrics` counts processes and the
  main thread's time in them, and names the commands run there.
- **Fewer, smaller writes:**
  - `index.json` and `usage.json` are written compactly, a second after they change, once for a
    burst (`JSONStore.writeSoon`), and flushed at quit and whenever a store opens. The index's
    first write is immediate, since sessions can't be found without it.
  - Checkpoints are one file per track (`think/checkpoints/<track>.json`), written at once
    because they're the record of what an agent changed. The old ledger is split the first
    time it's read. Deleting a track deletes its file.
  - Not done: pruning checkpoints by the retention setting. Retention governs conversation
    content, and a live track's checkpoints are its Review timeline; per-track files already
    stop one track's history from being rewritten with another's.
- **Idle transcripts let go:** past the three most recently visited tracks, a Heron runner that's
  idle and on no window drops its transcript. It's rebuilt from the session on the next visit,
  or before anything starts work there (a coordinator's message to a subtrack). Outside agents'
  harnesses aren't included.
- **Think's file index** listens only to changes under its own root, and marks itself stale
  instead of rescanning a second after any change in any open project. It rescans when an `@`
  next asks it for files.
- **The project walk is reused** by `list_files`, `search_files` and the rest while it holds.
  The list is names only, and a directory's modification time changes when an entry in it is
  added, removed or renamed, so the check is a stat per directory: 405 ms → 0.2 ms in 20,000
  files. `search_files` still reads each file: 2.3–2.9 s over 20,000 files.
- **Measured:**

  | Budget | Before | After |
  |---|---|---|
  | A checkpoint in a 20,000-file repository (measured on the main thread; see the correction above) | 875 ms, 10 processes | 121 ms, 5 (≤ 250 ms, ≤ 5) |
  | Main-thread time in Heron's git calls during a turn | 23–88 ms (the approval-time status) | 0 ms (0) |
  | 10 visited tracks of 200 turns: transcripts held | 10 | 3 (≤ 3) |
  | `list_files`, 20,000 files, a repeated call | 400 ms | 0.2 ms |

- **The whole table** (`scripts/budgets.sh`, 2026-09-27): 33 measured, 31 within budget. The
  new rows all hold; Think streaming with the transcript on screen, in the app, is 4.6% of a
  core (≤ 25%). Over:
  - Alloy's minimap while scrolling, p99 4.25 ms (≤ 4.00), which this RFC doesn't touch.
  - The app's idle wakeups (≤ 2 a second). Five runs of this code read 4, 23, 6, 1 and 0; two of
    the step 4 code read 5 and 0. The spread is the machine's, not step 5's. The one 23 is
    unexplained, and worth a run on a quiet machine.

## What remains (the audit)

- **`waitUntilExit` in the app:** 20 calls in 11 files. Corrected by the 2026-09-30 audit:
  only the five on the main thread pay the 65 ms (New Project's `git init`, since removed;
  `which` on first save; login-shell PATH resolution; TrackStore's `runGit` from promote and
  branch naming). TrackStore's polling runs off the main thread and pays nothing extra.
- **`search_files` reads every file on every call:** 2.5 s over 20,000 files. A content cache
  keyed by modification time, or `git grep` where the project is a repository, would cut it.
- **Outside agents' harnesses** (`ACPHarness`) keep their transcripts while unvisited.
- **Images** go back as base64 on every request after they're attached; the sweep doesn't stub
  them yet.
- **The benchmark** ran before and after caching only; its tasks never reach the sweep's or
  compaction's thresholds. A long-conversation task would measure those on the real API, at
  several dollars a run.
