import Cocoa

/// An embedded htop: meters and summary on a dark terminal panel, then the
/// sessions as a process table under a green header bar.
struct HtopStyle: MenuStyle {
    /// A terminal palette, fixed rather than dynamic: the panel is always dark.
    enum P {
        static let bg = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.098, alpha: 1)
        static let fg = NSColor(srgbRed: 0.80, green: 0.83, blue: 0.86, alpha: 1)
        static let dim = NSColor(srgbRed: 0.42, green: 0.46, blue: 0.51, alpha: 1)
        static let cyan = NSColor(srgbRed: 0.34, green: 0.83, blue: 0.87, alpha: 1)
        static let green = NSColor(srgbRed: 0.33, green: 0.80, blue: 0.40, alpha: 1)
        static let yellow = NSColor(srgbRed: 0.90, green: 0.73, blue: 0.25, alpha: 1)
        static let red = NSColor(srgbRed: 0.97, green: 0.36, blue: 0.33, alpha: 1)
        static let white = NSColor.white
    }

    static let columns = 64

    func contentItems(_ c: MenuContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let clock = shortClock()
        let windows = c.usage?.windows ?? []
        let extra = c.usage?.extra.flatMap { $0.enabled ? $0 : nil }
        let meterRows = windows.count + (extra == nil ? 0 : 1)
        let lines = max(1, meterRows) + 3

        let panel = GridPanelView(lines: lines, minColumns: Self.columns, backdrop: P.bg,
                                  margin: menuTextInset - 8, padding: 8) { cols in
            var g = Grid(cols: cols, rows: lines)
            guard let u = c.usage else {
                g.put("waiting for the first reading…", row: 0, col: 1, fg: P.dim)
                return g
            }
            // Meter: `5h[|||||||||||        72.0%]  1h48m`, tail column fixed.
            let tailW = 10
            let meterEnd = cols - tailW - 1
            var r = 0
            for w in windows {
                meter(&g, row: r, label: shortLabel(w.key), pct: w.utilization,
                      value: String(format: "%.1f%%", w.utilization), end: meterEnd)
                g.put(countdown(to: w.resetsAt), row: r, col: meterEnd + 2, fg: P.dim)
                r += 1
            }
            if let e = extra {
                let pct = spendPct(e)
                meter(&g, row: r, label: "$", pct: pct,
                      value: "\(money(e.used, e.currency))/\(money(e.limit, e.currency))", end: meterEnd)
                if e.used > e.limit {
                    g.put("+\(money(e.used - e.limit, e.currency))", row: r, col: meterEnd + 2, fg: P.red, bold: true)
                }
                r += 1
            }
            r += 1

            // Two-column summary, as htop prints Tasks / Load average / Uptime.
            let half = cols / 2 + 1
            let a = c.agents
            stat(&g, row: r, col: 1, "Sessions: ", [
                ("\(a.sessions.count)", P.white, true), (", ", P.fg, false),
                ("\(a.busyCount) running", P.green, true),
                (a.waiting.isEmpty ? "" : ", ", P.fg, false),
                (a.waiting.isEmpty ? "" : "\(a.waiting.count) waiting", P.yellow, true),
            ])
            let (paceStr, paceColor): (String, NSColor) = {
                guard !u.fromCache else { return ("n/a (cached)", P.dim) }
                switch c.pace {
                case .measuring: return ("measuring…", P.dim)
                case .full(let at): return ("full by \(clock.string(from: at))", P.red)
                case .onPace(let pct): return ("~\(Int(pct.rounded()))% at reset", P.green)
                }
            }()
            stat(&g, row: r, col: half, "Pace: ", [(paceStr, paceColor, true)])
            r += 1
            let warm = a.idle.filter { c.pins[$0.sessionId] != nil }.count
            stat(&g, row: r, col: 1, "Agents: ", [
                ("\(a.subagentCount)", P.white, true), (" sub, ", P.fg, false),
                ("\(warm)", P.white, true), (" kept warm", P.fg, false),
            ])
            let src = u.fromCache ? "cached" : (u.isStale ? "stale" : "live")
            stat(&g, row: r, col: half, "Updated: ", [
                (ago(u.fetchedAt), P.white, true), (" (\(src))", src == "live" ? P.dim : P.yellow, false),
            ])
            return g
        }
        items.append(viewItem(panel))

        // htop's green column header. Its cells start at the native title inset,
        // so the columns sit over the session rows' columns.
        let header = GridPanelView(lines: 1, minColumns: Self.columns, backdrop: P.green,
                                   margin: menuTextInset - 4, padding: 4, radius: 3) { cols in
            var g = Grid(cols: cols, rows: 1)
            g.put(" " + pad("S", 3) + pad("SESSION", 31) + pad("TIME", 10) + pad("CACHE", 12)
                  + pad("CTX", 7) + "NOTE", row: 0, col: 0, fg: .black, bold: true)
            return g
        }
        items.append(viewItem(header))

        let agents = c.agents
        func session(_ a: AgentSession) -> NSMenuItem {
            c.sessionItem(a, processLine(a, pin: c.pins[a.sessionId], now: c.now))
        }
        if agents.sessions.isEmpty {
            items.append(lineItem { g in g.put(" (no claude processes)", row: 0, col: 0, fg: .tertiaryLabelColor) })
        }
        let warm = agents.idle.filter { c.pins[$0.sessionId] != nil }
        items += (agents.waiting + agents.busy + warm).map(session)
        let idle = agents.idle.filter { c.pins[$0.sessionId] == nil }
        if !idle.isEmpty {
            let fold = infoItem(gridAligned(runs([
                (" " + pad("S", 3), .tertiaryLabelColor), ("\(idle.count) sleeping", .secondaryLabelColor),
            ])))
            let sub = NSMenu()
            for a in idle { sub.addItem(session(a)) }
            fold.submenu = sub
            items.append(fold)
        }
        if let err = c.lastError {
            items.append(.separator())
            items.append(lineItem { g in g.put([(" E  ", .systemRed), (err, .systemRed)], row: 0, col: 0) })
        }
        items.append(.separator())
        return items
    }

    /// htop's meter: label, bracket, bars split green / yellow / red at the
    /// 70% and 90% thresholds, and the value right-aligned inside the bracket.
    func meter(_ g: inout Grid, row: Int, label: String, pct: Double, value: String, end: Int) {
        let start = 1
        g.put(pad(label, 3), row: row, col: start, fg: P.cyan, bold: true)
        g.put("[", row: row, col: start + 3, fg: P.white, bold: true)
        g.put("]", row: row, col: end, fg: P.white, bold: true)
        let inner = end - (start + 4)
        let n = max(0, min(inner, Int((min(pct, 100) / 100 * Double(inner)).rounded())))
        for i in 0..<n {
            let at = Double(i + 1) / Double(inner) * 100
            let col: NSColor = at > 90 ? P.red : (at > 70 ? P.yellow : P.green)
            g.put("|", row: row, col: start + 4 + i, fg: col, bold: true)
        }
        // The value overwrites the bars under it, exactly as htop does.
        g.putRight(value, row: row, end: end, fg: n > inner - value.count ? P.white : P.dim, bold: true)
    }

    func stat(_ g: inout Grid, row: Int, col: Int, _ label: String, _ parts: [(String, NSColor, Bool)]) {
        var c = g.put(label, row: row, col: col, fg: P.cyan)
        for (s, color, bold) in parts { c = g.put(s, row: row, col: c, fg: color, bold: bold) }
    }

    /// ` R  Repo UI Improvement          32m       —           488k   ⚠ silent 14m`
    func processLine(_ a: AgentSession, pin: Pin?, now: Date) -> NSAttributedString {
        let (state, tint): (String, NSColor) = {
            switch a.status {
            case "busy": return ("R", .systemGreen)
            case "waiting": return ("W", .systemOrange)
            default: return ("S", pin != nil ? .labelColor : .tertiaryLabelColor)
            }
        }()
        let base: NSColor = a.isBusy || a.isWaiting || pin != nil ? .labelColor : .secondaryLabelColor
        var parts: [(String, NSColor)] = [(" ", base), (pad(state, 3), tint)]
        parts.append((pad(truncate(a.label, 29), 31), base))
        let since = a.statusSince.map { formatDuration(now.timeIntervalSince($0)) } ?? "—"
        parts.append((pad(since, 10), a.isWaiting ? .systemOrange : .secondaryLabelColor))
        if let (text, color) = cacheCell(a, pin: pin, now: now) {
            parts.append((pad(text, 12), color))
        } else {
            parts.append((pad("—", 12), .quaternaryLabelColor))
        }
        if let t = a.contextTokens {
            let color: NSColor = t >= contextAlertTokens ? .systemRed : (t >= contextWarnTokens ? .systemOrange : .tertiaryLabelColor)
            parts.append((pad(formatTokens(t), 7), color))
        } else {
            parts.append((pad("—", 7), .quaternaryLabelColor))
        }
        if let quiet = a.silence(at: now) {
            parts.append(("⚠ silent \(formatDuration(quiet))", .systemOrange))
        } else if a.isWaiting, let why = a.waitingFor {
            parts.append((why, .systemOrange))
        } else if a.subagents > 0 {
            parts.append(("+\(a.subagents) agents", .secondaryLabelColor))
        }
        return gridAligned(runs(parts))
    }

    func styleAction(_ item: NSMenuItem, command: String) {
        // htop's own setup screen marks options this way.
        styleCommand(item, runs([(" " + command, .labelColor)]), on: "[x]", off: "[ ]")
    }

    /// `5h[72%] 7d[41%]`
    func titleSegments(_ u: Usage) -> [(text: String, color: NSColor)] {
        let stale = (u.fromCache || u.isStale) ? "~" : ""
        return barWindows(u).map {
            (text: "\(shortLabel($0.key))[\(stale)\(Int($0.utilization.rounded()))%]", color: warnColor($0.utilization))
        }
    }

    func makeSpinner(size: CGFloat) -> NSView & Spinning {
        SpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
}

func viewItem(_ view: NSView) -> NSMenuItem {
    let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    mi.view = view
    return mi
}

extension NSAttributedString {
    func withBackground(_ color: NSColor) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: self)
        m.addAttribute(.backgroundColor, value: color, range: NSRange(location: 0, length: m.length))
        return m
    }
}
