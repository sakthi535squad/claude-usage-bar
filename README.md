# claude-usage-bar

A macOS menu bar app showing how much of your Claude Code rate limits you've used.

Menu bar shows the **binding** constraint — whichever window is closest to its limit:

```
7d 79%
```

Plain text, no background. Neutral under 70%, `systemOrange` at 70%+,
`systemRed` at 90%+ — the stock macOS system colours, which follow Light and
Dark Mode on their own. Each window is coloured by its own number, so a healthy
5-hour window stays neutral while the 7-day one turns orange.

## Data source

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
`Retry-After` on 429; that header is honoured rather than guessed at, and the app
falls back to the cache (marked `~`) meanwhile.

## Build / install

```bash
./build.sh          # compiles and installs to /Applications/ClaudeUsage.app
open -a ClaudeUsage
```

Requires only the Xcode Command Line Tools (`swiftc`). No dependencies, no Xcode
project. Enable **Open at Login** from the menu to have it start with the Mac.

## Debugging

The macOS status bar is invisible to `screencapture`, so the binary has a
headless mode that prints exactly what the menu would show:

```bash
ClaudeUsage --dump                 # print what the menu bar shows
ClaudeUsage --dump --cache-only    # exercise the offline fallback path
```

(`ClaudeUsage` = `/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage`.)

macOS status items and their menus do not appear in `screencapture` output, so
`--dump` is the way to check what the app is actually showing.

## Agents

A spinner appears in the menu bar while anything is running, and each row in the
dropdown is tinted by status: green filled dot for busy, orange half dot for
waiting, hollow dot dimmed for idle.

The spinner is a layer-backed `CAShapeLayer` with a Core Animation rotation, not
an animated title. Re-setting an `NSStatusItem` title measured **~13 ms a frame**
because it forces the entire menu bar to re-measure — 2.93% CPU at just 2 fps,
6.62% at 8 fps. Handing a layer to the compositor instead costs **0.37%** at
60 fps, indistinguishable from idle.

When anything is working, the menu bar gains a suffix: `· 2 busy` for top-level
sessions, `· 2 busy (+3)` when subagents are also in flight. When nothing is
running it disappears.

Each session is labelled with its Conductor chat title ("Claude usage tracker
Mac") rather than Claude Code's derived name ("worcester-a6"), joined on
`claude_session_id` against Conductor's read-only sqlite database. Sessions not
started from Conductor fall back to their git branch, then to the derived name.

Counts come from two places. Top-level sessions are registered by Claude Code at
`~/.claude/sessions/<pid>.json` with a `status` of `busy`/`idle`/`waiting`; each
entry is confirmed with `kill(pid, 0)` since the file outlives a crash.
Subagents run in-process and have no pid, so they are counted from the parent's
transcript: an `Agent` tool_use is pending until it finishes. A foreground agent
finishes when a `tool_result` quotes its id. A background agent gets that
`tool_result` immediately (marked `toolUseResult.isAsync`), so for those the
finish is the later `<task-notification>` carrying `<tool-use-id>`.

## Control panel

The dropdown is arranged around what needs you, not around every session:

```
5-hour       █·········  13%   resets 4h 2m
             ↳ full by 3:40 PM, resets 4:10 PM
NEEDS YOU
◐ knowledge-graph-le…   waiting 3h 32m          dialog open
WORKING
● Repo UI Improvement   busy 32m        488k    ⚠ silent 14m
2 idle ▸
```

- **Needs you.** Sessions whose registry `status` is `waiting` (a permission
  dialog or question), longest wait first, with `waitingFor` alongside. The menu
  bar gains a `⚑N` prefix, and a notification fires once a wait passes a minute
  — an agent blocked on a dialog makes no progress, and nothing else says so
  when its window is not in front. Clicking the
  notification brings Conductor forward.
- **Pace.** Live readings of the 5-hour window are kept for an hour and fitted
  with a line: `full by <time>` when that line crosses 100% before the reset,
  otherwise `on pace — ~N% at reset`. It needs 15 minutes of readings in the
  current window first, since they arrive every 5 minutes in whole-percent steps.
  This is your real plan limit, so it includes claude.ai and other machines.
- **Working.** How long each busy turn has run. Context size appears only from
  200k (orange) and 500k (red): auto-compact fires near the full window, so a
  session can sit at several hundred k for hours. `⚠ silent` flags a busy
  session whose transcript and subagent transcripts have not been written for
  10 minutes — usually a hung tool or MCP call, sometimes a long command.
- **Cache.** Idle and waiting rows show the last request's cache hit and how
  long until its prompt cache lapses (`97% 42m`), or `cold`. The TTL (1h or 5m)
  comes from the request's cache write. Busy rows omit it; they refresh their
  own cache every turn.
- **Kept warm** sessions are pinned ones (`↻`); other idle sessions fold into a
  submenu.

Clicking any session row opens its submenu: **Keep Cache Warm** and, for
Conductor sessions, **Open in Conductor**.

## Keep warm

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

Transcripts are read incrementally — each pass reads only bytes appended since
the last — on a background queue. The first pass over a 40 MB transcript takes
about a second; after that it is a few KB a minute. All of it is local file
reads, no API requests, so it costs nothing against the rate limit.

```bash
ClaudeUsage --agents   # session rows as the dropdown shows them
./test.sh              # unit-test the reader, session model and pace forecast
```

## Todo - future

1. ~~active running agent count~~ — done
2. a color scheme to show nearing 5 hr session limit + reaching near limits (customisable)

Where the data lives and how each would work: [TODO.md](TODO.md).
