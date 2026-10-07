import Foundation
let fixture = "/tmp/agent-fixture.jsonl"
var failed = false
func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
    if got != want { failed = true }
    print("\(got == want ? "PASS" : "FAIL")  \(label): got \(got), want \(want)")
}
func write(_ lines: [String]) {
    try? (lines.map { $0 + "\n" }.joined()).write(toFile: fixture, atomically: true, encoding: .utf8)
}
func append(_ s: String) {
    let h = FileHandle(forWritingAtPath: fixture)!
    h.seekToEndOfFile()
    h.write(s.data(using: .utf8)!)
    h.closeFile()
}
func appendBytes(_ d: Data) {
    let h = FileHandle(forWritingAtPath: fixture)!
    h.seekToEndOfFile()
    h.write(d)
    h.closeFile()
}
func pending(_ lines: [String]) -> Int {
    write(lines)
    return TranscriptReader().update(path: fixture)?.pendingAgents.count ?? -1
}

let launch = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{}}]}}"#
let launch2 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_B","name":"Agent","input":{}}]}}"#
let resultA = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":"done"}]}}"#
let asyncAckA = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":"Async agent launched"}]},"toolUseResult":{"isAsync":true,"status":"async_launched"}}"#
let queuedDoneA = #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>x</task-id>\n<tool-use-id>toolu_A</tool-use-id>\n</task-notification>"}"#
let userDoneA = #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<tool-use-id>toolu_A</tool-use-id>\n</task-notification>"}}"#
let otherTool = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_C","name":"Bash","input":{}}]}}"#

// Subagents
check("empty transcript", pending([]), 0)
check("one launched, no result", pending([launch]), 1)
check("launched then finished", pending([launch, resultA]), 0)
check("two launched, one finished", pending([launch, launch2, resultA]), 1)
check("ignores non-Agent tools", pending([otherTool, launch, resultA]), 0)
check("background launch ack is not completion", pending([launch, asyncAckA]), 1)
check("background done via queued notification", pending([launch, asyncAckA, queuedDoneA]), 0)
check("background done via user notification", pending([launch, asyncAckA, userDoneA]), 0)
check("missing file", TranscriptReader().update(path: "/tmp/does-not-exist.jsonl") == nil, true)

// Context size
func usageLine(id: String, read: Int, write: Int, input: Int) -> String {
    #"{"type":"assistant","message":{"id":"\#(id)","role":"assistant","content":[{"type":"text","text":"—"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write)}}}"#
}
let synthetic = #"{"type":"assistant","message":{"id":"msg_syn","role":"assistant","content":[],"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
write([usageLine(id: "msg_1", read: 0, write: 50_000, input: 10),
       usageLine(id: "msg_2", read: 90_000, write: 10_000, input: 5),
       synthetic])
check("context = last real request's input", TranscriptReader().update(path: fixture)?.contextTokens, 100_005)

// Incremental reading
let reader = TranscriptReader()
write([launch])
reader.update(path: fixture)
append(String(resultA.prefix(40)))
check("partial line not consumed yet", reader.update(path: fixture)?.pendingAgents.count, 1)
append(String(resultA.dropFirst(40)) + "\n")
check("completed line consumed on next pass", reader.update(path: fixture)?.pendingAgents.count, 0)

// A multi-byte character split across two writes must not poison either pass.
let r2 = TranscriptReader()
write([])
let line = Data((usageLine(id: "msg_u", read: 1, write: 1, input: 1) + "\n").utf8)
let dash = line.firstIndex(of: 0xE2)!   // first byte of "—"
appendBytes(line[..<(dash + 1)])
r2.update(path: fixture)
appendBytes(line[(dash + 1)...])
check("multi-byte split across passes", r2.update(path: fixture)?.contextTokens, 3)

write([launch])
let r3 = TranscriptReader()
r3.update(path: fixture)
write([])
check("rewritten (shrunk) file resets state", r3.update(path: fixture)?.pendingAgents.count, 0)

