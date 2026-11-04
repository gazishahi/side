# Session restore: terminals you can always get back

Status: agreed 2026-11-03. Phases 1, 2 and 3 built: notifications came last (an agent finishing a turn, a bell, or an OSC 9/777 notification while no Side window is attached; clicking one opens the tab).

## Why

Closing a project, or quitting Side, ends every shell in it. On reopening, Run brings back the
tabs (each one's folder and name, `TerminalSessionManager.rememberedDirectories`) but not what was
running in them. With six Claude Code sessions on a project, that means six `claude --resume`
runs, each picked from a list whose names don't say what the session was doing.

That's the biggest daily cost of using Side today. It also breaks the constitution's fourth
non-negotiable: work is durable.

**The goal:** a terminal in Side is as recoverable as one in tmux with tmux-resurrect and
tmux-continuum, whatever happens to Side, to the session machinery or to the Mac.

Today's code says outright why it stops short. `restoreRememberedSessionsOrCreateOne` explains
that a terminal is "a live PTY with a shell and whatever it was running; those die with the
process and cannot be restored". That's true only while Side's own process owns the PTYs. The fix
is to have processes that outlive Side own them, as tmux's server does. The owner doesn't want to
depend on tmux.

## The guarantee

| What happens | What comes back |
| --- | --- |
| Quit Side, close a window, close a project | Everything, live: the same processes, screen, scrollback and cursor. Agents keep working meanwhile. |
| Side crashes | The same: Side's process holds no terminals. |
| One session's keeper crashes | That session's screen and scrollback from its last saved snapshot. Its process can't survive; agent and command recovery apply to that one session only. |
| Restart, shutdown, logout, power loss | Each tab in its folder with its name, screen and scrollback from the last snapshot. Agent conversations resume by themselves; other programs as described under Programs after a restart. |

The one thing nothing can do, Side or tmux, is keep a process alive across a restart. tmux-resurrect
answers that by recreating panes and re-running known programs. Side does the same, and also
resumes agent conversations exactly, which tmux-resurrect can't.

## What the person sees

- **Quit and reopen.** Every Run tab is as it was, with the same process still running. A Claude
  session that was mid-turn is still mid-turn, or finished while Side was closed.
- **Closing a tab still ends it.** Ending a running process asks first (the close warning from
  the polish list). Detaching happens only on closing a window, closing a project or quitting,
  never on closing a tab.
- **Sessions keep running by default** (decided). Quitting doesn't ask. Settings can change it to
  ending sessions on quit.
- **Nothing is ended automatically** (decided). A detached session runs until its process exits or
  the person ends it.
- **The sessions list keeps it visible.** Every live terminal, across projects, shows what it's
  running, how long it's been idle and its memory, with End and End All. Until the sessions board
  from the direction work exists, this lives in Run's tab menu and the Window menu.
- **Notifications while Side is closed** (decided). When a detached session asks for attention
  (a bell, an OSC 9 or OSC 777 notification, or an agent finishing its turn), a macOS notification
  says which project and tab. Clicking it opens Side on that tab.
- **Tab names that say something.** A tab with no name of its own is named after what its program
  last titled it; Claude Code sets the terminal title to its task. That name is remembered.
- **After a restart, agent tabs resume by themselves** (decided). The first time each tab is shown,
  it runs `claude --resume <id>`, after a line saying "Resumed after a restart", so a resumed
  session is never mistaken for one that kept running.

## How

### One keeper per session

Each terminal is owned by its own small process, a session keeper (the dtach/abduco model), not by
one shared server.

- **Isolation.** One server for everything (tmux's model) means one crash ends every session.
  That's the limitation weighed in the first draft. With a keeper per session, a crash costs one
  session, and Side never holds a terminal at all.
- **Cost.** Measured with a prototype keeper (2026-11-03), a keeper process is 1.6 MB in Swift
  (0.9 MB in C), and isolation costs only that much per session. The rest is scrollback, which
  costs the same in one shared server. See Memory, below.
- **Started by Side,** detached with `posix_spawn` and `POSIX_SPAWN_SETSID`, so it isn't Side's
  child and quitting Side doesn't end it. It's shipped in the app bundle (`Contents/Helpers/`),
  signed and notarized with Side. No launchd agent or login item: nothing it holds survives a
  restart, so there's nothing to start at login.
- **What it owns:** the PTY master, the child process, and a headless libghostty-vt terminal fed
  every byte of output. That terminal is the source of truth for the screen and scrollback.
- **When it exits:** after the process exits and Side has acknowledged it, so a tab can show
  how it ended.

At the 600+ MB/s measured for libghostty-vt's parser
(`docs/SIDE_TERMINAL_BENCHMARKS_2026-11-03.md`), parsing in the keeper is noise next to the PTY's
~200 MB/s ceiling. This makes session restore libghostty-vt's first production use in Side, ahead
of the Run engine switch, which lowers that switch's risk.

### Finding sessions

`~/Library/Application Support/Side/run/`, mode 0700, holds per session:

- `<id>.sock`: its socket.
- `<id>.json`: its record. Project, track, Side's tab id, folder, the command it started with, its
  current foreground command, program title, agent and agent session id, and created and
  last-output times. Written on change, so it's never more than a moment stale.
- `<id>.snap`: its snapshot (below).

Side finds sessions by reading the records and connecting to each socket. A record whose socket
doesn't answer belongs to a session that ended unexpectedly, and goes through recovery. The keeper
checks each connection's peer with `getpeereid` and refuses any other user.

### The protocol (per keeper)

Length-prefixed messages; the first is a version handshake.

| Message | Direction | Carries |
| --- | --- | --- |
| `hello` | both | protocol version, keeper build, client build |
| `attach` | client → keeper | reply: a snapshot, then output streams |
| `detach` | client → keeper | — |
| `input` | client → keeper | bytes for the PTY |
| `resize` | client → keeper | cols × rows (the PTY and its terminal together) |
| `signal` | client → keeper | SIGINT, SIGTERM or SIGKILL, for the process group or the whole tree (today's `terminateProcessTree` moves here) |
| `output` | keeper → client | bytes, in order |
| `title` | keeper → client | the program's latest title (OSC 0/2) |
| `attention` | keeper → client | a bell or notification, with its text |
| `exited` | keeper → client | exit status |

A session is created by starting its keeper with the command, environment, folder and size as
arguments. A session has at most one attached client: a second `attach`, for example from another
build of Side, takes it over and the first gets `replaced`. A connection that doesn't attach
(it only says hello, or only checks the session is there) never disturbs the attached client.
Side checks whether a keeper is running by its process and arguments, not by connecting.

### Reattaching

On `attach`, the keeper sends the current state, then live output, with no gap or duplicate
between them: the snapshot is taken and streaming begins under one lock.

- **While Run is on SwiftTerm (now):** the snapshot is libghostty-vt's VT formatter output (`GHOSTTY_FORMATTER_FORMAT_VT`). That's escape sequences that redraw scrollback and screen, plus the mode state SwiftTerm needs: alternate screen, cursor position and visibility, scroll region, bracketed paste, mouse modes, keypad mode. Side feeds it into a fresh SwiftTerm terminal before showing the tab. Each mode needs a test, because a missed mode is a visible bug.
- **After Run moves to libghostty-vt + Alloy:** libghostty-vt's binary snapshot (`ghostty_snapshot_encode`), restored straight into the client's terminal. It puts enough to render ahead of the older scrollback, so the tab draws as soon as the screen has arrived.

After the snapshot, the client sends `resize` with its real size, so a TUI like Claude Code gets
SIGWINCH and redraws to fit.

### Snapshots on disk

For the restart rows of the guarantee, each keeper writes its binary snapshot to `<id>.snap`:
- every 30 seconds while there's new output, written to a temporary file and renamed into place;
- on SIGTERM, which macOS sends at shutdown and logout before ending processes;
- on SIGHUP.

This reverses a deliberate rule in today's code: that a terminal's contents are not Side's to
persist, because terminals routinely show tokens and passwords. tmux-resurrect makes the same
trade behind an option. Here:
- the files are readable only by the user (0600), in a 0700 directory;
- they're excluded from Time Machine;
- a session's file is deleted when the session is ended;
- Settings can turn it off.

On by default (decided).

### Changes in Side

- **`TerminalViewController`** stops using `LocalProcessTerminalView`'s own process. Its `SideTerminalView` becomes a plain SwiftTerm `TerminalView` fed from the keeper's socket, and `send(source:data:)` writes `input`. Its hooks (links, submitted lines, raw output for agent commands and unseen output, OSC 7 and OSC 133 marks) sit on the byte stream, so they keep working unchanged.
- **`TerminalSessionManager`:**
  - `makeSession` starts a keeper.
  - On project open, it reads the records for that project and attaches each live session to its tab, matched by Side's tab id.
  - `teardownAll` and quitting **detach**.
  - `discardSessions` (track deleted) and closing a tab end the session with `signal`.
- **Shell integration and ports** are unchanged. Side builds the environment (ZDOTDIR wrapper, `SIDE_MARK_NONCE`, `TrackPorts`) and passes it to the keeper.
- **Heron's typed agent commands** run in the shell's keeper, like anything else typed there.
- **Command tabs stay in Side's process** (decided while building phase 1). An outside agent's `terminal/create` and a debugged program's terminal belong to an agent or debugger session in this Side process, so they end with it. An ACP agent process itself (`claude-agent-acp` behind Think) isn't a terminal, and also ends with Side.
- **Closing a tab** sends SIGTERM to the whole tree and SIGHUP to the shell. An interactive shell ignores SIGTERM, and a keeper's PTY doesn't close with the tab, so the hangup a closing terminal sends has to be sent on purpose.

### Agent sessions

Each agent tab records its agent's own session id while it runs, so it can be resumed exactly:

- **Claude Code** (2.1.312 has `--session-id <uuid>` and `--resume <id>`). Side's zsh integration defines a `claude` shell function:
  - If the arguments include none of `--resume`/`-r`, `--continue`/`-c`, `--session-id` or `--print`/`-p`, it generates a UUID and runs `command claude --session-id <uuid> "$@"`.
  - It reports the id to Side with a private OSC sequence (same nonce as the OSC 133 marks), which the keeper stores in the session's record. An explicit `--resume <id>` reports that id.
  - `--continue` and a bare `--resume` picker report nothing at launch; the id is then taken from the newest transcript in `~/.claude/projects/<folder>/` written after the launch.
  - Nothing in the user's Claude configuration or credentials is touched, in line with the subscription policy.
- **A Claude session nothing was typed into** has no transcript to resume, so it starts fresh under the same session id (`claude --session-id <id>`).
- **OpenCode** (`opencode --continue`) and **Codex** (`codex resume --last`) resume the latest session in the tab's directory. That's the tab's own unless two tabs ran the same agent in one folder; an exact id would need a wrapper like Claude's. **Gemini** and other agents get Run Again, which starts a fresh session.

### Programs after a restart

What tmux-resurrect calls restoring programs. The keeper's record holds each session's foreground
command line, from the process group leading the terminal. On restore:

- **Agents** resume automatically, as above.
- **Programs that are safe to re-run** start again by themselves in their folder. That's editors, pagers, watchers and git UIs: `vim`, `nvim`, `less`, `man`, `top`, `htop`, `btop`, `tail -f`, `watch`, `lazygit`, `tig`. It's a fixed list (extendable in Settings later).
- **Everything else** comes back as a shell with the old screen above it and a "Run again: `npm run dev`" button. Re-running an arbitrary command by itself could deploy something or delete files twice.

### Notifications

The keeper raises `attention` for a bell, an OSC 9 or OSC 777 notification, or, for an agent
session, the end of a turn. A turn's end is the agent's title losing its working marker; Claude
Code animates a spinner glyph there. When Side is attached, Side handles it as it does today.

When Side isn't running, the keeper hands it to a small notifier app, Side Sessions.app, inside
Side's bundle. It has no Dock icon, and it posts the notification under its own name, which macOS
asks permission for once. Clicking the notification opens `side://run/<session id>`, which starts
Side if needed and shows that tab. Several notifications within a few seconds from one project are
grouped.

### Memory

The rule: a saving goes in only if it costs no speed and no feature. Measured with a prototype keeper (a PTY plus a headless libghostty-vt terminal, 10,000 lines of scrollback at 200 columns):

| | Plain text | Colored text (worst case) | Unicode |
| --- | --- | --- | --- |
| Keeper process (Swift) | 1.6 MB | 1.6 MB | 1.6 MB |
| Full scrollback, as written | 16.4 MB | 35.6 MB | 18.4 MB |
| Full scrollback, compressed | 1.3 MB | 14.3 MB | 1.9 MB |
| Compression, longest pause per step | 0.36 ms | 2.7 ms | 0.40 ms |
| Snapshot of compressed scrollback | 5.1 ms | 19.7 ms | 11.1 ms |

Scrollback is the memory, not the processes. A full plain-text scrollback is 10× the size of the keeper that holds it, and it would cost the same in one shared server. So:

- **Compress scrollback when a session goes quiet** (libghostty-vt's incremental compression, after 5 s without output, stopping the moment output resumes). Nothing changes while output flows. Scrolling back into compressed history decompresses it transparently; a full-scrollback snapshot of compressed history took about as long as an uncompressed one. Text compresses 10–12×; heavily colored output about 2.5×.
- **Write the keeper in Swift.** C would save 0.7 MB per session, about 17 MB at 24 sessions. That's not worth a second language in Side's codebase.
- **Stream snapshots through a writer** (`ghostty_snapshot_encode` with a writer callback) to the socket or disk, never built whole in memory. Building one whole took up to 18 MB at once, and macOS reclaims freed memory lazily.

At 24 sessions with full plain-text scrollback, that's about 70 MB in total (24 × 1.6 MB of processes, plus 24 × 1.3 MB of compressed scrollback). A Claude Code session that redraws in place keeps much less. The first draft's 150 MB estimate for processes alone was wrong.

Not done, because each would cost speed or a feature:
- Less scrollback: it's a feature.
- One shared server: it gives up crash isolation for 0.7–1.6 MB per session.
- Dropping Side's copy of hidden tabs' terminals and re-fetching on show: that would make switching tabs cost 5–20 ms, not under 1 ms.

### Updates

Sparkle can replace Side while keepers keep running from the old build. The `hello` handshake
carries both versions. New messages are added, never changed, so a new Side can always attach to
an old keeper. A keeper is never ended because Side updated; it runs its old build until its
session ends. So what a keeper itself does (notifications, turn detection, snapshots) is
the old build's until then: a terminal started before notifications existed never sends one
(seen 2026-11-04). Running Terminals could mark sessions on an older keeper; not built.

## Measures

The terminal benchmark harness (`Benchmarks/Terminal/`) gains a mode that runs through a keeper.
Targets, measured before this ships:

Measured 2026-11-03 by `Benchmarks/Sessions` (release builds, Apple M3 Pro), against a bare PTY
with no keeper:

| Measure | Target | Result |
| --- | --- | --- |
| Keypress latency added by the keeper hop | ≤ 0.5 ms median | 0.045 ms |
| End-to-end throughput through a keeper | ≥ 90% of direct | 94–102% (about 160 MB/s; every byte checked) |
| Reattach to visible screen, 6 sessions with full scrollback | ≤ 150 ms | 7–16 ms (keeper side) |
| Replaying those 6 snapshots into Run's terminal (Side's main thread) | ≤ 100 ms (added) | 51 ms |
| Keeper memory per idle session, scrollback empty | ≤ 2 MB | 2.0–2.1 MB |
| Keeper memory, full plain-text scrollback after compression | ≤ 4 MB | 4.3 MB (19.7 MB before) |
| Keeper CPU with no output | 0 | 0.0 ms over 10 s |

What it took, so the numbers stay honest:
- **Throughput** started at 69%. The keeper now reads the PTY on a thread of its own, gathering reads while more is readable (a zero-timeout poll, not FIONREAD, which also counts the program's unread input), and parses on another. Output goes to the client before it's parsed. Unix sockets get 1 MB buffers (8 KB by default), and read buffers come from a reused pool.
- **Reattach replay** first took 669 ms: Side's SwiftTerm terminal keeps 500 lines of scrollback, and the keeper sent all 10,000. An attach now says how much history the client keeps (`Attach.history`); the keeper still holds all of it.
- **Memory** is 0.1–0.3 MB over the two memory targets. That's the cost of the reader and parse threads, which took throughput from 69% to 94–102%. Per the owner's rule (no savings that cost speed or features), the threads stay. Compression of quiet scrollback (decision 7) is built.

Tests:
- **Snapshot round-trips.** For every mode the VT path restores (alternate screen, scroll region, cursor, bracketed paste, mouse, keypad), a session is driven into the mode, detached, reattached, and checked against the keeper's own screen.
- **Lifecycle.** Quit with sessions running, reopen and attach. Close a tab. Delete a track. Kill a keeper with SIGKILL mid-output and recover from its snapshot. Send SIGTERM as at shutdown and restore. Two clients attach to one session.
- **The `claude` wrapper.** Every argument form: none, `--resume <id>`, `-r`, `-c`, `--session-id`, and `-p` (left alone).

## Phases

1. **Keepers and reattach.** The keeper, its protocol and headless libghostty-vt. Side as a client, SwiftTerm fed by VT replay. Quit and reopen reattach live. Behind a setting, on in the owner's builds first.
2. **Restart recovery.** Snapshots on disk, agent ids and automatic resume, program re-runs, and remembered program titles.
3. **Visibility.** The sessions list, End All, the close-tab warning, and notifications through Side Sessions.app.
4. **Binary snapshots for reattach** once Run is on libghostty-vt + Alloy.

## Decided (2026-11-03)

1. Sessions keep running after quit, by default.
2. Detached sessions are never ended automatically.
3. Crash isolation matters, so one keeper per session rather than one shared server.
4. Agent tabs resume automatically after a restart.
5. Detached sessions post notifications.
6. Snapshots on disk are on by default, with the protections above.
7. Memory comes down only through savings that cost no speed or feature (Memory, above): compression when idle, streamed snapshots, and Swift for the keeper.

## Not doing

- Keeping processes alive across a restart. Nothing can; agent resume and program re-runs cover it.
- Remote or SSH sessions.
- Sharing a session between people.
- tmux as a dependency, or tmux's keybindings and panes.
- Restoring Make's open files. That's a separate bug (open files sometimes aren't restored) with its own fix.
