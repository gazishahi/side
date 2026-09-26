# RFC: The debugger

*2026-09-26. Status: **decisions pending**: five questions for the owner below, each with a
recommendation. Once they're answered, the build order is the plan below.*
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

## Decisions pending

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
