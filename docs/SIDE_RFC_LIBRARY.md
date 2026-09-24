# RFC: Library

*2026-09-23. Status: **in progress**: the owner asked for a short RFC and to start building. Steps 1–3 built; see Plan.*
*Companion to `SIDE_PRODUCT_CONSTITUTION.md` (Library is not a stage: a separate window, ⇧⌘L)
and `SIDE_RFC_NAVIGATION_LEDGER.md` R6. Builds on `ProjectRules` ("Library-lite") and
`SIDE_RFC_BYO_HARNESS.md` (outside agents).*

## The problem

What shapes an agent's behavior is scattered and mostly invisible:

- **Instruction files.** Heron reads the first of `SIDE.md`, `.side/rules.md`, `AGENTS.md`,
  `CLAUDE.md`, after the user acknowledges it. Claude Code reads `CLAUDE.md`, Codex and Pi read
  `AGENTS.md`, Gemini reads `GEMINI.md`, and each also reads a file in the user's home folder.
  Outside agents read theirs whether or not Side's acknowledgement was given. Nothing in Side
  shows which agent reads what.
- **Prompts people repeat.** "Review this for concurrency bugs", "write the release notes".
  Today they're retyped or pasted from somewhere else.
- **Tools.** Outside agents get only Side's own MCP server. A user who wants their database or
  issue-tracker MCP server has to configure it separately in each agent.
- **Skills.** Claude Code skills live in `~/.claude/skills` and `.claude/skills`; nothing in
  Side lists them.
- **Storage.** Conversations, checkpoints and worktrees accumulate with no place to see or trim
  them.

## Design

One window, **Library** (⇧⌘L, Window menu, Think's + popover, `/library`). It follows the
frontmost project window and says which project it's showing. A sidebar of sections, each a list
with a detail pane. It edits nothing silently: files open in Make, and anything that changes what
an agent receives says so where it's changed.

- **Instructions.** Every instruction file for the project and the user, found or missing, with
  the agents that read it. Heron's file shows whether it's acknowledged and lets the user
  acknowledge it after reading the preview. Actions: Open in Make, Create (from the template).
  The pane states plainly that outside agents read their own files without Side's
  acknowledgement.
- **Prompts.** Saved prompts are Markdown files: the user's own in
  `~/Library/Application Support/Side/Prompts/`, the project's in `.side/prompts/` (shared
  through the repo). The file name is the name; the first line may be a `# Title`. In Think,
  `/name` inserts the prompt into the composer; it never sends on its own, so a prompt that
  arrives with a cloned repo is read by the user before it does anything and needs no
  acknowledgement.
- **MCP servers.** The user's own stdio MCP servers (name, command, arguments, environment),
  on or off per project. Side passes the enabled ones to outside agents in `session/new`
  alongside its own server. Environment values go to the Keychain. Heron has no MCP client yet;
  the pane says so.
- **Skills.** Read-only discovery of skills on disk (`SKILL.md` folders for Claude Code and the
  shared `~/.agents/skills` convention): name, description, which agent loads it, Open.
- **Storage.** Per-project sizes (conversations, outside-agent logs, checkpoints, worktrees),
  the history retention setting, and removing worktrees of archived tracks (a confirmation that
  names what's removed).

**Templates** are prompts with a track: a prompt whose front matter says `track: true` offers
"Start Track", which creates a track named by its title and sends the prompt as the first
message. That is the whole feature; there is no separate template object.

## Guardrails

- Files that arrive with a repo never take effect silently. Heron's rules keep per-content
  acknowledgement; prompts only insert; project MCP servers are not a thing (servers are the
  user's, enabled per project by the user), because a cloned repo must not be able to launch a
  process.
- No secrets in plain files: MCP environment values live in the Keychain.
- No em dashes in user-facing copy.

## Decisions

- **L1: Where do MCP servers live?** *Recommend:* the user's, in Side's preferences, enabled
  per project. Not read from the repo (see Guardrails).
- **L2: Do prompts send?** *Recommend:* no, insert only.
- **L3: Heron and skills.** *Recommend:* list only for now; teaching Heron to load skills is a
  later RFC with its own consent story.

## Plan

1. **Window, Instructions, Prompts.** `LibraryWindowController` (⇧⌘L), `InstructionFiles`,
   `PromptLibrary`, `/name` insertion in Think, + popover and `/library` entry points.
   **Built 2026-09-23:** Window › Library (⇧⌘L), Think's + popover and `/library` open it for the
   frontmost window's working copy. Instructions lists every file with its readers and Heron's
   state (in use, waiting for acceptance, shadowed); "Use for Heron" is `ProjectRules.acknowledge`.
   Prompts saves Markdown files; the palette lists them after the built-in commands, which keep
   their names. Not yet: the Preferences entry point.
2. **MCP servers** for outside agents (`MCPServerStore`, `ACPHarness` passes them).
   **Built 2026-09-23:** Library › MCP Servers adds, edits and deletes stdio servers and switches
   each on per project. Environment values go to the Keychain and show as dots afterwards. A bare
   command resolves against the agent's PATH. Enabled servers go to `session/new` and
   `session/load` after Side's own; a change restarts idle outside agents, which resume their
   conversation. Verified live: Claude Code started a user's server and returned its tool's
   result. Known: in the test host, a command resolved to a pyenv shim timed out under Claude
   Code while `/usr/bin/python3` worked; not reproduced outside the test host.
3. **Skills and Storage.**
   **Built 2026-09-24:** Skills lists `SKILL.md` folders in `.claude/skills` and `.agents/skills`
   (project and home) and `~/.codex/skills`, with the name and description from the front matter
   and the agents that load them (`SkillCatalog`); Open in Make. Storage shows the sizes of
   Heron conversations, outside-agent records and track working copies, the history setting
   (the same one as Preferences), and removes archived tracks' working copies with
   `TrackStore.removeWorkingCopy`: branches and checkpoints stay, and a copy with uncommitted
   changes is kept and named.
4. **Templates** (Start Track from a prompt).

## Acceptance (step 1)

- ⇧⌘L opens Library for the frontmost project; it updates when another project window comes
  forward.
- Instructions lists each candidate file with its readers and state; acknowledging there is the
  same acknowledgement Think asks for.
- A prompt saved in Library shows up as `/name` in Think's slash palette and inserts its text.
