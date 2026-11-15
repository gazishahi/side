# Side

Side is a native macOS development environment for working with coding agents. It sees every agent session in your project, however it was started and wherever it went, tells you which one needs you, and lets you review and edit what each changed in a real editor. Sessions survive restarts and updates.

Agents (Claude Code, Codex and others) run on your own account. Side never needs to start them itself: it finds them in its terminals, through opt-in hooks, and from the agents' own session lists.

Status: 0.6.0, pre-1.0. Formats and behavior may still change. Signed builds are at [gazishahi/side-releases](https://github.com/gazishahi/side-releases).

## The app at a glance

Side has five stages. One stage owns the window at a time.

| Stage | What it is for |
|---|---|
| Editor | Alloy, Side's GPU editor: code, navigation, diagnostics, the debugger, and who wrote each changed line |
| Agent | A graphical view of any agent session, with its history |
| Changes | The review queue: what each session changed, by request; approve, commit, discard, or ask for changes |
| Terminal | The project's terminal tabs, kept alive by a helper so they outlive Side |
| Branches | Every branch and worktree, its pull request, and the sessions working on it |

⌃⌘S opens the session switcher: every terminal program and agent across your projects, the ones that need you first. The activity pill says what a session is waiting for. Library (prompts, skills, instruction files) is a separate window, and Settings holds agents, languages and appearance.

## Requirements

- macOS 15 or later
- Xcode 26 (Swift 6)
- Git, from Xcode or the Command Line Tools
- Zig 0.17 (`brew install zig`), to build libghostty-vt for the terminal
- For language features and debugging: the language servers and debuggers for your languages. Settings, Languages offers to install the common ones.

## Building

1. Build libghostty-vt once (it clones Ghostty at a pinned commit; output is git-ignored):
   ```sh
   scripts/build-ghostty-vt.sh
   ```
2. Open `SIDE.xcodeproj` in Xcode, choose the `SIDE` scheme and run.
3. The first build asks to trust SwiftTerm's build plugin (`SwiftTermBuildInfoPlugin`). Choose Trust and Enable.

A Release build run from Xcode is signed ad hoc, so the hardened runtime is off in the project. `scripts/release.sh` turns it on for a signed release.

The new terminal engine (libghostty-vt with Alloy's renderer) is behind a setting while it's finished; SwiftTerm is the default:

```sh
defaults write com.shahi.side terminal.engine alloy
```

## Testing

```sh
scripts/test.sh
```

Runs SideAgents', Alloy's and SideSessions' own tests (`swift test`), then the app's. A change is ready when it exits 0. There is no hosted CI for the app yet; this is the gate.

```sh
scripts/budgets.sh            # every performance budget, in an optimized build (about 15 minutes)
scripts/budgets.sh Review     # one suite
```

Budgets measure frame times, CPU and memory against the limits in `SIDETests/Budgets.swift`. Run them on a quiet machine.

## Repository layout

| Path | What it holds |
|---|---|
| `SIDE/` | The app: stages, shell, sessions, language and debugger integration |
| `SIDETests/`, `SIDEUITests/` | The app's tests and UI tests |
| `Packages/Alloy/` | Alloy, the editor and terminal renderer: Metal text rendering, tree-sitter syntax, input |
| `Packages/SideAgents/` | What agents run on: the ACP client, sessions, checkpoints, usage, Side's MCP tools |
| `Packages/SideSessions/` | Terminals that outlive Side: the session keeper, its protocol, and SideTerminal (libghostty-vt) |
| `Packages/SwiftMath/` | SwiftMath, vendored: LaTeX math in the Markdown preview |
| `Helpers/` | The session keeper's and notifier's app bundles |
| `Benchmarks/` | Terminal and session benchmarks |
| `docs/` | The constitution, design direction, RFCs, audits and distribution plan |
| `scripts/` | Building, testing, budgets, releases |

Alloy is also published on its own at [gazishahi/alloy](https://github.com/gazishahi/alloy). Its source of truth is here, under `Packages/`; the public repository is published from it. The terminal benchmarks are reproducible from [gazishahi/side-terminal-bench](https://github.com/gazishahi/side-terminal-bench).

## Releasing

The app:

```sh
scripts/release.sh            # Developer ID signed, notarized DMG
scripts/release.sh --dry-run  # build and sign only
```

The one-time setup (certificate, notary credentials, Sparkle key) is at the top of the script. DMGs and the update feed are published to [gazishahi/side-releases](https://github.com/gazishahi/side-releases).

Alloy:

```sh
scripts/publish-package.sh Alloy 0.7.5 "0.7.5: what changed"
scripts/publish-package.sh --release-only Alloy 0.7.5
```

Copies the package into a fresh clone of its public repository, pushes, waits for CI on that commit, then tags it and creates a GitHub Release with notes from the commits since the previous tag.

## Documents worth reading first

- `docs/SIDE_RFC_SESSIONS.md`: the sessions model Side is built around
- `docs/SIDE_PRODUCT_CONSTITUTION.md`: what Side is and its rules
- `docs/SIDE_DESIGN.md` and `docs/SIDE_DESIGN_DIRECTION_03.md`: how it looks and behaves
- `docs/SIDE_RFC_TERMINAL_ENGINE.md`: the new terminal engine
- `docs/SIDE_DISTRIBUTION.md`: signing, updates and releases

## License

Side is licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).

Third-party components keep their own licenses; they're listed in `docs/legal/THIRD_PARTY_NOTICES.md` and shipped in the app (About Side). The Apache license doesn't grant rights to the Side name or icon.
