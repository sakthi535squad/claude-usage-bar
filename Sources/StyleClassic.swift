import Cocoa

/// The original look, kept exactly: ASCII bars, whole lines tinted by usage.
struct ClassicStyle: MenuStyle {
    func contentItems(_ c: MenuContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let u = c.usage {
            for w in u.windows {
                let line = String(format: "%@ %@ %3d%%   resets %@",
                                  pad(w.label, 12), bar(w.utilization),
                                  Int(w.utilization.rounded()), countdown(to: w.resetsAt))
                items.append(infoItem(runs([(line, color(for: w.utilization))])))
                if w.key == "five_hour", !u.fromCache {
                    items.append(paceItem(c.pace, resetsAt: w.resetsAt))
                }
            }

            if let e = u.extra, e.enabled {
                items.append(.separator())
                let line = String(format: "%@ %@ %3d%%   %@%.0f of %.0f",
                                  pad("Extra usage", 12), bar(e.utilization),
                                  Int(e.utilization.rounded()),
                                  e.currency == "USD" ? "$" : "", e.used, e.limit)
                items.append(infoItem(runs([(line, color(for: e.utilization))])))
            }

            items.append(.separator())
            let src = u.fromCache ? "cached from Claude Code"
                : (u.isStale ? "stale — refresh to update" : "live")
            items.append(disabledItem("Updated \(ago(u.fetchedAt)) · \(src)"))
        }

        let agents = c.agents
        func row(_ a: AgentSession) -> NSMenuItem {
            c.sessionItem(a, sessionRow(a, font: mono12, now: c.now, pin: c.pins[a.sessionId]))
        }
        if agents.sessions.isEmpty {
            items.append(disabledItem("No Claude Code sessions running"))
        }
        if !agents.waiting.isEmpty {
            items.append(disabledItem("NEEDS YOU"))
            items += agents.waiting.map(row)
        }
        if !agents.busy.isEmpty {
            items.append(disabledItem("WORKING"))
            items += agents.busy.map(row)
        }
        let warm = agents.idle.filter { c.pins[$0.sessionId] != nil }
        if !warm.isEmpty {
            items.append(disabledItem("KEPT WARM"))
            items += warm.map(row)
        }
        let idle = agents.idle.filter { c.pins[$0.sessionId] == nil }
        if !idle.isEmpty {
            // Idle sessions need nothing from you, so they fold away.
            let fold = NSMenuItem(title: "\(idle.count) idle", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for a in idle { sub.addItem(row(a)) }
            fold.submenu = sub
            items.append(fold)
        }
        items.append(.separator())

        if let err = c.lastError {
            items.append(disabledItem("⚠ \(err)"))
        }
        items.append(.separator())
        return items
    }

    func paceItem(_ f: PaceForecast, resetsAt: Date?) -> NSMenuItem {
        let clock = shortClock()
        let (text, tint): (String, NSColor) = {
            switch f {
            case .measuring:
                return ("measuring pace…", .tertiaryLabelColor)
            case .full(let at):
                let reset = resetsAt.map { ", resets \(clock.string(from: $0))" } ?? ""
                return ("full by \(clock.string(from: at))\(reset)", .systemRed)
            case .onPace(let pct):
                return ("on pace — ~\(Int(pct.rounded()))% at reset", .secondaryLabelColor)
            }
        }()
        return infoItem(runs([("\(pad("", 12)) \u{21B3} \(text)", tint)]))
    }

    func styleAction(_ item: NSMenuItem, command: String) {}

    func titleSegments(_ u: Usage) -> [(text: String, color: NSColor)] {
        classicTitleSegments(u).map { (text: $0.text, color: color(for: $0.pct)) }
    }

    func makeSpinner(size: CGFloat) -> NSView & Spinning {
        SpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
}
