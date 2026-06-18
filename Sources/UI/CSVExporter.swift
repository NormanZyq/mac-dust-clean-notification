import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - CSVExporter
//
// Builds a CSV string from a list of Samples and writes it to a file
// the user picks via NSSavePanel. The format is one row per sample
// with columns: timestamp (ISO 8601), CPU temp, GPU temp, CPU freq,
// CPU load, GPU load, P-State, fan max RPM. Empty cells for missing
// values. The file is prefixed with a small metadata header
// (sampler version + range) so external tools can sanity-check.

enum CSVExporter {

    /// Show a save panel and write the samples for `[from, to]` to
    /// the chosen file. Returns the chosen URL on success.
    @MainActor
    static func exportSamples(from: Date, to: Date) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let defaultName = "clean-notification-\(df.string(from: Date())).csv"
        panel.nameFieldStringValue = defaultName
        panel.title = L("Export samples")
        panel.message = L("Export temperature and fan data as CSV.")

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        let samples = try Sampler.shared.databaseHandle.fetchRawForExport(
            from: Int64(from.timeIntervalSince1970),
            to:   Int64(to.timeIntervalSince1970)
        )

        let csv = buildCSV(samples: samples, from: from, to: to)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Build the CSV text. Exposed for testing.
    static func buildCSV(samples: [Sample], from: Date, to: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var out = "# Clean Notification Mac — sample export\n"
        out += "# From: \(iso.string(from: from))\n"
        out += "# To:   \(iso.string(from: to))\n"
        out += "# Rows: \(samples.count)\n"
        out += "timestamp,cpu_temp_c,gpu_temp_c,cpu_freq_ghz,cpu_load,gpu_load,p_state,fan_max_rpm\n"
        for s in samples {
            let ts = iso.string(from: s.timestamp)
            let cells: [String] = [
                ts,
                s.cpuTempC.map   { String(format: "%.2f", $0) } ?? "",
                s.gpuTempC.map   { String(format: "%.2f", $0) } ?? "",
                s.cpuFreqGHz.map { String(format: "%.3f", $0) } ?? "",
                s.cpuLoad.map    { String(format: "%.3f", $0) } ?? "",
                s.gpuLoad.map    { String(format: "%.3f", $0) } ?? "",
                s.maxPState.map  { String($0) }                ?? "",
                s.maxFanRPM.map  { String($0) }                ?? "",
            ]
            out += cells.joined(separator: ",") + "\n"
        }
        return out
    }
}
