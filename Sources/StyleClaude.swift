import Cocoa

/// Dressed as Claude Code itself: a terracotta welcome box holding the limits,
/// `●` tool-call bullets for sections, `⎿` result connectors, and the footer
/// actions as slash commands.
struct ClaudeStyle: MenuStyle {
    static let columns = 62

    func contentItems(_ c: MenuContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let clock = shortClock()
        let windows = c.usage?.windows ?? []
        let extra = c.usage?.extra.flatMap { $0.enabled ? $0 : nil }
        // Box top, title, gap, two lines per meter, gap, box bottom.
        let lines = 3 + 2 * (windows.count + (extra == nil ? 0 : 1)) + 2
        let border = claudeOrange.withAlphaComponent(0.85)

        let panel = GridPanelView(lines: lines, minColumns: Self.columns, margin: 12) { cols in
            var g = Grid(cols: cols, rows: lines)
            g.box(top: 0, bottom: lines - 1, color: border)
            g.put("✻", row: 1, col: 2, fg: claudeOrange)
            g.put("Claude Usage", row: 1, col: 4, fg: .labelColor, bold: true)
            if let u = c.usage {
                let tint: NSColor = u.fromCache || u.isStale ? .systemOrange : .tertiaryLabelColor
                g.putRight(freshness(u), row: 1, end: cols - 2, fg: tint)
            } else {
                g.putRight("connecting…", row: 1, end: cols - 2, fg: .tertiaryLabelColor)
            }

            let labelW = 9, pctW = 6
            let barCol = 3 + labelW
            let barW = max(8, cols - barCol - pctW - 3)
            var r = 3
            func meter(_ label: String, _ pct: Double, _ detail: [(String, NSColor)]) {
                let tint = pct >= 90 ? NSColor.systemRed : (pct >= 70 ? claudeOrange : NSColor.labelColor)
                g.put(label, row: r, col: 3, fg: .secondaryLabelColor)
                g.heavyBar(min(pct, 100), row: r, col: barCol, width: barW,
                           fg: tint, track: NSColor.quaternaryLabelColor)
                g.putRight("\(Int(pct.rounded()))%", row: r, end: cols - 2, fg: tint, bold: true)
                var col = g.put("⎿", row: r + 1, col: barCol, fg: .tertiaryLabelColor)
                // ⎿ is a cell and a half wide in its fallback font.
                col += 2
                for (s, color) in detail { col = g.put(s, row: r + 1, col: col, fg: color) }
                r += 2
            }
            for w in windows {
                var detail: [(String, NSColor)] = [("resets in \(countdown(to: w.resetsAt))", .secondaryLabelColor)]
                if w.key == "five_hour", c.usage?.fromCache == false {
                    switch c.pace {
                    case .measuring: detail.append((" · measuring pace…", .tertiaryLabelColor))
                    case .full(let at): detail.append((" · full by \(clock.string(from: at))", .systemRed))
                    case .onPace(let p): detail.append((" · on pace for ~\(Int(p.rounded()))%", .tertiaryLabelColor))
                    }
                }
                meter(w.label, w.utilization, detail)
            }
            if let e = extra {
                var detail: [(String, NSColor)] = [
                    ("\(money(e.used, e.currency)) of \(money(e.limit, e.currency))", .secondaryLabelColor),
                ]
                if e.used > e.limit {
                    detail.append((" · \(money(e.used - e.limit, e.currency)) over cap", .systemRed))
                }
                meter("Extra", spendPct(e), detail)
            }
            return g
        }
        items.append(viewItem(panel))

        let agents = c.agents
        func session(_ a: AgentSession, first: Bool) -> NSMenuItem {
            c.sessionItem(a, sessionLine(a, pin: c.pins[a.sessionId], now: c.now, first: first))
        }
        func section(_ title: String, _ bullet: NSColor, _ list: [AgentSession], note: String? = nil) {
            guard !list.isEmpty else { return }
            items.append(lineItem { g in
                var col = g.put([("● ", bullet), (title, .labelColor)], row: 0, col: 0, bold: true)
                col = g.put(" (\(list.count))", row: 0, col: col, fg: .tertiaryLabelColor)
                if let note { g.put(" · " + note, row: 0, col: col, fg: .tertiaryLabelColor) }
            })
            for (i, a) in list.enumerated() { items.append(session(a, first: i == 0)) }
        }
        if agents.sessions.isEmpty {
            items.append(lineItem { g in
                g.put([("● ", .tertiaryLabelColor), ("No sessions running", .secondaryLabelColor)], row: 0, col: 0)
            })
        }
        section("Needs you", .systemOrange, agents.waiting)
        section("Working", .systemGreen, agents.busy,
                note: agents.subagentCount > 0 ? "+\(agents.subagentCount) subagents" : nil)
        section("Kept warm", claudeOrange, agents.idle.filter { c.pins[$0.sessionId] != nil })
        let idle = agents.idle.filter { c.pins[$0.sessionId] == nil }
        if !idle.isEmpty {
            let fold = infoItem(gridAligned(runs([("● ", .tertiaryLabelColor), ("Idle", .secondaryLabelColor)], font: mono12Bold)
                .appending(runs([(" (\(idle.count))", .tertiaryLabelColor)]))))
            let sub = NSMenu()
            for (i, a) in idle.enumerated() { sub.addItem(session(a, first: i == 0)) }
            fold.submenu = sub
            items.append(fold)
        }
        if let err = c.lastError {
            items.append(.separator())
            items.append(lineItem { g in
                g.put([("● ", .systemRed), ("Error: ", .systemRed), (err, .labelColor)], row: 0, col: 0)
            })
        }
        items.append(.separator())
        return items
    }

