import Cocoa

enum Bar {
    /// The original menu bar font, unchanged.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let padH: CGFloat = 6
    static let boxHeight: CGFloat = 17
    static let imageHeight: CGFloat = 19
    static let radius: CGFloat = 4
    static let separator = "  "

    /// A dark box behind everything, so the text colours read the same over any
    /// wallpaper and in either theme. Near-opaque rather than solid, to sit more
    /// naturally in the menu bar.
    static let boxFill = NSColor(white: 0.0, alpha: 0.78)
}

/// Text colour on the dark box. systemOrange/systemRed are the original values;
/// neutral is white because the box, not the menu bar, is now the background.
func barTextColor(for pct: Double) -> NSColor {
    if pct >= 90 { return .systemRed }
    if pct >= 70 { return .systemOrange }
    return .white
}

/// Renders the segments as one boxed run of text. Returned as an image because
/// an NSStatusItem title cannot draw a background behind itself.
func titleImage(_ segments: [(text: String, pct: Double)],
                appearance: NSAppearance) -> NSImage {
    let run = NSMutableAttributedString()
    for (i, seg) in segments.enumerated() {
        if i > 0 {
            run.append(NSAttributedString(string: Bar.separator, attributes: [.font: Bar.font]))
        }
        run.append(NSAttributedString(string: seg.text, attributes: [
            .font: Bar.font,
            .foregroundColor: barTextColor(for: seg.pct),
        ]))
    }

    let textSize = run.size()
    let width = textSize.width + Bar.padH * 2
    let image = NSImage(size: NSSize(width: max(1, width), height: Bar.imageHeight))

    image.lockFocus()
    appearance.performAsCurrentDrawingAppearance {
        let boxY = (Bar.imageHeight - Bar.boxHeight) / 2
        let box = NSRect(x: 0, y: boxY, width: width, height: Bar.boxHeight)
        Bar.boxFill.setFill()
        NSBezierPath(roundedRect: box, xRadius: Bar.radius, yRadius: Bar.radius).fill()
        run.draw(at: NSPoint(x: Bar.padH, y: boxY + (Bar.boxHeight - textSize.height) / 2))
    }
    image.unlockFocus()
    // Template images get recoloured by the system, which would flatten the box.
    image.isTemplate = false
    return image
}

/// Writes menu bar previews over several backdrops. Status items never appear in
/// screencapture output, so this is the only way to check how it reads.
func renderBarPreview(_ segments: [(text: String, pct: Double)], to path: String) {
    let backdrops: [(NSColor, NSAppearance.Name)] = [
        (NSColor(white: 0.12, alpha: 1), .darkAqua),
        (NSColor(white: 0.95, alpha: 1), .aqua),
        (NSColor(srgbRed: 0.45, green: 0.52, blue: 0.40, alpha: 1), .darkAqua),
        (NSColor(srgbRed: 0.98, green: 0.85, blue: 0.35, alpha: 1), .aqua),
    ]
    let rowH: CGFloat = 26
    let width = titleImage(segments, appearance: NSAppearance(named: .darkAqua)!).size.width + 40

    // Drawn at 2x: the menu bar is Retina, and 1x antialiasing makes thin text
    // look duller than it really is.
    let totalH = rowH * CGFloat(backdrops.count)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(totalH * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return }
    rep.size = NSSize(width: width, height: totalH)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (i, b) in backdrops.enumerated() {
        let y = CGFloat(backdrops.count - 1 - i) * rowH
        b.0.setFill()
        NSRect(x: 0, y: y, width: width, height: rowH).fill()
        titleImage(segments, appearance: NSAppearance(named: b.1)!)
            .draw(at: NSPoint(x: 20, y: y + (rowH - Bar.imageHeight) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
