# Live output for outside agents' commands

Status: built 2026-11-02. Replaces the backlog item "Think agents write into our own terminal".
Symbols: `AgentCommandPresentation`, `ACPHarness`, `CommandProposalView`, `OutsideSessionLog`.

## Why

Side's own agent (Heron) types its commands into the track's Run terminal, and an ACP agent that
asks for a terminal (`terminal/create`) gets a Run tab of its own. Both are visible while they run.

Claude Code (`claude-agent-acp`) and Codex (`codex-acp`) never ask for a terminal: they run every
command in their own process. Today Think shows such a command as one tool line, its title and
the first line of its output cut at 120 characters. A two-minute `npm test` is a line that says
nothing until it ends, and then says one line.

Routing their commands into Run instead was considered and dropped: it means turning off the
agent's own Bash tool and substituting one of ours, which fights its permission prompts and
background tasks and breaks with the adapters' frequent releases.

## What

An outside agent's command shows in Think as a command card, the same card Heron's commands use:
the command, "Running · 12s" with a turning ring, its output scrolling in as it arrives, then
"Ran", "Failed · exit 1" or "Stopped". The output box shows up to 14 lines and scrolls through
the last 256 KB, following the end unless scrolled up. Stop still stops the turn; there is no
per-command interrupt, since the agent owns the process.

How live it is depends on the agent. Codex (`codex-acp`) streams each chunk as the command
prints it. Claude Code (`claude-agent-acp` 0.81) reports only elapsed-time beats while a command
runs and sends the whole output with the exit when it ends, so its card runs, then fills.

## How

Both adapters already stream command output to a client that says it can show it. They read
`clientCapabilities._meta`:

- `terminal_output_delta: true`: each `tool_call_update` for a command carries
  `_meta.terminal_output_delta { terminal_id, data }` (new bytes), and the last carries
  `_meta.terminal_exit { terminal_id, exit_code, signal }`.
- `terminal_output: true`: the same, with `_meta.terminal_output` carrying the whole output so far.

The content of such an update is `{ type: "terminal", terminalId }`, where `terminalId` is the
tool call's id, not a terminal Side created.

1. **Heron, `ACPHarness.initialize`:** add `"_meta": ["terminal_output_delta": true]` to
   `clientCapabilities`. Deltas, so a long log isn't resent on every chunk.
2. **Heron, `tool_call` with `kind: "execute"`:** append a command entry (the command from
   `rawInput.command`, else the title) instead of a tool line, keyed by `toolCallId`.
3. **Heron, `tool_call_update`:** append `terminal_output_delta.data` to that entry's output
   (bounded from the front, as `ACPTerminalBroker` bounds `terminal/output`, with ANSI stripped),
   and set its exit from `terminal_exit`. Updates coalesce to one redraw per frame.
4. **Side, Think:** `CommandProposalView(agentCommand:)`, without Run or Reject: the agent's own
   permission card has already asked. A card standing on its own, like Heron's, not a line in
   the collapsed "Worked for…" group, so its output is in view while it runs.
5. **Session log:** the entry is saved once it ends, with the last 64 KB of output, so a reopened
   session shows it.

An adapter that sends no `terminal_*` meta still gets the card: when the call completes, the
result's text stands in for the output.

## Acceptance

Covered by `LiveCommandOutputTests` (Side) and `AgentCommandOutputTests` (Heron):

- A fake agent shaped like `codex-acp` streams `for i in 1 2 3; do echo $i; done`: mid-run the
  card shows "1" and "Running", then "1 2 3" and "Ran", in the same card.
- One shaped like `claude-agent-acp` sends `npm test`'s output and exit 1 at the end: the card
  says "Failed · exit 1", with colour escapes stripped.
- Carriage-return progress lines settle at their last state, across chunks.
- Output past 256 KB is cut from the front at a line.
- An agent that streams nothing still shows the result's text.
- A conversation reopened from Side's record shows the finished cards as they ended.

## Not in this

- Per-command interrupt (the agent owns the process).
- Showing these commands in Run.
- Heron's own commands, which already run in Run.
