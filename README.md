# claude-usage-bar

A macOS menu bar app showing how much of your Claude Code rate limits you've used.

Menu bar shows the **binding** constraint — whichever window is closest to its limit:

```
7d 79%
```

The whole readout sits on one dark rounded box, so the text colours read the
same over any wallpaper and in either theme, without changing the colours
themselves: white under 70%, `systemOrange` at 70%+, `systemRed` at 90%+
(9.6:1 and 5.9:1 against the box). Each window is coloured by its own number.

A `~` prefix means the number is
stale (read from cache, see below). Clicking opens a breakdown:

```
5-hour       ████······  38%   resets 1h 12m
7-day        ████████··  80%   resets 3d 14h
Extra usage  ██████████ 100%   $223 of 200
Updated just now · live
```

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
ClaudeUsage --render-bar           # preview the pills over 4 backdrops (no API call)
```

(`ClaudeUsage` = `/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage`.)

macOS status items and their menus do not appear in `screencapture` output, so
`--dump` is the way to check what the app is actually showing.
