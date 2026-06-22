import SwiftUI
import Charts

// MARK: - HoverRow

struct HoverRow: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
    /// Value used for the chart's y-coordinate. May be normalized
    /// (e.g. RPM/100) to fit a shared y-scale with another series.
    let plotValue: Double?
    /// Value rendered in the tooltip. Always in the row's native
    /// units so the user sees the real number.
    let displayValue: Double?
    let unit: String
    let fractionDigits: Int

    init(label: String, color: Color, value: Double?,
         unit: String = "", fractionDigits: Int = 1) {
        self.label = label
        self.color = color
        self.plotValue = value
        self.displayValue = value
        self.unit = unit
        self.fractionDigits = fractionDigits
    }

    init(label: String, color: Color,
         plotValue: Double?, displayValue: Double?,
         unit: String = "", fractionDigits: Int = 1) {
        self.label = label
        self.color = color
        self.plotValue = plotValue
        self.displayValue = displayValue
        self.unit = unit
        self.fractionDigits = fractionDigits
    }

    var formatted: String {
        guard let v = displayValue else { return "—" }
        if fractionDigits == 0 {
            return String(Int(v.rounded())) + unit
        }
        return String(format: "%.\(fractionDigits)f", v) + unit
    }
}

// MARK: - HoverCard

struct HoverCard: View {
    let rows: [HoverRow]
    let header: String
    let subheader: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(header)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                if let sub = subheader {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Divider().padding(.vertical, 1)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 7, height: 7)
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.formatted)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: ChartTooltipMetrics.cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
    }
}

private enum ChartTooltipMetrics {
    static let cardWidth: CGFloat = 188
    static let edgePad: CGFloat = 8
    static let cursorGap: CGFloat = 14
}

private func cursorTooltipXOffset(
    cursorPlotX: CGFloat,
    chartWidth: CGFloat,
    plotFrame: CGRect
) -> CGFloat {
    let cursorX = plotFrame.minX + cursorPlotX
    let rightX = cursorX + ChartTooltipMetrics.cursorGap
    let leftX = cursorX - ChartTooltipMetrics.cardWidth - ChartTooltipMetrics.cursorGap
    let maxX = max(
        ChartTooltipMetrics.edgePad,
        chartWidth - ChartTooltipMetrics.cardWidth - ChartTooltipMetrics.edgePad
    )

    let unclamped = rightX <= maxX ? rightX : leftX
    return min(
        max(unclamped, ChartTooltipMetrics.edgePad),
        maxX
    )
}

private func fixedTooltipYOffset(plotFrame: CGRect) -> CGFloat {
    plotFrame.minY + ChartTooltipMetrics.edgePad
}

// MARK: - Series visibility
//
// User-controllable visibility of each plottable series. The
// chart wrappers don't need to know about this — the caller's
// `chartContent` and `rowsForPoint` closures read `config.showXxx`
// to decide whether to render a line or include a tooltip row.
// The toggle pills in the card header write to the same config.

struct ChartSeriesConfig: Equatable {
    var showCPUTemp: Bool = true
    var showGPUTemp: Bool = true
    var showFanRPM:  Bool = true
    var showCPULoad: Bool = true
    var showGPULoad: Bool = true
}

/// Which series a chart is able to display. Charts whose source
/// data lacks CPU/GPU load (e.g. hourly/daily aggregates) pass a
/// smaller set so the toggle bar doesn't show no-op controls.
enum SeriesKind: Hashable, CaseIterable {
    case cpuTemp, gpuTemp, fanRPM, cpuLoad, gpuLoad

    var label: String {
        switch self {
        case .cpuTemp: return L("CPU")
        case .gpuTemp: return L("GPU")
        case .fanRPM:  return L("Fan")
        case .cpuLoad: return L("CPU%")
        case .gpuLoad: return L("GPU%")
        }
    }

    var defaultColor: Color {
        switch self {
        case .cpuTemp: return .orange
        case .gpuTemp: return .blue
        case .fanRPM:  return .green
        case .cpuLoad: return Color.orange.opacity(0.55)
        case .gpuLoad: return Color.blue.opacity(0.55)
        }
    }

