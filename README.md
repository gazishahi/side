# Side

Side is a native macOS development environment built around tracks. A track is one line of work: an intent, its own git branch and working folder, the agent conversations working on it, and the checkpoints and evidence that lead back to `main`. Agents (Claude Code, Codex and others, on your own account) do the work; people review and promote it.

Status: pre-release, version 0.1.0. Not yet published.

## The app at a glance

Side has five stages. One stage owns the window at a time.

| Stage | What it is for |
|---|---|
| Editor | The editor (Alloy): code, navigation, diagnostics, edits, the debugger |
| Agent | Agent conversations on a track, with an agent of your choice over ACP |
| Changes | Checkpoints, diffs, test evidence, and promoting a track into its base |
| Terminal | Terminals that outlive Side, tasks, tests and logs |
| Branches | Every line of work: resume, park, stack, archive, clean up |

Library (prompts, skills, instruction files) is a separate window, and Settings holds agents, languages and appearance.

Agents speak the Agent Client Protocol. Claude Code is verified; Codex, Gemini CLI, Pi and OpenCode are built in and marked experimental. Any other ACP agent can be added by its command. New tracks start on the default agent (Settings, Agents). Side offers every agent its own tools over MCP: the project's other tracks, the editor's diagnostics, the debugger's state and the track's ports.

Side's own agent, Heron, was retired on 2026-11-04 (`docs/SIDE_RFC_HERON_RETIREMENT.md`); its conversations stay readable on the tracks that have them.

## Requirements

- macOS 15 or later
- Xcode 26 (Swift 6)
- Git, from Xcode or the Command Line Tools
- For language features and debugging: the language servers and debuggers for your languages. Settings, Languages offers to install the common ones.

## Building

1. Open `SIDE.xcodeproj` in Xcode.
2. Choose the `SIDE` scheme and run.
3. The first build asks to trust SwiftTerm's build plugin (`SwiftTermBuildInfoPlugin`). Choose Trust and Enable.

A Release build run from Xcode is signed ad hoc, so the hardened runtime is off in the project. `scripts/release.sh` turns it on for a signed release.

## Testing

```sh
scripts/test.sh
```

Runs SideAgents', Alloy's and SideSessions' own tests (`swift test`), then the app's. Commit only when it exits 0. There is no hosted CI for the app before launch; this is the gate.

```sh
scripts/budgets.sh            # every performance budget, in an optimized build (about 15 minutes)
scripts/budgets.sh Review     # one suite
```

Budgets measure frame times, CPU and memory against the limits in `SIDETests/Budgets.swift`. Run them on a quiet machine.

## Repository layout

| Path | What it holds |
|---|---|
| `SIDE/` | The app: stages, shell, tracks, language and debugger integration |
| `SIDETests/`, `SIDEUITests/` | The app's tests and UI tests |
| `Packages/SideAgents/` | What agents run on: the ACP client, sessions, checkpoints, usage, Side's MCP tools |
| `Packages/SideSessions/` | Terminals that outlive Side: the session keeper and its protocol |
| `Packages/Alloy/` | Alloy, the editor: Metal text rendering, tree-sitter syntax, input |
| `docs/` | The constitution, design direction, RFCs, audits and distribution plan |
| `scripts/` | Testing, budgets, releases |

Alloy is open source (Apache-2.0) in its own repository, [gazishahi/alloy](https://github.com/gazishahi/alloy). Its source of truth is here, under `Packages/`; the public repository is published from it. Heron's repository, [gazishahi/heron](https://github.com/gazishahi/heron), is archived.

## Releasing

The app:

```sh
scripts/release.sh            # Developer ID signed, notarized DMG
scripts/release.sh --dry-run  # build and sign only
```

The one-time setup (certificate, notary credentials, Sparkle key) is at the top of the script. DMGs and the update feed are published to [gazishahi/side-releases](https://github.com/gazishahi/side-releases), which holds no source.

Alloy:

```sh
scripts/publish-package.sh Alloy 0.7.5 "0.7.5: what changed"
scripts/publish-package.sh --release-only Alloy 0.7.5
```

Copies the package into a fresh clone of its public repository, pushes, waits for CI on that commit, then tags it and creates a GitHub Release with notes from the commits since the previous tag. Every version is both a tag and a Release.

## Documents worth reading first

- `docs/SIDE_PRODUCT_CONSTITUTION.md`: what Side is, its rules, and how tracks work
- `docs/SIDE_DESIGN.md` and `docs/SIDE_DESIGN_DIRECTION_02.md`: how it looks and behaves
- `docs/SIDE_DISTRIBUTION.md`: launch gates, signing, updates and licensing
- `docs/SIDE_AUDIT_REPORT_2026-09-30.md`: the latest audit and what was fixed

## License

The Side app is proprietary and not open source. Alloy is licensed under Apache-2.0; see its `LICENSE` file. Heron, archived, was too.
