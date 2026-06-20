import SwiftUI

// MARK: - ConfigView
//
// Tab that lets the user tweak thresholds, sample interval, and
// notification settings. Also where the user toggles demo mode and
// generates synthetic historical data so they can see the UI
// without waiting for the SMC struct to be reverse-engineered.

struct ConfigView: View {
    @State private var cfg: Config = Sampler.shared.config
    @State private var savedAt: Date?
    @State private var showResetConfirmation = false
    @State private var showCalibrationConfirmation = false
    @State private var showCalibrationResetConfirmation = false

    @State private var demoCfg: SyntheticConfig = SyntheticConfig.load()
    @State private var generating: Bool = false
    @State private var genProgress: Double = 0
    @State private var genMessage: String = ""
    @State private var clearingData: Bool = false

    @State private var realCount: Int = 0
    @State private var syntheticCount: Int = 0
    @State private var refreshTick: Int = 0

    var body: some View {
        Form {
            Section(L("Sampling")) {
                Stepper(value: $cfg.sampleIntervalSec, in: 10...600, step: 10) {
                    LabeledContent(L("Interval")) {
                        Text(String(format: L("%d sec"), cfg.sampleIntervalSec))
                            .monospacedDigit()
                    }
                }
            }

            Section(L("Thermal alert")) {
                HStack {
                    Text(L("Temperature rise threshold"))
                    Spacer()
                    TextField("°C", value: $cfg.tempThresholdC, format: .number.precision(.fractionLength(1)))
                        .frame(width: 60).multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                }
                Stepper(value: $cfg.fanThresholdRPM, in: 0...3000, step: 100) {
                    LabeledContent(L("Fan RPM rise")) {
                        Text("\(cfg.fanThresholdRPM) RPM")
                            .monospacedDigit()
                    }
                }
            }

            Section(L("Dust analysis")) {
                Stepper(value: $cfg.compareDays, in: 1...30, step: 1) {
                    LabeledContent(L("Recent analysis window")) {
                        Text(String(format: L("%d days"), cfg.compareDays))
                            .monospacedDigit()
                    }
                }
            }

            coolingReferenceSection

            Section(L("Notifications")) {
                Toggle(L("Enable system notifications"), isOn: $cfg.notificationsEnabled)
            }

            demoSection

            dataSection

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if let savedAt = savedAt {
                            let savedText = String(format: L("Auto-saved %@"), savedAt.formatted(date: .omitted, time: .shortened))
                            Text(savedText)
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(L("Settings save automatically."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            showResetConfirmation = true
                        } label: {
                            Label(L("Reset Settings"), systemImage: "arrow.counterclockwise")
                        }
                    }

                    Text(String(format: L("DB: %@"), Sampler.shared.databasePath))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .onAppear { refreshCounts() }
        .onChange(of: cfg) { _ in save() }
        .alert(L("Reset Settings?"), isPresented: $showResetConfirmation) {
            Button(L("Cancel"), role: .cancel) { }
            Button(L("Reset"), role: .destructive) {
                resetSettings()
            }
        } message: {
            Text(L("This restores sampling, alert thresholds, dust analysis, calibration, and notification settings to their defaults."))
        }
        .alert(L("Calibrate Cooling Reference?"), isPresented: $showCalibrationConfirmation) {
            Button(L("Cancel"), role: .cancel) { }
            Button(L("Calibrate"), role: .destructive) {
                calibrateCoolingReference()
            }
        } message: {
            Text(L("Use calibration only when the machine is in a known healthy cooling state, such as right after cleaning dust. Future risk analysis will learn the best cooling reference from samples collected after this moment."))
        }
        .alert(L("Reset Cooling Calibration?"), isPresented: $showCalibrationResetConfirmation) {
            Button(L("Cancel"), role: .cancel) { }
            Button(L("Reset"), role: .destructive) {
                resetCoolingCalibration()
            }
        } message: {
            Text(L("This clears the calibration time marker only. Existing samples are kept, and the app returns to automatically learning from the best available historical cooling data."))
        }
    }

    private var coolingReferenceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(L("Reference mode")) {
                    Text(coolingReferenceModeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Text(L("The app compares recent behavior with the best stable cooling capacity it has observed at similar workloads. Calibration limits that learning to samples collected after a known healthy moment."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    showCalibrationConfirmation = true
                } label: {
                    Label(L("Calibrate Now"), systemImage: "scope")
                }

                Button(role: .destructive) {
                    showCalibrationResetConfirmation = true
                } label: {
                    Label(L("Reset Calibration"), systemImage: "arrow.counterclockwise")
                }
                .disabled(cfg.coolingCalibrationStartedAt == nil)
            }
        } header: {
            Text(L("Cooling reference"))
        } footer: {
            Text(L("Calibration is optional. Use it only after cleaning dust or otherwise confirming the cooling system is healthy."))
                .font(.caption2)
        }
    }

    private var coolingReferenceModeText: String {
        guard let ts = cfg.coolingCalibrationStartedAt else {
            return L("Automatic")
        }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        return String(format: L("Calibrated since %@"), date.formatted(date: .abbreviated, time: .shortened))
    }

    // MARK: - Demo data section
    //
    // Lets the user flip the app into "demo mode" so the charts and
    // alert logic work even when SMC reads are broken. Two pieces:
    //   1. Toggle: switches the live sampler to synthetic data.
    //   2. Generate: bulk-inserts N days of historical data so the
    //      heatmap and weekly trend have something to show.
    //
    // The button shows a progress bar because generating 30+ days
    // takes a few seconds (43,200 rows).

    private var demoSection: some View {
        Section {
            Toggle(isOn: $demoCfg.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.orange)
                        Text(L("Use synthetic data (demo mode)"))
                            .fontWeight(.medium)
                    }
                    Text(L("Replaces SMC reads with a realistic generator. Useful when SMC isn't working on this macOS version, or to explore the app quickly."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: demoCfg.enabled) { newValue in
                demoCfg.save()
                Sampler.shared.isDemoMode = newValue
            }

            if demoCfg.enabled {
                Stepper(value: $demoCfg.daysOfData, in: 1...180, step: 7) {
                    LabeledContent(L("Days of history to generate")) {
                        Text(String(format: L("%d days"), demoCfg.daysOfData))
                            .monospacedDigit()
                    }
                }
                .onChange(of: demoCfg.daysOfData) { _ in demoCfg.save() }

                HStack {
                    Stepper(L("Random seed"), value: $demoCfg.seed, in: 0...9999)
                        .onChange(of: demoCfg.seed) { _ in demoCfg.save() }
                }

                HStack(spacing: 12) {
                    Button {
                        generateDemoData()
                    } label: {
                        if generating {
                            HStack { ProgressView().controlSize(.small); Text(L("Generating…")) }
                        } else {
                            Label(String(format: L("Generate %d-day history"), demoCfg.daysOfData),
                                  systemImage: "calendar.badge.plus")
                        }
                    }
                    .disabled(generating || clearingData)
                }

                if generating || !genMessage.isEmpty {
                    if generating {
                        ProgressView(value: genProgress) {
                            Text(L("Inserting synthetic samples…"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(genMessage)
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
        } header: {
            Text(L("Demo data"))
        } footer: {
            Text(L("Demo data is real, but synthesized. Once SMC reads work, toggle this off and the app will use actual sensor data."))
                .font(.caption2)
        }
    }

    // MARK: - Data section
    //
    // Lets the user see how much real vs synthetic data is in the
    // database, and clear each independently. Useful for keeping
    // curated synthetic data while accumulating real measurements,
    // or wiping the previous day/week of test data on demand.

    private var dataSection: some View {
        Section {
            // Live counts from the DB
            HStack(spacing: 24) {
                dataCount(label: L("Real"),      n: realCount,      tint: .green)
                dataCount(label: L("Synthetic"), n: syntheticCount, tint: .orange)
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Button {
                    clearSynthetic()
                } label: {
                    Label(L("Clear synthetic only"), systemImage: "wand.and.stars.outline")
                }
                .disabled(syntheticCount == 0 || clearingData)

                Button {
                    clearBeforeToday()
                } label: {
                    Label(L("Clear data before today"), systemImage: "calendar.badge.minus")
                }
                .disabled(clearingData)
            }

            Button(role: .destructive) {
                clearEverything()
            } label: {
                Label(L("Clear all data"), systemImage: "trash")
            }
            .disabled(clearingData)
        } header: {
            Text(L("Data"))
        } footer: {
            Text(L("Use \"Clear synthetic only\" to remove demo data while keeping real SMC samples. \"Clear data before today\" wipes test data from previous days. \"Clear all data\" removes everything."))
                .font(.caption2)
        }
    }

    private func dataCount(label: String, n: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(String(format: L("%d samples"), n))
                .font(.system(.title3, design: .rounded)).fontWeight(.medium)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearSynthetic() {
        clearingData = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Sampler.shared.databaseHandle.clearSyntheticData()
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = L("✓ Cleared synthetic data")
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = String(format: L("✗ Clear failed: %@"), error.localizedDescription)
                }
            }
        }
    }

    private func clearBeforeToday() {
        clearingData = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Sampler.shared.databaseHandle.clearBeforeToday()
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = L("✓ Cleared data before today 00:00")
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = String(format: L("✗ Clear failed: %@"), error.localizedDescription)
                }
            }
        }
    }

    private func clearEverything() {
        clearingData = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Sampler.shared.databaseHandle.clearAllSamples()
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = L("✓ All data cleared")
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.clearingData = false
                    self.genMessage = String(format: L("✗ Clear failed: %@"), error.localizedDescription)
                }
            }
        }
    }

