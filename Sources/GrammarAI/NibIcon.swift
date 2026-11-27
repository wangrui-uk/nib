import AppKit

/// Nib's icons, drawn in code so they're crisp at any size: a fountain-pen nib pointing down-left.
enum NibIcon {
    enum MenuState: String, CaseIterable { case idle, working, attention, off }

    // MARK: Geometry (unit square, y up, nib pointing down before rotation)

    /// The nib outline.
    static func outline() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0.5, y: 0.03))
        p.curve(to: NSPoint(x: 0.19, y: 0.57), controlPoint1: NSPoint(x: 0.33, y: 0.22), controlPoint2: NSPoint(x: 0.19, y: 0.40))
        p.curve(to: NSPoint(x: 0.28, y: 0.93), controlPoint1: NSPoint(x: 0.19, y: 0.72), controlPoint2: NSPoint(x: 0.24, y: 0.84))
        p.line(to: NSPoint(x: 0.72, y: 0.93))
        p.curve(to: NSPoint(x: 0.81, y: 0.57), controlPoint1: NSPoint(x: 0.76, y: 0.84), controlPoint2: NSPoint(x: 0.81, y: 0.72))
        p.curve(to: NSPoint(x: 0.5, y: 0.03), controlPoint1: NSPoint(x: 0.81, y: 0.40), controlPoint2: NSPoint(x: 0.67, y: 0.22))
        p.close()
        return p
    }

    static let holeCenter = NSPoint(x: 0.5, y: 0.54)
    static let holeRadius: CGFloat = 0.065

    static func slit() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0.5, y: 0.03))
        p.line(to: NSPoint(x: 0.5, y: holeCenter.y - holeRadius))
        return p
    }

    static func hole() -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: holeCenter.x - holeRadius, y: holeCenter.y - holeRadius, width: holeRadius * 2, height: holeRadius * 2))
    }

    static func collar() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0.235, y: 0.80))
        p.line(to: NSPoint(x: 0.765, y: 0.80))
        return p
    }

    /// Maps the unit nib into `rect`, rotated so it points down-left.
    static func transform(into rect: NSRect, scale: CGFloat = 0.92) -> AffineTransform {
        var t = AffineTransform.identity
        t.translate(x: rect.midX, y: rect.midY)
        t.rotate(byDegrees: -45)
        t.scale(rect.width * scale)
        t.translate(x: -0.5, y: -0.48)
        return t
    }

    /// A four-pointed sparkle.
    static func sparkle(center c: NSPoint, radius r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let w = r * 0.28
        p.move(to: NSPoint(x: c.x, y: c.y + r))
        p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
        p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
        p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
        p.close()
        return p
    }

    // MARK: Menu bar (template, 18 pt)

    static func menuBar(_ state: MenuState, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let u = r.width / 18 // points per design unit at 18 pt
            // Leave the bottom-left corner free for the sparkle when working.
            let box = state == .working ? NSRect(x: r.minX + 3.2 * u, y: r.minY + 3.2 * u, width: 14.6 * u, height: 14.6 * u)
                                        : r.insetBy(dx: 0.6 * u, dy: 0.6 * u)
            let t = transform(into: box)
            let alpha: CGFloat = state == .off ? 0.45 : 1
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let o = outline(); o.transform(using: t); o.lineWidth = 1.35 * u; o.lineJoinStyle = .round; o.stroke()
            let s = slit(); s.transform(using: t); s.lineWidth = 1.1 * u; s.lineCapStyle = .round; s.stroke()
            NSColor.black.withAlphaComponent(alpha).setFill()
            let h = hole(); h.transform(using: t); h.fill()

            switch state {
            case .idle: break
            case .working:
                NSColor.black.setFill()
                sparkle(center: NSPoint(x: r.minX + 3.0 * u, y: r.minY + 3.0 * u), radius: 3.0 * u).fill()
            case .attention:
                // A badge in the top-right corner, with a clear ring so it reads against the outline.
                let c = NSPoint(x: r.maxX - 3.4 * u, y: r.maxY - 3.4 * u)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: c.x - 3.8 * u, y: c.y - 3.8 * u, width: 7.6 * u, height: 7.6 * u)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 2.6 * u, y: c.y - 2.6 * u, width: 5.2 * u, height: 5.2 * u)).fill()
            case .off:
                // A thin slash across, with a clear gap either side.
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: r.minX + 2 * u, y: r.maxY - 2 * u))
                slash.line(to: NSPoint(x: r.maxX - 2 * u, y: r.minY + 2 * u))
                NSGraphicsContext.current?.compositingOperation = .clear
                slash.lineWidth = 3.4 * u; slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                slash.lineWidth = 1.3 * u; slash.lineCapStyle = .round; slash.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Nib"
        return img
    }

    // MARK: App icon

    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let k = r.width / 1024
            // macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
            let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
            let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 18 * k
            shadow.shadowOffset = NSSize(width: 0, height: -8 * k)
            shadow.set()
            NSColor.black.setFill(); shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let ink = NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.24, blue: 0.80, alpha: 1),
                                          NSColor(srgbRed: 0.16, green: 0.14, blue: 0.45, alpha: 1)])!
            ink.draw(in: body, angle: -60)
            // A soft light from the top-left, fading to nothing well inside the edge.
            let glow = NSGradient(colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0.05), NSColor(white: 1, alpha: 0)])!
            glow.draw(in: NSBezierPath(rect: body), relativeCenterPosition: NSPoint(x: -0.35, y: 0.35))
            NSGraphicsContext.restoreGraphicsState()

            let t = transform(into: body.insetBy(dx: 150 * k, dy: 150 * k).offsetBy(dx: 30 * k, dy: 30 * k), scale: 1.0)
            let cream = NSColor(srgbRed: 1.0, green: 0.965, blue: 0.90, alpha: 1)
            let o = outline(); o.transform(using: t)
            cream.setFill(); o.fill()
            let cut = NSColor(srgbRed: 0.24, green: 0.19, blue: 0.58, alpha: 1)
            cut.setStroke()
            let s = slit(); s.transform(using: t); s.lineWidth = 16 * k; s.lineCapStyle = .round; s.stroke()
            cut.setFill()
            let h = hole(); h.transform(using: t); h.fill()
            let c = collar(); c.transform(using: t); c.lineWidth = 12 * k; c.lineCapStyle = .round
            cut.withAlphaComponent(0.55).setStroke(); c.stroke()

            // The sparkle at the tip.
            let tip = t.transform(NSPoint(x: 0.5, y: 0.03))
            let gold = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.42, alpha: 1)
            gold.setFill()
            sparkle(center: NSPoint(x: tip.x - 62 * k, y: tip.y - 62 * k), radius: 78 * k).fill()
            sparkle(center: NSPoint(x: tip.x + 40 * k, y: tip.y - 120 * k), radius: 34 * k).fill()
            return true
        }
    }

    // MARK: Files

    static func png(_ img: NSImage, pixels: Int, height: Int? = nil) -> Data? {
        let h = height ?? pixels
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: pixels, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// `Nib --make-icons DIR`: AppIcon.iconset plus preview strips for checking by eye.
    static func writeAll(to dir: String) {
        let base = URL(fileURLWithPath: dir)
        let iconset = base.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                try? png(appIcon(size: CGFloat(pt * scale)), pixels: pt * scale)?.write(to: iconset.appendingPathComponent(name))
            }
        }
        // App icon at 16/32/128/512 side by side.
        let sizes: [CGFloat] = [16, 32, 128, 512]
        let strip = NSImage(size: NSSize(width: sizes.reduce(0, +) + 50, height: 520), flipped: false) { r in
            NSColor(white: 0.93, alpha: 1).setFill(); r.fill()
            var x: CGFloat = 10
            for s in sizes { appIcon(size: s).draw(in: NSRect(x: x, y: (520 - s) / 2, width: s, height: s)); x += s + 10 }
            return true
        }
        try? png(strip, pixels: Int(strip.size.width), height: Int(strip.size.height)).map { try $0.write(to: base.appendingPathComponent("nib-appicon-sizes.png")) }
        // Menu bar states on a light and a dark bar, at 2x for inspection.
        for dark in [false, true] {
            let states = MenuState.allCases
            let w: CGFloat = CGFloat(states.count) * 40 + 10
            let img = NSImage(size: NSSize(width: w, height: 30), flipped: false) { r in
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill(); r.fill()
                for (i, st) in states.enumerated() {
                    let icon = menuBar(st)
                    let tinted = NSImage(size: icon.size, flipped: false) { ir in
                        icon.draw(in: ir)
                        (dark ? NSColor.white : NSColor.black).set()
                        ir.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: 15 + CGFloat(i) * 40, y: 6, width: 18, height: 18))
                }
                return true
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 4), pixelsHigh: 120, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = img.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            img.draw(in: NSRect(origin: .zero, size: img.size))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathComponent(dark ? "nib-menubar-dark.png" : "nib-menubar-light.png"))
        }
    }
}