    /// Whether this series is rendered as a dashed line in the
    /// chart body. Currently only Fan RPM, so the visual treatment
    /// matches the legend pill.
    var isDashed: Bool { self == .fanRPM }
}

/// A row of pill-shaped toggles shown in a chart's title bar. One
/// pill per available series; click to toggle visibility. Color
/// dot dims to gray when off so the user can see at a glance which
/// series are active.
struct SeriesToggleBar: View {
    @Binding var config: ChartSeriesConfig
    let available: Set<SeriesKind>

    var body: some View {
        HStack(spacing: 5) {
            ForEach(SeriesKind.allCases.filter { available.contains($0) }, id: \.self) { kind in
                toggle(for: kind)
            }
        }
    }

    @ViewBuilder
    private func toggle(for kind: SeriesKind) -> some View {
        let isOn = bindingFor(kind)
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Group {
                    if kind.isDashed {
                        Capsule()
                            .stroke(isOn.wrappedValue ? kind.defaultColor : Color.gray.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1.6, dash: [2.5, 1.5]))
                            .frame(width: 12, height: 7)
                    } else {
                        Circle()
                            .fill(isOn.wrappedValue ? kind.defaultColor : Color.gray.opacity(0.35))
                            .frame(width: 8, height: 8)
                    }
                }
                Text(kind.label)
                    .font(.caption2)
                    .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isOn.wrappedValue
                          ? kind.defaultColor.opacity(0.15)
                          : Color.gray.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(String(format: L("Toggle %@ series"), kind.label))
    }

    private func bindingFor(_ kind: SeriesKind) -> Binding<Bool> {
        switch kind {
        case .cpuTemp: return $config.showCPUTemp
        case .gpuTemp: return $config.showGPUTemp
        case .fanRPM:  return $config.showFanRPM
        case .cpuLoad: return $config.showCPULoad
        case .gpuLoad: return $config.showGPULoad
        }
    }
}

// MARK: - HoverEngine
//
// Shared hover-detection logic used by both `InteractiveChart` and
// `DualAxisChart`.
//
// Two kinds of state are tracked:
//   - the cursor's plot-area X, used to draw the guideline exactly
//     over the chart plot, not over the full overlay including axes.
//   - the nearest data-point index, used for snapped dots/tooltips.
//
// The nearest-data search is O(log N) via binary search, since
// all our data is sorted by time (samples / hourly / daily
// tables all return rows in time order).

struct HoverEngine<DataPoint: Identifiable> {
    let data: [DataPoint]
    let dateKey: KeyPath<DataPoint, Date>

    /// Returns the index of the data point nearest to `date` in
    /// the time-sorted `data` array. O(log N).
    func nearestIndex(to date: Date) -> Int? {
        guard !data.isEmpty else { return nil }
        var lo = 0
        var hi = data.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let midDate = data[mid][keyPath: dateKey]
            if midDate < date {
                lo = mid + 1
            } else if midDate > date {
                hi = mid - 1
            } else {
                return mid
            }
        }
        if lo >= data.count { return data.count - 1 }
        if hi < 0 { return 0 }
        let loDate = data[lo][keyPath: dateKey]
        let hiDate = data[hi][keyPath: dateKey]
        return abs(loDate.timeIntervalSince(date)) <=
               abs(hiDate.timeIntervalSince(date)) ? lo : hi
    }
}

// MARK: - Axis scaling helpers

func paddedAxisDomain(
    values: [Double],
    fallback: ClosedRange<Double>,
    minSpan: Double,
    paddingFraction: Double = 0.12,
    clampLowerToZero: Bool = false
) -> ClosedRange<Double> {
    let finiteValues = values.filter { $0.isFinite }
    guard let minValue = finiteValues.min(), let maxValue = finiteValues.max() else {
        return fallback
    }

    let span = maxValue - minValue
    let lower: Double
    let upper: Double

    if span < minSpan {
        let center = (minValue + maxValue) / 2
        lower = center - minSpan / 2
        upper = center + minSpan / 2
    } else {
        let padding = span * paddingFraction
        lower = minValue - padding
        upper = maxValue + padding
    }

    let clampedLower = clampLowerToZero ? max(0, lower) : lower
    if clampedLower < upper {
        return clampedLower...upper
    }
    return fallback
}

