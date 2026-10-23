import AppKit

/// The menu bar glyph: the app icon's motifs (a monitor showing "2x" with a
/// magnifier) as a monochrome template image, so macOS tints it for light and
/// dark menu bars and for the highlighted state. Drawn in code, so it is sharp
/// at every scale.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static let image: NSImage = {
        let image = NSImage(size: size, flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "BetterDPI"
        return image
    }()

    /// Draws in an 18×18 pt space, origin bottom-left.
    static func draw() {
        NSColor.black.set()

        // Screen outline.
        let screen = NSBezierPath(roundedRect: NSRect(x: 1, y: 5, width: 16, height: 11.5), xRadius: 2, yRadius: 2)
        screen.lineWidth = 1.5
        screen.stroke()

        // Stand: neck and base.
        NSBezierPath(rect: NSRect(x: 8.1, y: 2.4, width: 1.8, height: 2.6)).fill()
        NSBezierPath(roundedRect: NSRect(x: 5.5, y: 1.2, width: 7, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()

        // "2x" on the screen, left of centre to leave room for the magnifier.
        let font = NSFont.systemFont(ofSize: 6.5, weight: .heavy)
        let text = NSAttributedString(string: "2x", attributes: [.font: font, .foregroundColor: NSColor.black])
        let t = text.size()
        text.draw(at: NSPoint(x: 6.2 - t.width / 2, y: 11.6 - t.height / 2))

        // Magnifier over the bottom-right corner, cut out from what is behind it.
        let center = NSPoint(x: 13.2, y: 6.6), radius: CGFloat = 2.6, gap: CGFloat = 1.1
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: center.x - radius - gap, y: center.y - radius - gap,
                                    width: 2 * (radius + gap), height: 2 * (radius + gap))).fill()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: center.x + radius * 0.7, y: center.y - radius * 0.7))
        handle.line(to: NSPoint(x: 16.3, y: 3.3))   // round cap stays inside the 18 pt canvas
        handle.lineWidth = 3.2
        handle.lineCapStyle = .round
        handle.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        let lens = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: 2 * radius, height: 2 * radius))
        lens.lineWidth = 1.3
        lens.stroke()
        handle.lineWidth = 1.5
        handle.stroke()
    }
}
