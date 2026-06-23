import SwiftUI

// MARK: - PopoverView
//
// The small panel that appears when the user clicks the menu bar icon.
// Shows the latest sample, a hint about today's peak temperature, and
// a button to open the main window. Refreshes whenever a new sample
// is posted.

struct PopoverView: View {
    @State private var sample: Sample?
    @State private var todayPeakCPU: Double?
    @State private var todayPeakGPU: Double?
    @ObservedObject private var samplerObserver = SamplerObserver()

    let onOpenMain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.tint)
                Text(L("DustWatch"))
                    .font(.headline)
                Spacer()
                if samplerObserver.isDemoMode { DemoModeBadge() }
            }
            Divider()

            // Headline: CPU load is the primary "what's my Mac doing right now"
            // indicator. The user glances at the popover to see whether the
            // machine is busy. Temperature and fan speed are secondary.
            headlineLoadRow

            Divider()
            metricRow(label: L("CPU temp"), value: sample?.cpuTempC, unit: "°C", tint: .orange)
            metricRow(label: L("GPU temp"), value: sample?.gpuTempC, unit: "°C", tint: .blue)
            metricRow(label: L("Fan"), value: sample?.maxFanRPM.map { Double($0) },
                      unit: " RPM", tint: .green, isInt: true)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Today peak"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    miniStat(label: L("CPU"), value: todayPeakCPU)
                    miniStat(label: L("GPU"), value: todayPeakGPU)
                }
            }
            Spacer(minLength: 0)
            Button(action: onOpenMain) {
                HStack {
                    Text(L("Open Dashboard"))
                    Spacer()
                    Text("⇧⌘T")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 320, height: 360)
        .onReceive(NotificationCenter.default.publisher(
            for: Sampler.newSampleNotification)) { note in
            if let s = note.userInfo?[Sampler.sampleKey] as? Sample {
                sample = s
                recalcTodayPeak()
            }
        }
        .onAppear {
            sample = Sampler.shared.latest
            recalcTodayPeak()
        }
    }

    // MARK: - Headline load row
    //
    // The big number at the top of the popover. Shows the current
    // CPU load as a percentage with a tinted progress bar so the
    // user can tell at a glance whether the machine is busy.

    @ViewBuilder
    private var headlineLoadRow: some View {
        let load = sample?.cpuLoad ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("CPU load"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", load * 100))
                    .font(.system(size: 28, design: .rounded))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(loadColor(load))
            }
            // Slim progress bar visualizing the same number.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(loadColor(load))
                        .frame(width: max(2, geo.size.width * load))
                        .animation(.easeInOut(duration: 0.4), value: load)
                }
            }
            .frame(height: 6)
        }
    }

    private func loadColor(_ load: Double) -> Color {
        switch load {
        case ..<0.3:  return .green
        case 0.3..<0.7: return .orange
        default:      return .red
        }
    }

    @ViewBuilder
    private func metricRow(label: String, value: Double?, unit: String,
                           tint: Color, isInt: Bool = false, fractionDigits: Int = 1) -> some View {
        HStack {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let v = value {
                Text(formatNumber(v, fractionDigits: fractionDigits, isInt: isInt) + unit)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func miniStat(label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f°C", $0) } ?? "—")
                .font(.system(.body, design: .monospaced))
        }
    }

    private func formatNumber(_ v: Double, fractionDigits: Int, isInt: Bool) -> String {
        if isInt { return String(Int(v.rounded())) }
        return String(format: "%.\(fractionDigits)f", v)
    }

    private func recalcTodayPeak() {
        // Best-effort: query the DB for today's max. For a popover we
        // want this fast, so we only look at the last 24 hours of raw
        // samples. A more sophisticated implementation would cache.
        let start = Int64(Date().addingTimeInterval(-86400).timeIntervalSince1970)
        let end   = Int64(Date().timeIntervalSince1970)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let samples = try Sampler.shared.databaseHandle.fetchSamples(from: start, to: end)
                let cpuPeak = samples.compactMap { $0.cpuTempC }.max()
                let gpuPeak = samples.compactMap { $0.gpuTempC }.max()
                DispatchQueue.main.async {
                    self.todayPeakCPU = cpuPeak
                    self.todayPeakGPU = gpuPeak
                }
            } catch {
                // ignore; popover will just show dashes
            }
        }
    }
}
