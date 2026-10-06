import Cocoa

/// Where AppKit starts a menu item's title, measured from the item's left edge
/// on macOS 27 with no item checked (a checked item adds a state column and
/// moves titles right). Grid views start their first cell here so their
/// columns line up with native session rows.
let menuTextInset: CGFloat = 16

/// A non-interactive menu item view that paints a `Grid` at a fixed cell size.
/// Unlike an action-less native item, it is not drawn dimmed and does not
/// highlight on hover.
/// It is laid out at draw time from the width the menu gives it, so boxes and
/// bars always span the menu however wide the session rows make it.
final class GridPanelView: NSView {
    let font: NSFont
    let boldFont: NSFont
    let cell: NSSize
    let lineCount: Int
    let backdrop: NSColor?
    /// Horizontal inset from the menu edge to the first cell.
    let margin: CGFloat
    let padding: CGFloat
    let radius: CGFloat
    let compose: (Int) -> Grid

    /// `margin + padding` should equal `menuTextInset` to stay column-aligned.
    init(lines: Int, minColumns: Int, font: NSFont = mono12, backdrop: NSColor? = nil,
         margin: CGFloat = menuTextInset, padding: CGFloat = 0, radius: CGFloat = 8,
         lineHeight: CGFloat? = nil, compose: @escaping (Int) -> Grid) {
        self.font = font
        self.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        // Box-drawing characters are drawn to the cell edges, so the line height is
        // the cell height: no leading, or vertical rules show gaps.
        let h = lineHeight ?? ceil(font.ascender - font.descender) + 3
        self.cell = NSSize(width: w, height: h)
        self.lineCount = lines
        self.backdrop = backdrop
        self.margin = margin
        self.padding = padding
        self.radius = radius
        self.compose = compose
        let width = menuTextInset * 2 + w * CGFloat(minColumns)
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: h * CGFloat(lines) + padding * 2 + 4))
        // NSMenu stretches width-resizable item views to the menu's full width.
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { backdrop == nil }

    /// Columns that fit between the text inset and the same inset on the right.
    var columns: Int {
        max(1, Int((bounds.width - (margin + padding) * 2) / cell.width))
    }

    override func draw(_ dirty: NSRect) {
        if let backdrop {
            backdrop.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: margin, dy: 2), xRadius: radius, yRadius: radius).fill()
        }
        let grid = compose(columns)
        let x0 = margin + padding, y0 = 2 + padding
        for (r, line) in grid.rows.enumerated() {
            var c = 0
            while c < line.count {
                let cl = line[c]
                // A run of one block colour paints as a single rect: per-cell
                // rects meet on fractional pixels and leave visible seams.
                if Self.runChars.contains(cl.ch) {
                    var e = c
                    while e + 1 < line.count, line[e + 1].ch == cl.ch, line[e + 1].fg == cl.fg,
                          line[e + 1].under == nil { e += 1 }
                    let run = NSRect(x: x0 + CGFloat(c) * cell.width, y: y0 + CGFloat(r) * cell.height,
                                     width: CGFloat(e - c + 1) * cell.width, height: cell.height)
                    _ = drawShape(cl.ch, in: run, color: cl.fg)
                    c = e + 1
                    continue
                }
                defer { c += 1 }
                let rect = NSRect(x: x0 + CGFloat(c) * cell.width, y: y0 + CGFloat(r) * cell.height,
                                  width: cell.width, height: cell.height)
                if let bg = cl.bg {
                    bg.setFill()
                    // Overlap neighbours by a hair so a run of backgrounds has no seams.
                    rect.insetBy(dx: -0.3, dy: 0).fill()
                }
                if let under = cl.under { _ = drawShape("░", in: rect, color: under) }
                if cl.ch == " " { continue }
                if drawShape(cl.ch, in: rect, color: cl.fg) { continue }
                drawGlyph(cl.ch, in: rect, color: cl.fg, bold: cl.bold)
            }
        }
        for s in grid.splitCells {
            let rect = NSRect(x: x0 + CGFloat(s.col) * cell.width, y: y0 + CGFloat(s.row) * cell.height,
                              width: cell.width, height: cell.height)
            _ = drawShape("╺", in: rect, color: s.right)
            _ = drawShape("╸", in: rect, color: s.left)
        }
    }

    /// Characters whose same-coloured runs are painted as one shape.
    static let runChars: Set<Character> = ["█", "░", "━", "─"]

    private func drawGlyph(_ ch: Character, in rect: NSRect, color: NSColor, bold: Bool) {
        let s = NSAttributedString(string: String(ch), attributes: [
            .font: bold ? boldFont : font, .foregroundColor: color,
        ])
        let size = s.size()
        // Centre fallback glyphs, which are narrower or wider than the cell.
        let x = rect.minX + (rect.width - size.width) / 2
        let y = rect.minY + (rect.height - size.height) / 2
        s.draw(at: NSPoint(x: x, y: y))
    }

    /// Box-drawing and block characters drawn as geometry, the way terminals do,
    /// so rules meet edge to edge instead of leaving the font's side bearings.
    private func drawShape(_ ch: Character, in r: NSRect, color: NSColor) -> Bool {
        let light: CGFloat = 1, heavy: CGFloat = 2.5
        let midX = r.midX, midY = r.midY
        // Block bars run at half the line height; full-height blocks would
        // stack into one slab across rows.
        let bar = backingAlignedRect(r.insetBy(dx: 0, dy: r.height / 4), options: .alignAllEdgesNearest)
        color.set()
        func hline(_ x0: CGFloat, _ x1: CGFloat, _ w: CGFloat) {
            backingAlignedRect(NSRect(x: x0, y: midY - w / 2, width: x1 - x0, height: w),
                               options: .alignAllEdgesNearest).fill()
        }
        func vline(_ y0: CGFloat, _ y1: CGFloat) {
            NSRect(x: midX - light / 2, y: y0, width: light, height: y1 - y0).fill()
        }
        func corner(from a: NSPoint, to b: NSPoint) {
            let p = NSBezierPath()
            p.lineWidth = light
            p.move(to: a)
            p.curve(to: b, controlPoint1: NSPoint(x: midX, y: midY), controlPoint2: NSPoint(x: midX, y: midY))
            p.stroke()
        }
        switch ch {
        case "─": hline(r.minX, r.maxX, light)
        case "━": hline(r.minX, r.maxX, heavy)
        case "╸": hline(r.minX, midX, heavy)
        case "╺": hline(midX, r.maxX, heavy)
        case "│": vline(r.minY, r.maxY)
        // Flipped view: minY is the top of the cell.
        case "╭": corner(from: NSPoint(x: r.maxX, y: midY), to: NSPoint(x: midX, y: r.maxY))
        case "╮": corner(from: NSPoint(x: r.minX, y: midY), to: NSPoint(x: midX, y: r.maxY))
        case "╰": corner(from: NSPoint(x: r.maxX, y: midY), to: NSPoint(x: midX, y: r.minY))
        case "╯": corner(from: NSPoint(x: r.minX, y: midY), to: NSPoint(x: midX, y: r.minY))
        case "├": vline(r.minY, r.maxY); hline(midX, r.maxX, light)
        case "┤": vline(r.minY, r.maxY); hline(r.minX, midX, light)
        case "█": bar.fill()
        case "▏", "▎", "▍", "▌", "▋", "▊", "▉":
            let eighths = CGFloat(Array("▏▎▍▌▋▊▉").firstIndex(of: ch)! + 1)
            NSRect(x: bar.minX, y: bar.minY, width: bar.width * eighths / 8, height: bar.height).fill()
        case "░":
            bar.fill()
        default:
            return false
        }
        return true
    }
}
