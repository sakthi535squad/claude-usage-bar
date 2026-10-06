import Cocoa

/// Native menu rows set like a shell's output: a prompt header, two-tone
/// eighth-cell bars, tree-connected detail lines and rule-style section heads.
struct TerminalStyle: MenuStyle {
    static let barWidth = 18
    static let labelWidth = 9
    /// Rules and the header are drawn to this many cells.
    static let width = 60

    func contentItems(_ c: MenuContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = [usagePanel(c)]
        let agents = c.agents
        func session(_ a: AgentSession) -> NSMenuItem {
            c.sessionItem(a, sessionLine(a, pin: c.pins[a.sessionId], now: c.now))
        }
        if agents.sessions.isEmpty {
            items.append(rule("no sessions running"))
        }
        if !agents.waiting.isEmpty {
            items.append(rule("needs you", count: agents.waiting.count, tint: .systemOrange))
            items += agents.waiting.map(session)
        }
        if !agents.busy.isEmpty {
            let subs = agents.subagentCount
            items.append(rule("working", count: agents.busy.count,
                              note: subs > 0 ? "+\(subs) subagents" : nil, tint: .systemGreen))
            items += agents.busy.map(session)
        }
        let warm = agents.idle.filter { c.pins[$0.sessionId] != nil }
        if !warm.isEmpty {
            items.append(rule("kept warm", count: warm.count, tint: .labelColor))
            items += warm.map(session)
        }
        let idle = agents.idle.filter { c.pins[$0.sessionId] == nil }
        if !idle.isEmpty {
            let fold = infoItem(gridAligned(runs([("○ ", .tertiaryLabelColor), ("\(idle.count) idle", .secondaryLabelColor)])))
            let sub = NSMenu()
            for a in idle { sub.addItem(session(a)) }
            fold.submenu = sub
            items.append(fold)
        }

        if let err = c.lastError {
            items.append(.separator())
            items.append(row([("✗ ", .systemRed), (err, .systemRed)]))
        }
        items.append(.separator())
        return items
    }

    func shortName(_ w: Window) -> String {
        switch w.key {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "seven_day_opus": return "7d opus"
        case "seven_day_sonnet": return "7d sonnet"
        default: return "7d apps"
        }
    }

    func row(_ parts: [(String, NSColor)]) -> NSMenuItem {
        lineItem { g in g.put(parts, row: 0, col: 0) }
    }

    /// One meter per window, each followed by its `└─` detail line when it has
    /// one, under a prompt line carrying freshness:
    ///
    ///     ❯ claude usage                                    live · 3m ago
    ///     5h       ██████████████▍░░░░░░░   72%   ↺ 1h 47m
    ///              └─ full by 6:47 AM
    func usagePanel(_ c: MenuContext) -> NSMenuItem {
        typealias Line = (label: String, pct: Double, tail: String, detail: (String, NSColor)?)
        var meters: [Line] = []
        let clock = shortClock()
        if let u = c.usage {
            for w in u.windows {
                let pace = w.key == "five_hour" && !u.fromCache ? paceText(c.pace, clock: clock) : nil
                meters.append((shortName(w), w.utilization, "↺ " + countdown(to: w.resetsAt), pace))
            }
            if let e = u.extra, e.enabled {
                let detail: (String, NSColor) = e.used > e.limit
                    ? ("\(money(e.used - e.limit, e.currency)) over the monthly cap", .systemRed)
                    : ("\(money(e.limit - e.used, e.currency)) left this month", .secondaryLabelColor)
                meters.append(("extra", spendPct(e),
                               "\(money(e.used, e.currency)) / \(money(e.limit, e.currency))", detail))
            }
        }
        let lines = 1 + meters.count + meters.filter { $0.detail != nil }.count

        let view = GridPanelView(lines: lines, minColumns: Self.width) { cols in
            var g = Grid(cols: cols, rows: lines)
            g.put([("❯ ", .systemGreen), ("claude usage", .labelColor)], row: 0, col: 0, bold: true)
            if let u = c.usage {
                let stale = u.fromCache || u.isStale
                g.putRight(freshness(u), row: 0, end: cols, fg: stale ? .systemOrange : .tertiaryLabelColor)
            } else {
                g.putRight("connecting…", row: 0, end: cols, fg: .tertiaryLabelColor)
            }
            let tailW = 14, pctW = 6
            let barW = max(10, cols - Self.labelWidth - pctW - tailW - 1)
            var r = 1
            for m in meters {
                let tint = warnColor(m.pct)
                g.put(m.label, row: r, col: 0, fg: .secondaryLabelColor)
                g.blockBar(min(m.pct, 100), row: r, col: Self.labelWidth, width: barW,
                           fg: tint, track: .quaternaryLabelColor)
                g.putRight("\(Int(m.pct.rounded()))%", row: r, end: Self.labelWidth + barW + pctW,
                           fg: tint, bold: true)
                g.put(m.tail, row: r, col: Self.labelWidth + barW + pctW + 3, fg: .secondaryLabelColor)
                r += 1
                if let (text, color) = m.detail {
                    g.put([("└─ ", .tertiaryLabelColor), (text, color)], row: r, col: Self.labelWidth)
                    r += 1
                }
            }
            return g
        }
        return viewItem(view)
    }

