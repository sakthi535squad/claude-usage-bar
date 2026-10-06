import Cocoa

/// A look for the dropdown and the menu bar title. Every theme reads the same
/// model; only presentation differs, so switching never changes what is polled.
enum Theme: String, CaseIterable {
    case classic, terminal, htop, claude

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .terminal: return "Terminal"
        case .htop: return "htop"
        case .claude: return "Claude Code"
        }
    }

    var style: MenuStyle {
        switch self {
        case .classic: return ClassicStyle()
        case .terminal: return TerminalStyle()
        case .htop: return HtopStyle()
        case .claude: return ClaudeStyle()
        }
    }

    /// `-theme htop` on the command line overrides this for one run, via the
    /// argument domain of UserDefaults.
    static var current: Theme {
        get { UserDefaults.standard.string(forKey: "theme").flatMap(Theme.init) ?? .classic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme") }
    }
}

/// Everything a theme may show, captured once per menu build.
struct MenuContext {
    let usage: Usage?
    let pace: PaceForecast
    let agents: AgentSnapshot
    let pins: [String: Pin]
    let lastError: String?
    let now: Date
    /// Wraps a theme's row title in a session item with its submenu attached,
    /// so themes never have to know about pins or Conductor.
    let sessionItem: (AgentSession, NSAttributedString) -> NSMenuItem
}

protocol MenuStyle {
    /// Everything above the footer actions: usage, sessions and any error.
    func contentItems(_ c: MenuContext) -> [NSMenuItem]
    /// Restyles a footer action. `command` is a short lowercase verb.
    func styleAction(_ item: NSMenuItem, command: String)
    /// Menu bar text for the usage windows, before the waiting badge and agent suffix.
    func titleSegments(_ u: Usage) -> [(text: String, color: NSColor)]
    func makeSpinner(size: CGFloat) -> NSView & Spinning
}

// MARK: - Shared pieces

let mono12 = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let mono12Bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

/// Anthropic's terracotta, the accent Claude Code uses for its own chrome.
/// Deepened in light mode, where the dark-mode shade is about 3:1 on white.
let claudeOrange = NSColor(name: "claudeOrange") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
        : NSColor(srgbRed: 0.722, green: 0.353, blue: 0.231, alpha: 1)
}

/// Builds one attributed line from (text, colour) runs in a single font.
func runs(_ parts: [(String, NSColor)], font: NSFont = mono12) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (s, c) in parts {
        out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]))
    }
    return out
}

func infoItem(_ title: NSAttributedString) -> NSMenuItem {
    let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    mi.attributedTitle = title
    return mi
}

func disabledItem(_ text: String) -> NSMenuItem {
    let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
    mi.isEnabled = false
    mi.attributedTitle = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
    ])
    return mi
}

/// Neutral under 70%, so colour only ever means "look at this".
func warnColor(_ pct: Double, base: NSColor = .labelColor) -> NSColor {
    if pct >= 90 { return .systemRed }
    if pct >= 70 { return .systemOrange }
    return base
}

func spendPct(_ e: ExtraUsage) -> Double {
    spendShare(used: e.used, limit: e.limit, reported: e.utilization)
}

/// Pace in words, shared by the themes that print it.
func paceText(_ f: PaceForecast, clock: DateFormatter) -> (String, NSColor)? {
    switch f {
    case .measuring: return ("measuring pace…", .tertiaryLabelColor)
    case .full(let at): return ("full by \(clock.string(from: at))", .systemRed)
    case .onPace(let pct): return ("on pace for ~\(Int(pct.rounded()))% at reset", .secondaryLabelColor)
    }
}

func shortClock() -> DateFormatter {
    let f = DateFormatter()
    f.timeStyle = .short
    return f
}

/// "live · 3m ago", "cached · 1h ago", "stale · 14m ago".
func freshness(_ u: Usage) -> String {
    let src = u.fromCache ? "cached" : (u.isStale ? "stale" : "live")
    return "\(src) · \(ago(u.fetchedAt))"
}

/// Idle-row cache column: "↻ 99% 27m", "97% 42m" or "cold"; nil for busy rows,
/// which keep their own cache warm.
func cacheCell(_ a: AgentSession, pin: Pin?, now: Date) -> (String, NSColor)? {
    guard !a.isBusy, let c = cacheState(a, pin: pin) else { return nil }
    let mark = pin != nil ? "↻ " : ""
    let left = c.remaining(at: now)
    guard left > 0 else { return (mark + "cold", .tertiaryLabelColor) }
    let hit = c.hit.map { "\(Int(($0 * 100).rounded()))% " } ?? ""
    // A low hit on a warm session means something rewrote the prefix.
    let tint: NSColor = (c.hit ?? 1) < 0.8 ? .systemOrange : (pin != nil ? .labelColor : .secondaryLabelColor)
    return (mark + hit + formatDuration(left), tint)
}

/// Snaps every glyph to whole monospace cells. Symbols SF Mono lacks (◐ ↻ ⚠ ⎿)
/// fall back to fonts with other advances, and each one would otherwise shift
/// every later column of its row against the rows around it.
func gridAligned(_ s: NSAttributedString, font: NSFont = mono12) -> NSAttributedString {
    let cellW = ("M" as NSString).size(withAttributes: [.font: font]).width
    let out = NSMutableAttributedString(attributedString: s)
    let ns = s.string as NSString
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                           options: .byComposedCharacterSequences) { sub, range, _, _ in
        guard let sub, sub != " " else { return }
        let f = (s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? font
        let w = (sub as NSString).size(withAttributes: [.font: f]).width
        let cells = max(1, (w / cellW - 0.15).rounded(.up))
        let kern = cells * cellW - w
        if abs(kern) > 0.01 { out.addAttribute(.kern, value: kern, range: range) }
    }
    return out
}

/// A lowercase monospaced footer action, the way a CLI lists its commands.
/// A toggle shows its state as text: these themes never check an item (see buildMenu).
func styleCommand(_ item: NSMenuItem, _ title: NSAttributedString, on: String = "[on]", off: String = "[off]") {
    let out = NSMutableAttributedString(attributedString: title)
    if item.action == #selector(AppDelegate.toggleLogin) {
        let isOn = item.state == .on
        out.append(runs([("  " + (isOn ? on : off), isOn ? .systemGreen : .tertiaryLabelColor)]))
    }
    item.attributedTitle = gridAligned(out)
}

/// One full-strength, non-highlighting line: section heads and the like.
func lineItem(minColumns: Int = 40, lineHeight: CGFloat? = nil, _ compose: @escaping (inout Grid) -> Void) -> NSMenuItem {
    let view = GridPanelView(lines: 1, minColumns: minColumns, lineHeight: lineHeight) { cols in
        var g = Grid(cols: cols, rows: 1)
        compose(&g)
        return g
    }
    return viewItem(view)
}
