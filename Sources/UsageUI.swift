import Cocoa

enum UI {
    static let width: CGFloat = 268
    static let inset: CGFloat = 14
    static let rowHeight: CGFloat = 50
    static let headerHeight: CGFloat = 30
    static let barHeight: CGFloat = 5
}

/// One usage window: name, percentage, a filled track, and when it resets.
final class UsageRowView: NSView {
    private let title: String
    private let detail: String
    private let pct: Double
    private let accent: NSColor

    init(title: String, detail: String, pct: Double, accent: NSColor) {
        self.title = title
        self.detail = detail
        self.pct = pct
        self.accent = accent
        super.init(frame: NSRect(x: 0, y: 0, width: UI.width, height: UI.rowHeight))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let right = bounds.width - UI.inset

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        title.draw(at: NSPoint(x: UI.inset, y: 7), withAttributes: titleAttrs)

        let pctStr = "\(Int(pct.rounded()))%"
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: accent,
        ]
        let pctSize = pctStr.size(withAttributes: pctAttrs)
        pctStr.draw(at: NSPoint(x: right - pctSize.width, y: 7), withAttributes: pctAttrs)

        // Track, then fill. A 2px minimum keeps a non-zero value from vanishing.
        let trackRect = NSRect(x: UI.inset, y: 27,
                               width: bounds.width - UI.inset * 2, height: UI.barHeight)
        let radius = UI.barHeight / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()

        let frac = max(0, min(1, pct / 100))
        if frac > 0 {
            let w = max(UI.barHeight, trackRect.width * frac)
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: trackRect.minX, y: trackRect.minY,
                                             width: w, height: trackRect.height),
                         xRadius: radius, yRadius: radius).fill()
        }

        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        detail.draw(at: NSPoint(x: UI.inset, y: 35), withAttributes: detailAttrs)
    }
}

/// Section header: a small caps label with an optional right-aligned status.
final class HeaderView: NSView {
    private let text: String
    private let trailing: String
    private let trailingColor: NSColor

    init(_ text: String, trailing: String = "", trailingColor: NSColor = .tertiaryLabelColor) {
        self.text = text
        self.trailing = trailing
        self.trailingColor = trailingColor
        super.init(frame: NSRect(x: 0, y: 0, width: UI.width, height: UI.headerHeight))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.6,
        ]
        text.uppercased().draw(at: NSPoint(x: UI.inset, y: 12), withAttributes: attrs)

        guard !trailing.isEmpty else { return }
        let tAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: trailingColor,
        ]
        let size = trailing.size(withAttributes: tAttrs)
        trailing.draw(at: NSPoint(x: bounds.width - UI.inset - size.width, y: 12),
                      withAttributes: tAttrs)
    }
}

/// Builds the stack of custom views shown at the top of the menu.
func usageViews(_ u: Usage) -> [NSView] {
    var views: [NSView] = []
    let fresh = u.fromCache ? "cached · \(ago(u.fetchedAt))" : "updated \(ago(u.fetchedAt))"
    views.append(HeaderView("Claude Code Usage", trailing: fresh,
                            trailingColor: u.fromCache ? warnColor : .tertiaryLabelColor))

    for w in u.windows {
        let resets = w.resetsAt == nil ? "no reset window" : "resets in \(countdown(to: w.resetsAt))"
        views.append(UsageRowView(title: w.label, detail: resets,
                                  pct: w.utilization, accent: barColor(for: w.utilization)))
    }

    if let e = u.extra, e.enabled {
        views.append(HeaderView("Extra Usage"))
        let sym = e.currency == "USD" ? "$" : "\(e.currency) "
        let detail = String(format: "%@%.0f of %@%.0f this month", sym, e.used, sym, e.limit)
        views.append(UsageRowView(title: "Credits", detail: detail,
                                  pct: e.utilization, accent: barColor(for: e.utilization)))
    }
    return views
}

/// Opaque backdrop for previews. cacheDisplay captures drawn content but not a
/// bare layer colour, so the background has to be a real view in the hierarchy.
final class BackdropView: NSView {
    var fill: NSColor = .clear
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
    }
}

/// Renders the menu contents to a PNG. The macOS status bar and its menus are
/// invisible to screencapture, so this is the only way to eyeball the layout.
func renderPreview(_ u: Usage, appearance name: NSAppearance.Name, to path: String) {
    // lockFocus resets the drawing appearance, so the backdrop is a literal colour
    // approximating the menu material rather than a dynamic system one.
    let backdrop = name == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    let views = usageViews(u)
    let height = views.reduce(0) { $0 + $1.frame.height } + 16
    let container = NSView(frame: NSRect(x: 0, y: 0, width: UI.width, height: height))
    container.appearance = NSAppearance(named: name)

    let back = BackdropView(frame: container.bounds)
    back.fill = backdrop
    container.addSubview(back)

    var y = height - 8
    for v in views {
        y -= v.frame.height
        v.setFrameOrigin(NSPoint(x: 0, y: y))
        container.addSubview(v)
    }

    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds),
          let app = NSAppearance(named: name) else { return }

    // Every colour here is dynamic, so drawing must happen inside the target
    // appearance or text and background resolve from different modes.
    app.performAsCurrentDrawingAppearance {
        container.cacheDisplay(in: container.bounds, to: rep)
    }

    guard let out = rep.representation(using: .png, properties: [:]) else { return }
    try? out.write(to: URL(fileURLWithPath: path))
}
