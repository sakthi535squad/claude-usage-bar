# How it works

The internals behind [the README](../README.md): where each number comes from,
and the measurements behind the design choices.

## Rate limits

Polls `https://api.anthropic.com/api/oauth/usage` every 5 minutes — the same endpoint
`/usage` uses inside Claude Code. The OAuth token is read fresh on each poll from
the `Claude Code-credentials` Keychain item, via `/usr/bin/security`, so token
rotations by Claude Code are picked up automatically and no credential is stored
by this app.

If the API call fails (no token, expired token, offline), it falls back to
`cachedUsageUtilization` in `~/.claude.json`, which Claude Code refreshes while
it runs. That value can be well over an hour old, so the bar marks it with `~`
and the menu says `cached`.

Opening the menu never triggers a fetch — only the 5-minute timer and **Refresh
Now** do. The endpoint rate-limits at roughly one request per minute and returns
`Retry-After` on 429; that header is honoured rather than guessed at (with a
60-second floor), and the app falls back to the cache, marked `~`, meanwhile.

### Colours

Neutral under 70%, `systemOrange` at 70%+, `systemRed` at 90%+ — the stock macOS
system colours, which follow Light and Dark Mode on their own. Each window is
coloured by its own number, so a healthy 5-hour window stays neutral while the
7-day one turns orange.

### Pace forecast

Live readings of the 5-hour window are kept for an hour and fitted with a line:
`full by <time>` when that line crosses 100% before the reset, otherwise
`on pace — ~N% at reset`. It needs 15 minutes of readings in the current window
first, since they arrive every 5 minutes in whole-percent steps. Cached readings
are never used.

## Sessions and agents

Counts come from two places, all local file reads with no API requests.

**Top-level sessions** are registered by Claude Code at
`~/.claude/sessions/<pid>.json` with a `status` of `busy`, `idle` or `waiting`.
Each entry is confirmed with `kill(pid, 0)`, since the file outlives a crash.

**Subagents** run in-process and have no pid, so they are counted from the
parent's transcript: an `Agent` tool_use is pending until it finishes. A
foreground agent finishes when a `tool_result` quotes its id. A background agent
gets that `tool_result` immediately (marked `toolUseResult.isAsync`), so for
those the finish is the later `<task-notification>` carrying `<tool-use-id>`.

Transcripts are read incrementally — each pass reads only bytes appended since
the last — on a background queue. The first pass over a 40 MB transcript takes
about a second; after that it is a few KB a minute.

### Labels

