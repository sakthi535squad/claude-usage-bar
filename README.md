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

When anything is working, the menu bar gains a suffix: `· 2 busy` for top-level
sessions, `· 2 busy (+3)` when subagents are also in flight. When nothing is
running it disappears, and a notification fires on that busy -> idle edge.

Counts come from two places. Top-level sessions are registered by Claude Code at
`~/.claude/sessions/<pid>.json` with a `status` of `busy`/`idle`/`waiting`; each
entry is confirmed with `kill(pid, 0)` since the file outlives a crash.
Subagents run in-process and have no pid, so they are counted from the parent's
transcript: an `Agent` tool_use is pending until a `tool_result` quotes its id.
All of it is local file reads — no API requests, so it costs nothing against the
rate limit and rides the existing 60s display tick.

```bash
ClaudeUsage --agents   # list sessions, statuses and subagent counts
./test.sh              # unit-test the transcript parser against fixtures
```

## Todo - future

1. ~~active running agent count~~ — done
2. a color scheme to show nearing 5 hr session limit + reaching near limits (customisable)

Where the data lives and how each would work: [TODO.md](TODO.md).
