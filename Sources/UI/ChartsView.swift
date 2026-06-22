import SwiftUI
import Charts

// MARK: - ChartsView
//
// A detail view for exploring a specific time range in depth. Three
// modes:
//
//   .live     — last 24h, raw samples
//   .compare  — baseline vs recent (Mann-Whitney finding)
//   .history  — full date range the user has data for, with date
//               range picker, aggregation toggle, and export button
//
// This is the "I want to dig into the data" view. The Overview tab
// gives the at-a-glance summary; this one is for forensics.
//
// Every chart here uses `InteractiveChart` for iOS-Health-style
// hover: snap to nearest point, vertical guideline, per-series
// dots, and a glass tooltip with formatted values.

struct ChartsView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live"
        case compare = "Compare"
        case history = "History"
        var id: String { rawValue }
    }

    enum Aggregation: String, CaseIterable, Identifiable {
        case raw    = "Raw"
        case hourly = "Hourly"
        case daily  = "Daily"
        var id: String { rawValue }
    }

    enum Range: String, CaseIterable, Identifiable {
        case last24h = "24h"
        case last7d  = "7d"
        case last30d = "30d"
        case last90d = "90d"
        case all     = "All"
        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .last24h: return 24 * 3600
            case .last7d:  return 7 * 86400
            case .last30d: return 30 * 86400
            case .last90d: return 90 * 86400
            case .all:     return 365 * 5 * 86400  // ~5 years
            }
        }
    }

    let mode: Mode

    @State private var samples: [Sample] = []
    @State private var hourly: [HourlyStats] = []
    @State private var daily:  [DailyStats]  = []
    @State private var finding: ThermalFinding?
    @State private var loading: Bool = false

    // History-mode controls
    @State private var range: Range = .last7d
    @State private var aggregation: Aggregation = .raw
    @State private var exportError: String?
    @State private var exportedURL: URL?

    /// Dashboard-wide series visibility. Stored in UserDefaults so toggles
    /// survive tab switches and the next app launch.
    @AppStorage("dashboard.series.showCPUTemp") private var showCPUTemp = true
    @AppStorage("dashboard.series.showGPUTemp") private var showGPUTemp = true
    @AppStorage("dashboard.series.showFanRPM")  private var showFanRPM = true
    @AppStorage("dashboard.series.showCPULoad") private var showCPULoad = true
    @AppStorage("dashboard.series.showGPULoad") private var showGPULoad = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controlsCard
            chartCard
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: range)        { _ in load() }
        .onChange(of: aggregation)  { _ in load() }
        .alert(L("Export failed"),
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button(L("OK"), role: .cancel) { }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2).fontWeight(.semibold)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch mode {
        case .live:    return L("Live (last 24 hours)")
        case .compare: return L("Best cooling vs recent")
        case .history: return L("History")
        }
    }
    private var subtitle: String {
        switch mode {
        case .live:
            return L("Raw 1-minute samples from the last 24 hours. Hover for CPU/GPU/Fan values.")
        case .compare:
            return L("Median thermal rise at the most-degraded load level, recent vs best observed cooling reference.")
        case .history:
            return L("Explore the full range of recorded data. Pick a time range, an aggregation level, and hover for point values.")
        }
    }

    // MARK: - Controls
    //
    // Only shown in history mode. Live/compare have no controls.

    @ViewBuilder
    private var controlsCard: some View {
        if mode == .history {
            HStack(spacing: 14) {
                Picker(L("Range"), selection: $range) {
                    ForEach(Range.allCases) { r in
                        Text(L(r.rawValue)).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Picker(L("Aggregation"), selection: $aggregation) {
                    ForEach(Aggregation.allCases) { a in
                        Text(L(a.rawValue)).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                Button {
                    exportCSV()
                } label: {
                    Label(L("Export CSV"), systemImage: "square.and.arrow.up")
                }
                .help(L("Export the current view as a CSV file"))
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        } else {
            EmptyView()
        }
    }

    // MARK: - Chart card
    //
    // The actual chart area. Switches between raw line chart, hourly
    // bars, and daily bars based on the mode and aggregation choice.
    // For modes that have toggleable series, a `SeriesToggleBar` is
    // rendered at the top of the card.

    @ViewBuilder
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shouldShowToggleBar {
                HStack {
                    Text(L("Series"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SeriesToggleBar(
                        config: seriesConfigBinding,
                        available: availableToggleKinds
                    )
                    Spacer()
                    if let range = chartTimeRangeText {
                        Text(range)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            Group {
                if loading && samples.isEmpty && hourly.isEmpty && daily.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEmpty {
                    ContentUnavailableViewCompat(
                        title: L("No data in this range"),
                        systemImage: "tray",
                        description: L("Pick a wider time range, or wait for the sampler to collect more.")
                    )
                } else {
                    switch mode {
                    case .live:    liveChart
                    case .compare: compareChart
                    case .history: historyChart
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Only show the series toggle bar for chart views that have
    /// multiple plottable series. Compare has just two bars, so it
    /// does not need toggling.
    private var shouldShowToggleBar: Bool {
        switch (mode, aggregation) {
        case (.live, _):              return true
        case (.history, .raw):        return true
        case (.history, .hourly):     return true
        case (.history, .daily):      return true
        case (.compare, _):           return false
        }
    }

    private var chartTimeRangeText: String? {
        switch (mode, aggregation) {
        case (.live, _):
            return chartDateRangeLabel(samples.map(\.timestamp))
        case (.history, .raw):
            return chartDateRangeLabel(samples.map(\.timestamp))
        case (.history, .hourly):
            return chartDateRangeLabel(hourly.map(\.hour))
        case (.history, .daily):
            return chartDateRangeLabel(daily.map(\.date))
        case (.compare, _):
            return nil
        }
    }

    /// Which toggles to show for the current chart. Live and
    /// History-raw have all five series (raw samples carry load
    /// data); History-hourly only has temp + fan (no load in the
    /// rollup).
    private var availableToggleKinds: Set<SeriesKind> {
        switch (mode, aggregation) {
        case (.live, _),
             (.history, .raw):
            return [.cpuTemp, .gpuTemp, .fanRPM, .cpuLoad, .gpuLoad]
        case (.history, .hourly),
             (.history, .daily):
            return [.cpuTemp, .gpuTemp, .fanRPM]
        default:
            return []
        }
    }

    private var seriesConfig: ChartSeriesConfig {
        ChartSeriesConfig(
            showCPUTemp: showCPUTemp,
            showGPUTemp: showGPUTemp,
            showFanRPM: showFanRPM,
            showCPULoad: showCPULoad,
            showGPULoad: showGPULoad
        )
    }

    private var seriesConfigBinding: Binding<ChartSeriesConfig> {
        Binding {
            seriesConfig
        } set: { newValue in
            showCPUTemp = newValue.showCPUTemp
            showGPUTemp = newValue.showGPUTemp
            showFanRPM = newValue.showFanRPM
            showCPULoad = newValue.showCPULoad
            showGPULoad = newValue.showGPULoad
        }
    }

    private func rawPrimaryDomain(_ data: [Sample]) -> ClosedRange<Double> {
        var values: [Double] = []
        if seriesConfig.showCPUTemp {
            values += data.compactMap(\.cpuTempC)
        }
        if seriesConfig.showGPUTemp {
            values += data.compactMap(\.gpuTempC)
        }
        if seriesConfig.showCPULoad {
            values += data.compactMap { $0.cpuLoad.map { $0 * 100 } }
        }
        if seriesConfig.showGPULoad {
            values += data.compactMap { $0.gpuLoad.map { $0 * 100 } }
        }
        return paddedAxisDomain(values: values, fallback: 0...100, minSpan: 12)
    }

    private func rawSecondaryDomain(_ data: [Sample]) -> ClosedRange<Double> {
        let values = seriesConfig.showFanRPM
            ? data.compactMap { $0.maxFanRPM.map { Double($0) } }
            : []
        return paddedAxisDomain(
            values: values,
            fallback: 0...4800,
            minSpan: 800,
            clampLowerToZero: true
        )
    }

    private func hourlyPrimaryDomain(_ data: [HourlyStats]) -> ClosedRange<Double> {
        var values: [Double] = []
        if seriesConfig.showCPUTemp {
            values += data.compactMap(\.cpuTempMin)
            values += data.compactMap(\.cpuTempAvg)
            values += data.compactMap(\.cpuTempPeak)
        }
        if seriesConfig.showGPUTemp {
            values += data.compactMap(\.gpuTempAvg)
            values += data.compactMap(\.gpuTempPeak)
        }
        return paddedAxisDomain(values: values, fallback: 0...100, minSpan: 12)
    }

    private func hourlySecondaryDomain(_ data: [HourlyStats]) -> ClosedRange<Double> {
        let values = seriesConfig.showFanRPM
            ? data.compactMap { $0.fanRpmPeak.map { Double($0) } }
            : []
        return paddedAxisDomain(
            values: values,
            fallback: 0...4800,
            minSpan: 800,
            clampLowerToZero: true
        )
    }

    private func dailyPrimaryDomain(_ data: [DailyStats]) -> ClosedRange<Double> {
        var values: [Double] = []
        if seriesConfig.showCPUTemp {
            values += data.compactMap(\.cpuTempMin)
            values += data.compactMap(\.cpuTempAvg)
            values += data.compactMap(\.cpuTempPeak)
        }
        if seriesConfig.showGPUTemp {
            values += data.compactMap(\.gpuTempAvg)
            values += data.compactMap(\.gpuTempPeak)
        }
        return paddedAxisDomain(values: values, fallback: 0...100, minSpan: 12)
    }

    private func dailySecondaryDomain(_ data: [DailyStats]) -> ClosedRange<Double> {
        let values = seriesConfig.showFanRPM
            ? data.compactMap { $0.fanRpmPeak.map { Double($0) } }
            : []
        return paddedAxisDomain(
            values: values,
            fallback: 0...4800,
            minSpan: 800,
            clampLowerToZero: true
        )
    }

    private func displaySamples(_ source: [Sample], maxPoints: Int) -> [Sample] {
        guard maxPoints > 0, source.count > maxPoints else { return source }
        let chunkSize = Int(ceil(Double(source.count) / Double(maxPoints)))
        return stride(from: 0, to: source.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, source.count)
            let chunk = Array(source[start..<end])
            let middle = chunk[chunk.count / 2]
            return Sample(
                timestamp: middle.timestamp,
                cpuTempC: average(chunk.compactMap(\.cpuTempC)),
                gpuTempC: average(chunk.compactMap(\.gpuTempC)),
                cpuFreqGHz: average(chunk.compactMap(\.cpuFreqGHz)),
                cpuLoad: average(chunk.compactMap(\.cpuLoad)),
                gpuLoad: average(chunk.compactMap(\.gpuLoad)),
                cpuPState: chunk.flatMap(\.cpuPState).max().map { [$0] } ?? [],
                fanRPMs: chunk.compactMap(\.maxFanRPM).max().map { [$0] } ?? [],
                source: middle.source
            )
        }
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var isEmpty: Bool {
        switch (mode, aggregation) {
        case (.live, _):             return samples.isEmpty
        case (.compare, _):          return finding == nil
        case (.history, .raw):       return samples.isEmpty
        case (.history, .hourly):    return hourly.isEmpty
        case (.history, .daily):     return daily.isEmpty
        }
    }

    // MARK: - Live chart (24h raw samples)
    //
    // Dual-axis: CPU/GPU temperature on the left axis (°C), fan
    // RPM on the right axis. Both series are normalized to a shared
    // 0–100 internal scale so they share the plot area; the axis
    // labels restore the real units. Hover shows every series'
    // value at that minute plus the fan RPM if the sample had one.

    private var liveChart: some View {
        let chartSamples = displaySamples(samples, maxPoints: 360)
        let primaryDomain = rawPrimaryDomain(chartSamples)
        let secondaryDomain = rawSecondaryDomain(chartSamples)
        return DualAxisChart(
            data: chartSamples,
            dateKey: \.timestamp,
            rowsForPoint: { liveRows($0, primaryDomain: primaryDomain, secondaryDomain: secondaryDomain) },
            dateLabel: liveDateLabel,
            primaryAxisLabel: "°C / %",
            primaryDomain: primaryDomain,
            secondaryAxisLabel: "RPM",
            secondaryDomain: secondaryDomain
        ) {
            // CPU line + soft min-max band (only when CPU temp is on)
            if seriesConfig.showCPUTemp {
                ForEach(chartSamples) { s in
                    if let lo = s.cpuTempC, let hi = s.cpuTempC, hi > lo + 0.5 {
                        AreaMark(
                            x: .value("Time", s.timestamp),
                            yStart: .value("Min", lo - 0.5),
                            yEnd: .value("Max", hi + 0.5)
                        )
                        .foregroundStyle(Color.orange.opacity(0.08))
                        .interpolationMethod(.monotone)
                    }
                }
                ForEach(chartSamples) { s in
                    if let v = s.cpuTempC {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("CPU"))
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }

            if seriesConfig.showGPUTemp {
                ForEach(chartSamples) { s in
                    if let v = s.gpuTempC {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("GPU"))
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }

            if seriesConfig.showFanRPM {
                ForEach(chartSamples) { s in
                    if let rpm = s.maxFanRPM.map({ Double($0) }) {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("RPM", mapValue(rpm, from: secondaryDomain, to: primaryDomain)),
                            series: .value(L("Series"), L("Fan"))
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    }
                }
            }

            if seriesConfig.showCPULoad {
                ForEach(chartSamples) { s in
                    if let load = s.cpuLoad {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("%", load * 100),
                            series: .value(L("Series"), L("CPU load"))
                        )
                        .foregroundStyle(Color.orange.opacity(0.55))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [2, 3]))
                    }
                }
            }

            if seriesConfig.showGPULoad {
                ForEach(chartSamples) { s in
                    if let load = s.gpuLoad {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("%", load * 100),
                            series: .value(L("Series"), L("GPU load"))
                        )
                        .foregroundStyle(Color.blue.opacity(0.55))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [2, 3]))
                    }
                }
            }

            if seriesConfig.showCPUTemp && shouldShowWarningRule(in: primaryDomain) {
                RuleMark(y: .value("Warning", 75))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(L("75°C")).font(.caption2).foregroundStyle(.red.opacity(0.8))
                    }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            compactTimeAxisMarks(dates: chartSamples.map(\.timestamp), desiredCount: 6)
        }
        .padding(12)
    }

    /// Tooltip rows for the Live chart. Each row is only included
    /// when its series is enabled.
    private func liveRows(
        _ s: Sample,
        primaryDomain: ClosedRange<Double>,
        secondaryDomain: ClosedRange<Double>
    ) -> [HoverRow] {
        var rows: [HoverRow] = []
        if seriesConfig.showCPUTemp {
            rows.append(HoverRow(label: L("CPU temp"), color: .orange, value: s.cpuTempC))
        }
        if seriesConfig.showGPUTemp {
            rows.append(HoverRow(label: L("GPU temp"), color: .blue, value: s.gpuTempC))
        }
        if seriesConfig.showFanRPM {
            rows.append(HoverRow(
                label: L("Fan RPM"),
                color: .green,
                plotValue: s.maxFanRPM.map {
                    mapValue(Double($0), from: secondaryDomain, to: primaryDomain)
                },
                displayValue: s.maxFanRPM.map { Double($0) },
                unit: " RPM",
                fractionDigits: 0
            ))
        }
        if seriesConfig.showCPULoad {
            rows.append(HoverRow(label: L("CPU load"), color: .orange.opacity(0.6),
                                 value: s.cpuLoad.map { $0 * 100 },
                                 unit: "%", fractionDigits: 0))
        }
        if seriesConfig.showGPULoad {
            rows.append(HoverRow(label: L("GPU load"), color: .blue.opacity(0.6),
                                 value: s.gpuLoad.map { $0 * 100 },
                                 unit: "%", fractionDigits: 0))
        }
        return rows
    }

    private func liveDateLabel(_ s: Sample) -> (header: String, sub: String?) {
        let f1 = DateFormatter()
        f1.dateFormat = "EEE  MMM d"
        let f2 = DateFormatter()
        f2.dateFormat = "HH:mm"
        return (f1.string(from: s.timestamp), f2.string(from: s.timestamp))
    }

    // MARK: - Compare chart
    //
    // Best-reference vs recent bars. Hover any bar to see n (sample
    // count) and median ± spread in the tooltip, plus the p-value
    // and delta that drove the alert.

    private var compareChart: some View {
        let f = finding
        let yLabel = (f?.ambientCorrected ?? true) ? L("Thermal rise °C") : L("Median °C")
        return Chart {
            BarMark(
                x: .value("Window", L("Reference")),
                y: .value(yLabel, f?.baselineMedian ?? 0)
            )
            .foregroundStyle(.green)
            .annotation(position: .top) {
                Text(String(format: "%.1f°C", f?.baselineMedian ?? 0))
                    .font(.caption2)
                    .monospacedDigit()
            }
            BarMark(
                x: .value("Window", L("Recent")),
                y: .value(yLabel, f?.recentMedian ?? 0)
            )
            .foregroundStyle((f?.tempDelta ?? 0) > 0 ? .red : .blue)
            .annotation(position: .top) {
                Text(String(format: "%.1f°C", f?.recentMedian ?? 0))
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .padding(12)
        .overlay(alignment: .bottom) {
            if let f = f {
                VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("Δ = %+.1f°C · p = %.3f · n=%d vs %d"),
                            f.tempDelta, f.pValue, f.recentCount, f.baselineCount))
                        .font(.caption).foregroundStyle(.secondary)
                    if f.fanDelta > 0 {
                        Text(String(format: L("Fan RPM: %.0f → %.0f (+%.0f)"),
                                    f.fanBaselineMean, f.fanRecentMean, f.fanDelta))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            } else {
                Text(L("No significant degradation detected in the current window."))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    // MARK: - History chart
    //
    // Switches between raw line, hourly line, and daily bar chart
    // based on the user's aggregation choice.

    @ViewBuilder
    private var historyChart: some View {
        switch aggregation {
        case .raw:    historyRawChart
        case .hourly: historyHourlyChart
        case .daily:  historyDailyChart
        }
    }

    private var historyRawChart: some View {
        let chartSamples = displaySamples(samples, maxPoints: 500)
        let primaryDomain = rawPrimaryDomain(chartSamples)
        let secondaryDomain = rawSecondaryDomain(chartSamples)
        return DualAxisChart(
            data: chartSamples,
            dateKey: \.timestamp,
            rowsForPoint: { liveRows($0, primaryDomain: primaryDomain, secondaryDomain: secondaryDomain) },
            dateLabel: liveDateLabel,
            primaryAxisLabel: "°C / %",
            primaryDomain: primaryDomain,
            secondaryAxisLabel: "RPM",
            secondaryDomain: secondaryDomain
        ) {
            if seriesConfig.showCPUTemp {
                ForEach(chartSamples) { s in
                    if let v = s.cpuTempC {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("CPU"))
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
            }
            if seriesConfig.showGPUTemp {
                ForEach(chartSamples) { s in
                    if let v = s.gpuTempC {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("GPU"))
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
            }
            if seriesConfig.showFanRPM {
                ForEach(chartSamples) { s in
                    if let rpm = s.maxFanRPM.map({ Double($0) }) {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("RPM", mapValue(rpm, from: secondaryDomain, to: primaryDomain)),
                            series: .value(L("Series"), L("Fan"))
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [3, 2]))
                    }
                }
            }
            if seriesConfig.showCPULoad {
                ForEach(chartSamples) { s in
                    if let load = s.cpuLoad {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("%", load * 100),
                            series: .value(L("Series"), L("CPU load"))
                        )
                        .foregroundStyle(Color.orange.opacity(0.55))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [2, 3]))
                    }
                }
            }
            if seriesConfig.showGPULoad {
                ForEach(chartSamples) { s in
                    if let load = s.gpuLoad {
                        LineMark(
                            x: .value("Time", s.timestamp),
                            y: .value("%", load * 100),
                            series: .value(L("Series"), L("GPU load"))
                        )
                        .foregroundStyle(Color.blue.opacity(0.55))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [2, 3]))
                    }
                }
            }
            if seriesConfig.showCPUTemp && shouldShowWarningRule(in: primaryDomain) {
                RuleMark(y: .value("Warning", 75))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis {
            compactTimeAxisMarks(dates: chartSamples.map(\.timestamp), desiredCount: 8)
        }
        .chartLegend(position: .top, alignment: .leading)
        .padding(12)
    }

    private var historyHourlyChart: some View {
        let primaryDomain = hourlyPrimaryDomain(hourly)
        let secondaryDomain = hourlySecondaryDomain(hourly)
        return DualAxisChart(
            data: hourly,
            dateKey: \.hour,
            rowsForPoint: { h in
                var rows: [HoverRow] = []
                if seriesConfig.showCPUTemp {
                    rows.append(HoverRow(label: L("CPU peak"), color: .orange, value: h.cpuTempPeak))
                    rows.append(HoverRow(label: L("CPU avg"),  color: .orange.opacity(0.85), value: h.cpuTempAvg))
                    rows.append(HoverRow(label: L("CPU min"),  color: .orange.opacity(0.55), value: h.cpuTempMin))
                }
                if seriesConfig.showGPUTemp {
                    rows.append(HoverRow(label: L("GPU peak"), color: .blue, value: h.gpuTempPeak))
                }
                if seriesConfig.showFanRPM {
                    rows.append(HoverRow(
                        label: L("Fan RPM"),
                        color: .green,
                        plotValue: h.fanRpmPeak.map {
                            mapValue(Double($0), from: secondaryDomain, to: primaryDomain)
                        },
                        displayValue: h.fanRpmPeak.map { Double($0) },
                        unit: " RPM",
                        fractionDigits: 0
                    ))
                }
                return rows
            },
            dateLabel: { h in
                let f = DateFormatter()
                f.dateFormat = "EEE  MMM d  HH:00"
                return (f.string(from: h.hour), nil)
            },
            primaryAxisLabel: "°C",
            primaryDomain: primaryDomain,
            secondaryAxisLabel: "RPM",
            secondaryDomain: secondaryDomain
        ) {
            if seriesConfig.showCPUTemp {
                ForEach(hourly) { h in
                    if let lo = h.cpuTempMin, let hi = h.cpuTempPeak, hi > lo {
                        AreaMark(
                            x: .value("Hour", h.hour),
                            yStart: .value("Min", lo),
                            yEnd: .value("Max", hi)
                        )
                        .foregroundStyle(LinearGradient(
                            colors: [
                                Color.orange.opacity(0.22),
                                Color.orange.opacity(0.05),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .interpolationMethod(.monotone)
                    }
                }
                ForEach(hourly) { h in
                    if let v = h.cpuTempAvg {
                        LineMark(
                            x: .value("Hour", h.hour),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("CPU avg"))
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.0))
                    }
                }
            }
            if seriesConfig.showGPUTemp {
                ForEach(hourly) { h in
                    if let v = h.gpuTempAvg {
                        LineMark(
                            x: .value("Hour", h.hour),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("GPU avg"))
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.0))
                    }
                }
            }
            if seriesConfig.showFanRPM {
                ForEach(hourly) { h in
                    if let rpm = h.fanRpmPeak.map({ Double($0) }) {
                        LineMark(
                            x: .value("Hour", h.hour),
                            y: .value("RPM", mapValue(rpm, from: secondaryDomain, to: primaryDomain)),
                            series: .value(L("Series"), L("Fan"))
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 2]))
                    }
                }
            }
            if seriesConfig.showCPUTemp && shouldShowWarningRule(in: primaryDomain) {
                RuleMark(y: .value("Warning", 75))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis {
            compactTimeAxisMarks(dates: hourly.map(\.hour), desiredCount: 8)
        }
        .chartLegend(position: .top, alignment: .leading)
        .padding(12)
    }

    private var historyDailyChart: some View {
        let primaryDomain = dailyPrimaryDomain(daily)
        let secondaryDomain = dailySecondaryDomain(daily)
        return DualAxisChart(
            data: daily,
            dateKey: \.date,
            rowsForPoint: { d in
                var rows: [HoverRow] = []
                if seriesConfig.showCPUTemp {
                    rows.append(HoverRow(label: L("CPU peak"), color: .orange, value: d.cpuTempPeak))
                    rows.append(HoverRow(label: L("CPU avg"),  color: .orange.opacity(0.85), value: d.cpuTempAvg))
                    rows.append(HoverRow(label: L("CPU min"),  color: .orange.opacity(0.55), value: d.cpuTempMin))
                }
                if seriesConfig.showGPUTemp {
                    rows.append(HoverRow(label: L("GPU peak"), color: .blue, value: d.gpuTempPeak))
                    rows.append(HoverRow(label: L("GPU avg"), color: .blue.opacity(0.75), value: d.gpuTempAvg))
                }
                if seriesConfig.showFanRPM {
                    rows.append(HoverRow(
                        label: L("Fan peak"),
                        color: .green,
                        plotValue: d.fanRpmPeak.map {
                            mapValue(Double($0), from: secondaryDomain, to: primaryDomain)
                        },
                        displayValue: d.fanRpmPeak.map { Double($0) },
                        unit: " RPM",
                        fractionDigits: 0
                    ))
                }
                rows.append(HoverRow(
                    label: L("Samples"),
                    color: .secondary,
                    plotValue: nil,
                    displayValue: Double(d.sampleCount),
                    fractionDigits: 0
                ))
                return rows
            },
            dateLabel: { d in
                let f = DateFormatter()
                f.dateFormat = "EEE  MMM d"
                return (f.string(from: d.date), nil)
            },
            primaryAxisLabel: "°C",
            primaryDomain: primaryDomain,
            secondaryAxisLabel: "RPM",
            secondaryDomain: secondaryDomain
        ) {
            if seriesConfig.showCPUTemp {
                ForEach(daily) { d in
                    if let v = d.cpuTempPeak {
                        LineMark(
                            x: .value("Day", d.date),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("CPU peak"))
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.0))
                        .symbol(Circle())
                        .symbolSize(28)
                    }
                }
                ForEach(daily) { d in
                    if let v = d.cpuTempAvg {
                        LineMark(
                            x: .value("Day", d.date),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("CPU avg"))
                        )
                        .foregroundStyle(Color.orange.opacity(0.75))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.3))
                    }
                }
                ForEach(daily) { d in
                    if let v = d.cpuTempMin {
                        LineMark(
                            x: .value("Day", d.date),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("CPU min"))
                        )
                        .foregroundStyle(Color.orange.opacity(0.45))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [3, 2]))
                    }
                }
            }
            if seriesConfig.showGPUTemp {
                ForEach(daily) { d in
                    if let v = d.gpuTempPeak {
                        LineMark(
                            x: .value("Day", d.date),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("GPU peak"))
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .symbol(Circle())
                        .symbolSize(24)
                    }
                }
                ForEach(daily) { d in
                    if let v = d.gpuTempAvg {
                        LineMark(
                            x: .value("Day", d.date),
                            y: .value("°C", v),
                            series: .value(L("Series"), L("GPU avg"))
                        )
                        .foregroundStyle(Color.blue.opacity(0.6))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [3, 2]))
                    }
                }
            }
            if seriesConfig.showFanRPM {
                ForEach(daily) { d in
                    if let rpm = d.fanRpmPeak.map({ Double($0) }) {
                        LineMark(
                            x: .value("Day", d.date),
                            y: .value("RPM", mapValue(rpm, from: secondaryDomain, to: primaryDomain)),
                            series: .value(L("Series"), L("Fan"))
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 2]))
                        .symbol(Circle())
                        .symbolSize(22)
                    }
                }
            }
            if seriesConfig.showCPUTemp && shouldShowWarningRule(in: primaryDomain) {
                RuleMark(y: .value("Warning", 75))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis {
            compactDayAxisMarks(dates: daily.map(\.date), desiredCount: 8)
        }
        .chartLegend(position: .top, alignment: .leading)
        .padding(12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(String(format: L("%d data points"), sampleCount))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let url = exportedURL {
                Button(L("Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .font(.caption)
            }
        }
    }

    private var sampleCount: Int {
        switch aggregation {
        case .raw:    return samples.count
        case .hourly: return hourly.count
        case .daily:  return daily.count
        }
    }

    // MARK: - Data loading

    private func load() {
        loading = true
        let from: Date
        let to = Date()
        switch mode {
        case .live, .compare:
            from = Calendar.current.date(byAdding: .hour, value: -24, to: to)!
        case .history:
            from = Date(timeIntervalSinceNow: -range.seconds)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let db = Sampler.shared.databaseHandle
            let samples = (try? db.fetchSamples(
                from: Int64(from.timeIntervalSince1970),
                to:   Int64(to.timeIntervalSince1970))) ?? []
            let hourly = (try? db.fetchHourlyStats(
                from: Int64(from.timeIntervalSince1970),
                to:   Int64(to.timeIntervalSince1970))) ?? []
            let daily = (try? db.fetchDailyStats(
                from: Int64(from.timeIntervalSince1970),
                to:   Int64(to.timeIntervalSince1970))) ?? []
            let cfg = (try? db.loadConfig()) ?? Config()
            let finding = (try? BaselineComparator.run(database: db, config: cfg))

            DispatchQueue.main.async {
                self.samples = samples
                self.hourly = hourly
                self.daily = daily
                self.finding = finding
                self.loading = false
            }
        }
    }

    // MARK: - Export

    private func exportCSV() {
        let from: Date
        let to = Date()
        switch mode {
        case .live, .compare:
            from = Calendar.current.date(byAdding: .hour, value: -24, to: to)!
        case .history:
            from = Date(timeIntervalSinceNow: -range.seconds)
        }
        do {
            let url = try CSVExporter.exportSamples(from: from, to: to)
            exportedURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - ChartPoint
//
// Identifiable point for SwiftUI Charts ForEach.
// (Kept for any future external code that constructs series of
// raw time-stamped values; the new InteractiveChart can take any
// Identifiable directly.)

struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
    let series: String
}

// MARK: - ContentUnavailableViewCompat
//
// `ContentUnavailableView` is iOS 17+ / macOS 14+. For macOS 13 we
// substitute a custom layout.

struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
