# claude-usage-bar

A macOS menu bar app showing how much of your Claude Code rate limits you've used.

Menu bar shows the **binding** constraint — whichever window is closest to its limit:

```
7d 79%
```

Black under 70%, orange at 70%+, red at 90%+. A `~` prefix means the number is
stale (read from cache, see below). Clicking opens a breakdown:

```
5-hour       ████······  36%   resets 1h 12m
7-day        ████████··  79%   resets 3d 15h
Extra usage  ██████████ 100%   223 of 200 USD
updated just now · live
```

## Data source

Polls `https://api.anthropic.com/api/oauth/usage` every 60s — the same endpoint
`/usage` uses inside Claude Code. The OAuth token is read fresh on each poll from
the `Claude Code-credentials` Keychain item, via `/usr/bin/security`, so token
rotations by Claude Code are picked up automatically and no credential is stored
by this app.

If the API call fails (no token, expired token, offline), it falls back to
`cachedUsageUtilization` in `~/.claude.json`, which Claude Code refreshes while
it runs. That value can be well over an hour old, so the bar marks it with `~`
and the menu says `cached`.

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
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --dump
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --dump --cache-only   # exercise the offline path
```
