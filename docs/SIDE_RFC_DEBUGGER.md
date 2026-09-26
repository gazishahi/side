# RFC: The debugger

*2026-09-26. Status: **accepted**: the owner answered on 2026-09-26. The debugger lives in Make;
a breakpoint is a click on the line number; a project's `.vscode/launch.json` is read, with
consent; agents get read-only access first. Q4, the first languages, took the recommendation
(default). The build order is the plan below. Steps 1 and 2 are built.*
Symbols: `DAPClient`, `DebugSession`, `BreakpointStore`, `DebugLaunch`, `MakeDebugger`, `DebugBar`, `DebugInspector`.
*Companion to `SIDE_RFC_IDE_ESSENTIALS.md` (the language-server client this mirrors, and
Settings → Languages, which gains a debugger per language) and `SIDE_RFC_ALLOY.md` (the gutter
and line tints the debugger draws with).*

## Why

Side can write, check, navigate and run code, but it can't pause it. Today:

- **Nothing stops a program.** Run starts tasks in terminals (`ProjectTasks`: detected or
  declared in `.side/tasks.json`). There are no breakpoints, no stepping, no call stack and no
  variables. You debug with `print`, or leave for Xcode or VS Code.
- **The pieces exist:**
  - The Debug Adapter Protocol (DAP) is to debuggers what LSP is to language servers: one
    client, many adapters. It uses the same framing (`Content-Length` over stdio or a socket),
    which Side already speaks (`JSONRPCFraming`).
  - **`lldb-dap` ships with Xcode** (`xcrun lldb-dap`), so Swift, C, C++ and Rust need nothing
    installed.
  - The other common adapters are one install each:
    - JavaScript and TypeScript: `vscode-js-debug`, the one VS Code uses;
    - Python: `debugpy`;
    - Go: Delve (`dlv dap`).
  - Alloy's gutter already draws marks per line and takes clicks. The editor can tint a whole
    line (`lineBackground`, which Review uses) and decorate ranges.
- **Agents can't see a stopped program.** An agent asked why something crashes can read code
  and run tests, but not the stack or the values at the crash.

## What a person does

1. Clicks a line number in Make. A breakpoint appears (a mark on the number, as in Xcode).
2. Starts debugging (⌘R, default) with the project's launch configuration. The first time
   there's one to pick, and Side proposes one from what the project is.
3. The program stops at the breakpoint:
   - the line is tinted and the editor shows it;
   - a debug bar appears (continue, step over, into, out, restart, stop);
   - an inspector shows the call stack, the variables in the selected frame, watch expressions
     and the breakpoints.
4. Hovering a variable shows its value, using the hover card from IDE step 2. The debug console
   evaluates expressions in the stopped frame. The program's own output shows where Run's
   output does.
5. Stop ends it. Breakpoints are kept per project.

## Decisions (the owner's answers, 2026-09-26; each recommendation was chosen)

- **Q1. Where the debug UI lives.**
  - **Recommended:** in Make, since you debug while looking at code. The debug bar sits over
    the editor's top edge, glass like the tab strip. The inspector takes the file explorer's
    place while debugging (the explorer comes back when it ends, or with ⇧⌘E). The program's
    output and the debug console are a Debug tab in Run.
  - Other options: all of it in Run (the code is then another stage away), or a fifth Debug
    stage (more chrome for a mode).
- **Q2. The breakpoint gesture.** **Recommended:** click the line number, as in Xcode, with ⌘\
  to toggle at the caret and a right-click for condition, hit count, log message, disable and
  delete. Diagnostics keep their dot to the number's left, and change bars stay at the edge.
- **Q3. Launch configurations.**
  - **Recommended:** read the project's `.vscode/launch.json` when it has one (many projects
    do), using VS Code's schema for the fields Side supports (`type`, `request`, `program`,
    `args`, `cwd`, `env`, `preLaunchTask`), with `${workspaceFolder}`, `${file}` and similar
    filled in.
  - Otherwise Side proposes one: a Swift package's executable (built first), `npm run` scripts
    under Node, the current Python file, a Go main package, and attach to a running process.
  - A cloned repository's launch file runs commands, so it gets the same per-content consent
    `.side/tasks.json` has.