func mapValue(_ value: Double, from source: ClosedRange<Double>, to target: ClosedRange<Double>) -> Double {
    let sourceSpan = source.upperBound - source.lowerBound
    guard sourceSpan != 0 else {
        return (target.lowerBound + target.upperBound) / 2
    }
    let ratio = (value - source.lowerBound) / sourceSpan
    return target.lowerBound + ratio * (target.upperBound - target.lowerBound)
}

func chartDateRangeLabel(_ dates: [Date]) -> String? {
    guard let start = dates.min(), let end = dates.max() else { return nil }
    let calendar = Calendar.current
    let startDay = calendar.startOfDay(for: start)
    let endDay = calendar.startOfDay(for: end)

    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        ? "MMM d"
        : "MMM d, yyyy"

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm"

    if startDay == endDay {
        return "\(dayFormatter.string(from: start))  \(timeFormatter.string(from: start))-\(timeFormatter.string(from: end))"
    }
    return "\(dayFormatter.string(from: start)) - \(dayFormatter.string(from: end))"
}

private func timeAxisLabel(for date: Date, in dates: [Date]) -> String {
    let span = (dates.max()?.timeIntervalSince(dates.min() ?? date)) ?? 0
    let calendar = Calendar.current

    if span <= 2 * 86_400 {
        let hourFormatter = DateFormatter()
        hourFormatter.dateFormat = "HH:mm"
        if calendar.component(.hour, from: date) == 0 {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "M/d"
            return "\(dayFormatter.string(from: date))\n\(hourFormatter.string(from: date))"
        }
        return hourFormatter.string(from: date)
    }

    let formatter = DateFormatter()
    formatter.dateFormat = span > 370 * 86_400 ? "MMM yyyy" : "MMM d"
    return formatter.string(from: date)
}

private func dayAxisLabel(for date: Date, in dates: [Date]) -> String {
    let span = (dates.max()?.timeIntervalSince(dates.min() ?? date)) ?? 0
    let formatter = DateFormatter()
    switch span {
    case ..<(45.0 * 86_400):
        formatter.dateFormat = "MMM d"
    case ..<(370.0 * 86_400):
        formatter.dateFormat = "MMM"
    default:
        formatter.dateFormat = "MMM yyyy"
    }
    return formatter.string(from: date)
}

@AxisContentBuilder
func compactTimeAxisMarks(dates: [Date], desiredCount: Int = 8) -> some AxisContent {
    let span = (dates.max()?.timeIntervalSince(dates.min() ?? Date())) ?? 0
    if span <= 2 * 86_400 {
        AxisMarks(values: .stride(by: .hour, count: 6)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(timeAxisLabel(for: date, in: dates))
                        .multilineTextAlignment(.center)
                }
            }
        }
    } else {
        AxisMarks(values: .automatic(desiredCount: desiredCount)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(timeAxisLabel(for: date, in: dates))
                }
            }
        }
    }
}

@AxisContentBuilder
func compactDayAxisMarks(dates: [Date], desiredCount: Int = 8) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: desiredCount)) { value in
        AxisGridLine()
        AxisTick()
        AxisValueLabel {
            if let date = value.as(Date.self) {
                Text(dayAxisLabel(for: date, in: dates))
            }
        }
    }
}

func shouldShowWarningRule(in domain: ClosedRange<Double>, threshold: Double = 75) -> Bool {
    domain.contains(threshold)
}

// MARK: - ChartHoverState
//
// Mouse-move events can arrive far faster than the UI needs to redraw.
// This object coalesces those events and publishes at most 30 updates per
// second. Pending values are stored in non-published properties, so rapid
// pointer movement does not invalidate the SwiftUI chart for every event.

private final class ChartHoverState: ObservableObject {
    @Published var cursorPlotX: CGFloat?
    @Published var hoveredIndex: Int?

