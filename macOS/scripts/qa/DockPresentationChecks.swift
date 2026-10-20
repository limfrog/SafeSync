import AppKit

@main @MainActor final class DockChecks: NSObject, NSApplicationDelegate {
    private var presentation: AppPresentation?
    private var windows: [NSWindow] = []
    private var status: NSStatusItem?
    private var ticks = 0
    private var clock: Timer?
    private var results: [String] = []
    static func main() {
        let app = NSApplication.shared
        let delegate = DockChecks()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        presentation = AppPresentation()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.title = "QA"
        clock = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ticks += 1 }
        }
        Task { @MainActor in await runChecks() }
    }
    func pause() async { try? await Task.sleep(for: .milliseconds(350)) }
    func check(_ condition: Bool, _ label: String) {
        results.append("\(condition ? "PASS" : "FAIL"): \(label)")
    }
    func window(_ title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 240), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false; windows.append(w); return w
    }
    func runChecks() async {
        let main = window("SafeSync Dock QA")
        main.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); await pause()
        check(NSApp.activationPolicy() == .regular, "visible main window uses Dock")
        main.close(); await pause()
        check(NSApp.activationPolicy() == .accessory, "closing last window hides Dock")
        let oldTicks = ticks; await pause()
        check(NSApp.isRunning && ticks > oldTicks && status?.button != nil, "process, background timer and menu-bar item survive close")
        AppPresentation.showInDock(); main.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); await pause()
        check(NSApp.activationPolicy() == .regular && main.isVisible, "menu-bar reopen restores Dock and main window")
        main.miniaturize(nil); await pause()
        check(NSApp.activationPolicy() == .regular, "minimizing preserves normal Dock behavior")
        main.deminiaturize(nil); await pause()
        let settings = window("Settings QA"); settings.makeKeyAndOrderFront(nil); await pause()
        main.close(); await pause()
        check(NSApp.activationPolicy() == .regular, "another visible settings window keeps Dock available")
        settings.close(); await pause()
        check(NSApp.activationPolicy() == .accessory, "closing remaining settings window hides Dock")
        AppPresentation.showInDock(); main.makeKeyAndOrderFront(nil); await pause()
        main.close(); await pause()
        check(NSApp.activationPolicy() == .accessory, "repeated reopen-close cycle remains stable")
        try? (results.joined(separator: "\n") + "\n").write(toFile: "/private/tmp/safesync-dock-checks.txt", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
