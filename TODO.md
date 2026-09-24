# TODO

## 1. Show running agent count, separating agents from subagents

Show how many Claude Code agents are working right now, and say so plainly when
none are. Agents and subagents counted separately.

### Where the data is (verified 2026-09-24)

**Top-level agents — `~/.claude/sessions/<pid>.json`.** Claude Code maintains a
live registry, one file per session:

```json
{"pid":68196,"sessionId":"55ed4f48-…","cwd":"…/worcester","version":"2.1.280",
 "kind":"interactive","name":"worcester-a6","status":"busy","statusUpdatedAt":1790239870982}
```

`status` is the signal that matters. Observed values: `busy`, `idle`, `waiting`.
A sample across five live sessions:

```
  12669 idle     skills-6a
  65074 idle     cairo-5b
  68074 idle     worcester-eb
  68196 busy     worcester-a6
   9471 waiting  worcester-d4
```

This gives the count, a per-session name, and busy/idle for free — no parsing of
transcripts, no network. Entries matched running PIDs exactly in the sample, but
**verify liveness with `kill(pid, 0)` anyway** rather than trusting the file to
be cleaned up after a crash.

**Subagents — parse the parent's transcript.** Subagents run in-process, so they
have no PID of their own and do not appear in the registry. They show up in
`~/.claude/projects/<cwd-slug>/<sessionId>.jsonl` as a tool_use:

```json
{"name":"Agent","input":{"description":"…","subagent_type":"general-purpose",
 "prompt":"…","run_in_background":true}}
```

Running count = `Agent` tool_use entries with no matching `tool_result` for their
`tool_use_id`. Caveats: transcripts reach several MB (4.9 MB for one session), so
read from the tail rather than parsing whole files; `isSidechain` is **not**
present in 2.1.280, so don't rely on it.

### Design notes

- Poll on the existing display tick (60s, no network) — this is all local file
  reads, so it costs nothing against the rate limit.
- Menu bar: append something like `· 2 agents` only when non-zero, so the
  readout stays short when idle. Watch the notch — the bar is width-constrained.
- "All agents stopped": distinguish *no sessions* from *sessions all idle*. The
  useful signal is the busy→none-busy transition; consider a notification on
  that edge rather than only a passive count.
- Dropdown: list each session by `name` and `cwd` with its status, plus the
  subagent count nested under its parent.

## 2. Customisable colour thresholds

Two related asks:

- Warn when the **5-hour session limit** is getting close, which today is
  invisible until it is already orange at 70%.
- Warn on nearing limits generally, with the thresholds and colours
  **user-customisable** rather than hardcoded.

Currently `color(for:)` in `Sources/main.swift` hardcodes neutral / 70% orange /
90% red, and those numbers appear in the menu bar and the dropdown alike.

### Design notes

- Read from a config file (`~/.config/claude-usage-bar/config.json`), created
  with defaults on first run. No UI for editing it initially.
- Make thresholds per-window: the 5-hour and 7-day windows deserve different
  trigger points, since a 5-hour window refills on its own and a 7-day one does
  not.
- Consider a time-aware trigger for the 5-hour window — "80% used with 3 hours
  still to run" matters more than the raw percentage.
- Keep the stock macOS system colours as the default. Prior attempts at custom
  palettes were rejected; customisation should be opt-in, not a new default.
- Re-read the config on change (or at least on each poll) so edits apply without
  a relaunch.