- **Q4. The first languages.** **Recommended:**
  - first Swift, C, C++ and Rust (lldb-dap, nothing to install);
  - then JavaScript/TypeScript (js-debug), Python (debugpy) and Go (Delve), each with Install
    in Settings → Languages as servers have;
  - later Ruby (rdbg) and Java (through jdtls).
- **Q5. What agents may do.**
  - **Recommended first:** read-only. A tool gives the agent the stopped program's stack,
    locals and the exception, so "why did this crash" has evidence.
  - Controlling the debugger (setting breakpoints, stepping) would come later, with approval
    like running a command.

## Design (subject to the answers above)

- **D1: a DAP client beside the LSP client.**
  - One actor per session, over stdio or a socket (js-debug serves on a port), with
    Content-Length framing and one parse per message.
  - It sends `initialize`, `launch` / `attach`, `setBreakpoints`, `setExceptionBreakpoints`,
    `configurationDone`, `threads`, `stackTrace`, `scopes`, `variables` (paged by
    `variablesReference`, so a 100,000-element array opens in pages), `evaluate`, `continue`,
    `next`, `stepIn`, `stepOut`, `pause`, `restart`, `terminate` and `disconnect`.
  - It handles the events `initialized`, `stopped`, `continued`, `output`, `breakpoint`,
    `thread`, `exited` and `terminated`.
  - It answers the reverse requests `runInTerminal` (the program runs in a Run terminal, so its
    input works) and `startDebugging` (js-debug's child sessions).
- **D2: adapters are presets,** as language servers are (`LanguageSettings`):
  - each language gets a Debugger row with the adapter, whether it's installed, Install, or a
    command of your own;
  - the opt-in test that checks registries and starts servers covers adapters too.
- **D3: breakpoints are Side's.** They're kept per project and per file, and follow edits (a
  line inserted above moves them, as folds and diagnostics do). They're sent per file on start
  and on change. The adapter's reply says whether each one bound: unverified ones are hollow,
  and a moved one jumps to the line the adapter chose.
- **D4: stopping shows the code.** The stopped frame's file opens at its line, tinted and
  centered. A frame without source (a system library) shows its function and module in the
  stack and doesn't open anything. Stepping keeps one tab per file rather than opening new
  ones.
- **D5: the inspector is lazy.** Variables expand one level at a time, and only rows on screen
  exist (the same rule as Review's diffs). Watch expressions re-evaluate on each stop.
- **D6: budgets**, as rows of `Budgets.table`:

  | Measure | Budget |
  |---|---|
  | A step, from the adapter's `stopped` event to the line shown and the stack filled | ≤ 50 ms of Side's own work |
  | Variables: expanding an array of 100,000 | first page ≤ 30 ms; memory bounded by what's on screen |
  | Idle, a session paused | no CPU, no timers |
  | Breakpoints following an edit, 1,000 breakpoints | ≤ 1 ms a keystroke |

## Plan

1. **The core loop on Swift/C/C++/Rust:**
   - the DAP client and lldb-dap;
   - breakpoints in the gutter (set, toggled, kept, following edits);
   - launching a Swift package's executable (built first);
   - the debug bar;
   - the stopped line shown;
   - the call stack and variables.

   Checked on a real Swift package.
2. **The rest of stopping:** the debug console (evaluate, output), watch expressions, hover to
   evaluate, conditional breakpoints, hit counts and logpoints, exception breakpoints, and the
   program's input and output in a Run terminal (`runInTerminal`).
3. **More languages:** js-debug (with child sessions), debugpy and Delve: presets, installs,
   the proposed launch configurations, and the start test.
4. **Launch configurations:** `.vscode/launch.json` with consent, Side's launch picker, and
   attach to a process.
5. **Agents and budgets:** the read-only debug-state tool for Heron, the budgets above in
   `Budgets.table`, and tests throughout (a fake adapter over stdio, as the LSP tests use a
   fake server).

Later: data breakpoints, disassembly and memory views, multiple concurrent sessions, and remote
debugging with the mobile rollout.

## Built

**Step 1, 2026-09-26.**

- **The client** (`DAPClient`): an actor on the LSP transport (`Content-Length` framing),
  requests paired by `request_seq`, events handed on, reverse requests refused until step 2
  offers them. `SIDE_DAP_LOG=<file>` writes every message both ways, for diagnosing an adapter.
- **A session** (`DebugSession`):
  - `initialize`, then `launch` (not awaited: an adapter may answer it only after
    `configurationDone`), and on `initialized` every file's breakpoints,
    `setExceptionBreakpoints` (none yet) and `configurationDone`.
  - On `stopped`: `threads`, then `stackTrace` (60 frames). The frame shown is the first with
    source that isn't marked subtle, so a stop inside a library shows where the program called it.
  - Scopes and variables are fetched when shown; an array over 200 elements opens 200 at a time,
    with a row for the rest.
  - Continue, pause, step over, into and out, restart (built again first) and stop
    (`disconnect` with `terminateDebuggee`). Nothing polls: a paused session has no timers.
  - Paths sent to the adapter are real paths (`realPath`, not Foundation's
    `resolvingSymlinksInPath`, which strips `/private` again). A project opened through a symlink
    (`/tmp`, `/var`) otherwise got breakpoints lldb never bound.
- **Breakpoints** (`BreakpointStore`):
  - They're kept per project in preferences. A change reaches the gutter at once; the write to
    preferences is coalesced per run-loop turn.
  - They follow edits. The text before a keystroke is rebuilt from the edits' inverses (no copy
    kept), and breakpoints below a change in line count move by it. One inside removed lines
    goes to where the removal started, and two that meet become one.
  - The adapter's reply marks each as verified or not, and moves one the adapter placed on
    another line.
- **Launching** (`DebugLaunch`): the Swift package's executable products (from
  `swift package describe`). With more than one, Side asks which and remembers it per project.
  The product is built with `swift build --product`, its output going to the session's output.
  lldb-dap comes from `xcrun --find`.
