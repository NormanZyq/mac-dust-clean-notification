import Foundation
import AppKit

// MARK: - Sampler
//
// Drives the periodic sensor reading + persistence loop. Owns the
// SMCDevice and Database instances. Notifies the rest of the app via
// NSNotification.Name so UI components can refresh.
//
// Lifecycle:
//   start()                — open SMC, create timer, take first sample
//   timer fires (every N sec by config)
//   sleep notification     — pause timer
//   wake notification      — resume timer and take an immediate sample
//                             to recover from a gap in the data
//   stop()                 — invalidate timer, close SMC

final class Sampler {
    static let shared = Sampler()

    private let smc: SMCDevice
    private let reader: SMCReader
    private let database: Database
    private let queue = DispatchQueue(label: "io.github.normanzyq.dustwatch.sampler",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var aggregationTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    // MARK: - Notifications
    //
    // Posted on the main queue after each sample is persisted. UI views
    // subscribe via NotificationCenter to refresh charts and badges.

    static let newSampleNotification = Notification.Name("DustWatch.newSample")
    static let sampleKey: String = "sample"

    private(set) var latest: Sample?
    var config: Config

    /// When true, the Sampler generates synthetic samples instead of
    /// reading SMC. Set this from the UI to demo the charts/alerts
    /// before SMC reads are working, or when the user just wants to
    /// play with the app on a fresh machine.
    var isDemoMode: Bool = false {
        didSet { syntheticRNG = nil }   // reset RNG so demo looks fresh
    }
    private var syntheticRNG: SplitMix64?

    init() {
        self.smc = SMCDevice()
        self.reader = SMCReader(device: smc)
        // Default DB path; main() rewrites this before calling start().
        let dir = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let path = (dir as NSString)
            .appendingPathComponent("DustWatch")
            .appending("/data.db")
        self.database = (try? Database(path: path)) ?? {
            // Fallback: try /tmp so the app still launches.
            return try! Database(path: NSTemporaryDirectory() + "cnm-fallback.db")
        }()
        self.config = (try? database.loadConfig()) ?? Config()
    }

    /// Replace the default database (used in main() before start() so the
    /// caller can control the storage location).
    func bootstrap(database: Database, config: Config) {
        // Sampler holds the initial DB created in init(); we can swap
        // implementations by deferring to it. For simplicity we just
        // re-save the config to the new DB.
        try? database.saveConfig(config)
    }

    func start() {
        do {
            try smc.open()
        } catch {
            NSLog("Sampler: failed to open SMC: \(error.localizedDescription)")
            // Continue anyway; we'll just have no data.
        }
        // After the connection is open, verify SMC is returning real
        // sensor data (not garbage from a wrong struct layout). This
        // sets a flag that gates subsequent reads.
        reader.runSelfTest()
        installSleepObservers()
        scheduleTimer()
        scheduleAggregation()
        takeSample()  // immediate first sample
    }

    func stop() {
        timer?.cancel()
        timer = nil
        aggregationTimer?.cancel()
        aggregationTimer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        smc.close()
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(5, config.sampleIntervalSec)
        t.schedule(deadline: .now() + .seconds(interval),
                   repeating: .seconds(interval),
                   leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.takeSample() }
        t.resume()
        timer = t
    }

    // Roll-up of old samples (raw → hourly → daily) is cheap but involves a
    // full GROUP BY and a write transaction, so it does not belong on the
    // per-sample path. Nothing ages out in under a day anyway. We run it on
    // its own hourly timer with generous leeway so the scheduler can coalesce
    // the wake-up with other work and the SoC stays in deep idle between
    // samples.
    private func scheduleAggregation() {
        aggregationTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(120),   // first run shortly after launch
                   repeating: .seconds(3600),           // hourly thereafter
                   leeway: .seconds(300))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try Aggregator.run(database: self.database)
            } catch {
                NSLog("Sampler: aggregation failed: \(error.localizedDescription)")
            }
        }
        t.resume()
        aggregationTimer = t
    }

    private func takeSample() {
        let sample: Sample
        if isDemoMode {
            // Synthesize a sample with realistic patterns. We keep
            // an RNG around so the noise is continuous across
            // samples within one session.
            if syntheticRNG == nil {
                syntheticRNG = SplitMix64(seed: UInt64(Date().timeIntervalSince1970))
            }
            let cfg = SyntheticConfig.load()
            var s = SyntheticDataGenerator.sampleAt(
                ts: Date(), cfg: cfg, rng: &syntheticRNG!
            )
            // Tag the live synthetic sample with its source.
            s.source = .synthetic
            sample = s
        } else {
            let snapshot = reader.readAll()
            var s = Sample(
                timestamp: snapshot.timestamp,
                cpuTempC:  snapshot.cpuTempC,
                gpuTempC:  snapshot.gpuTempC,
                cpuFreqGHz: snapshot.cpuFreqGHz,
                cpuLoad:   snapshot.cpuLoad,
                gpuLoad:   snapshot.gpuLoad,
                cpuPState: snapshot.cpuPState,
                fanRPMs:   snapshot.fanRPMs
            )
            // Augment with system-level stats (CPU load, GPU load approximation).
            if s.cpuLoad == nil { s.cpuLoad = SystemStats.cpuLoad() }
            if s.gpuLoad == nil { s.gpuLoad = SystemStats.gpuLoad() }
            // Apple Silicon exposes no usable per-cluster P-State over SMC, so
            // we derive a workload bucket (0..8) from CPU load. This must match
            // SyntheticDataGenerator's formula so real and demo samples bucket
            // identically — the baseline comparator groups by this value.
            if s.cpuPState.isEmpty, let load = s.cpuLoad, load > 0.05 {
                s.cpuPState = [Int((load * 8).rounded())]
            }
            s.source = .real
            sample = s
        }

        do {
            try database.insert(sample)
        } catch {
            NSLog("Sampler: failed to persist sample: \(error.localizedDescription)")
        }

        DispatchQueue.main.async {
            self.latest = sample
            NotificationCenter.default.post(
                name: Self.newSampleNotification,
                object: self,
                userInfo: [Self.sampleKey: sample]
            )
        }
    }

    // MARK: - Sleep / wake

    private func installSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let willSleep = nc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.timer?.cancel()
            self?.timer = nil
        }
        let didWake = nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.scheduleTimer()
            self?.takeSample()  // fill the gap immediately
        }
        observers.append(willSleep)
        observers.append(didWake)
    }

    // MARK: - Public accessors

    var databasePath: String { database.filePath }
    var databaseHandle: Database { database }
}
