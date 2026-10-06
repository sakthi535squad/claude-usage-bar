import Foundation

/// Fixed data for `--demo`: one of every state the menu can show, so a theme
/// can be judged, screenshotted or pitched without live sessions, network or
/// keep-warm pings.
enum Demo {
    static func usage(now: Date) -> Usage {
        Usage(windows: [
            Window(key: "five_hour", label: "5-hour", utilization: 72,
                   resetsAt: now.addingTimeInterval(1 * 3600 + 48 * 60)),
            Window(key: "seven_day", label: "7-day", utilization: 41,
                   resetsAt: now.addingTimeInterval(4 * 86400 + 2 * 3600)),
        ],
        extra: ExtraUsage(used: 225, limit: 200, currency: "USD", utilization: 100, enabled: true),
        fetchedAt: now.addingTimeInterval(-3 * 60), fromCache: false)
    }

    static func pace(now: Date) -> PaceForecast {
        .full(at: now.addingTimeInterval(65 * 60))
    }

    static let warmId = "demo-warm"

    static func pins(now: Date) -> [String: Pin] {
        [warmId: Pin(sessionId: warmId, pinnedAt: now.addingTimeInterval(-2 * 3600), lastPingAt: nil)]
    }

    static func agents(now: Date) -> AgentSnapshot {
        func s(_ label: String, _ status: String, since mins: Double, id: String? = nil,
               waitingFor: String? = nil, context: Int? = nil, hit: Double? = nil,
               requestAgo: Double? = nil, writeAgo: Double = 0.2, subagents: Int = 0,
               conductor: Bool = true) -> AgentSession {
            var a = AgentSession(
                pid: pid_t(40000 + label.unicodeScalars.reduce(0) { $0 + Int($1.value) }), name: label, cwd: "/tmp",
                status: status, sessionId: id ?? label,
                statusSince: now.addingTimeInterval(-mins * 60), waitingFor: waitingFor)
            a.label = truncate(label, 34)
            a.fromConductor = conductor
            a.contextTokens = context
            a.cacheHit = hit
            a.lastRequestAt = requestAgo.map { now.addingTimeInterval(-$0 * 60) }
            a.cacheTTL = requestAgo == nil ? nil : 3600
            a.lastWriteAt = now.addingTimeInterval(-writeAgo * 60)
            a.subagents = subagents
            return a
        }
        return AgentSnapshot(sessions: [
            s("knowledge-graph-learning", "waiting", since: 212, waitingFor: "dialog open",
              context: 121_000, hit: 0.97, requestAgo: 18),
            s("Repo UI Improvement", "busy", since: 32, context: 488_000, writeAgo: 14),
            s("Pipecat 1.6 rollout audit", "busy", since: 6, context: 156_000, subagents: 3),
            s("Worktrees old delete", "idle", since: 32, id: warmId, context: 64_000, hit: 0.99, requestAgo: 33),
            s("Fix Exotel webhook retries", "idle", since: 48, context: 92_000, hit: 0.95, requestAgo: 48),
            s("Claude usage tracker Mac", "idle", since: 75, context: 230_000, hit: 0.98, requestAgo: 75),
            s("Lens trace explorer", "idle", since: 140, hit: 0.91, requestAgo: 140),
            s("Deepgram proxy setup", "idle", since: 26, hit: 0.62, requestAgo: 26),
            s("Weekly cost report", "idle", since: 9, hit: 0.99, requestAgo: 9, conductor: false),
        ].sorted { $0.label < $1.label })
    }
}