    private func refreshCounts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let counts = (try? Sampler.shared.databaseHandle.sourceCounts())
                ?? (real: 0, synthetic: 0)
            DispatchQueue.main.async {
                self.realCount = counts.real
                self.syntheticCount = counts.synthetic
            }
        }
    }

    // MARK: - Save

    private func save() {
        do {
            try Sampler.shared.databaseHandle.saveConfig(cfg)
            Sampler.shared.config = cfg
            savedAt = Date()
        } catch {
            NSLog("ConfigView save failed: \(error.localizedDescription)")
        }
    }

    private func resetSettings() {
        cfg = Config()
        save()
    }

    private func calibrateCoolingReference() {
        cfg.coolingCalibrationStartedAt = Int64(Date().timeIntervalSince1970)
        save()
    }

    private func resetCoolingCalibration() {
        cfg.coolingCalibrationStartedAt = nil
        save()
    }

    // MARK: - Demo actions

    private func generateDemoData() {
        generating = true
        genProgress = 0
        genMessage = ""
        let cfg = self.demoCfg
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SyntheticDataGenerator.generate(
                    database: Sampler.shared.databaseHandle,
                    days: cfg.daysOfData,
                    seed: cfg.seed,
                    progress: { p in
                        DispatchQueue.main.async { self.genProgress = p }
                    })
                DispatchQueue.main.async {
                    self.generating = false
                    let totalSamples = cfg.daysOfData * 24 * 60
                    self.genMessage = String(format: L("✓ Generated %d synthetic samples"), totalSamples)
                    self.refreshCounts()
                }
            } catch {
                DispatchQueue.main.async {
                    self.generating = false
                    self.genMessage = String(format: L("✗ Generation failed: %@"), error.localizedDescription)
                }
            }
        }
    }
}
