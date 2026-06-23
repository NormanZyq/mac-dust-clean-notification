import Foundation

// Quick test: generate 7 days of synthetic data and check it looks
// reasonable. Run with: swift Sources/Diagnostic/test_synthetic.swift

let home = FileManager.default.homeDirectoryForCurrentUser
let dbPath = home
    .appendingPathComponent("Library/Application Support/DustWatch/data.db")
    .path

let db = try Database(path: dbPath)
print("✓ DB opened at \(dbPath)")

// Clear existing
try db.clearAllSamples()
print("✓ Cleared existing data")

let start = Date()
try SyntheticDataGenerator.generate(
    database: db,
    days: 7,
    seed: 42,
    progress: { p in
        if Int(p * 100) % 25 == 0 {
            print("  progress: \(Int(p * 100))%")
        }
    }
)
let elapsed = Date().timeIntervalSince(start)
let rowCount = (try? db.fetchSamples(from: 0, to: Int64(Date().timeIntervalSince1970)).count) ?? 0
print("✓ Generated \(rowCount) samples in \(String(format: "%.2f", elapsed))s")
print("  expected: \(7 * 24 * 60) = \(7*24*60)")

// Show some sample rows
let samples = try db.fetchSamples(from: 0, to: Int64(Date().timeIntervalSince1970))
print("\n=== First 5 samples ===")
for s in samples.prefix(5) {
    let ts = s.timestamp.formatted(date: .abbreviated, time: .shortened)
    let cpu = s.cpuTempC.map { String(format: "%.1f", $0) } ?? "—"
    let gpu = s.gpuTempC.map { String(format: "%.1f", $0) } ?? "—"
    let load = s.cpuLoad.map { String(format: "%.2f", $0) } ?? "—"
    let fan = s.maxFanRPM.map { String($0) } ?? "—"
    print("  \(ts): CPU=\(cpu)°C GPU=\(gpu)°C load=\(load) fan=\(fan)rpm")
}

print("\n=== Last 5 samples ===")
for s in samples.suffix(5) {
    let ts = s.timestamp.formatted(date: .abbreviated, time: .shortened)
    let cpu = s.cpuTempC.map { String(format: "%.1f", $0) } ?? "—"
    let gpu = s.gpuTempC.map { String(format: "%.1f", $0) } ?? "—"
    let load = s.cpuLoad.map { String(format: "%.2f", $0) } ?? "—"
    let fan = s.maxFanRPM.map { String($0) } ?? "—"
    print("  \(ts): CPU=\(cpu)°C GPU=\(gpu)°C load=\(load) fan=\(fan)rpm")
}

// Aggregate stats
let summary = try db.fetchSummaryStats(
    from: 0,
    to: Int64(Date().timeIntervalSince1970),
    thresholdC: 70
)
print("\n=== Summary ===")
print("  samples: \(summary.sampleCount)")
print("  CPU peak: \(summary.cpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—")")
print("  CPU avg:  \(summary.cpuTempAvg.map  { String(format: "%.1f°C", $0) } ?? "—")")
print("  CPU min:  \(summary.cpuTempMin.map  { String(format: "%.1f°C", $0) } ?? "—")")
print("  GPU peak: \(summary.gpuTempPeak.map { String(format: "%.1f°C", $0) } ?? "—")")
print("  Fan peak: \(summary.fanRpmPeak.map { "\($0) RPM" } ?? "—")")
print("  seconds above 70°C: \(summary.cpuSecondsAboveThreshold)")
