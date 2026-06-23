import AppKit
import SwiftUI

// MARK: - App entry point
//
// SPM-built executables need an explicit `@main`. We use the App
// protocol to bootstrap an NSApplication in a way that lets us
// configure accessory (no Dock icon) behavior from Info.plist's
// LSUIElement key — but we also force `.accessory` here in case
// the plist is missing.

@main
struct DustWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // We don't want a SwiftUI-managed window. The actual window
        // is created on demand by WindowManager. Returning an empty
        // Settings scene keeps the protocol happy without spawning
        // a default window.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?
    var notifier: Notifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force accessory mode even if Info.plist isn't honored.
        NSApp.setActivationPolicy(.accessory)

        // Ask for notification permission (graceful if denied).
        let n = Notifier.shared
        n.requestAuthorization()
        self.notifier = n

        // Wire up the menu bar UI.
        let mb = MenuBarController()
        self.menuBar = mb

        // CLI convenience flags (useful for headless testing):
        //   --generate-demo  — insert 30 days of synthetic data, then exit
        //   --demo-mode      — turn on live synthetic sampling
        let args = CommandLine.arguments
        if args.contains("--generate-demo") {
            do {
                try SyntheticDataGenerator.generate(
                    database: Sampler.shared.databaseHandle,
                    days: 30, seed: 42
                )
                print("✓ Generated 30 days of demo data into \(Sampler.shared.databasePath)")
            } catch {
                print("✗ Generation failed: \(error)")
            }
            exit(0)
        }
        if args.contains("--demo-mode") {
            Sampler.shared.isDemoMode = true
            var cfg = SyntheticConfig.load()
            cfg.enabled = true
            cfg.save()
        }

        // Start the sampling loop.
        Sampler.shared.start()

        // Start the alert reporter (runs every 6 hours).
        AlertReporter.shared.start(
            database: Sampler.shared.databaseHandle,
            notifier: n
        )

        // Observe notification taps → focus the main window.
        NotificationCenter.default.addObserver(
            forName: .openMainWindowRequested, object: nil, queue: .main
        ) { _ in
            WindowManager.shared.showMain()
        }

        WindowManager.shared.showMain()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AlertReporter.shared.stop()
        Sampler.shared.stop()
    }

    // Ensure the app stays running even with no windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
