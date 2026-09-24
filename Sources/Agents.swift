import Foundation

struct AgentSession {
    let pid: pid_t
    let name: String
    let cwd: String
    let status: String        // busy | idle | waiting
    let sessionId: String
    var subagents: Int = 0
    /// Conductor chat title if there is one, else branch, else the derived name.
    var label: String = ""

    var isBusy: Bool { status == "busy" }
}

struct AgentSnapshot {
    let sessions: [AgentSession]

    var busy: [AgentSession] { sessions.filter(\.isBusy) }
    var busyCount: Int { busy.count }
    var subagentCount: Int { sessions.reduce(0) { $0 + $1.subagents } }
    var anyRunning: Bool { busyCount > 0 || subagentCount > 0 }
}

/// Claude Code registers each live session as ~/.claude/sessions/<pid>.json.
/// The file is not always cleaned up after a crash, so every entry is confirmed
/// against the running process before it counts.
func readAgentSessions() -> [AgentSession] {
    let dir = NSHomeDirectory() + "/.claude/sessions"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }

    var out: [AgentSession] = []
    for name in names where name.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: dir + "/" + name),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidNum = root["pid"] as? Int
        else { continue }

        let pid = pid_t(pidNum)
        // kill(pid, 0) succeeds only if the process exists and we may signal it.
        guard kill(pid, 0) == 0 || errno == EPERM else { continue }

        out.append(AgentSession(
            pid: pid,
            name: (root["name"] as? String) ?? "session \(pid)",
            cwd: (root["cwd"] as? String) ?? "",
            status: (root["status"] as? String) ?? "unknown",
            sessionId: (root["sessionId"] as? String) ?? ""))
    }
    return out
}

/// Transcripts live under a slug of the cwd with every "/" replaced by "-".
func transcriptPath(for session: AgentSession) -> String? {
    guard !session.cwd.isEmpty, !session.sessionId.isEmpty else { return nil }
    let slug = session.cwd.replacingOccurrences(of: "/", with: "-")
    return "\(NSHomeDirectory())/.claude/projects/\(slug)/\(session.sessionId).jsonl"
}

/// Subagents run inside the parent process, so they have no pid and never appear
/// in the session registry. They show up in the parent's transcript as an "Agent"
/// tool_use; one is still running until a tool_result quotes its id back.
///
/// Only the tail is read: transcripts reach several MB and a pending subagent is
/// recent by nature. A subagent launched before that window is not counted.
func countRunningSubagents(_ session: AgentSession, tailBytes: Int = 1_048_576) -> Int {
    guard let path = transcriptPath(for: session) else { return 0 }
    return countPendingAgents(inTranscriptAt: path, tailBytes: tailBytes)
}

/// Split out from the session lookup so it can be exercised against a fixture.
func countPendingAgents(inTranscriptAt path: String, tailBytes: Int = 1_048_576) -> Int {
    guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
    defer { try? handle.close() }

    guard let size = try? handle.seekToEnd() else { return 0 }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd(),
          let text = String(data: data, encoding: .utf8) else { return 0 }

    var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    // A mid-file seek almost always lands inside a line; that fragment is not valid JSON.
    if start > 0, !lines.isEmpty { lines.removeFirst() }

    var pending = Set<String>()
    for line in lines {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { continue }

        for item in content {
            let type = item["type"] as? String
            if type == "tool_use", item["name"] as? String == "Agent",
               let id = item["id"] as? String {
                pending.insert(id)
            } else if type == "tool_result", let id = item["tool_use_id"] as? String {
                pending.remove(id)
            }
        }
    }
    return pending.count
}

/// Menu bar suffix, or nil when nothing is running. Shared by the GUI and --dump
/// so what gets verified on the command line is what actually gets displayed.
func agentSuffix(_ snap: AgentSnapshot) -> String? {
    guard snap.anyRunning else { return nil }
    var label = "\u{2007} \(snap.busyCount) busy"
    if snap.subagentCount > 0 { label += " (+\(snap.subagentCount))" }
    return label
}

func agentSnapshot() -> AgentSnapshot {
    var sessions = readAgentSessions()
    let titles = conductorTitles()
    for i in sessions.indices {
        sessions[i].subagents = countRunningSubagents(sessions[i])
        if let title = titles[sessions[i].sessionId] {
            sessions[i].label = truncate(title, 34)
        } else if let branch = gitBranch(sessions[i].cwd) {
            sessions[i].label = truncate(branch, 34)
        } else {
            sessions[i].label = sessions[i].name
        }
    }
    return AgentSnapshot(sessions: sessions.sorted { $0.label < $1.label })
}
