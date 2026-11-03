# Live output for outside agents' commands

Status: proposed 2026-11-02. Replaces the backlog item "Think agents write into our own terminal".

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
the command, its output scrolling in as it runs (the last lines, monospaced), then its exit
status. Clicking the card shows the full output. Stop still stops the turn; there is no
per-command interrupt, since the agent owns the process.

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
4. **Side, Think:** render the entry with the existing command card in its finished-output state
   (`CommandProposalView`'s terminal tail), without Run or Approve buttons: the agent's own
   permission card has already asked.
5. **Session log:** the entry is saved with its final output, so a reopened session shows it.

An adapter that sends no `terminal_*` meta, or a command with no terminal content, keeps today's
tool line.

## Acceptance

- A replayed `claude-agent-acp` transcript of `for i in 1 2 3; do echo $i; sleep 1; done` shows
  1, 2, 3 arriving in the card, then exit 0.
- The same for `codex-acp`.
- A command that fails shows its exit code in the failed status color.
- 5 MB of output keeps the card's tail and the full-output view bounded, and Think stays at 60 fps.
- A session reopened from the log shows the finished card.
- An adapter without the capability renders exactly as before.

## Not in this

- Per-command interrupt (the agent owns the process).
- Showing these commands in Run.
- Heron's own commands, which already run in Run.
