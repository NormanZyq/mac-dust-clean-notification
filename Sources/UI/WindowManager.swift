import AppKit
import SwiftUI

// MARK: - WindowManager
//
// Singleton that creates and shows the main "Dashboard" window. We
// keep a single instance for the lifetime of the app; reopening the
// window from the menu just brings the existing one forward.

final class WindowManager {
    static let shared = WindowManager()

    private var window: NSWindow?

    func showMain() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = MainWindowView()
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = L("DustWatch")
        w.setContentSize(NSSize(width: 880, height: 620))
        w.minSize = NSSize(width: 720, height: 480)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.center()
        w.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