    /// `── needs you · 1 ─────────────────────────────` to the menu's edge.
    func rule(_ title: String, count: Int? = nil, note: String? = nil, tint: NSColor = .secondaryLabelColor) -> NSMenuItem {
        lineItem { g in
            var c = g.put([("── ", .quaternaryLabelColor), (title, tint)], row: 0, col: 0, bold: true)
            if let count { c = g.put(" · \(count)", row: 0, col: c, fg: .tertiaryLabelColor) }
            if let note { c = g.put(" · \(note)", row: 0, col: c, fg: .tertiaryLabelColor) }
            g.put(" " + String(repeating: "─", count: max(0, g.cols - c - 1)), row: 0, col: c, fg: .quaternaryLabelColor)
        }
    }

    /// `● Repo UI Improvement           busy 32m        488k  ⚠ silent 14m`
    func sessionLine(_ a: AgentSession, pin: Pin?, now: Date) -> NSAttributedString {
        let (dot, tint): (String, NSColor) = {
            switch a.status {
            case "busy": return ("●", .systemGreen)
            case "waiting": return ("◐", .systemOrange)
            case "exited": return ("◌", .secondaryLabelColor)
            default: return (pin != nil ? "◉" : "○", pin != nil ? .labelColor : .tertiaryLabelColor)
            }
        }()
        let base: NSColor = a.isBusy || a.isWaiting || pin != nil ? .labelColor : .secondaryLabelColor
        var parts: [(String, NSColor)] = [(dot + " ", tint), (pad(truncate(a.label, 30), 32), base)]

        let since = a.statusSince.map { " " + formatDuration(now.timeIntervalSince($0)) } ?? ""
        parts.append((pad(a.status + since, 16), a.isWaiting ? .systemOrange : .secondaryLabelColor))

        if let (text, color) = cacheCell(a, pin: pin, now: now) {
            parts.append((pad(text, 12), color))
        } else {
            parts.append((pad("", 12), base))
        }
        if let tokens = a.contextTokens, tokens >= contextWarnTokens {
            parts.append((pad(formatTokens(tokens), 7), tokens >= contextAlertTokens ? .systemRed : .systemOrange))
        } else {
            parts.append((pad("", 7), base))
        }
        if a.subagents > 0 { parts.append(("+\(a.subagents) agents  ", .secondaryLabelColor)) }
        if let quiet = a.silence(at: now) { parts.append(("⚠ silent \(formatDuration(quiet))", .systemOrange)) }
        if a.isWaiting, let why = a.waitingFor { parts.append(("→ \(why)", .secondaryLabelColor)) }
        return gridAligned(runs(parts))
    }

    func styleAction(_ item: NSMenuItem, command: String) {
        styleCommand(item, runs([(command, .labelColor)]))
    }

    /// `5h ▆ 72%  7d ▃ 41%`: a one-cell gauge per window, so the bar reads at a glance.
    func titleSegments(_ u: Usage) -> [(text: String, color: NSColor)] {
        let stale = (u.fromCache || u.isStale) ? "~" : ""
        return barWindows(u).map {
            (text: "\(shortLabel($0.key)) \(gauge($0.utilization)) \(stale)\(Int($0.utilization.rounded()))%",
             color: warnColor($0.utilization))
        }
    }

    func makeSpinner(size: CGFloat) -> NSView & Spinning {
        SpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
}

/// The windows the menu bar shows: 5-hour and 7-day, else whichever binds.
func barWindows(_ u: Usage) -> [Window] {
    let shown = u.windows.filter { $0.key == "five_hour" || $0.key == "seven_day" }
    return shown.isEmpty ? (u.binding.map { [$0] } ?? []) : shown
}
