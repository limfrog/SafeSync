import AppKit
import Combine

/// Let AppKit allocate a normal square status item; SwiftUI view layout must not determine its size.
@MainActor final class StatusBarController: NSObject {
    private let store: Store
    private let item: NSStatusItem
    private let progressItem = NSMenuItem(title: "동기화 상태", action: nil, keyEquivalent: "")
    private var observation: AnyCancellable?
    private var updateObservation: AnyCancellable?
    private let updateItem = NSMenuItem(title: "업데이트 확인", action: nil, keyEquivalent: "")
    private var animation: Timer?
    private var animationStart: TimeInterval?
    private var appearanceObservation: NSKeyValueObservation?

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
        updateItem.action = #selector(checkUpdates); updateItem.target = self; menu.addItem(updateItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "프로그램 종료", action: #selector(quit), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        observation = store.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        updateObservation = ApplicationUpdates.shared.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        animation = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, self.store.runningCount > 0 { self.refresh() } }
        }
        if let animation { RunLoop.main.add(animation, forMode: .common) }
        // The menu bar can have a different appearance from the app's content windows.
        appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    private func refresh() {
        let running = store.runningCount > 0
        let warning = store.issues.contains { !$0.automaticNetworkRetry } || store.error != nil
        if running && animationStart == nil { animationStart = ProcessInfo.processInfo.systemUptime }
        if !running { animationStart = nil }
        // AppKit's unflipped coordinates use negative angles for clockwise rotation.
        let elapsed = animationStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let angle = -CGFloat(elapsed.truncatingRemainder(dividingBy: 2) * .pi)
        let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let monochrome = BrandIcon.usesMonochromeMenuIcon(appearance: appearance)
        let image = BrandIcon.menuImage(angle: angle, warning: warning, monochrome: monochrome)
        image.size = NSSize(width: 16, height: 16)
        item.button?.image = image
        item.button?.toolTip = running ? "SafeSync · 백업 중" : warning ? "SafeSync · 확인 필요" : "SafeSync"
        item.button?.setAccessibilityLabel(item.button?.toolTip)
        progressItem.title = "동기화 상태 · 확인 \(store.issues.filter { !$0.automaticNetworkRetry }.count)건"
        if let version = ApplicationUpdates.shared.availableVersion {
            updateItem.title = "새 버전 \(version) · 다운로드 / 업데이트"
            item.button?.toolTip = "SafeSync · 업데이트 \(version) 있음"
        } else { updateItem.title = "업데이트 확인" }
    }
    @objc func showMain() { show("main", title: "SafeSync") }
    @objc private func showProgress() { show("progress", title: "백업 비교 및 충돌 처리") }
    private func show(_ id: String, title: String) {
        AppPresentation.showInDock()
        NSApp.activate(ignoringOtherApps: true)
        if let open = store.openAppWindow { open(id) }
        else { NSApp.windows.first { $0.title == title }?.makeKeyAndOrderFront(nil) }
    }
    @objc private func runAll() { store.runAll() }
    @objc private func checkUpdates() { ApplicationUpdates.shared.check(manual: true) }
    @objc private func quit() { store.quit() }
}
