import Foundation
let fixture = "/tmp/agent-fixture.jsonl"
func check(_ label: String, _ got: Int, _ want: Int) {
    print("\(got == want ? "PASS" : "FAIL")  \(label): got \(got), want \(want)")
}
let launch = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_A","name":"Agent","input":{"run_in_background":true}}]}}"#
let launch2 = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_B","name":"Agent","input":{}}]}}"#
let resultA = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":"done"}]}}"#
let otherTool = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_C","name":"Bash","input":{}}]}}"#

try? "".write(toFile: fixture, atomically: true, encoding: .utf8)
check("empty transcript", countPendingAgents(inTranscriptAt: fixture), 0)

try? launch.write(toFile: fixture, atomically: true, encoding: .utf8)
check("one launched, no result", countPendingAgents(inTranscriptAt: fixture), 1)

try? [launch, resultA].joined(separator: "\n").write(toFile: fixture, atomically: true, encoding: .utf8)
check("launched then finished", countPendingAgents(inTranscriptAt: fixture), 0)

try? [launch, launch2, resultA].joined(separator: "\n").write(toFile: fixture, atomically: true, encoding: .utf8)
check("two launched, one finished", countPendingAgents(inTranscriptAt: fixture), 1)

try? [otherTool, launch, resultA].joined(separator: "\n").write(toFile: fixture, atomically: true, encoding: .utf8)
check("ignores non-Agent tools", countPendingAgents(inTranscriptAt: fixture), 0)

check("missing file", countPendingAgents(inTranscriptAt: "/tmp/does-not-exist.jsonl"), 0)
