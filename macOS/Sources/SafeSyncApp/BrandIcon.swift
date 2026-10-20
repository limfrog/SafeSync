import AppKit

// Keep the original full-size artwork for the app, Dock and About window.
enum BrandIcon {
    static var image: NSImage {
        let url = Bundle.main.resourceURL?.appendingPathComponent("SafeSync.png")
        let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/SafeSync.png")
        let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(contentsOf: original) ?? NSImage()
        image.isTemplate = false
        return image
    }
    static func usesMonochromeMenuIcon(appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Menu-bar artwork uses independent layers so the shield never rotates or clips.
    static func menuImage(angle: CGFloat, warning: Bool, monochrome: Bool = false) -> NSImage {
        let result = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: 8, y: 15.3))
            shield.line(to: NSPoint(x: 14.6, y: 12.2))
            shield.curve(to: NSPoint(x: 8, y: 0.8), controlPoint1: NSPoint(x: 14.8, y: 6.0), controlPoint2: NSPoint(x: 12.9, y: 2.7))
            shield.curve(to: NSPoint(x: 1.4, y: 12.2), controlPoint1: NSPoint(x: 3.1, y: 2.7), controlPoint2: NSPoint(x: 1.2, y: 6.0))
            shield.close()
            if monochrome {
                NSColor.black.setStroke()
                shield.lineWidth = 1.0; shield.lineJoinStyle = .round; shield.stroke()
            } else {
                NSGradient(starting: NSColor(red: 0.03, green: 0.34, blue: 0.87, alpha: 1),
                           ending: NSColor(red: 0.01, green: 0.12, blue: 0.43, alpha: 1))?.draw(in: shield, angle: -90)
                NSColor(red: 0.16, green: 0.58, blue: 1, alpha: 1).setStroke()
                shield.lineWidth = 0.65; shield.stroke()
            }

            // Explicit translate/rotate/translate keeps the arrow layer centered at (8, 8).
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext.current?.cgContext {
                context.translateBy(x: 8, y: 8)
                context.rotate(by: angle)
                context.translateBy(x: -8, y: -8)
            }
            drawArrow(start: 195, end: 60, color: monochrome ? .black : NSColor(red: 0.17, green: 0.93, blue: 0.13, alpha: 1), outline: monochrome)
            drawArrow(start: 15, end: -120, color: monochrome ? .black : NSColor(red: 1, green: 0.69, blue: 0.02, alpha: 1), outline: monochrome)
            NSGraphicsContext.restoreGraphicsState()
            if warning {
                (monochrome ? NSColor.black : NSColor.systemOrange).setFill()
                NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 5, height: 5)).fill()
            }
            return true
        }
        result.isTemplate = monochrome
        return result
    }

    private static func drawArrow(start: CGFloat, end: CGFloat, color: NSColor, outline: Bool) {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 8, y: 8), radius: 4.5, startAngle: start, endAngle: end, clockwise: true)
        arc.lineWidth = outline ? 1.1 : 2.15; arc.lineCapStyle = .round
        color.setStroke(); arc.stroke()
        let radians = end * .pi / 180
        let tip = NSPoint(x: 8 + 4.5 * cos(radians), y: 8 + 4.5 * sin(radians))
        let tangent = NSPoint(x: sin(radians), y: -cos(radians))
        let normal = NSPoint(x: cos(radians), y: sin(radians))
        let head = NSBezierPath()
        if outline {
            head.move(to: NSPoint(x: tip.x - tangent.x * 1.3 + normal.x * 1.3, y: tip.y - tangent.y * 1.3 + normal.y * 1.3))
            head.line(to: NSPoint(x: tip.x + tangent.x * 0.7, y: tip.y + tangent.y * 0.7))
            head.line(to: NSPoint(x: tip.x - tangent.x * 1.3 - normal.x * 1.3, y: tip.y - tangent.y * 1.3 - normal.y * 1.3))
            head.lineWidth = 1.1; head.lineCapStyle = .round; head.lineJoinStyle = .round
            color.setStroke(); head.stroke()
        } else {
            head.move(to: NSPoint(x: tip.x + tangent.x * 1.25, y: tip.y + tangent.y * 1.25))
            head.line(to: NSPoint(x: tip.x - tangent.x * 1.5 + normal.x * 1.65, y: tip.y - tangent.y * 1.5 + normal.y * 1.65))
            head.line(to: NSPoint(x: tip.x - tangent.x * 1.5 - normal.x * 1.65, y: tip.y - tangent.y * 1.5 - normal.y * 1.65))
            head.close(); color.setFill(); head.fill()
        }
    }
}