// Sessions
let now = Date()
func session(_ status: String, since: TimeInterval, lastWrite: TimeInterval? = nil) -> AgentSession {
    var a = AgentSession(pid: 1, name: status, cwd: "", status: status, sessionId: "s",
                         statusSince: now.addingTimeInterval(-since), waitingFor: nil)
    a.lastWriteAt = lastWrite.map { now.addingTimeInterval(-$0) }
    return a
}
let snap = AgentSnapshot(sessions: [session("waiting", since: 60), session("idle", since: 9),
                                    session("waiting", since: 3600), session("busy", since: 5)])
check("longest wait listed first", snap.waiting.map { Int(now.timeIntervalSince($0.statusSince!)) }, [3600, 60])
check("idle excludes busy and waiting", snap.idle.count, 1)
check("badge counts waiting", waitingBadge(snap), "\u{2691}2")
check("no badge when nothing waits", waitingBadge(AgentSnapshot(sessions: [session("busy", since: 1)])), nil)
check("busy and quiet past threshold is silent",
      session("busy", since: 900, lastWrite: 700).silence(at: now).map(Int.init), 700)
check("busy and writing is not silent", session("busy", since: 900, lastWrite: 30).silence(at: now) == nil, true)
check("idle is never silent", session("idle", since: 900, lastWrite: 900).silence(at: now) == nil, true)

// Formatting
check("duration <1m", formatDuration(59), "<1m")
check("duration m", formatDuration(32 * 60), "32m")
check("duration h m", formatDuration(3 * 3600 + 24 * 60), "3h 24m")
check("duration d h", formatDuration(2 * 86400 + 4 * 3600), "2d 4h")
check("tokens k", formatTokens(313_300), "313k")
check("tokens M", formatTokens(1_250_000), "1.2M")
check("tokens small", formatTokens(512), "512")

// Pace
let reset = now.addingTimeInterval(2 * 3600)
func tracker(_ points: [(minsAgo: Double, pct: Double)], resetsAt: Date = reset) -> PaceTracker {
    let t = PaceTracker()
    for p in points { t.record(pct: p.pct, resetsAt: resetsAt, at: now.addingTimeInterval(-p.minsAgo * 60)) }
    return t
}
check("too little history", tracker([(10, 20), (5, 22), (0, 24)]).forecast(now: now), .measuring)
check("too few readings", tracker([(20, 20), (0, 24)]).forecast(now: now), .measuring)
// 1 point per minute from 40% now: 100% in 60 minutes, before the 2h reset.
check("full before reset", tracker([(30, 10), (15, 25), (0, 40)]).forecast(now: now),
      .full(at: now.addingTimeInterval(60 * 60)))
// 0.1 point per minute: +12 over the remaining 120 minutes.
check("on pace", tracker([(30, 37), (15, 38.5), (0, 40)]).forecast(now: now), .onPace(atReset: 52))
check("flat usage stays put", tracker([(30, 40), (15, 40), (0, 40)]).forecast(now: now), .onPace(atReset: 40))
let rolled = tracker([(50, 80), (40, 90), (30, 95)])
rolled.record(pct: 2, resetsAt: now.addingTimeInterval(5 * 3600), at: now)
check("new window drops old readings", rolled.forecast(now: now), .measuring)
let jitter = tracker([(30, 10), (15, 25)])
jitter.record(pct: 40, resetsAt: reset.addingTimeInterval(1), at: now)
check("reset jitter is the same window", jitter.forecast(now: now), .full(at: now.addingTimeInterval(60 * 60)))

