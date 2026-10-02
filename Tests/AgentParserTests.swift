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

// Usage
func usageLine(id: String, ts: String, read: Int, write: Int, input: Int, ttl1h: Bool = true) -> String {
    let split = ttl1h ? #"{"ephemeral_1h_input_tokens":\#(write),"ephemeral_5m_input_tokens":0}"#
                      : #"{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":\#(write)}"#
    return #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","role":"assistant","content":[{"type":"text","text":"—"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"cache_creation":\#(split)}}}"#
}
let synthetic = #"{"type":"assistant","timestamp":"2026-10-03T10:09:00.000Z","message":{"id":"msg_syn","role":"assistant","content":[],"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#

write([
    usageLine(id: "msg_1", ts: "2026-10-03T10:00:00.000Z", read: 0, write: 50_000, input: 10),
    usageLine(id: "msg_2", ts: "2026-10-03T10:05:00.000Z", read: 90_000, write: 10_000, input: 0),
    usageLine(id: "msg_2", ts: "2026-10-03T10:05:30.000Z", read: 90_000, write: 10_000, input: 0),
    synthetic,
])
let ctx = TranscriptReader().update(path: fixture)?.context
check("context = last request input", ctx?.tokens, 100_000)
check("cache hit of last request", ctx?.cacheHit, 0.9)
check("1h TTL picked up from write split", ctx?.ttl, 3600)
check("earliest timestamp kept for one request id",
      ctx?.requestedAt, ISO8601DateFormatter().date(from: "2026-10-03T10:05:00Z"))

write([usageLine(id: "msg_1", ts: "2026-10-03T10:00:00.000Z", read: 0, write: 500, input: 0, ttl1h: false)])
check("5m TTL picked up", TranscriptReader().update(path: fixture)?.context?.ttl, 300)

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
let line = Data((usageLine(id: "msg_u", ts: "2026-10-03T11:00:00.000Z", read: 1, write: 1, input: 1) + "\n").utf8)
let dash = line.firstIndex(of: 0xE2)!   // first byte of "—"
appendBytes(line[..<(dash + 1)])
r2.update(path: fixture)
appendBytes(line[(dash + 1)...])
check("multi-byte split across passes", r2.update(path: fixture)?.context?.tokens, 3)

write([launch])
let r3 = TranscriptReader()
r3.update(path: fixture)
write([])
check("rewritten (shrunk) file resets state", r3.update(path: fixture)?.pendingAgents.count, 0)

// Formatting
let now = Date()
func stats(age: TimeInterval, hit: Double = 0.97) -> ContextStats {
    ContextStats(tokens: 1, cacheHit: hit, requestedAt: now.addingTimeInterval(-age), ttl: 3600)
}
check("warm, far from expiry", formatCache(stats(age: 60), now: now), "97%")
check("warm, near expiry", formatCache(stats(age: 3600 - 8 * 60 - 30), now: now), "97% · 8m")
check("expired", formatCache(stats(age: 3601), now: now), "cold")
check("tokens k", formatTokens(313_300), "313k")
check("tokens M", formatTokens(1_250_000), "1.2M")
check("tokens small", formatTokens(512), "512")

exit(failed ? 1 : 0)
