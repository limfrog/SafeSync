import AppKit

/// Keep the process and status item alive while all document/settings windows are closed.
@MainActor final class AppPresentation {
    private var observers: [NSObjectProtocol] = []
    private var terminating = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let closing = notification.object as? NSWindow, closing.canBecomeMain else { return }
                // willClose is delivered before AppKit removes the window from its list.
                DispatchQueue.main.async { [weak self, weak closing] in
                    self?.updateAfterClose(excluding: closing)
                }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow, window.canBecomeMain else { return }
                Self.showInDock()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminating = true }
        })
    }

    static func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    private func updateAfterClose(excluding closing: NSWindow?) {
        guard !terminating else { return }
        let hasWindow = NSApp.windows.contains { window in
            window !== closing && window.canBecomeMain && !(window is NSPanel) &&
                (window.isVisible || window.isMiniaturized)
        }
        if !hasWindow && NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