- **The gutter** (Alloy): `GutterMark.Style.breakpoint(enabled:verified:)` draws Xcode's tag
  behind the number: filled when verified, hollow when not, faded when disabled.
  `AlloyGutterView.onNumberClick` takes clicks and right-clicks on the numbers; the marks' column
  keeps its own clicks.
- **In Make** (`MakeDebugger`):
  - A click on a number toggles a breakpoint; ⌘\ toggles at the caret.
  - A right-click offers Disable/Enable, Delete, and Delete All.
  - A Debug menu: Start (⌘R; it also continues a paused session), Pause or Continue (⌃⌘Y), Stop
    (⇧⌘.), Step Over, Into and Out (F6, F7, F8), and Toggle Breakpoint. The VS Code and
    JetBrains keymaps get their own keys (F5, F6, ⇧F5, F10, F11, ⇧F11, F9; ⌃D, ⌥⌘R, ⌘F2, F8, F7,
    ⇧F8, ⌘F8).
  - The debug bar is glass over the editor's top edge, and the editor's text moves down by its
    height while it's there.
  - The inspector holds the call stack, variables, breakpoints and output. It sits in the file
    explorer's slot on the explorer's side, and the editor narrows beside it.
  - The stopped line is tinted.
  - Arriving in another file centers the line; a step within one file only scrolls if the line
    isn't visible.
  - A session that ends quietly clears the bar and inspector after 1.5 s. One that ends with a
    message (a failed build) stays until Stop.

Tests (`DebuggerTests.swift`):

- The store: toggling and keeping, following edits (typing, lines above, a newline at a line's
  end, deletions), and the adapter's answers.
- A fake adapter over stdio (Python) for a whole session: the handshake's order, breakpoints
  moved and unplaced, the stop's frame, variables and paging, a step, and the end.
- The inspector paging a 100,000-element array.
- The package description's executables and the build command's quoting.
- Opt-in (`SIDE_DEBUGGER_TESTS=1`): lldb-dap on a real Swift package. The test builds it, stops
  in `square`, reads `result`, and runs to its output.
