# Changelog

## Unreleased

- **Keep All Sessions Warm.** Off, 8, 24 or 48 hours. Every session with a
  real turn in that window stays pinned, new sessions start pinned, and each is
  dropped after that long without a turn. Pings never count as activity.

## v0.4 — 6 Oct 2026

- **Keep Cache Warm.** Pin an idle session from its submenu and it is pinged
  shortly before its prompt cache lapses, so the next real turn reads its
  context at cache-read prices. Measured 63.7k of 64k and 173k of 170k read back
  from cache; a real turn after the pings read 99% from cache.
- Pings that miss the cache unpin themselves; pins expire after 8 hours; pings
  pause at 90% of the 5-hour window. Every ping is logged with its cost.
- `--ping <pid> [--dry-run]` runs or prints a single ping.

## v0.3 — 3 Oct 2026

- **Control panel.** The dropdown groups sessions by what they need from you:
  *Needs you* (blocked on a dialog, with a `⚑N` menu bar badge and a
  notification after a minute), *Working*, and folded idle sessions.
- **5-hour pace forecast.** `full by 3:40 PM` or `on pace — ~N% at reset`,
  fitted to the last hour of live readings.
- **Silent-session flag** for busy sessions that have written nothing for
  10 minutes.
- Per-session context size and prompt cache state; background subagents are
  now counted.

## v0.2 — 24 Sep 2026

- **Running agent counts** in the menu bar (`2 busy (+3)`), separating
  top-level sessions from subagents.
- Sessions labelled with their Conductor chat titles, falling back to git
  branch.
- GPU-composited spinner: 0.37% CPU at 60 fps, against 6.6% for an animated
  menu bar title.

## v0.1 — 20 Sep 2026

- 5-hour and 7-day utilisation in the menu bar, each coloured by its own
  number in stock macOS colours.
- Reads the Claude Code OAuth token from the Keychain on each poll; falls back
  to Claude Code's cached figure when offline, marked `~`.
- Polls every 5 minutes, honours `Retry-After` on 429, and survives sleep.
- `--dump` headless mode for checking what the menu shows.
