import AppKit
import SwiftUI

// MARK: - MenuBarController
//
// Owns the NSStatusItem that represents the app in the menu bar.
// Hosts a small popover with the latest readings and a button to
// open the main window. Switches the icon color and symbol when an
// alert is active.

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var alertActive: Bool = false
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureIcon()
        rebuildMenu()

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(onOpenMain: { [weak self] in self?.openMainWindow() })
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        observer = NotificationCenter.default.addObserver(
            forName: .thermalAlertStateChanged, object: nil, queue: .main
        ) { [weak self] note in
            self?.alertActive = (note.userInfo?["active"] as? Bool) ?? false
            self?.configureIcon()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Popover

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Activate first so the popover gets focus.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Icon

    private func configureIcon() {
        guard let button = statusItem.button else { return }
        let symbol = alertActive ? "thermometer.high.fill" : "thermometer.medium"
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let img = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: L("DustWatch")
        )
        button.image = img?.withSymbolConfiguration(cfg)
        // Tint: red when alert, default otherwise.
        button.contentTintColor = alertActive ? NSColor.systemRed : nil
    }

    // MARK: - Menu (right-click)
    //
    // We rebuild this lazily so it always reflects the latest state
    // (e.g. toggle on/off for "Open at Login"). Items with no target
    // are dimmed by the system automatically.

    private func rebuildMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Dashboard…",
                                  action: #selector(openMainWindowFromMenu),
                                  keyEquivalent: "d")
        openItem.keyEquivalentModifierMask = [.command, .shift]
        openItem.title = L("Open Dashboard…")
        openItem.toolTip = L("Show the DustWatch dashboard")
        openItem.target = self
        menu.addItem(openItem)

        let exportItem = NSMenuItem(title: "Export Last 24 Hours as CSV…",
                                    action: #selector(exportLast24h),
                                    keyEquivalent: "")
        exportItem.title = L("Export Last 24 Hours as CSV…")
        exportItem.target = self
        menu.addItem(exportItem)

        let revealItem = NSMenuItem(title: "Reveal Data File in Finder",
                                    action: #selector(revealDataFile),
                                    keyEquivalent: "")
        revealItem.title = L("Reveal Data File in Finder")
        revealItem.target = self
        menu.addItem(revealItem)

        // Demo data submenu — for users who want to see the app in
        // action before SMC reads are working.
        let demoItem = NSMenuItem(title: "Generate 30-Day Demo Data…",
                                  action: #selector(generateDemoData),
                                  keyEquivalent: "")
        demoItem.title = L("Generate 30-Day Demo Data…")
        demoItem.target = self
        menu.addItem(demoItem)

        // CPU stress test — runs a 30-second burn loop. Good for
        // watching temperature respond in real time.
        let stressItem = NSMenuItem(title: "Run 30s CPU Stress Test…",
                                    action: #selector(runStressTest),
                                    keyEquivalent: "")
        stressItem.title = L("Run 30s CPU Stress Test…")
        stressItem.target = self
        menu.addItem(stressItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.title = L("Quit")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openMainWindowFromMenu() {
        openMainWindow()
    }

    @objc private func exportLast24h() {
        let from = Calendar.current.date(byAdding: .hour, value: -24, to: Date())!
        DispatchQueue.main.async {
            do {
                if let url = try CSVExporter.exportSamples(from: from, to: Date()) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                NSLog("MenuBarController export failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func revealDataFile() {
        let path = Sampler.shared.databasePath
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func generateDemoData() {
        // Convenience action: turn on demo mode and generate 30 days
        // of synthetic data, so the user can see the dashboard in
        // action immediately. Runs the generator on a background
        // queue and shows a brief HUD via a notification.
        var cfg = SyntheticConfig.load()
        cfg.enabled = true
        cfg.save()
        Sampler.shared.isDemoMode = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SyntheticDataGenerator.generate(
                    database: Sampler.shared.databaseHandle,
                    days: 30,
                    seed: cfg.seed
                )
                Notifier.shared.send(
                    title: L("Demo data ready"),
                    body: L("Generated 30 days of synthetic samples. Open the dashboard to explore."),
                    userInfo: [:]
                )
            } catch {
                NSLog("MenuBarController demo gen failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func runStressTest() {
        Notifier.shared.send(
            title: L("Stress test running"),
            body: L("Burning CPU for 30 seconds. Watch the temperature climb in the popover."),
            userInfo: [:]
        )
        DispatchQueue.global(qos: .userInitiated).async {
            StressTestRunner.run(durationSeconds: 30)
            Notifier.shared.send(
                title: L("Stress test done"),
                body: L("30-second load complete. Check the dashboard for the temperature curve."),
                userInfo: [:]
            )
        }
    }

    func openMainWindow() {
        if popover.isShown { popover.performClose(nil) }
        WindowManager.shared.showMain()
    }
}

extension Notification.Name {
    static let thermalAlertStateChanged = Notification.Name("DustWatch.thermalAlertStateChanged")
}