// Cache state from the transcript
let ts = "2026-10-05T23:20:38.013Z"
let warmLine = #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"m1","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_read_input_tokens":63277,"cache_creation_input_tokens":443,"cache_creation":{"ephemeral_1h_input_tokens":443,"ephemeral_5m_input_tokens":0}}}}"#
let readOnlyLine = #"{"type":"assistant","timestamp":"2026-10-05T23:30:00.000Z","message":{"id":"m2","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_read_input_tokens":63720,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}"#
write([warmLine])
let cs = TranscriptReader().update(path: fixture)
check("1h TTL from cache write", cs?.cacheTTL, 3600)
check("cache hit share", cs.flatMap { $0.cacheHit.map { Int(($0 * 1000).rounded()) } }, 993)
check("request time from timestamp", cs?.lastRequestAt.map { Int($0.timeIntervalSince1970) }, 1791242438)
write([warmLine, readOnlyLine])
check("read-only request keeps prior TTL", TranscriptReader().update(path: fixture)?.cacheTTL, 3600)
check("5m TTL", cacheTTL(from: ["cache_creation": ["ephemeral_5m_input_tokens": 10, "ephemeral_1h_input_tokens": 0]]), 300)

// Keep-warm scheduling
func idle(requestAgo: TimeInterval, ttl: TimeInterval = 3600, status: String = "idle") -> AgentSession {
    var a = session(status, since: requestAgo)
    a.lastRequestAt = now.addingTimeInterval(-requestAgo)
    a.cacheTTL = ttl
    a.cacheHit = 0.97
    return a
}
let pin = Pin(sessionId: "s", pinnedAt: now.addingTimeInterval(-7200))
check("fresh cache is not due", pingDue(idle(requestAgo: 20 * 60), pin: pin, now: now), false)
check("inside the lead is due", pingDue(idle(requestAgo: 52 * 60), pin: pin, now: now), true)
check("cold is never pinged", pingDue(idle(requestAgo: 61 * 60), pin: pin, now: now), false)
check("busy is never pinged", pingDue(idle(requestAgo: 52 * 60, status: "busy"), pin: pin, now: now), false)
check("waiting can be pinged", pingDue(idle(requestAgo: 52 * 60, status: "waiting"), pin: pin, now: now), true)
check("5m TTL due at 3.5m", pingDue(idle(requestAgo: 210, ttl: 300), pin: pin, now: now), true)
var pinged = pin
pinged.lastPingAt = now.addingTimeInterval(-5 * 60)
check("recent ping resets the clock", pingDue(idle(requestAgo: 52 * 60), pin: pinged, now: now), false)
check("ping extends remaining TTL",
      cacheState(idle(requestAgo: 52 * 60), pin: pinged).map { Int($0.remaining(at: now)) }, 55 * 60)

// Pin store
let pinPath = "/tmp/agent-fixture-pins.json"
try? FileManager.default.removeItem(atPath: pinPath)
let store = PinStore(path: pinPath)
store.toggle("a", now: now)
store.toggle("b", now: now.addingTimeInterval(-(pinMaxAge + 3600)))
store.recordPing("a", at: now)
check("pins persist", PinStore(path: pinPath).pins.keys.sorted(), ["a", "b"])
check("ping time persists", PinStore(path: pinPath).pins["a"]?.lastPingAt.map { Int($0.timeIntervalSince1970) },
      Int(now.timeIntervalSince1970))
store.prune(now: now)
check("old pin expires", store.pins.keys.sorted(), ["a"])
store.prune(now: now)
check("ended session stays pinned", store.pins.keys.sorted(), ["a"])
store.remove("a")
store.toggle("c", now: now)
store.toggle("c", now: now)
check("toggle twice unpins", PinStore(path: pinPath).pins.isEmpty, true)

let old = now.addingTimeInterval(-(pinMaxAge + 3600))
store.toggle("busy", now: old)
store.toggle("stale", now: old)
store.toggle("quiet", now: old)
store.recordActivity("busy", at: now.addingTimeInterval(-600))
store.recordActivity("busy", at: now.addingTimeInterval(-7200))
store.recordActivity("stale", at: old.addingTimeInterval(1800))
store.recordPing("quiet", at: now)
check("activity persists and only moves forward",
      PinStore(path: pinPath).pins["busy"]?.lastActiveAt.map { Int($0.timeIntervalSince1970) },
      Int(now.addingTimeInterval(-600).timeIntervalSince1970))
