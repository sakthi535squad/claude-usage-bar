# Claude Usage Bar

A macOS menu bar app (Swift, AppKit, one binary, no dependencies, no Xcode
project) that shows Claude Code rate limits, running sessions and subagents,
prompt cache state, and keeps chosen sessions' prompt caches warm. User-facing
docs: `README.md`. Internals and measurements: `docs/HOW-IT-WORKS.md`.

## Build and test

```bash
./test.sh     # unit tests; fixtures in /tmp, never touches ~/.claude
./build.sh    # builds AND replaces /Applications/ClaudeUsage.app
```

- `build.sh` installs over the user's running copy. To only check that it
  compiles: `swiftc -target "$(uname -m)-apple-macos13.0" -framework Cocoa -lsqlite3 -o /tmp/cub Sources/*.swift`.
- Always pass `-target …-macos13.0`. Without it swiftc targets the SDK version
  and the app refuses to launch on an older macOS. Keep it in step with
  `LSMinimumSystemVersion` in `build.sh`.
- `test.sh` compiles a fixed list of sources (no `main.swift`, no Cocoa). A new
  file with testable logic must be added to that list; keep AppKit out of it.
- The status item is invisible to `screencapture`. Check output headlessly:
  `ClaudeUsage --dump`, `--agents`, `--ping <pid> --dry-run`.
- `build.sh` does not restart a running copy, which keeps the old binary.
  Quit it and `open -a /Applications/ClaudeUsage.app`, then confirm with
  `ps -o lstart= -p $(pgrep -f ClaudeUsage.app)`.

## Git workflow

- `main` is usually checked out in `~/Developer/claude-usage-bar`, and work
  happens in other worktrees, so `git switch main` fails there. Branch from
  `origin/main`, commit, then publish with `git push origin HEAD:main` (or open
  a PR), and `git pull --ff-only` in the `main` checkout afterwards.
- Check `git log origin/main..HEAD` before pushing. A worktree's branch may
  already have been squash-merged, so start new work on a fresh branch.

## Chat apps

Session labels and **Open in …** come from other apps' sqlite databases,
opened read-only (`Sources/Titles.swift`). Their schemas are not contracts:
any failure must degrade to no titles.

- **Conductor:** `~/Library/Application Support/com.conductor.app/conductor.db`,
  `sessions.claude_session_id`.
- **T3 Code:** `~/.t3/userdata/state.sqlite`, `projection_threads.title` joined
  through `provider_session_runtime.resume_cursor_json` → `$.resume`. T3 runs
  `claude` through the Agent SDK (`entrypoint: "sdk-ts"`), so its sessions are
  in `~/.claude/sessions` like any other. Its argv carries `--mcp-config` with a
  bearer token that changes when T3 restarts, so a keep-warm pin captured before
  a restart is likely to miss and unpin itself (issue #26).

## Layout

| File | What it owns |
|---|---|
| `Sources/main.swift` | `AppDelegate`: usage polling, menu building, timers, keep-warm scheduling, CLI modes |
| `Sources/Agents.swift` | `AgentSession`, `SessionScanner`: `~/.claude/sessions/<pid>.json` plus transcript state |
| `Sources/Transcripts.swift` | Incremental JSONL transcript reader (subagents, context, cache hit/TTL, model) |
| `Sources/KeepWarm.swift` | `Pin`/`PinStore` (`pins.json`), ping arguments, running and parsing pings, `keepwarm.log` |
| `Sources/Spend.swift` | List-price table, per-ping cost, `SpendLedger` (`keepwarm-spend.json`) |
| `Sources/Pace.swift` | 5-hour pace forecast |
| `Sources/Titles.swift` | Conductor and T3 Code chat titles (read-only sqlite) and git branch labels |
| `Sources/Awake.swift` | `caffeinate` child process and `pmset disablesleep` read/toggle |
| `Sources/Spinner.swift` | Core Animation spinner |

State lives in `~/.config/claude-usage-bar/` (`pins.json`, `keepwarm.log`,
`keepwarm-spend.json`) and `UserDefaults` (`keepAllWindow`, `keepAllSkip`).

## Performance limits

These are measured budgets. Don't regress them without measuring again.

- **Idle CPU about 0.** Usage polls every 300s and the session scan every 60s,
  with timer tolerance (30s/15s) so macOS can batch wakeups. Don't add
  sub-minute timers.
- **Never animate the status item title.** Re-setting it costs about 13 ms a
  frame (2.9% CPU at 2 fps). The spinner is a `CAShapeLayer` at 0.37% CPU at
  60 fps. `renderTitle()` exists so the title is not rebuilt with the menu.
- **Transcripts are read incrementally** from a stored byte offset on
  `scanQueue`, never on main. Lines are only JSON-parsed if they contain a
  cheap byte marker (`"usage"`, `"name":"Agent"`, …). A first pass over a 40 MB
  transcript takes about 1s; after that it is a few KB a minute. Never read a
  whole transcript per tick.
- **One network call:** `GET api.anthropic.com/api/oauth/usage`. It
  rate-limits at about 1 request a minute. Opening the menu must never fetch.
  On 429, honour `Retry-After` (60s floor) and fall back to the cached value.
- **Don't swap `item.menu` while the menu is open.** It closes under the user's
  cursor. `rebuildMenu()` defers to `menuDidClose`.
- **Pings run off main** (`DispatchQueue.global`), one per session at a time
  (`pinging`), with a 120s timeout.

## Keep-warm invariants

- A ping is `claude -p --resume <id> --fork-session --no-session-persistence`
  with the live process's own argv/env, so the cached prefix is byte-identical.
  Any flag that changes the prefix (model, thinking, effort, tools, setting
  sources) must be kept. Only I/O, identity and permission flags are dropped
  (`droppedWithValue`/`droppedBare`).
- Pings never reach the transcript, so they never count as activity.
  "Activity" is the last assistant request (`lastRequestAt`).
- A ping that reads less than 90% of the last context from cache unpins its
  session. Cold sessions are never re-warmed. Pings pause at 90% of the 5-hour
  window.
- Manual pins expire after `pinMaxAge` (24h) without activity. Auto pins
  (Keep All Sessions Warm) expire on the chosen window and start at the
  session's last turn, so they are not re-pinned until a new turn.
- Never use `total_cost_usd` from ping output for cost. On a resumed session it
  includes everything the session had already spent. Cost is computed from
  token counts in `Spend.swift`. Update `prices` when models or prices change.

## Conventions

- Match the surrounding style: comments explain *why*, sparingly, as `///` on
  declarations. No third-party packages.
- Commits use conventional prefixes (`feat:`, `fix:`, `test:`, `revert:`).
  User-visible changes go in `CHANGELOG.md` and the README feature list.