Each session is labelled with its Conductor chat title ("Claude usage tracker
Mac") rather than Claude Code's derived name ("worcester-a6"), joined on
`claude_session_id` against Conductor's sqlite database, opened read-only.
Sessions not started from Conductor fall back to their git branch, then to the
derived name.

### Control panel rows

- **Needs you.** Sessions whose `status` is `waiting` (a permission dialog or
  question), longest wait first, with `waitingFor` alongside. The menu bar gains
  a `⚑N` prefix, and a notification fires once a wait passes a minute. Clicking
  the notification brings Conductor forward.
- **Working.** How long each busy turn has run. Context size appears only from
  200k (orange) and 500k (red): auto-compact fires near the full window, so a
  session can sit at several hundred k for hours. `⚠ silent` flags a busy
  session whose transcript and subagent transcripts have not been written for
  10 minutes.
- **Cache.** Idle and waiting rows show the last request's cache hit and how
  long until its prompt cache lapses (`97% 42m`), or `cold`. The TTL (1h or 5m)
  comes from the request's cache write. Busy rows omit it; they refresh their
  own cache every turn.
- **Kept warm** rows are pinned sessions (`↻`); other idle sessions fold into a
  submenu.

## The spinner

The spinner is a layer-backed `CAShapeLayer` with a Core Animation rotation, not
an animated title. Re-setting an `NSStatusItem` title measured **~13 ms a frame**
because it forces the entire menu bar to re-measure — 2.93% CPU at just 2 fps,
6.62% at 8 fps. Handing a layer to the compositor instead costs **0.37%** at
60 fps, indistinguishable from idle.

The Claude Code theme's `✢ ✳ ✶ ✻ ✽` spinner uses the same model: the frames
are rendered to images once and swapped by a discrete `CAKeyframeAnimation`
on `contents`, so nothing wakes per frame either.

## Themes

Each theme is a `MenuStyle` that turns the same `MenuContext` (usage, pace,
sessions, pins, last error) into menu items and a menu bar title. Classic is
the original code, moved without changes.

- **Nothing drawn dimmed.** AppKit draws any item without an action as
  disabled, which is why Classic's usage lines look washed out. The new themes
  draw informational lines as item views (`GridPanelView`), which are drawn at
  full strength and do not highlight on hover. Session rows stay native items,
  so hover, keyboard navigation and submenus behave as before.
- **A character grid.** Panels compose into a `Grid` of cells and paint it the
  way a terminal does: box-drawing (`─ ━ │ ╭ ╮ ╰ ╯`) and block (`█ ▏…▉ ░`)
  characters are drawn as geometry, and same-coloured runs are merged into one
  pixel-aligned shape. Typed block characters leave seams on fractional pixel
  boundaries; drawn ones meet edge to edge.
- **Columns line up.** `◐ ↻ ⚠ ⎿` are not in SF Mono, and their fallback glyphs
  are 0.2–3.7pt off the 7.42pt cell, which nudged every later column of a row.
  `gridAligned` kerns each glyph back onto whole cells. Grid views start their
  first cell at `menuTextInset` (16pt, AppKit's title inset measured on macOS
  27), so the htop header sits exactly over the native rows' columns.
- **No state column.** A checked item makes AppKit add a state column, which
  shifts native titles right but not the views aligned to them, and
  `showsStateColumn = false` does not prevent it. The new themes never check an
  item; toggles say their state in the title (`login [on]`, `[x]`, `· on`).
- **Spend past the cap.** The API reports extra usage as 100% once it reaches
  its limit; the themes compute the share from the amounts (`113%`).

Screenshots come from the real menu: `--demo --snapshot` pops the `NSMenu` up
away from the cursor and captures that one window with `screencapture -l`, so
nothing else on screen is in the image. The status item is drawn offscreen by
`--render-bar`, because a full menu bar hides new status items behind the
notch.

## Keep Cache Warm

A pinned session gets a ping when 10 minutes are left on a 1h cache (2 minutes
on a 5m one). The ping replays the session's cached prefix, which resets the TTL,
so the next real turn reads its context at cache-read prices instead of
rewriting all of it. On a 1h cache, rewriting costs 2× the input price and a
read costs 0.1×, so one avoided cold turn pays for about 20 pings, roughly 17
hours of pinning.

The ping is `claude -p --resume <id> --fork-session --no-session-persistence`,
launched with the live process's own executable, argv and environment (read
with `KERN_PROCARGS2`). Claude Code records the system prompt on the first
request and resume re-sends that record, so with the same model, thinking,
effort, tools and setting sources the prefix is byte-identical. Measured: 63.7k
of a 64k context read back from cache, and 173k of 170k. Only I/O, identity
and permission flags are dropped. Default permissions deny any tool call,
hooks are off, and `--max-turns 1` caps it. Nothing is written to the
session's transcript.

Guards:
- **Cold sessions are left alone.** Re-warming one costs the full rewrite the
  next real turn would pay anyway.
- **A ping that misses gets unpinned.** If it reads less than 90% of the
  session's last context from cache, it warmed a different prefix, and repeating
  it would pay write prices every time.
- **Pins expire** after 8 hours or when the session ends.
- **Pings pause** while the 5-hour window is at 90% or more.
- Every ping is logged to `~/.config/claude-usage-bar/keepwarm.log`, with its
  token counts and list-price cost. Pins are stored in `pins.json` next to it.

```bash
ClaudeUsage --ping <pid> --dry-run   # the exact command a ping would run
ClaudeUsage --ping <pid>             # one real ping; exit 2 if it missed the cache
```

## Debugging

Without Screen Recording permission, status items and their menus do not
appear in `screencapture` output, so the binary has a headless mode that prints
exactly what the menu would show (with permission, see `--snapshot` above):

```bash
ClaudeUsage --dump                 # what the menu bar shows
ClaudeUsage --dump --cache-only    # exercise the offline fallback path
ClaudeUsage --agents               # session rows as the dropdown shows them
./test.sh                          # unit-test the reader, session model and pace forecast
```