check("a ping is not activity", store.pins["quiet"]?.lastActiveAt, nil)
store.prune(now: now)
check("recent activity keeps an old pin", store.isPinned("busy"), true)
check("activity older than pinMaxAge expires", store.isPinned("stale"), false)
check("no activity falls back to pinnedAt", store.isPinned("quiet"), false)
store.remove("busy")

// Keep All Sessions Warm
func live(_ id: String, requestAgo: TimeInterval?, since: TimeInterval = 60, pid: pid_t = 1) -> AgentSession {
    var a = AgentSession(pid: pid, name: id, cwd: "", status: "idle", sessionId: id,
                         statusSince: now.addingTimeInterval(-since), waitingFor: nil)
    a.lastRequestAt = requestAgo.map { now.addingTimeInterval(-$0) }
    return a
}
let autoPath = "/tmp/agent-fixture-pins-auto.json"
try? FileManager.default.removeItem(atPath: autoPath)
let auto = PinStore(path: autoPath)
let day: TimeInterval = 24 * 3600
auto.toggle("manual", now: now.addingTimeInterval(-3600))
auto.autoPin([live("new", requestAgo: nil), live("recent", requestAgo: 20 * 3600),
              live("old", requestAgo: 30 * 3600), live("gone", requestAgo: 60, pid: 0),
              live("skipped", requestAgo: 60), live("manual", requestAgo: 60)],
             window: day, skip: ["skipped"], now: now)
check("auto-pins sessions active inside the window", auto.pins.keys.sorted(), ["manual", "new", "recent"])
check("manual pin stays manual", auto.pins["manual"]?.auto, nil)
check("auto flag persists", PinStore(path: autoPath).pins["new"]?.auto, true)
auto.prune(now: now.addingTimeInterval(5 * 3600), autoWindow: day)
check("auto pin expires a window after its last turn", auto.pins.keys.sorted(), ["manual", "new"])
auto.autoPin([live("recent", requestAgo: 25 * 3600)], window: day, skip: [], now: now)
check("expired session is not re-pinned without a new turn", auto.isPinned("recent"), false)
auto.prune(now: now.addingTimeInterval(9 * 3600), autoWindow: 8 * 3600)
check("auto pins follow the chosen window", auto.pins.keys.sorted(), ["manual"])
auto.autoPin([live("a1", requestAgo: 60)], window: day, skip: [], now: now)
auto.removeAuto()
check("turning off drops only auto pins", auto.pins.keys.sorted(), ["manual"])

let legacyPath = "/tmp/agent-fixture-pins-legacy.json"
try? Data(#"[{"sessionId":"l","pinnedAt":"2026-01-01T00:00:00Z"}]"#.utf8).write(to: URL(fileURLWithPath: legacyPath))
check("pins.json without lastActiveAt still decodes", PinStore(path: legacyPath).pins["l"]?.lastActiveAt == nil
      && PinStore(path: legacyPath).pins["l"] != nil, true)

// Ping command
let conductorArgs = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                     "--thinking", "adaptive", "--effort", "medium", "--max-turns", "1000",
                     "--model", "claude-opus-5-5[1m]", "--permission-prompt-tool", "stdio",
                     "--resume=old-id", "--session-mirror", "--disallowedTools", "AskUserQuestion",
                     "--setting-sources=user,project,local", "--permission-mode", "bypassPermissions",
                     "--session-id", "x"]
let built = pingArguments(from: conductorArgs, sessionId: "sid")
check("keeps prefix-shaping flags", Array(built.prefix(9)),
      ["--thinking", "adaptive", "--effort", "medium", "--model", "claude-opus-5-5[1m]",
       "--disallowedTools", "AskUserQuestion", "--setting-sources=user,project,local"])
check("drops I/O, identity and permission flags",
      built.contains { ["stream-json", "--verbose", "stdio", "--resume=old-id", "bypassPermissions", "x", "1000", "--session-mirror"].contains($0) }, false)
