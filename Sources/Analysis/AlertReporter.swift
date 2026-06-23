import Foundation

// MARK: - AlertReporter
//
// Glue between BaselineComparator and the Notifier. Runs the
// comparison on a slow cadence (every 6 hours, regardless of sample
// interval) and dispatches a notification when a new finding
// appears. Uses Database.recentAlert to throttle.

final class AlertReporter {
    static let shared = AlertReporter()

    private let cooldownSec: Int64 = 7 * 86400   // 7 days
    private let runIntervalSec: TimeInterval = 6 * 3600
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.github.normanzyq.dustwatch.alerts",
                                      qos: .utility)
    private let alertKind = "thermal_degradation"

    func start(database: Database, notifier: Notifier) {
        // Stagger the first run so we don't fire 5 minutes after launch.
        let initialDelay: TimeInterval = 60 * 5
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + initialDelay,
                   repeating: runIntervalSec,
                   leeway: .seconds(60))
        t.setEventHandler { [weak self] in
            self?.runCheck(database: database, notifier: notifier)
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func runCheck(database: Database, notifier: Notifier) {
        do {
            let cfg = try database.loadConfig()
            guard cfg.notificationsEnabled else { return }
            if try database.recentAlert(kind: alertKind, withinSec: cooldownSec) { return }
            guard let finding = try BaselineComparator.run(database: database, config: cfg) else {
                return
            }
            let summary = format(finding: finding, config: cfg)
            try database.recordAlert(kind: alertKind, details: summary)
            notifier.send(
                title: L("Possible thermal degradation detected"),
                body: summary,
                userInfo: ["findingTempDelta": finding.tempDelta]
            )
        } catch {
            NSLog("AlertReporter: \(error.localizedDescription)")
        }
    }

    private func format(finding f: ThermalFinding, config: Config) -> String {
        let sub = f.subsystem.rawValue
        let tempLine: String
        if f.ambientCorrected {
            // The headline is the ambient-corrected rise-above-idle growth,
            // which is what actually indicates reduced cooling capacity.
            tempLine = String(
                format: L("%@ temperature rise over idle, at load level %d, grew by %.1f°C over the "
                      + "last %d days versus the best observed cooling reference (now +%.1f°C above idle, reference +%.1f°C; "
                      + "p = %.3f). This is corrected for room-temperature changes."),
                sub, f.cpuPState, f.riseDelta,
                config.compareDays,
                f.recentRise, f.baselineRise, f.pValue
            )
        } else {
            tempLine = String(
                format: L("%@ median temperature at load level %d is %.1f°C in the last %d days — "
                      + "%.1f°C higher than the best observed cooling reference (p = %.3f). Note: no idle reference "
                      + "was available, so this is not corrected for room-temperature changes."),
                sub, f.cpuPState, f.recentMedian,
                config.compareDays, f.tempDelta, f.pValue
            )
        }
        let fanLine: String
        if f.fanDelta > 50 {
            fanLine = " " + String(
                format: L("%@ Fan RPM at this load also rose from %.0f to %.0f (+%.0f RPM), consistent "
                      + "with the cooling system working harder to hold the same temperature."),
                sub, f.fanBaselineMean, f.fanRecentMean, f.fanDelta
            )
        } else {
            fanLine = ""
        }
        return tempLine + fanLine
    }
}
