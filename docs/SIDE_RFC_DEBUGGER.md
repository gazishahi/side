# RFC: The debugger

*2026-09-26. Status: **built**: the owner answered on 2026-09-26 and all five steps are built.
The debugger lives in Make; a breakpoint is a click on the line number; a project's
`.vscode/launch.json` is read, with consent; agents get read-only access first. Q4, the first
languages, took the recommendation (default).*
Symbols: `DAPClient`, `DAPSocketTransport`, `DebugSession`, `BreakpointStore`, `DebugLaunch`, `DebugLaunchFile`, `DebugProcesses`, `DebugAdapters`, `MakeDebugger`, `DebugBar`, `DebugInspector`, `DebugSnapshot` (Heron).
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

**Step 3, 2026-09-26.**

- **Adapters as presets** (`DebugAdapters`, D2):
  - lldb-dap (Swift, C and C++, Rust; with Xcode).
  - js-debug (JavaScript and TypeScript): VS Code's DAP server from its GitHub release, run by
    the person's Node.
  - debugpy (Python), in a virtual environment of Side's own. The program runs with the
    project's `.venv` or `venv`, else `python3`.
  - Delve (Go): `go install`ed.

  Side keeps js-debug and debugpy in `~/Library/Application Support/Side/Debuggers`
  (`SIDE_DEBUGGERS_FOLDER` stands in for it, as `SIDE_DLV` does for Delve), so installing them
  changes neither Node nor Python. `LanguageInstall.script` is the install kind for these.
- **Settings → Languages → Debuggers:** a row per adapter with the languages it debugs, what
  runs, whether it's there, and Install (the language servers' install popover, generalized).
- **Transports** (D1): `DAPConnection` is one of:
  - stdio;
  - a server Side starts on a free port (`{port}` in its arguments), then connects to on the
    loopback (js-debug, Delve);
  - another connection to a running server.

  `DAPSocketTransport` does the TCP side. Servers are tracked and ended when Side quits;
  node running js-debug otherwise outlives its client.
- **Reverse requests:**
  - `runInTerminal` runs the program in a Run tab of its own, and answers with its process id
    (debugpy's and js-debug's `console: integratedTerminal`); the environment's null entries
    are dropped.
  - `startDebugging` (js-debug's program session) opens a child session over the same server.
    The bar and inspector follow the child, the launcher session stays behind it, and each ends
    the other.
- **What Side proposes** (`DebugLaunch.proposals`), the open file's language first:
  - a Swift package's executables;
  - a Cargo project's bins (`cargo metadata`, built with `cargo build`);
  - the open JavaScript, TypeScript or Python file;
  - each `npm run` script;
  - the Go main package holding the open file (Delve's `mode: debug`, `outputMode: remote`).

  One is used as is; with more, Side asks and remembers the choice per project. A missing
  adapter says which, and opens Settings.
- **Fixes the new adapters needed:**
  - Launch paths are real paths: Go found no module when the project was open through `/tmp`.
  - Breakpoints follow the adapter's `breakpoint` events (js-debug's provisional ones bind when
    the script loads).
  - A `disconnect` that isn't answered no longer stalls Stop: after a second the client stops
    anyway.
  - Adapters don't get Side's injected `DYLD_*` libraries (Xcode's, XCTest's).
  - Program output the adapter also reports (js-debug) isn't repeated in the console when the
    program has its terminal.
  - The bar's failure line is short: "Couldn't run X: see the console".
- **Delve and Developer Tools Access:** macOS asks for the person's password the first time a
  debugger that isn't Xcode's takes control of a process, unless Developer Mode is on
  (`DevToolsSecurity -enable`). Settings' note for Delve says so.

Tests:

- Proposals (their order, npm scripts, a project's `.venv`), the presets, and a free port.
- A fake server adapter over TCP: the launcher session's `runInTerminal` (arguments,
  directory, environment without nulls, the process id answered) and `startDebugging`, and the
  child session with its breakpoints, stop and end.
- Opt-in (`SIDE_DEBUGGER_TESTS=1`): js-debug on TypeScript, debugpy on Python and Delve on Go,
  each stopped at a breakpoint with a local read, `result * 10` evaluated to 10, and "total 14"
  printed.
- Opt-in (`SIDE_SERVER_TESTS=1`): every installed adapter answers `initialize`.
- Opt-in (`SIDE_NETWORK_TESTS=1`):
  - Side's own installs of js-debug and debugpy work, into a folder whose name has a space;
  - Delve's module and js-debug's release exist.

Checked in Side, against scratch installs:

- TypeScript: paused in `square` with `n 1` and `result 1`. A breakpoint added mid-session bound
  at once. The watch `result * 10` said ReferenceError before `result` existed.
  "total 14" printed in the program's Run tab, and the js-debug server was gone afterwards.
- Python: paused at `app.py:1`, with debugpy's "Uncaught Exceptions" on by default.
- Go: paused at `main.go:11`, with Delve's panic filters on by default.
- Settings: the Debuggers section showed debugpy installed.

A global Python whose `.pth` files point into `~/Documents` (an editable install) blocks at
startup in a process without Documents access. The test process has none, so the debugpy test
runs its program with debugpy's own environment. Side itself has access.

**Step 4, 2026-09-26.**

- **`.vscode/launch.json`** (`DebugLaunchFile`):
  - It's read as VS Code reads it: comments and trailing commas allowed.
  - VS Code's variables are filled in: `${workspaceFolder}`, `${file}` and its parts,
    `${relativeFile}`, `${env:…}`, `${userHome}` and the rest.
  - A variable Side can't fill (`${command:…}`, `${input:…}`), or `${file}` with no file open,
    makes that configuration unusable, with the reason shown, rather than wrong.
  - Types map to adapters:
    - `lldb`, `lldb-dap`, `swift` and `codelldb` → lldb-dap, as Side's own configuration, so the
      program still gets its Run tab;
    - `node`, `pwa-node`, `chrome` and their kin → js-debug;
    - `python` and `debugpy` → debugpy;
    - `go` → Delve.

    Other types are listed as not supported yet. A launched Node or Python program defaults to a
    terminal, as in VS Code.
  - `preLaunchTask` is found by label in `.vscode/tasks.json` (`command` and `args`, quoted) and
    runs as the build step. A task that isn't there makes the configuration unusable.
- **Consent** (Q3): the launch file, and the tasks file with it, take effect only once accepted.
  - This is per content, with the same record (`ProjectRules.acknowledge`) as `.side/tasks.json`
    and `AGENTS.md`.
  - The sheet offers Use Them, Show Me the File, or Not Now. Not Now goes on with Side's
    proposals only, and asks again after the file changes or Side restarts.
  - A changed file is asked about again.
- **The launch picker:** the palette gains a choices mode (`PaletteChoice`, `choose(_:from:)`).
  - Debug what? lists the file's configurations, then Side's proposals, each with its adapter
    and where it came from. An unusable one shows why, and picking it explains.
  - ⌘R starts the last one chosen in this project, or asks when there's no choice yet and more
    than one option. Debug → Choose What to Debug… always asks.
- **Attach to Process…** (`DebugProcesses`):
  - The person's own processes are listed: not the system's, the iOS Simulator's, or Side's
    own. The project's own programs come first, then the rest by name.
  - Each path comes from the system (`proc_pidpath`), not `ps`, which gives the path the program
    was started with.
  - Node attaches through js-debug; everything else through lldb-dap.
  - Stop detaches from an attached program and leaves it running (`terminateDebuggee` only for
    what Side launched).
  - A program macOS protects, such as a system binary or a notarized app with the hardened
    runtime, can't be attached to; lldb's reason shows in the console.
- **Fixes:**
  - Pause works on a session that hasn't stopped yet (an attached process): the threads are
    fetched first.
  - The SIGSTOP that pausing reports reads as "Paused".
  - A breakpoint that was hit counts as verified, whatever an earlier event said. lldb-dap
    reports one unverified while the program's modules load, which step 3's event handling had
    started to believe.

Tests:

- The launch file:
  - each type's configuration;
  - variables, including `${env:…}`;
  - `preLaunchTask` from the tasks file;
  - what can't run, and why;
  - `${file}` without a file.
- Consent: nothing takes effect before acceptance, and a changed file is asked about again.
- The process list: its filtering, the project's programs first, and a live listing.
- Opt-in (`SIDE_DEBUGGER_TESTS=1`): lldb-dap attaches to a compiled program, pauses it with
  frames, and detaches with the program still running.

Checked in Side:

- A project with a `launch.json` asked for consent first. The picker showed "Run app.ts with a
  flag" (its `preLaunchTask` from `tasks.json`), "Needs a picker" (unusable,
  `${command:pickFile}`), and Side's own `app.ts`. The chosen one ran to "total 14".
