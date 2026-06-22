import SwiftUI
import Charts

// MARK: - OverviewView
//
// The first thing the user sees when opening the dashboard. A
// at-a-glance summary of "how is my Mac doing today?" laid out as
// cards: today's peak temperatures, a 24-hour trend chart with
// min/max range band, a 7-day trend with range bars, and (if
// applicable) a status card for any active thermal alert.
//
// Data is loaded on appear and refreshed whenever a new sample is
// posted (so the numbers move in real time as the sampler runs).
//
// Every chart here uses `InteractiveChart` for iOS-Health-style
// hover interaction: hovering snaps to the nearest data point and
// shows a glass tooltip with all the relevant values formatted.

struct OverviewView: View {
    @State private var todayStats: SummaryStats?
    @State private var yesterdayStats: SummaryStats?
    @State private var hourly: [HourlyStats] = []
    @State private var last7Days: [DailyStats] = []
    @State private var loading: Bool = false
    @State private var latestSample: Sample?
    @State private var dustRisk: DustRiskAssessment?
    @State private var showDustRiskDetails = false
    @ObservedObject private var samplerObserver = SamplerObserver()

    /// Dashboard-wide series visibility. Stored in UserDefaults so toggles
    /// survive tab switches and the next app launch.
    @AppStorage("dashboard.series.showCPUTemp") private var showCPUTemp = true
    @AppStorage("dashboard.series.showGPUTemp") private var showGPUTemp = true
    @AppStorage("dashboard.series.showFanRPM")  private var showFanRPM = true
    @AppStorage("dashboard.series.showCPULoad") private var showCPULoad = true
    @AppStorage("dashboard.series.showGPULoad") private var showGPULoad = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if samplerObserver.isDemoMode { demoBanner }
                dustRiskCard
                statCardGrid
                sparklineCard
                weeklyTrendCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(
            for: Sampler.newSampleNotification)) { note in
            if let s = note.userInfo?[Sampler.sampleKey] as? Sample {
                latestSample = s
                // Light refresh: only re-fetch the small "today" summary,
                // not the whole 7-day window. That keeps the live view
                // responsive at 1 sample/min.
                refreshTodayOnly()
            }
        }
    }

    private var sparkConfig: ChartSeriesConfig {
        ChartSeriesConfig(
            showCPUTemp: showCPUTemp,
            showGPUTemp: showGPUTemp,
            showFanRPM: showFanRPM,
            showCPULoad: showCPULoad,
            showGPULoad: showGPULoad
        )
    }

    private var sparkConfigBinding: Binding<ChartSeriesConfig> {
        Binding {
            sparkConfig
        } set: { newValue in
            showCPUTemp = newValue.showCPUTemp
            showGPUTemp = newValue.showGPUTemp
            showFanRPM = newValue.showFanRPM
            showCPULoad = newValue.showCPULoad
            showGPULoad = newValue.showGPULoad
        }
    }

    private func overviewPrimaryDomain(_ data: [HourlyStats]) -> ClosedRange<Double> {
        var values: [Double] = []
        if sparkConfig.showCPUTemp {
            values += data.compactMap(\.cpuTempMin)
            values += data.compactMap(\.cpuTempAvg)
            values += data.compactMap(\.cpuTempPeak)
        }
        if sparkConfig.showGPUTemp {
            values += data.compactMap(\.gpuTempAvg)
            values += data.compactMap(\.gpuTempPeak)
        }
        return paddedAxisDomain(values: values, fallback: 0...100, minSpan: 12)
    }

    private func overviewSecondaryDomain(_ data: [HourlyStats]) -> ClosedRange<Double> {
        let values = sparkConfig.showFanRPM
            ? data.compactMap { $0.fanRpmPeak.map { Double($0) } }
            : []
        return paddedAxisDomain(
            values: values,
            fallback: 0...4800,
            minSpan: 800,
            clampLowerToZero: true
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L("Overview")).font(.title2).fontWeight(.semibold)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if let sample = latestSample ?? Sampler.shared.latest {
                    Text(String(format: L("Updated %@"), relativeTime(sample.timestamp)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L("Live summary of CPU/GPU temperature, fan activity, and recent trends."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Dust risk
    //
    // Shows the current dust risk derived from the baseline comparator.
    // The card stays visible even when the answer is "none" or "not enough
    // data" so users can understand what the algorithm currently knows.

    // Banner shown when the user is in demo mode. Explains what
    // they're looking at and links to the toggle in Settings.
    private var demoBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            DemoModeBadge()
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Demo data is showing")).font(.headline)
                Text(L("Temperatures and fan RPM are synthesized, not from the SMC. Open Settings to turn this off (once SMC reads are working)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.3)))
    }

    private var dustRiskCard: some View {
        let assessment = currentDustRisk
        let color = dustRiskColor(assessment.level)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: dustRiskIcon(assessment.level))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(dustRiskTitle(assessment.level))
                    .font(.headline)
                    .foregroundStyle(color)
                Text(dustRiskSummary(assessment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                showDustRiskDetails.toggle()
            } label: {
                Image(systemName: assessment.evidence == nil ? "info.circle" : "exclamationmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(color)
            .help(L("Show risk details"))
            .popover(isPresented: $showDustRiskDetails, arrowEdge: .trailing) {
                dustRiskDetails(assessment)
                    .frame(width: 320)
                    .padding(14)
            }
        }
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.28)))
    }

    private var currentDustRisk: DustRiskAssessment {
        dustRisk ?? DustRiskAssessment(
            level: .insufficientData,
            evidence: nil,
            baselineSampleCount: 0,
            recentSampleCount: todayStats?.sampleCount ?? 0,
            requiredSamplesPerWindow: 60,
            baselineCoverage: 0,
            recentCoverage: 0,
            referenceDayCount: 0,
            requiredReferenceDays: 7
        )
    }

    private func dustRiskTitle(_ level: DustRiskAssessment.Level) -> String {
        switch level {
        case .insufficientData:
            return L("Current dust risk: low")
        case .none:
            return L("Current dust risk: none")
        case .minor:
            return L("Current dust risk: minor")
        case .elevated:
            return L("Current dust risk: watching")
        case .needsCleaning:
            return L("Current dust risk: cleaning recommended")
        }
    }

    private func dustRiskIcon(_ level: DustRiskAssessment.Level) -> String {
        switch level {
        case .insufficientData: return "leaf.fill"
        case .none: return "checkmark.seal.fill"
        case .minor: return "chart.line.uptrend.xyaxis"
        case .elevated: return "exclamationmark.triangle.fill"
        case .needsCleaning: return "exclamationmark.octagon.fill"
        }
    }

    private func dustRiskColor(_ level: DustRiskAssessment.Level) -> Color {
        switch level {
        case .insufficientData, .none: return .green
        case .minor: return .orange
        case .elevated: return Color(red: 0.95, green: 0.45, blue: 0.05)
        case .needsCleaning: return .red
        }
    }

    private func dustRiskSummary(_ assessment: DustRiskAssessment) -> String {
        switch assessment.level {
        case .insufficientData:
            return String(
                format: L("Sample count is still insufficient: %d reference and %d recent samples. Keep the app running in the background for more accurate analysis."),
                assessment.baselineSampleCount,
                assessment.recentSampleCount
            )
        case .none:
            return L("No statistically significant loss versus the best cooling reference was found.")
        case .minor:
            guard let evidence = assessment.evidence else {
                return L("A small but significant thermal shift was found.")
            }
            return String(
                format: L("%@ shows a small rise at load level %d."),
                evidence.subsystem.rawValue,
                evidence.cpuPState
            )
        case .elevated:
            guard let evidence = assessment.evidence else {
                return L("A thermal signal is visible, but it is not corroborated enough to recommend cleaning.")
            }
            return String(
                format: L("%@ shows a stronger signal, but more reference days or corroborating buckets are needed."),
                evidence.subsystem.rawValue
            )
        case .needsCleaning:
            guard let evidence = assessment.evidence else {
                return L("The cooling reference comparison found a clear capacity drop.")
            }
            return String(
                format: L("%@ cooling capacity appears reduced versus its best reference at load level %d."),
                evidence.subsystem.rawValue,
                evidence.cpuPState
            )
        }
    }

    private func dustRiskDetails(_ assessment: DustRiskAssessment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: dustRiskIcon(assessment.level))
                    .foregroundStyle(dustRiskColor(assessment.level))
                Text(dustRiskTitle(assessment.level))
                    .font(.headline)
            }

            Text(dustRiskDetailText(assessment))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(String(
                format: L("Reference samples: %d · Recent samples: %d"),
                assessment.baselineSampleCount,
                assessment.recentSampleCount
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func dustRiskDetailText(_ assessment: DustRiskAssessment) -> String {
        guard let evidence = assessment.evidence else {
            if assessment.level == .insufficientData {
                return String(
                    format: L("The current algorithm compares the recent window with a best-observed cooling reference model. It needs at least %d raw samples in the reference model and recent window before it can compare cooling capacity reliably. You can calibrate the reference in Settings after cleaning dust or confirming the machine is healthy. Keep the app running in the background for long-term analysis; sampling is lightweight and designed for low power use. Current readiness: reference %.0f%%, recent coverage %.0f%%."),
                    assessment.requiredSamplesPerWindow,
                    assessment.baselineCoverage * 100,
                    assessment.recentCoverage * 100
                )
            }
            return L("The current algorithm compares recent temperatures against the best observed cooling reference at the same workload. No significant cooling-capacity drop was found.")
        }

        let signal = evidence.ambientCorrected
            ? String(format: L("Heat rise over idle increased by %.1f°C versus reference."), evidence.riseDelta)
            : String(format: L("Median temperature increased by %.1f°C versus reference."), evidence.tempDelta)
        let fan = String(format: L("Fan speed changed by %+.0f RPM at the same load."), evidence.fanDelta)
        let stats = String(
            format: L("The signal is at load level %d with p = %.3f."),
            evidence.cpuPState,
            evidence.pValue
        )
        let support = String(
            format: L("Evidence support: %d reference days, %d recent signal days, %d supporting load buckets."),
            evidence.referenceDayCount,
            evidence.supportingRecentDayCount,
            evidence.supportingBucketCount
        )
        let requirement = assessment.level == .elevated
            ? String(
                format: L("Cleaning recommendation requires at least %d reference days and corroboration across multiple recent days or load buckets."),
                assessment.requiredReferenceDays
            )
            : ""
        return [signal, fan, stats, support, requirement]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Stat cards grid
    //
    // 2x2 grid: today CPU peak, today GPU peak, today fan peak,
    // minutes above threshold. Each card shows a value, a delta
    // vs yesterday, and a tiny sparkline of the last 24h of the
    // relevant metric. Sparklines come from the same `hourly`
    // array that's already loaded — no extra DB queries.

    private var statCardGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard(
                title: L("Today · CPU peak"),
                value: todayStats?.cpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—",
                delta: deltaString(current: todayStats?.cpuTempPeak, previous: yesterdayStats?.cpuTempPeak),
                icon: "thermometer.medium",
                tint: .orange,
                sparklinePrimary: hourly.map { $0.cpuTempPeak },
                sparklineSecondary: hourly.map { $0.gpuTempPeak },
                secondaryTint: .blue,
                sparklineCaption: sparklineCaption24h { $0.cpuTempPeak },
                sparklineTint: .orange,
                warning: (todayStats?.cpuTempPeak ?? 0) >= 75
            )
            statCard(
                title: L("Today · GPU peak"),
                value: todayStats?.gpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—",
                delta: deltaString(current: todayStats?.gpuTempPeak, previous: yesterdayStats?.gpuTempPeak),
                icon: "display",
                tint: .blue,
                sparklinePrimary: hourly.map { $0.gpuTempPeak },
                sparklineSecondary: nil,
                secondaryTint: .clear,
                sparklineCaption: sparklineCaption24h { $0.gpuTempPeak },
                sparklineTint: .blue,
                warning: (todayStats?.gpuTempPeak ?? 0) >= 75
            )
            statCard(
                title: L("Today · Fan peak"),
                value: todayStats?.fanRpmPeak.map { "\($0) RPM" } ?? "—",
                delta: deltaString(current: todayStats?.fanRpmAvg, previous: yesterdayStats?.fanRpmAvg, suffix: " RPM"),
                icon: "fan.fill",
                tint: .green,
                sparklinePrimary: hourly.map { $0.fanRpmPeak.map { Double($0) } },
                sparklineSecondary: nil,
                secondaryTint: .clear,
                sparklineCaption: sparklineCaption24h { $0.fanRpmPeak.map(Double.init) },
                sparklineTint: .green,
                warning: false
            )
            statCard(
                title: L("Above 70°C today"),
                value: "\(todayStats?.cpuMinutesAboveThreshold ?? 0) min",
                delta: nil,
                icon: "flame.fill",
                tint: .red,
                sparklinePrimary: nil,
                sparklineSecondary: nil,
                secondaryTint: .clear,
                sparklineCaption: hourlyBarSummary,
                sparklineTint: .red,
                warning: (todayStats?.cpuMinutesAboveThreshold ?? 0) > 0
            )
        }
    }

    @ViewBuilder
    private func statCard(title: String,
                          value: String,
                          delta: String?,
                          icon: String,
                          tint: Color,
                          sparklinePrimary: [Double?]?,
                          sparklineSecondary: [Double?]?,
                          secondaryTint: Color,
                          sparklineCaption: String,
                          sparklineTint: Color,
                          warning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(value)
                .font(.system(.title, design: .rounded))
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(warning ? .red : .primary)
            if let delta = delta {
                Text(delta)
                    .font(.caption2)
                    .foregroundStyle(deltaColor(delta))
            } else {
                Text(" ").font(.caption2)  // placeholder for layout stability
            }
            // Sparkline area. Either a line chart for temp/fan cards
            // or a small bar histogram for the "minutes above 70" card.
            if let sparklinePrimary, !sparklinePrimary.allSatisfy({ $0 == nil }) {
                MiniSparkline(
                    values: sparklinePrimary,
                    tint: sparklineTint,
                    secondary: sparklineSecondary,
                    secondaryTint: secondaryTint
                )
                .frame(height: 36)
            } else if title.hasPrefix("Above 70") {
                // Mini hourly bar histogram of peak CPU temps > 70
                MiniHotBar(hourly: hourly)
                    .frame(height: 36)
            } else {
                // placeholder height to keep cards aligned when no sparkline
                Color.clear.frame(height: 36)
            }
            Text(sparklineCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Short caption rendered below each card's sparkline. Uses the
    /// pre-loaded `hourly` array so we don't hit the DB. Returns the
    /// "min – max · avg" range for the metric over the last 24h.
    /// Takes a `Double?` getter; Int fields (like fan RPM) are
    /// converted to Double at the call site.
    private func sparklineCaption24h(_ getter: (HourlyStats) -> Double?) -> String {
        let values = hourly.compactMap(getter)
        guard !values.isEmpty else { return L("no data yet") }
        let lo = values.min()!
        let hi = values.max()!
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: L("24h range %.1f–%.1f  ·  avg %.1f"), lo, hi, avg)
    }

    /// Caption for the "Above 70°C" card: a textual breakdown of how
    /// many hours spent above the threshold vs below it.
    private var hourlyBarSummary: String {
        let hot = hourly.filter { ($0.cpuTempPeak ?? 0) >= 70 }.count
        if hot == 0 {
            return L("no hours ≥ 70°C in last 24h")
        }
        return String(format: L("%d hours · ≥ 70°C in 24h"), hot, hourly.count)
    }

    // MARK: - 24h interactive chart
    //
    // The main "today" chart. Three layers of information:
    //   1. A soft orange area band from CPU min → CPU peak (the
    //      temperature "spread" through the hour)
    //   2. CPU avg and GPU avg lines on top
    //   3. The 75°C warning line
    // Hovering snaps to the nearest hour and shows a glass tooltip
    // with peak/avg/min for both CPU and GPU.

    private var sparklineCard: some View {
        ChartCard(
            title: L("Last 24 hours"),
            trailing: AnyView(
                HStack(spacing: 10) {
                    SeriesToggleBar(
                        config: sparkConfigBinding,
                        // Hourly aggregates have no CPU/GPU load data,
                        // so the load toggles are no-ops for this chart.
                        available: [.cpuTemp, .gpuTemp, .fanRPM]
                    )
                    if let range = chartDateRangeLabel(hourly.map(\.hour)) {
                        Text(range)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            )
        ) {
            if hourly.isEmpty {
                ContentUnavailableViewCompat(
                    title: L("No hourly data yet"),
                    systemImage: "chart.xyaxis.line",
                    description: L("Data is rolled up to hourly buckets after a few hours of running.")
                )
                .frame(height: 200)
            } else {
                let primaryDomain = overviewPrimaryDomain(hourly)
                let secondaryDomain = overviewSecondaryDomain(hourly)
                DualAxisChart(
                    data: hourly,
                    dateKey: \.hour,
                    rowsForPoint: {
                        overviewSparklineRows(
                            $0,
                            primaryDomain: primaryDomain,
                            secondaryDomain: secondaryDomain
                        )
                    },
                    dateLabel: { p in
                        let f = DateFormatter()
                        f.dateFormat = "EEE  MMM d"
                        let header = f.string(from: p.hour)
                        let f2 = DateFormatter()
                        f2.dateFormat = "HH:00"
                        return (header, f2.string(from: p.hour))
                    },
                    primaryAxisLabel: "°C",
                    primaryDomain: primaryDomain,
                    secondaryAxisLabel: "RPM",
                    secondaryDomain: secondaryDomain
                ) {
                    // CPU min-max band — only when CPU series is on.
                    if sparkConfig.showCPUTemp {
                        ForEach(hourly) { h in
                            if let lo = h.cpuTempMin, let hi = h.cpuTempPeak {
                                AreaMark(
                                    x: .value("Hour", h.hour),
                                    yStart: .value("Min", lo),
                                    yEnd: .value("Peak", hi)
                                )
                                .foregroundStyle(LinearGradient(
                                    colors: [
                                        Color.orange.opacity(0.28),
                                        Color.orange.opacity(0.06),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ))
                                .interpolationMethod(.monotone)
                            }
                        }
                    }

                    if sparkConfig.showCPUTemp {
                        ForEach(hourly) { h in
                            if let v = h.cpuTempAvg {
                                LineMark(
                                    x: .value("Hour", h.hour),
                                    y: .value("°C", v),
                                    series: .value("Series", L("CPU"))
                                )
                                .foregroundStyle(.orange)
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2.0))
                            }
                        }
                    }

                    if sparkConfig.showGPUTemp {
                        ForEach(hourly) { h in
                            if let v = h.gpuTempAvg {
                                LineMark(
                                    x: .value("Hour", h.hour),
                                    y: .value("°C", v),
                                    series: .value("Series", L("GPU"))
                                )
                                .foregroundStyle(.blue)
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 2.0))
                            }
                        }
                    }

                    if sparkConfig.showFanRPM {
                        ForEach(hourly) { h in
                            if let rpm = h.fanRpmPeak.map({ Double($0) }) {
                                LineMark(
                                    x: .value("Hour", h.hour),
                                    y: .value("RPM", mapValue(rpm, from: secondaryDomain, to: primaryDomain)),
                                    series: .value("Series", L("Fan"))
                                )
                                .foregroundStyle(.green)
                                .interpolationMethod(.monotone)
                                .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 2]))
                            }
                        }
                    }

                    // 75°C warning rule (only when CPU temp is visible
                    // — otherwise the rule has nothing to relate to).
                    if sparkConfig.showCPUTemp && shouldShowWarningRule(in: primaryDomain) {
                        RuleMark(y: .value("Warning", 75))
                            .foregroundStyle(.red.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading, spacing: 2) {
                                Text(L("75°C"))
                                    .font(.caption2)
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                    }
                }
                .chartXAxis {
                    compactTimeAxisMarks(dates: hourly.map(\.hour), desiredCount: 6)
                }
                .frame(height: 200)
            }
        }
    }

    /// Tooltip rows for the 24h chart. Each row is only included
    /// when its series is enabled, so the tooltip never advertises
    /// a value the user can't see on the chart.
    private func overviewSparklineRows(
        _ h: HourlyStats,
        primaryDomain: ClosedRange<Double>,
        secondaryDomain: ClosedRange<Double>
    ) -> [HoverRow] {
        var rows: [HoverRow] = []
        if sparkConfig.showCPUTemp {
            rows.append(HoverRow(label: L("CPU peak"), color: .orange, value: h.cpuTempPeak))
            rows.append(HoverRow(label: L("CPU avg"),  color: .orange.opacity(0.85), value: h.cpuTempAvg))
            rows.append(HoverRow(label: L("CPU min"),  color: .orange.opacity(0.55), value: h.cpuTempMin))
        }
        if sparkConfig.showGPUTemp {
            rows.append(HoverRow(label: L("GPU avg"),  color: .blue, value: h.gpuTempAvg))
        }
        if sparkConfig.showFanRPM {
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
    }

    // MARK: - 7-day trend
    //
    // Daily CPU trend as lines rather than bars. This keeps one- or
    // two-day ranges readable without oversized bars and avoids
    // mixed bar/line center alignment issues.

    private var weeklyTrendCard: some View {
        ChartCard(
            title: L("Last 7 days · daily peak CPU"),
            trailing: AnyView(
                Text(L("hover for details"))
                    .font(.caption2).foregroundStyle(.secondary)
            )
        ) {
            if last7Days.isEmpty {
                ContentUnavailableViewCompat(
                    title: L("Not enough data yet"),
                    systemImage: "calendar",
                    description: L("After a week of running, you'll see a daily trend here.")
                )
                .frame(height: 180)
            } else {
                let primaryDomain = weeklyTrendDomain(last7Days)
                InteractiveChart(
                    data: last7Days,
                    dateKey: \.date,
                    rowsForPoint: weeklyTrendRows,
                    dateLabel: { d in
                        let f = DateFormatter()
                        f.dateFormat = "EEE  MMM d"
                        return (f.string(from: d.date), nil)
                    }
                ) {
                    ForEach(last7Days) { d in
                        if let v = d.cpuTempPeak {
                            LineMark(
                                x: .value("Day", d.date),
                                y: .value("°C", v),
                                series: .value("Series", L("CPU peak"))
                            )
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2.0))
                            .symbol(Circle())
                            .symbolSize(28)
                        }
                    }
                    ForEach(last7Days) { d in
                        if let v = d.cpuTempAvg {
                            LineMark(
                                x: .value("Day", d.date),
                                y: .value("°C", v),
                                series: .value("Series", L("CPU avg"))
                            )
                            .foregroundStyle(Color.orange.opacity(0.75))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.3))
                        }
                    }
                    ForEach(last7Days) { d in
                        if let v = d.cpuTempMin {
                            LineMark(
                                x: .value("Day", d.date),
                                y: .value("°C", v),
                                series: .value("Series", L("CPU min"))
                            )
                            .foregroundStyle(Color.orange.opacity(0.45))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [3, 2]))
                        }
                    }

                    if shouldShowWarningRule(in: primaryDomain) {
                        RuleMark(y: .value("Warning", 75))
                            .foregroundStyle(.red.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXAxis {
                    compactDayAxisMarks(dates: last7Days.map(\.date), desiredCount: 7)
                }
                .chartYScale(domain: primaryDomain.lowerBound...primaryDomain.upperBound)
                .frame(height: 180)
            }
        }
    }

    /// Tooltip rows for the 7-day chart.
    private func weeklyTrendRows(_ d: DailyStats) -> [HoverRow] {
        [
            HoverRow(label: L("CPU peak"), color: .orange, value: d.cpuTempPeak),
            HoverRow(label: L("CPU avg"),  color: .orange.opacity(0.85), value: d.cpuTempAvg),
            HoverRow(label: L("CPU min"),  color: .orange.opacity(0.55), value: d.cpuTempMin),
            HoverRow(label: L("GPU peak"), color: .blue,   value: d.gpuTempPeak),
            HoverRow(label: L("Fan peak"), color: .green,  value: d.fanRpmPeak.map { Double($0) },
                     unit: " RPM", fractionDigits: 0),
            HoverRow(label: L("Samples"),  color: .secondary,
                     value: Double(d.sampleCount), unit: "", fractionDigits: 0),
        ]
    }

    private func weeklyTrendDomain(_ data: [DailyStats]) -> ClosedRange<Double> {
        let values = data.compactMap(\.cpuTempMin)
            + data.compactMap(\.cpuTempAvg)
            + data.compactMap(\.cpuTempPeak)
        return paddedAxisDomain(values: values, fallback: 0...100, minSpan: 12)
    }

    // MARK: - Data loading

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cal = Calendar.current
            let now = Date()
            let startOfToday = cal.startOfDay(for: now)
            let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
            let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: startOfToday)!

            let db = Sampler.shared.databaseHandle
            let today = (try? db.fetchSummaryStats(
                from: Int64(startOfToday.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? nil
            let yesterday = (try? db.fetchSummaryStats(
                from: Int64(startOfYesterday.timeIntervalSince1970),
                to:   Int64(startOfToday.timeIntervalSince1970))) ?? nil
            let hourly = (try? db.fetchHourlyStats(
                from: Int64(cal.date(byAdding: .day, value: -1, to: now)!.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? []
            let daily = (try? db.fetchDailyStats(
                from: Int64(sevenDaysAgo.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))) ?? []
            let cfg = (try? db.loadConfig()) ?? Config()
            let risk = (try? BaselineComparator.assessDustRisk(database: db, config: cfg))

            DispatchQueue.main.async {
                self.todayStats = today
                self.yesterdayStats = yesterday
                self.hourly = hourly
                self.last7Days = daily
                self.dustRisk = risk
                self.loading = false
            }
        }
    }

    /// Lightweight re-fetch that only updates the "today" summary and
    /// the latest sample timestamp. The hourly chart and weekly bars
    /// don't need to redraw on every 1-minute sample.
    private func refreshTodayOnly() {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        DispatchQueue.global(qos: .utility).async {
            let db = Sampler.shared.databaseHandle
            let today = try? db.fetchSummaryStats(
                from: Int64(startOfToday.timeIntervalSince1970),
                to:   Int64(now.timeIntervalSince1970))
            DispatchQueue.main.async {
                if let today = today { self.todayStats = today }
            }
        }
    }

    // MARK: - Formatting helpers

    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func deltaString(current: Double?, previous: Double?, suffix: String = "°C") -> String? {
        guard let c = current, let p = previous, p != 0 else { return nil }
        let delta = c - p
        let arrow = delta > 0.1 ? "▲" : (delta < -0.1 ? "▼" : "•")
        let arrowDelta = String(format: "%+.1f", delta)
        return "\(arrow) \(arrowDelta) \(suffix) \(L("vs yesterday"))"
    }

    private func deltaColor(_ s: String) -> Color {
        if s.contains("▲") { return .red }
        if s.contains("▼") { return .green }
        return .secondary
    }
}

// MARK: - MiniHotBar
//
// Tiny 24-bin bar histogram used in the "Above 70°C today" card.
// Each bin is a single hour; bar height = peak CPU temp on a
// dynamic scale that still includes the 70°C reference. Bars >= 70°C are tinted red; cooler bars are
// secondary-tinted so the visual emphasis is on "where it was
// hot." Drawn from the in-memory `hourly` array — no DB hit.

private struct MiniHotBar: View {
    let hourly: [HourlyStats]

    var body: some View {
        Chart {
            ForEach(hourly) { h in
                let v = h.cpuTempPeak ?? 0
                BarMark(
                    x: .value("h", h.hour),
                    y: .value("°C", v)
                )
                .foregroundStyle(v >= 70 ? .red.opacity(0.85) : .secondary.opacity(0.25))
                .cornerRadius(1)
            }
            RuleMark(y: .value("70", 70))
                .foregroundStyle(.red.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .allowsHitTesting(false)
    }

    private var yDomain: ClosedRange<Double> {
        paddedAxisDomain(
            values: hourly.compactMap(\.cpuTempPeak) + [70],
            fallback: 0...100,
            minSpan: 20
        )
    }
}

// MARK: - Legend dot
//
// A small colored marker + label, used in chart headers. The
// marker is a solid dot by default, but can be rendered as a
// short dashed segment so dashed chart lines (e.g. Fan RPM on
// the dual-axis chart) match their visual treatment.

struct LegendDot: View {
    enum LineStyle { case solid, dashed }
    let color: Color
    let label: String
    var lineStyle: LineStyle = .solid

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if lineStyle == .solid {
                    Circle().fill(color).frame(width: 8, height: 8)
                } else {
                    Capsule()
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, dash: [2.5, 1.5]))
                        .frame(width: 14, height: 8)
                }
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