- Measured against D6:
  - following an edit with 1,000 breakpoints ≤ 1 ms: it was 1.1 ms until the preferences write
    was coalesced;
  - the first page of a 100,000-element array ≤ 30 ms of Side's work.

  Both go into `Budgets.table` in step 5.

Checked in Side on a Swift package (a `Point` distance loop): clicked breakpoints, ⌘R built and
stopped at line 9, with the line tinted, the stack (`distance(_:_:)`, `DebugDemo_main`) and locals
(`a`, `b`, `dx 1`, `dy 2`). Step Over returned to line 15 in the caller. Stop left no lldb-dap
or program running. The right-click menu disabled a breakpoint (faded), and ⌘\ added one at
the caret.

**Step 2, 2026-09-26.**

- **The program's terminal.** The program runs on a Run tab of its own ("Debug: <name>"), so it
  reads what's typed there and writes there. The tab's own process only holds the pty open;
  the tab becomes the one Run shows, and the next session replaces it.
  - lldb-dap is pointed at the tab's pty with lldb's own settings
    (`target.input-path`/`output-path`/`error-path`, in `preRunCommands`, not echoed to the
    console).
  - Not `runInTerminal`, as D1 planned: lldb-1703's launcher and adapter both time out on their
    comm file (checked outside Side's sandbox too). Nor `stdio`, which lldb-1703 ignores.
  - `DAPClient` now answers the adapter's reverse requests through a handler; js-debug's and
    debugpy's `runInTerminal` use it in step 3.
- **The console** is the inspector's last section, not a Debug tab in Run as Q1 said:
  - you type expressions while looking at the stack and the code;
  - the program's own output is already in Run.

  It evaluates in the selected frame (`repl`, so lldb commands work too), with ↑/↓ history.
  The adapter's messages are dimmed, the program's shown plain, and errors in red.
- **Watches:** a section of their own, kept per project, evaluated in the selected frame on
  each stop (`watch`). A failure shows lldb's message in one line.
- **Hover to evaluate:** while paused, resting on a name (or a member chain, `a.x`) shows its
  value in the hover card. Where there's no value, the language server's hover shows as before.
- **Breakpoint options:** Edit Breakpoint… (the gutter's right-click, or the inspector's list)
  sets:
  - a condition;
  - a hit count;
  - a log message, which makes a logpoint that prints `{expressions}` without stopping.

  They're kept with the breakpoint (breakpoints kept before step 2 still load), shown in the
  list ("if a.x == 3"), and sent in `setBreakpoints`.
- **Exception breakpoints:** the adapter's `exceptionBreakpointFilters`, as checkboxes above the
  file breakpoints (the file's language's first: Swift Catch and Swift Throw in a Swift
  package). They're kept per project; the adapter's defaults apply until the person picks.
  A stop on one reads "Paused: Swift Throw", at the frame that threw.
- **The breakpoints list:** each file breakpoint has a checkbox (enable) and says what it does,
  or that it wasn't placed; the adapter's reason is in its tooltip.

Tests:

- The fake adapter now checks the options sent with breakpoints, the default and chosen exception
  filters, and evaluation (a result, and a failure's message).
- Options, watches and filters are kept, and old breakpoints load.
- lldb's errors read as one line.
- Opt-in lldb-dap: a conditional breakpoint (`n == 2`) stops with `result` 4, a logpoint prints
  "squaring 1", `result * 10` evaluates to 40, and the program's "total 14" reaches its pty,
  not the adapter's output.

Checked in Side on the demo package (now asking "How many points?" and throwing past 100):

- The prompt showed in the program's Run tab, and typing 8 there ran it to `total: 35`.
- A condition set in Edit Breakpoint (`a.x == 3`) stopped only there.
- The console gave `b.y + dy` → `(Int) $R1 = 6`.
- The watch `a.x * 100` went from 100 to 200 on the next stop.
- Hovering `dx` showed `dx = 1`.
- Swift Throw stopped in `check(_:)` at line 15 with `total 145`.
