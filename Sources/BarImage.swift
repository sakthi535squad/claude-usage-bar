import Cocoa

/// The menu bar sits on top of the wallpaper, so plain coloured text has no
/// guaranteed contrast. Each segment is drawn on its own opaque pill instead;
/// foregrounds are picked for >=4.5:1 against their pill.
func pillColors(for pct: Double) -> (bg: NSColor, fg: NSColor) {
    if pct >= 90 {
        // systemRed only reaches 3.55:1 against white text; this red gives 5.43:1.
        return (NSColor(srgbRed: 0.80, green: 0.15, blue: 0.12, alpha: 1), .white)
    }
    if pct >= 70 {
        return (.systemOrange, .black)  // 9.55:1
    }
    // Healthy: no alarm colour, but still opaque — a translucent pill lets a
    // midtone wallpaper through and the contrast stops being predictable.
    let neutral = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.30, alpha: 1)   // white text on this: 8.5:1
            : NSColor(white: 0.82, alpha: 1)   // black text on this: 13.8:1
    }
    return (neutral, .labelColor)
}

enum Bar {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let padH: CGFloat = 5
    static let gap: CGFloat = 4
    static let pillHeight: CGFloat = 15
    static let imageHeight: CGFloat = 18
}

/// Renders the segments as a row of pills. Returned as an image because
/// NSStatusItem titles cannot draw a rounded background.
func titleImage(_ segments: [(text: String, pct: Double)],
                appearance: NSAppearance) -> NSImage {
    let attrsFor: (NSColor) -> [NSAttributedString.Key: Any] = {
        [.font: Bar.font, .foregroundColor: $0]
    }
    let sizes = segments.map { $0.text.size(withAttributes: attrsFor(.black)) }
    let width = sizes.reduce(0) { $0 + $1.width + Bar.padH * 2 }
        + Bar.gap * CGFloat(max(0, segments.count - 1))

    let image = NSImage(size: NSSize(width: max(1, width), height: Bar.imageHeight))
    image.lockFocus()
    appearance.performAsCurrentDrawingAppearance {
        var x: CGFloat = 0
        let y = (Bar.imageHeight - Bar.pillHeight) / 2
        for (i, seg) in segments.enumerated() {
            let colors = pillColors(for: seg.pct)
            let w = sizes[i].width + Bar.padH * 2
            let rect = NSRect(x: x, y: y, width: w, height: Bar.pillHeight)
            colors.bg.setFill()
            NSBezierPath(roundedRect: rect,
                         xRadius: Bar.pillHeight / 2,
                         yRadius: Bar.pillHeight / 2).fill()

            let attrs = attrsFor(colors.fg)
            let textY = y + (Bar.pillHeight - sizes[i].height) / 2
            seg.text.draw(at: NSPoint(x: x + Bar.padH, y: textY), withAttributes: attrs)
            x += w + Bar.gap
        }
    }
    image.unlockFocus()
    // Template images are recoloured by the system, which would erase the pills.
    image.isTemplate = false
    return image
}

/// Writes menu bar previews over several backdrops, to check the pills hold up
/// against any wallpaper. Status items never appear in screencapture output.
func renderBarPreview(_ segments: [(text: String, pct: Double)], to path: String) {
    let backdrops: [(String, NSColor, NSAppearance.Name)] = [
        ("dark", NSColor(white: 0.12, alpha: 1), .darkAqua),
        ("light", NSColor(white: 0.95, alpha: 1), .aqua),
        ("midtone", NSColor(srgbRed: 0.45, green: 0.52, blue: 0.40, alpha: 1), .darkAqua),
        ("bright", NSColor(srgbRed: 0.98, green: 0.85, blue: 0.35, alpha: 1), .aqua),
    ]
    let rowH: CGFloat = 26
    let sample = titleImage(segments, appearance: NSAppearance(named: .darkAqua)!)
    let width = sample.size.width + 40

    let out = NSImage(size: NSSize(width: width, height: rowH * CGFloat(backdrops.count)))
    out.lockFocus()
    for (i, b) in backdrops.enumerated() {
        let y = CGFloat(backdrops.count - 1 - i) * rowH
        b.1.setFill()
        NSRect(x: 0, y: y, width: width, height: rowH).fill()
        let img = titleImage(segments, appearance: NSAppearance(named: b.2)!)
        img.draw(at: NSPoint(x: 20, y: y + (rowH - Bar.imageHeight) / 2),
                 from: .zero, operation: .sourceOver, fraction: 1)
    }
    out.unlockFocus()

    guard let tiff = out.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