    /// `  ⎿ ◐ knowledge-graph-learning    waiting 3h 32m · dialog open`
    func sessionLine(_ a: AgentSession, pin: Pin?, now: Date, first: Bool) -> NSAttributedString {
        let (dot, tint): (String, NSColor) = {
            switch a.status {
            case "busy": return ("●", .systemGreen)
            case "waiting": return ("◐", .systemOrange)
            default: return (pin != nil ? "↻" : "○", pin != nil ? claudeOrange : .tertiaryLabelColor)
            }
        }()
        let base: NSColor = a.isBusy || a.isWaiting || pin != nil ? .labelColor : .secondaryLabelColor
        // ⎿ takes two cells once aligned, so the prefix is one character shorter.
        var parts: [(String, NSColor)] = [(first ? "  ⎿ " : "     ", .tertiaryLabelColor)]
        parts += [(dot + " ", tint), (pad(truncate(a.label, 28), 30), base)]

        let since = a.statusSince.map { " " + formatDuration(now.timeIntervalSince($0)) } ?? ""
        parts.append((pad(a.status + since, 16), a.isWaiting ? .systemOrange : .secondaryLabelColor))
        var notes: [(String, NSColor)] = []
        if !a.isBusy, let cache = cacheState(a, pin: pin) {
            let left = cache.remaining(at: now)
            if left <= 0 {
                notes.append(("cache cold", .tertiaryLabelColor))
            } else {
                let hit = cache.hit.map { "\(Int(($0 * 100).rounded()))% hit · " } ?? ""
                let tint: NSColor = (cache.hit ?? 1) < 0.8 ? .systemOrange : .secondaryLabelColor
                notes.append(("\(hit)\(formatDuration(left)) warm", tint))
            }
        }
        if let tokens = a.contextTokens, tokens >= contextWarnTokens {
            notes.append(("\(formatTokens(tokens)) ctx", tokens >= contextAlertTokens ? .systemRed : .systemOrange))
        }
        if a.subagents > 0 { notes.append(("+\(a.subagents) agents", .secondaryLabelColor)) }
        if let quiet = a.silence(at: now) { notes.append(("silent \(formatDuration(quiet))", .systemOrange)) }
        if a.isWaiting, let why = a.waitingFor { notes.append((why, .secondaryLabelColor)) }
        for (i, n) in notes.enumerated() {
            if i > 0 { parts.append((" · ", .quaternaryLabelColor)) }
            parts.append(n)
        }
        return gridAligned(runs(parts))
    }

    func styleAction(_ item: NSMenuItem, command: String) {
        let slug = command.split(separator: " ").last.map(String.init) ?? command
        styleCommand(item, runs([("/", claudeOrange), (slug, .labelColor)]), on: "· on", off: "· off")
    }

    /// `✻ 5h 72%  7d 41%`
    func titleSegments(_ u: Usage) -> [(text: String, color: NSColor)] {
        let stale = (u.fromCache || u.isStale) ? "~" : ""
        let windows = barWindows(u).map {
            (text: "\(shortLabel($0.key)) \(stale)\(Int($0.utilization.rounded()))%",
             color: $0.utilization >= 90 ? NSColor.systemRed : ($0.utilization >= 70 ? claudeOrange : .labelColor))
        }
        return [(text: "✻", color: claudeOrange)] + windows
    }

    func makeSpinner(size: CGFloat) -> NSView & Spinning {
        GlyphSpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size), color: claudeOrange)
    }
}

extension NSAttributedString {
    func appending(_ other: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: self)
        m.append(other)
        return m
    }
}
