import Foundation

struct AgentSession {
    let pid: pid_t
    let name: String
    let cwd: String
    let status: String        // busy | idle | waiting
    let sessionId: String
    var subagents: Int = 0
    var context: ContextStats?
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

/// Menu bar suffix, or nil when nothing is running. Shared by the GUI and --dump
/// so what gets verified on the command line is what actually gets displayed.
/// Blank run the spinner view is drawn over. Must be at least as wide as the
/// spinner or it overlaps the count; measured at 15.12pt for a 12pt spinner.
let spinnerPlaceholder = "\u{2007}\u{2007}"

func agentSuffix(_ snap: AgentSnapshot) -> String? {
    guard snap.anyRunning else { return nil }
    var label = "\(spinnerPlaceholder) \(snap.busyCount) busy"
    if snap.subagentCount > 0 { label += " (+\(snap.subagentCount))" }
    return label
}

/// Holds what must survive between scans: transcript read offsets and branch
/// lookups. Not thread-safe; drive it from one serial queue.
final class SessionScanner {
    private let reader = TranscriptReader()
    private var branches: [String: (branch: String?, at: Date)] = [:]

    func snapshot() -> AgentSnapshot {
        var sessions = readAgentSessions()
        let titles = conductorTitles()
        var watched = Set<String>()
        for i in sessions.indices {
            if let path = transcriptPath(for: sessions[i]), let state = reader.update(path: path) {
                watched.insert(path)
                sessions[i].subagents = state.pendingAgents.count
                sessions[i].context = state.context
            }
            if let title = titles[sessions[i].sessionId] {
                sessions[i].label = truncate(title, 34)
            } else if let branch = branch(sessions[i].cwd) {
                sessions[i].label = truncate(branch, 34)
            } else {
                sessions[i].label = sessions[i].name
            }
        }
        reader.retain(only: watched)
        return AgentSnapshot(sessions: sessions.sorted { $0.label < $1.label })
    }

    /// Spawning git for every session every minute is wasted work; branches
    /// rarely change, so a few minutes of staleness is fine.
    private func branch(_ cwd: String) -> String? {
        if let hit = branches[cwd], Date().timeIntervalSince(hit.at) < 300 { return hit.branch }
        let b = gitBranch(cwd)
        branches[cwd] = (b, Date())
        return b
    }
}
