import Cocoa

protocol Spinning: AnyObject {
    func start()
    func stop()
}

/// A spinner that costs no per-frame CPU.
///
/// Animating by re-setting the status item's title measured ~13ms a frame,
/// because it forces the whole menu bar to re-measure. This instead is a
/// fixed-size layer-backed view with a Core Animation rotation: the layer is
/// handed to the compositor once and spun on the GPU, so nothing wakes per frame.
final class SpinnerView: NSView, Spinning {
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(arc)

        let inset: CGFloat = 2.5
        let box = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: box.midX, y: box.midY),
                    radius: box.width / 2,
                    startAngle: 0, endAngle: .pi * 1.45, clockwise: false)
        arc.path = path
        arc.fillColor = nil
        arc.lineWidth = 1.6
        arc.lineCap = .round
        arc.frame = bounds
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateColor() {
        arc.strokeColor = NSColor.labelColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { updateColor() }
    }

    func start() {
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 1.0
        spin.repeatCount = .infinity
        // Survives the layer being detached and re-attached as the menu bar redraws.
        spin.isRemovedOnCompletion = false
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arc.frame = bounds
        arc.add(spin, forKey: "spin")
    }

    func stop() {
        arc.removeAnimation(forKey: "spin")
    }
}

/// Claude Code's thinking glyph, cycling ✢ ✳ ✶ ✻ ✽ and back. Same cost model as
/// SpinnerView: the frames are images handed to Core Animation once, and a
/// discrete keyframe animation swaps them on the compositor.
final class GlyphSpinnerView: NSView, Spinning {
    private let glyph = CALayer()
    private let frames: [CGImage]

    init(frame: NSRect, color: NSColor) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let cycle = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
        frames = cycle.compactMap { Self.render($0, size: frame.size, scale: scale, color: color) }
        super.init(frame: frame)
        wantsLayer = true
        glyph.frame = bounds
        glyph.contentsScale = scale
        glyph.contents = frames.dropFirst(4).first
        layer?.addSublayer(glyph)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func render(_ s: String, size: NSSize, scale: CGFloat, color: NSColor) -> CGImage? {
        let px = NSSize(width: size.width * scale, height: size.height * scale)
        let font = NSFont.systemFont(ofSize: size.height * scale * 0.95, weight: .bold)
        let text = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let img = NSImage(size: px, flipped: false) { r in
            let t = text.size()
            text.draw(at: NSPoint(x: (r.width - t.width) / 2, y: (r.height - t.height) / 2))
            return true
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func start() {
        guard glyph.animation(forKey: "cycle") == nil, !frames.isEmpty else { return }
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = frames
        a.calculationMode = .discrete
        a.duration = 0.12 * Double(frames.count)
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        glyph.add(a, forKey: "cycle")
    }

    func stop() {
        glyph.removeAnimation(forKey: "cycle")
    }
}
