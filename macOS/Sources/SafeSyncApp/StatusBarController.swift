import AppKit
import Combine

/// Let AppKit allocate a normal square status item; SwiftUI view layout must not determine its size.
@MainActor final class StatusBarController: NSObject {
    private let store: Store
    private let item: NSStatusItem
    private let progressItem = NSMenuItem(title: "동기화 상태", action: nil, keyEquivalent: "")
    private var observation: AnyCancellable?
    private var animation: Timer?

    init(store: Store) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
        let menu = NSMenu(title: "SafeSync")
        let open = NSMenuItem(title: "SafeSync 열기", action: #selector(showMain), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        progressItem.target = self; progressItem.action = #selector(showProgress); menu.addItem(progressItem)
        menu.addItem(.separator())
        let run = NSMenuItem(title: "모든 작업 백업", action: #selector(runAll), keyEquivalent: "")
        run.target = self; menu.addItem(run)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "프로그램 종료", action: #selector(quit), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        observation = store.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        animation = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, self.store.runningCount > 0 { self.refresh() } }
        }
        refresh()
    }
    private func refresh() {
        let running = store.runningCount > 0
        let warning = !store.issues.isEmpty || store.error != nil
        let angle = running ? CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * .pi) : 0
        let image = BrandIcon.menuImage(angle: angle, warning: warning)
        image.size = NSSize(width: 16, height: 16)
        item.button?.image = image
        item.button?.toolTip = running ? "SafeSync · 백업 중" : warning ? "SafeSync · 확인 필요" : "SafeSync"
        item.button?.setAccessibilityLabel(item.button?.toolTip)
        progressItem.title = "동기화 상태 · 확인 \(store.issues.count)건"
    }
    @objc func showMain() { show("main", title: "SafeSync") }
    @objc private func showProgress() { show("progress", title: "백업 비교 및 충돌 처리") }
    private func show(_ id: String, title: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let open = store.openAppWindow { open(id) }
        else { NSApp.windows.first { $0.title == title }?.makeKeyAndOrderFront(nil) }
    }
    @objc private func runAll() { store.runAll() }
    @objc private func quit() { store.quit() }
}