- Attach to Process… listed the project's `sleeper` first. Attaching, then Pause, showed
  `work` at `sleeper.c:2` with `n 121`.

**Step 5, 2026-09-26.**

- **The agent's read-only tool** (Q5): Heron's `read_debug_state`, in every scope, reads a
  `DebugSnapshot` that Make publishes, as `read_diagnostics` reads `DiagnosticsSnapshot`.
  - It gives whether the program is paused and why, the exception (`exceptionInfo` when the
    adapter has it), the stack (paths relative to the project, the selected frame marked), the
    selected frame's locals, the watches, and the console's last lines.
  - It's bounded: 20 frames, 30 locals, 12 members each, 200 characters a value, 1,500 of
    console.
  - Reading never touches the adapter, so it costs no requests and can't change the program.
    The tool's description says it can't start or step anything, and that the agent should ask
    the person to.
  - The snapshot is what the inspector already has: the first scope's variables are fetched
    once, for the Variables list and the snapshot both. A small structured local's members
    (up to four locals, twelve members each) are fetched only once the program has stayed
    paused half a second, so stepping through fetches nothing extra.
  - The agent's instructions mention the tool, and a running or ended session says so.
- **Budgets** (D6), as rows of `Budgets.table`, measured by `DebugBudgetTests`
  (`scripts/budgets.sh Debug`). In an optimized build:

  | Measure | Measured | Budget |
  |---|---|---|
  | A step, the stopped event to the line shown and 41 frames filled (fake adapter's answers included), median | 1.01 ms (p90 1.4) | ≤ 50 ms |
  | The first page of a 100,000-element array | 6.16 ms | ≤ 30 ms |
  | Paused, Side's CPU over 3 s | 0.26 % | ≤ 0.5 % |
  | 1,000 breakpoints following a keystroke's edit, median | 0.18 ms | ≤ 1 ms |
- **Fixes found on the way:**
  - A `stopped` event still being handled as Stop ended the session set it back to paused:
    an ended session now stays ended.
  - The client didn't end a server adapter's process after the adapter hung up first
    (`stop()` returned early); node running js-debug outlived it. It now always ends the
    transport.

Tests:

- Heron: the report (paused, running, none), its bounds, and the tool in every scope.
- Make publishes the paused program over a fake adapter. The stack is relative to the project,
  with 41 frames and the locals; members follow once it stays paused; nothing is left once it
  ends.
- The four budgets.
- The opt-in real-adapter tests pass (lldb-dap launch and attach, js-debug, debugpy, Delve),
  and nothing outlives the tests.
