import Foundation

/// Context colours: under `contextWarnTokens` neutral, then orange, then red at
/// `contextAlertTokens`. The point is to steer a session (compact, clear, hand
/// off) before every turn is re-reading a huge context.
let contextWarnTokens = 200_000
let contextAlertTokens = 500_000
/// Show the countdown once a warm cache is this close to expiring.
let cacheExpiryWarn: TimeInterval = 15 * 60

/// What the most recent API request in a transcript says about its context.
struct ContextStats {
    /// Everything sent as input on that request: cache reads + writes + uncached.
    let tokens: Int
    /// Share of `tokens` served from cache.
    let cacheHit: Double
    let requestedAt: Date
    let ttl: TimeInterval

    var expiresAt: Date { requestedAt.addingTimeInterval(ttl) }
    func isCold(at now: Date = Date()) -> Bool { now >= expiresAt }
}

/// Running state for one transcript. Advanced incrementally, so each pass reads
/// only what was appended since the last one.
final class TranscriptState {
    fileprivate(set) var offset: UInt64 = 0
    fileprivate(set) var pendingAgents = Set<String>()
    fileprivate(set) var context: ContextStats?
    fileprivate var lastMessageId: String?
    /// The cache TTL is only visible on requests that write; reads inherit it.
    /// Default to the shorter TTL so an unknown session reads cold, not warm.
    fileprivate var ttl: TimeInterval = 300
}

private let transcriptDate: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

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
            applyUsage(usage, messageId: message["id"] as? String,
                       timestamp: root["timestamp"] as? String, to: state)
        }
    }

    private func applyUsage(_ usage: [String: Any], messageId: String?,
                            timestamp: String?, to state: TranscriptState) {
        let read = usage["cache_read_input_tokens"] as? Int ?? 0
        let written = usage["cache_creation_input_tokens"] as? Int ?? 0
        let uncached = usage["input_tokens"] as? Int ?? 0
        let total = read + written + uncached
        // Synthetic entries (interrupts, local errors) carry all-zero usage.
        guard total > 0 else { return }

        if let split = usage["cache_creation"] as? [String: Any] {
            if (split["ephemeral_1h_input_tokens"] as? Int ?? 0) > 0 {
                state.ttl = 3600
            } else if (split["ephemeral_5m_input_tokens"] as? Int ?? 0) > 0 {
                state.ttl = 300
            }
        }

        // One response is written as several lines sharing an id. The cache
        // clock starts with the request, so keep the earliest timestamp.
        let sameRequest = messageId != nil && messageId == state.lastMessageId
        let requestedAt = sameRequest
            ? state.context?.requestedAt
            : timestamp.flatMap { transcriptDate.date(from: $0) }
        state.lastMessageId = messageId
        state.context = ContextStats(tokens: total,
                                     cacheHit: Double(read) / Double(total),
                                     requestedAt: requestedAt ?? Date(),
                                     ttl: state.ttl)
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

/// "97%", "97% · 8m" near expiry, or "cold" once the cache has lapsed.
func formatCache(_ c: ContextStats, now: Date = Date()) -> String {
    if c.isCold(at: now) { return "cold" }
    let pct = "\(Int((c.cacheHit * 100).rounded()))%"
    let left = c.expiresAt.timeIntervalSince(now)
    return left <= cacheExpiryWarn ? "\(pct) · \(max(1, Int(left / 60)))m" : pct
}
