import Cocoa

extension AppDelegate {
    /// `--demo --snapshot <png>`: opens the real NSMenu, captures it, then quits. Needs Screen Recording
    /// permission for whichever app launched it.
    func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            // Menu tracking runs the loop in event-tracking mode, so the capture
            // timer has to be scheduled in common modes to fire while it is open.
            // The menu window can take a moment to reach the window list, so
            // poll for it rather than trusting one fixed delay.
            var tries = 0
            let capture = Timer(timeInterval: 0.5, repeats: true) { timer in
                tries += 1
                guard let window = menuWindowID() else {
                    if tries < 10 { return }
                    print("menu never appeared"); exit(1)
                }
                // Capturing the one window, not a screen rect, keeps whatever is
                // on screen around the menu out of the image.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(window), path]
                try? p.run()
                p.waitUntilExit()
                // A window still animating in can refuse capture; try again.
                if p.terminationStatus != 0, tries < 10 { return }
                timer.invalidate()
                self.item.menu?.cancelTracking()
                print(p.terminationStatus == 0 ? "wrote \(path)" : "capture failed: \(path)")
                exit(p.terminationStatus)
            }
            RunLoop.main.add(capture, forMode: .common)
            // A crowded menu bar hides new items behind the notch, where a
            // simulated click opens nothing, so the menu is popped up directly.
            guard let menu = item.menu, let screen = NSScreen.main else { exit(1) }
            // Away from the cursor, or whichever row it rests on is highlighted.
            let left = NSEvent.mouseLocation.x > screen.frame.midX
            let at = NSPoint(x: left ? screen.frame.minX + 40 : screen.frame.midX + 40,
                             y: screen.visibleFrame.maxY - 20)
            menu.popUp(positioning: nil, at: at, in: nil)
        }
    }
}

/// The open menu: this process's largest on-screen window below the menu bar.
func menuWindowID() -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: (id: CGWindowID, area: CGFloat)?
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == getpid() {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              (b["Y"] ?? 0) >= 40 else { continue }
        let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
        if area > best?.area ?? 0 { best = (id, area) }
    }
    return best?.id
}

/// `--demo --render-bar <png>`: every theme's menu bar title on demo data, on
/// dark and light menu bar strips. A crowded menu bar hides new status items
/// behind the notch, so this draws the same attributed title offscreen.
func renderBarPreview(to path: String) {
    let now = Date()
    let u = Demo.usage(now: now), agents = Demo.agents(now: now)
    let rowH: CGFloat = 30, labelW: CGFloat = 110, stripW: CGFloat = 330, gap: CGFloat = 10
    let modes: [(NSAppearance.Name, NSColor)] = [
        (.darkAqua, NSColor(white: 0.12, alpha: 1)),
        (.aqua, NSColor(white: 0.93, alpha: 1)),
    ]
    let size = NSSize(width: labelW + (stripW + gap) * CGFloat(modes.count) + gap,
                      height: rowH * CGFloat(Theme.allCases.count) + gap * CGFloat(Theme.allCases.count + 1))
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.18, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    for (i, theme) in Theme.allCases.enumerated() {
        let y = size.height - gap - CGFloat(i + 1) * (rowH + gap) + gap
        NSAttributedString(string: theme.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: gap, y: y + 8))
        for (m, (name, back)) in modes.enumerated() {
            let strip = NSRect(x: labelW + CGFloat(m) * (stripW + gap), y: y, width: stripW, height: rowH)
            back.setFill()
            NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6).fill()
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                let title = composeTitle(menuBarSegments(theme.style, u, agents))
                let t = title.size()
                let origin = NSPoint(x: strip.maxX - t.width - 14, y: strip.midY - t.height / 2)
                title.draw(at: origin)
                // The spinner is a separate layer in the app; draw one frame of it
                // centred in the placeholder run, as positionSpinner places it.
                guard let suffix = agentSuffix(agents) else { return }
                let font = AppDelegate.barFont
                let suffixW = (suffix as NSString).size(withAttributes: [.font: font]).width
                let gapW = (spinnerPlaceholder as NSString).size(withAttributes: [.font: font]).width
                let s = AppDelegate.spinnerSize
                let box = NSRect(x: origin.x + t.width - suffixW + (gapW - s) / 2, y: strip.midY - s / 2,
                                 width: s, height: s)
                if theme == .claude {
                    let g = NSAttributedString(string: "✻", attributes: [
                        .font: NSFont.systemFont(ofSize: s * 0.95, weight: .bold), .foregroundColor: claudeOrange,
                    ])
                    let gs = g.size()
                    g.draw(at: NSPoint(x: box.midX - gs.width / 2, y: box.midY - gs.height / 2))
                } else {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: box.midX, y: box.midY), radius: s / 2 - 2.5,
                                  startAngle: 90, endAngle: 90 + 261, clockwise: false)
                    arc.lineWidth = 1.6
                    arc.lineCapStyle = .round
                    NSColor.labelColor.setStroke()
                    arc.stroke()
                }
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
