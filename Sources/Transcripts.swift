import Foundation

/// Running state for one transcript. Advanced incrementally, so each pass reads
/// only what was appended since the last one.
final class TranscriptState {
    fileprivate(set) var offset: UInt64 = 0
    fileprivate(set) var pendingAgents = Set<String>()
    /// Input sent on the most recent API request: cache reads + writes + uncached.
    fileprivate(set) var contextTokens: Int?
}

private let newline = UInt8(ascii: "\n")
private let notificationOpen = "<tool-use-id>"
private let notificationClose = "</tool-use-id>"
private let markerNotification = Data(notificationOpen.utf8)
private let markerUsage = Data(#""usage""#.utf8)
private let markerAgent = Data(#""name":"Agent""#.utf8)
private let markerToolResult = Data(#""tool_result""#.utf8)

/// Not thread-safe: own one per serial queue.
final class TranscriptReader {
    private var states: [String: TranscriptState] = [:]

    /// Reads whatever was appended to `path` since the last call and returns the
    /// updated state, or nil when the file does not exist.
    @discardableResult
    func update(path: String) -> TranscriptState? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            states[path] = nil
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var state = states[path] ?? TranscriptState()
        // A file that shrank was rewritten, so the saved offset points at nothing.
        if size < state.offset { state = TranscriptState() }
        states[path] = state
        guard size > state.offset else { return state }

        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: newline) else { return state }

        // Lines are split as bytes before decoding: a multi-byte character can
        // straddle a read boundary, and decoding first would fail the whole chunk.
        // The trailing partial line is left for the next pass.
        let complete = data[data.startIndex..<lastNewline]
        for line in complete.split(separator: newline, omittingEmptySubsequences: true) {
            apply(Data(line), to: state)
        }
        state.offset += UInt64(lastNewline - data.startIndex + 1)
        return state
    }

    /// Drops state for transcripts no longer being watched.
    func retain(only paths: Set<String>) {
        states = states.filter { paths.contains($0.key) }
    }

    private func apply(_ line: Data, to state: TranscriptState) {
        // A finished background agent is announced by a task-notification, which
        // can arrive as a queued string rather than a structured message.
        if line.range(of: markerNotification) != nil,
           let text = String(data: line, encoding: .utf8) {
            for id in notificationIds(in: text) { state.pendingAgents.remove(id) }
        }
        // Most lines are tool output and progress; skip parsing them. Tool results
        // are the bulk of the bytes and only matter while an agent is open. Matched
        // as bytes: decoding every line of a 40 MB transcript dominated the scan.
        guard line.range(of: markerUsage) != nil || line.range(of: markerAgent) != nil
                || (!state.pendingAgents.isEmpty && line.range(of: markerToolResult) != nil)
        else { return }
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return }

        if let content = message["content"] as? [[String: Any]] {
            // A background launch is answered immediately; that reply is not the
            // agent finishing, so it must not clear the pending entry.
            let launchedAsync = (root["toolUseResult"] as? [String: Any])?["isAsync"] as? Bool == true
            for item in content {
                let type = item["type"] as? String
                if type == "tool_use", item["name"] as? String == "Agent",
                   let id = item["id"] as? String {
                    state.pendingAgents.insert(id)
                } else if type == "tool_result", !launchedAsync,
                          let id = item["tool_use_id"] as? String {
                    state.pendingAgents.remove(id)
                }
            }
        }

        if root["type"] as? String == "assistant",
           let usage = message["usage"] as? [String: Any] {
            let total = ["cache_read_input_tokens", "cache_creation_input_tokens", "input_tokens"]
                .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            // Synthetic entries (interrupts, local errors) carry all-zero usage.
            if total > 0 { state.contextTokens = total }
        }
    }
}

func notificationIds(in text: String) -> [String] {
    var ids: [String] = []
    var rest = text[...]
    while let open = rest.range(of: notificationOpen),
          let close = rest.range(of: notificationClose, range: open.upperBound..<rest.endIndex) {
        ids.append(String(rest[open.upperBound..<close.lowerBound]))
        rest = rest[close.upperBound...]
    }
    return ids
}

/// "87k", "1.2M": short enough for a menu column.
func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return "\(n / 1000)k" }
    return "\(n)"
}