check("resumes the registry session, forked and unpersisted",
      built.contains("sid") && built.contains("--fork-session") && built.contains("--no-session-persistence"), true)
check("pings skip the skill listing", built.contains("--disable-slash-commands"), true)

let okOut = Data(#"{"type":"result","is_error":false,"result":"ok","total_cost_usd":0.7350,"usage":{"input_tokens":2,"cache_read_input_tokens":63720,"cache_creation_input_tokens":1825}}"#.utf8)
if case .success(let r) = parsePingOutput(okOut) {
    check("ping output parsed", [r.cacheRead, r.cacheWrite, r.input], [63720, 1825, 2])
} else { check("ping output parsed", false, true) }
let fullOut = Data(#"{"is_error":false,"usage":{"input_tokens":2,"output_tokens":5,"cache_read_input_tokens":96160,"cache_creation_input_tokens":3000,"cache_creation":{"ephemeral_1h_input_tokens":3000,"ephemeral_5m_input_tokens":0}}}"#.utf8)
if case .success(let r) = parsePingOutput(fullOut) {
    check("ping output and 1h write parsed", [r.output, r.cacheWrite1h], [5, 3000])
    // Opus 5.5: 96160 × $0.20 + 3000 × $8 (1h write) + 2 × $4 + 5 × $20, per MTok.
    check("ping cost at list price", pingCost(r, model: "claude-opus-5-5").map { Int(($0 * 1_000_000).rounded()) },
          96160 * 20 / 100 + 3000 * 8 + 2 * 4 + 5 * 20)
    check("unknown model has no cost", pingCost(r, model: "gpt-x") == nil, true)
    check("longest model prefix wins", price(for: "claude-opus-5-5")?.input, 4)
    check("older opus 5 price", price(for: "claude-opus-5")?.input, 5)

    let spendPath = "/tmp/agent-fixture-spend.json"
    try? FileManager.default.removeItem(atPath: spendPath)
    let ledger = SpendLedger(path: spendPath)
    ledger.record(r, model: "claude-opus-5-5", at: now)
    ledger.record(r, model: nil, at: now)
    ledger.record(r, model: "claude-opus-5-5", at: now.addingTimeInterval(-3 * 86400))
    ledger.record(r, model: "claude-opus-5-5", at: now.addingTimeInterval(-40 * 86400))
    let reread = SpendLedger(path: spendPath)
    check("today's pings and tokens", [reread.total(days: 1, now: now).pings, reread.total(days: 1, now: now).cacheRead],
          [2, 2 * 96160])
    check("unpriced pings counted apart", reread.total(days: 1, now: now).unpriced, 1)
    check("7-day total", reread.total(days: 7, now: now).pings, 3)
    check("days past keepDays are dropped", reread.days.count, 2)
} else { check("ping output and 1h write parsed", false, true) }
let errOut = Data(#"{"type":"result","is_error":true,"result":"No conversation found"}"#.utf8)
if case .failure(.failed(let msg)) = parsePingOutput(errOut) {
    check("ping error surfaced", msg.contains("No conversation found"), true)
} else { check("ping error surfaced", false, true) }

// An exited pinned session stays visible with its cache state
let exitedPin = Pin(sessionId: "no-such-session", pinnedAt: now, lastPingAt: nil, cwd: "/tmp/nowhere",
                    label: "Old chat", exe: "/bin/true", args: [])
let ex = SessionScanner().snapshot(pinned: [exitedPin]).sessions.first { $0.sessionId == "no-such-session" }
check("exited pin kept in snapshot", ex?.status, "exited")
check("exited pin keeps its label", ex?.label, "Old chat")
check("exited pin uses captured launch",
      pingLaunch(ex!, pin: exitedPin, live: []).map { $0.exe }, "/bin/true")
check("no captured launch, no ping", pingLaunch(ex!, pin: Pin(sessionId: "x", pinnedAt: now), live: []) == nil, true)

exit(failed ? 1 : 0)
