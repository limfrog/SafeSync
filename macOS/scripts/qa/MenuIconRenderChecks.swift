import AppKit

@main struct MenuRenderChecks {
    static func render(_ angle: CGFloat, warning: Bool = false, scale: Int = 2) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        BrandIcon.menuImage(angle: angle, warning: warning).draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func main() throws {
        var frames: [NSBitmapImageRep] = []
        var checks: [String] = []
        for i in 0..<24 {
            let frame = render(-CGFloat(i) * .pi / 12)
            frames.append(frame)
            var count = 0
            for y in 0..<32 { for x in 0..<32 { if (frame.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { count += 1 } } }
            precondition(count > 450, "Animation frame disappeared")
        }
        checks.append("PASS: all 24 frames retain visible artwork at 16pt / Retina 32px")
        let shieldPixel = frames[0].colorAt(x: 16, y: 2)!
        precondition(shieldPixel.alphaComponent > 0.2)
        for frame in frames { precondition(frame.colorAt(x: 16, y: 2)! == shieldPixel, "Shield moved") }
        checks.append("PASS: top of shield stays at exactly the same position and color")
        precondition(frames[0].representation(using: .png, properties: [:]) != frames[6].representation(using: .png, properties: [:]))
        checks.append("PASS: arrows change between quarter-turn frames")
        for i in 0..<24 { precondition(render(-CGFloat(i) * .pi / 12, warning: true).colorAt(x: 27, y: 28)!.alphaComponent > 0.8) }
        checks.append("PASS: warning badge remains visible during rotation")
        let contact = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 768, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: contact)
        NSColor(calibratedWhite: 0.15, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 768, height: 128).fill()
        for i in 0..<6 { BrandIcon.menuImage(angle: -CGFloat(i) * .pi / 3, warning: false).draw(in: NSRect(x: i * 128 + 16, y: 16, width: 96, height: 96)) }
        NSGraphicsContext.restoreGraphicsState()
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/SafeSyncMenuRenderChecks")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try contact.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("메뉴바-회전-프레임.png"))
        try (checks.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("메뉴바-렌더링-검증.txt"), atomically: true, encoding: .utf8)
        print(checks.joined(separator: "\n"))
    }
}
