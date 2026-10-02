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

exit(failed ? 1 : 0)