    private let publishInterval: TimeInterval = 1.0 / 30.0
    private var pendingPlotX: CGFloat?
    private var pendingHoveredIndex: Int?
    private var lastPublish: TimeInterval = 0
    private var publishScheduled = false
    private var scheduleGeneration = 0

    func update(plotX: CGFloat, hoveredIndex: Int?) {
        pendingPlotX = plotX
        pendingHoveredIndex = hoveredIndex

        let now = Date().timeIntervalSinceReferenceDate
        let delay = publishInterval - (now - lastPublish)
        if delay <= 0 {
            publishPending(now: now)
            return
        }

        guard !publishScheduled else { return }
        publishScheduled = true
        scheduleGeneration += 1
        let generation = scheduleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.scheduleGeneration == generation else { return }
            self.publishScheduled = false
            self.publishPending(now: Date().timeIntervalSinceReferenceDate)
        }
    }

    func clear() {
        pendingPlotX = nil
        pendingHoveredIndex = nil
        publishScheduled = false
        scheduleGeneration += 1
        publishPending(now: Date().timeIntervalSinceReferenceDate)
    }

    private func publishPending(now: TimeInterval) {
        lastPublish = now
        if cursorPlotX != pendingPlotX {
            cursorPlotX = pendingPlotX
        }
        if hoveredIndex != pendingHoveredIndex {
            hoveredIndex = pendingHoveredIndex
        }
    }
}

// MARK: - InteractiveChart
//
// A wrapper around SwiftUI Charts that adds iOS-Health-style
// hover interaction. Hover handling has two distinct concerns:
//
//   1. **Guideline** — a vertical line that follows the cursor
//      in plot-area coordinates. It is drawn in the chart overlay
//      so the full chart content does not re-render just to move a
//      rule mark.
//
//   2. **Tooltip + dots** — snap to the nearest data point, so
//      they show the value at a real sample. Pointer events are
//      coalesced to 30 Hz to avoid burning CPU on rapid movement.

struct InteractiveChart<DataPoint: Identifiable, Content: ChartContent>: View {
    let data: [DataPoint]
    let dateKey: KeyPath<DataPoint, Date>
    let rowsForPoint: (DataPoint) -> [HoverRow]
    let dateLabel: (DataPoint) -> (header: String, sub: String?)
    let chartContent: () -> Content

    init(
        data: [DataPoint],
        dateKey: KeyPath<DataPoint, Date>,
        rowsForPoint: @escaping (DataPoint) -> [HoverRow],
        dateLabel: @escaping (DataPoint) -> (header: String, sub: String?),
        @ChartContentBuilder chartContent: @escaping () -> Content
    ) {
        self.data = data
        self.dateKey = dateKey
        self.rowsForPoint = rowsForPoint
        self.dateLabel = dateLabel
        self.chartContent = chartContent
    }

    @StateObject private var hover = ChartHoverState()

