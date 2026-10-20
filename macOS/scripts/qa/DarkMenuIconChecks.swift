import AppKit

@main struct DarkMenuIconChecks {
    static func render(angle: CGFloat, warning: Bool = false) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        BrandIcon.menuImage(angle: angle, warning: warning, monochrome: true).draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func main() throws {
        var checks: [String] = []
        for name: NSAppearance.Name in [.darkAqua, .accessibilityHighContrastDarkAqua] {
            precondition(BrandIcon.usesMonochromeMenuIcon(appearance: NSAppearance(named: name)!))
        }
        for name: NSAppearance.Name in [.aqua, .accessibilityHighContrastAqua] {
            precondition(!BrandIcon.usesMonochromeMenuIcon(appearance: NSAppearance(named: name)!))
        }
        checks.append("PASS: light/dark and high-contrast appearances select the expected artwork")
        precondition(BrandIcon.menuImage(angle: 0, warning: false, monochrome: true).isTemplate)
        precondition(!BrandIcon.menuImage(angle: 0, warning: false).isTemplate)
        checks.append("PASS: dark outline is an AppKit template; light artwork retains color")
        var frames: [NSBitmapImageRep] = []
        for i in 0..<24 {
            let frame = render(angle: -CGFloat(i) * .pi / 12)
            var visible = 0
            for y in 0..<32 { for x in 0..<32 {
                let c = frame.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if c.alphaComponent > 0.1 {
                    visible += 1
                    precondition(max(c.redComponent, c.greenComponent, c.blueComponent) < 0.02)
                }
            } }
            precondition(visible > 150)
            precondition(frame.colorAt(x: 16, y: 16)!.alphaComponent < 0.05, "Outline must have a transparent center")
            frames.append(frame)
        }
        checks.append("PASS: 24 frames contain black/clear outline artwork, remain visible, and have transparent centers")
        let fixed = frames[0].colorAt(x: 16, y: 2)!
        precondition(fixed.alphaComponent > 0.2)
        for frame in frames { precondition(frame.colorAt(x: 16, y: 2)! == fixed) }
        precondition(frames[0].representation(using: .png, properties: [:]) != frames[6].representation(using: .png, properties: [:]))
        checks.append("PASS: shield stays fixed while arrows change")
        for i in 0..<24 { precondition(render(angle: -CGFloat(i) * .pi / 12, warning: true).colorAt(x: 27, y: 28)!.alphaComponent > 0.8) }
        checks.append("PASS: monochrome warning indicator stays visible")

        let contact = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 768, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: contact)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 768, height: 128).fill()
        for i in 0..<6 {
            // Tint a copy for a legible enlarged preview; AppKit tints the actual template status item.
            let icon = BrandIcon.menuImage(angle: -CGFloat(i) * .pi / 3, warning: i == 5, monochrome: true)
            let preview = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                icon.draw(in: rect)
                NSColor.white.setFill(); rect.fill(using: .sourceIn)
                return true
            }
            preview.draw(in: NSRect(x: i * 128 + 16, y: 16, width: 96, height: 96))
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/SafeSyncDarkMenuIconChecks")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try contact.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("다크모드-메뉴바-미리보기.png"))
        try (checks.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("다크모드-아이콘-검증.txt"), atomically: true, encoding: .utf8)
        print(checks.joined(separator: "\n"))
    }
}
