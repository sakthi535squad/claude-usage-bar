import Cocoa

/// A spinner that costs no per-frame CPU.
///
/// Animating by re-setting the status item's title measured ~13ms a frame,
/// because it forces the whole menu bar to re-measure. This instead is a
/// fixed-size layer-backed view with a Core Animation rotation: the layer is
/// handed to the compositor once and spun on the GPU, so nothing wakes per frame.
final class SpinnerView: NSView {
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