    var body: some View {
        Chart {
            chartContent()
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = geo[proxy.plotAreaFrame]
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let pos):
                            guard plotFrame.contains(pos) else {
                                hover.clear()
                                return
                            }
                            let plotX = pos.x - plotFrame.minX
                            guard let cursor: Date = proxy.value(atX: plotX) else {
                                hover.clear()
                                return
                            }
                            let engine = HoverEngine(data: data, dateKey: dateKey)
                            hover.update(
                                plotX: plotX,
                                hoveredIndex: engine.nearestIndex(to: cursor)
                            )
                        case .ended:
                            hover.clear()
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let x = hover.cursorPlotX {
                            Path { path in
                                let absoluteX = plotFrame.minX + x
                                path.move(to: CGPoint(x: absoluteX, y: plotFrame.minY))
                                path.addLine(to: CGPoint(x: absoluteX, y: plotFrame.maxY))
                            }
                            .stroke(Color.primary.opacity(0.3),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let idx = hover.hoveredIndex,
                           data.indices.contains(idx) {
                            let point = data[idx]
                            let x = plotFrame.minX + (proxy.position(forX: point[keyPath: dateKey]) ?? 0)
                            ZStack {
                                ForEach(Array(rowsForPoint(point).enumerated()), id: \.element.id) { _, row in
                                    if let val = row.plotValue,
                                       let y = proxy.position(forY: val) {
                                        Circle()
                                            .fill(row.color)
                                            .frame(width: 8, height: 8)
                                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                                            .position(x: x, y: plotFrame.minY + y)
                                    }
                                }
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    // Tooltip follows the cursor horizontally with a small
                    // gap. Near the right edge it flips to the cursor's left
                    // side and always stays inside the chart bounds.
                    .overlay(alignment: .topLeading) {
                        if let idx = hover.hoveredIndex,
                           let cursorPlotX = hover.cursorPlotX,
                           data.indices.contains(idx) {
                            let point = data[idx]
                            let labels = dateLabel(point)
                            let rows = rowsForPoint(point)
                            HoverCard(
                                rows: rows,
                                header: labels.header,
                                subheader: labels.sub
                            )
                            .fixedSize()
                            .offset(x: cursorTooltipXOffset(
                                cursorPlotX: cursorPlotX,
                                chartWidth: geo.size.width,
                                plotFrame: plotFrame
                            ))
                            .offset(y: fixedTooltipYOffset(plotFrame: plotFrame))
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - DualAxisChart
//
// A Chart that shows two metrics with different units on the same
// X axis. The left Y axis is in the primary unit (e.g. °C), the
// right Y axis is in the secondary unit (e.g. RPM). Both data
// secondary series are mapped into the primary axis domain so they
// share the same plot area, while the trailing axis labels render
// the secondary values in their real units.

struct DualAxisChart<DataPoint: Identifiable, Content: ChartContent>: View {
    let data: [DataPoint]
    let dateKey: KeyPath<DataPoint, Date>
    let rowsForPoint: (DataPoint) -> [HoverRow]
    let dateLabel: (DataPoint) -> (header: String, sub: String?)
    let primaryAxisLabel: String
    let secondaryAxisLabel: String
    let primaryDomain: ClosedRange<Double>
    let secondaryDomain: ClosedRange<Double>
    let chartContent: () -> Content

    init(
        data: [DataPoint],
        dateKey: KeyPath<DataPoint, Date>,
        rowsForPoint: @escaping (DataPoint) -> [HoverRow],
        dateLabel: @escaping (DataPoint) -> (header: String, sub: String?),
        primaryAxisLabel: String,
        primaryDomain: ClosedRange<Double>,
        secondaryAxisLabel: String,
        secondaryDomain: ClosedRange<Double>,
        @ChartContentBuilder chartContent: @escaping () -> Content
    ) {
        self.data = data
        self.dateKey = dateKey
        self.rowsForPoint = rowsForPoint
        self.dateLabel = dateLabel
        self.primaryAxisLabel = primaryAxisLabel
        self.secondaryAxisLabel = secondaryAxisLabel
        self.primaryDomain = primaryDomain
        self.secondaryDomain = secondaryDomain
        self.chartContent = chartContent
    }

    @StateObject private var hover = ChartHoverState()

    var body: some View {
        Chart {
            chartContent()
        }
        .chartYScale(domain: primaryDomain.lowerBound...primaryDomain.upperBound)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(formatAxisValue(v))
                            .font(.caption2)
                    }
                }
            }
            AxisMarks(position: .trailing) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        let raw = mapValue(v, from: primaryDomain, to: secondaryDomain)
                        Text(formatAxisValue(raw))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxisLabel(position: .leading) {
            Text(primaryAxisLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .chartYAxisLabel(position: .trailing) {
            Text(secondaryAxisLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = geo[proxy.plotAreaFrame]
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let pos):
                            guard plotFrame.contains(pos) else {
                                hover.clear()
                                return
                            }
                            let plotX = pos.x - plotFrame.minX
                            guard let cursor: Date = proxy.value(atX: plotX) else {
                                hover.clear()
                                return
                            }
                            let engine = HoverEngine(data: data, dateKey: dateKey)
                            hover.update(
                                plotX: plotX,
                                hoveredIndex: engine.nearestIndex(to: cursor)
                            )
                        case .ended:
                            hover.clear()
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let x = hover.cursorPlotX {
                            Path { path in
                                let absoluteX = plotFrame.minX + x
                                path.move(to: CGPoint(x: absoluteX, y: plotFrame.minY))
                                path.addLine(to: CGPoint(x: absoluteX, y: plotFrame.maxY))
                            }
                            .stroke(Color.primary.opacity(0.3),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let idx = hover.hoveredIndex,
                           data.indices.contains(idx) {
                            let point = data[idx]
                            let x = plotFrame.minX + (proxy.position(forX: point[keyPath: dateKey]) ?? 0)
                            ZStack {
                                ForEach(Array(rowsForPoint(point).enumerated()), id: \.element.id) { _, row in
                                    if let val = row.plotValue,
                                       let y = proxy.position(forY: val) {
                                        Circle()
                                            .fill(row.color)
                                            .frame(width: 8, height: 8)
                                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                                            .position(x: x, y: plotFrame.minY + y)
                                    }
                                }
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let idx = hover.hoveredIndex,
                           let cursorPlotX = hover.cursorPlotX,
                           data.indices.contains(idx) {
                            let point = data[idx]
                            let labels = dateLabel(point)
                            let rows = rowsForPoint(point)
                            HoverCard(
                                rows: rows,
                                header: labels.header,
                                subheader: labels.sub
                            )
                            .fixedSize()
                            .offset(x: cursorTooltipXOffset(
                                cursorPlotX: cursorPlotX,
                                chartWidth: geo.size.width,
                                plotFrame: plotFrame
                            ))
                            .offset(y: fixedTooltipYOffset(plotFrame: plotFrame))
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func formatAxisValue(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 100 || value.rounded() == value {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - MiniSparkline

struct MiniSparkline: View {
    let values: [Double?]
    let tint: Color
    let secondary: [Double?]?
    let secondaryTint: Color

    init(values: [Double?], tint: Color,
         secondary: [Double?]? = nil, secondaryTint: Color = .clear) {
        self.values = values
        self.tint = tint
        self.secondary = secondary
        self.secondaryTint = secondaryTint
    }

    var body: some View {
        Chart {
            if let secondary = secondary {
                ForEach(Array(secondary.enumerated()), id: \.offset) { i, v in
                    if let v {
                        LineMark(
                            x: .value("i", i),
                            y: .value("v", v)
                        )
                        .foregroundStyle(secondaryTint.opacity(0.5))
                        .interpolationMethod(.monotone)
                    }
                }
            }
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                if let v {
                    LineMark(
                        x: .value("i", i),
                        y: .value("v", v)
                    )
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }
            }
            if let peakIdx = peakIndex {
                if let v = values[peakIdx] {
                    PointMark(
                        x: .value("i", peakIdx),
                        y: .value("v", v)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(18)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { $0.background(.clear) }
        .allowsHitTesting(false)
    }

    private var peakIndex: Int? {
        var bestIdx: Int? = nil
        var bestVal: Double = -.infinity
        for (i, v) in values.enumerated() {
            if let v, v > bestVal { bestVal = v; bestIdx = i }
        }
        return bestIdx
    }
}

// MARK: - Color helpers

enum TempColor {
    /// Map a CPU/GPU peak temperature to a heat palette color.
    static func forPeak(_ temp: Double) -> Color {
        switch temp {
        case ..<45:  return Color(red: 0.30, green: 0.65, blue: 0.42)
        case 45..<60: return Color(red: 0.78, green: 0.82, blue: 0.36)
        case 60..<75: return Color(red: 0.96, green: 0.65, blue: 0.14)
        case 75..<85: return Color(red: 0.91, green: 0.34, blue: 0.18)
        default:      return Color(red: 0.78, green: 0.13, blue: 0.18)
        }
    }
}

// MARK: - Chart card shell

struct ChartCard<Content: View>: View {
    let title: String
    let trailing: AnyView?
    let content: Content

    init(title: String,
         trailing: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let trailing = trailing { trailing }
            }
            content
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Legend dot
//
// `LegendDot` lives in `OverviewView.swift` (the only place it's
// still used as a static legend marker). The interactive version
// is `SeriesToggleBar` at the top of this file.
