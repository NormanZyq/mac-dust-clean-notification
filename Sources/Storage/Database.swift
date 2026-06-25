import Foundation
import SQLite3

// MARK: - Database
//
// Thin Swift wrapper around the system sqlite3 library. We avoid any
// third-party SQLite dependency (GRDB, SQLite.swift) to keep the build
// simple and the binary small.
//
// Schema overview:
//
//   samples              — raw 1-minute samples, kept for 30 days
//   samples_hourly       — rolled up to hour buckets, kept for 1 year
//   samples_daily        — rolled up to day buckets, kept forever
//   alerts               — record of every notification we've sent
//   config               — single-row table of user settings
//
// All queries use prepared statements; we never build SQL via string
// interpolation (so SQL injection is not a concern).

final class Database {
    private var db: OpaquePointer?
    private let path: String
    private static let minimumTrustedRealGPUTempC = 15.0
    private static let latestSchemaVersion = 3
    private static let bestCoolingModelRetentionDays = 365

    init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        if sqlite3_open_v2(path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw DBError.openFailed(msg)
        }

        try createSchema()
        try pragmas()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    var filePath: String { path }

    // MARK: - Schema

    private func createSchema() throws {
        let stmts: [String] = [
            // Raw 1-minute samples. Use INTEGER for ts (unix seconds) for
            // compactness and easy range queries. `source` is "real" or
            // "synthetic" so the user can clear demo data independently.
            """
            CREATE TABLE IF NOT EXISTS samples (
                ts        INTEGER PRIMARY KEY,
                cpu_temp  REAL,
                gpu_temp  REAL,
                gpu_temp_raw REAL,
                cpu_freq  REAL,
                cpu_load  REAL,
                gpu_load  REAL,
                p_state   INTEGER,
                fan_max   INTEGER,
                source    TEXT NOT NULL DEFAULT 'real'
            );
            """,

            // Hourly rollup. Created by Aggregator when raw rows are evicted.
            // Includes source so we keep real and synthetic separate.
            """
            CREATE TABLE IF NOT EXISTS samples_hourly (
                bucket       INTEGER NOT NULL,
                source       TEXT    NOT NULL DEFAULT 'real',
                cpu_temp_avg REAL,
                cpu_temp_max REAL,
                gpu_temp_avg REAL,
                gpu_temp_max REAL,
                fan_max_avg  REAL,
                fan_max_max  INTEGER,
                n            INTEGER,
                PRIMARY KEY (bucket, source)
            );
            """,

            // Daily rollup. Same source-aware structure.
            """
            CREATE TABLE IF NOT EXISTS samples_daily (
                bucket       INTEGER NOT NULL,
                source       TEXT    NOT NULL DEFAULT 'real',
                cpu_temp_avg REAL,
                cpu_temp_max REAL,
                gpu_temp_avg REAL,
                gpu_temp_max REAL,
                fan_max_avg  REAL,
                fan_max_max  INTEGER,
                n            INTEGER,
                PRIMARY KEY (bucket, source)
            );
            """,

            // Alert log so we don't re-notify for the same condition within
            // the cool-down window. Keyed by (bucket, kind).
            """
            CREATE TABLE IF NOT EXISTS alerts (
                ts        INTEGER PRIMARY KEY,
                kind      TEXT NOT NULL,
                details   TEXT NOT NULL
            );
            """,

            // Single-row config table. id is always 0; we use ON CONFLICT
            // semantics to upsert.
            """
            CREATE TABLE IF NOT EXISTS config (
                id              INTEGER PRIMARY KEY CHECK (id = 0),
                sample_interval INTEGER NOT NULL DEFAULT 60,
                temp_threshold  REAL    NOT NULL DEFAULT 3.0,
                fan_threshold   INTEGER NOT NULL DEFAULT 500,
                baseline_days   INTEGER NOT NULL DEFAULT 60,
                compare_days    INTEGER NOT NULL DEFAULT 7,
                notif_enabled   INTEGER NOT NULL DEFAULT 1,
                cooling_calibrated_at INTEGER
            );
            """,
            // Initialize the single config row on first run.
            """
            INSERT OR IGNORE INTO config (id) VALUES (0);
            """,
        ]
        for sql in stmts {
            try exec(sql)
        }

        let schemaVersion = try userVersion()
        try migrateSchema(from: schemaVersion)
        if schemaVersion < Self.latestSchemaVersion {
            try setUserVersion(Self.latestSchemaVersion)
        }
        try createIndexes()
    }

    private func migrateSchema(from version: Int) throws {
        try migrateConfigSchema()
        try migrateSamplesSchema()
        try migrateRollupTable("samples_hourly")
        try migrateRollupTable("samples_daily")
        if version < 2 {
            try sanitizeRollupGPUTemps("samples_hourly")
            try sanitizeRollupGPUTemps("samples_daily")
        }
    }

    private func migrateConfigSchema() throws {
        if try !tableHasColumn("config", column: "cooling_calibrated_at") {
            try exec("ALTER TABLE config ADD COLUMN cooling_calibrated_at INTEGER;")
        }
    }

    private func migrateSamplesSchema() throws {
        if try !tableHasColumn("samples", column: "source") {
            try exec("ALTER TABLE samples ADD COLUMN source TEXT NOT NULL DEFAULT 'real';")
        }

        if try !tableHasColumn("samples", column: "gpu_temp_raw") {
            try exec("ALTER TABLE samples ADD COLUMN gpu_temp_raw REAL;")
        }

        try exec("""
            UPDATE samples
            SET gpu_temp_raw = gpu_temp
            WHERE gpu_temp_raw IS NULL AND gpu_temp IS NOT NULL;
            """)

        try exec("""
            UPDATE samples
            SET gpu_temp = NULL
            WHERE source = 'real'
              AND gpu_temp IS NOT NULL
              AND gpu_temp < ?;
            """, bindings: [.double(Self.minimumTrustedRealGPUTempC)])
    }

    private func migrateRollupTable(_ table: String) throws {
        guard try !tableHasColumn(table, column: "source") else { return }

        let temp = "\(table)_migrating"
        try exec("DROP TABLE IF EXISTS \(temp);")
        try exec("""
            CREATE TABLE \(temp) (
                bucket       INTEGER NOT NULL,
                source       TEXT    NOT NULL DEFAULT 'real',
                cpu_temp_avg REAL,
                cpu_temp_max REAL,
                gpu_temp_avg REAL,
                gpu_temp_max REAL,
                fan_max_avg  REAL,
                fan_max_max  INTEGER,
                n            INTEGER,
                PRIMARY KEY (bucket, source)
            );
            """)
        try exec("""
            INSERT INTO \(temp)
                (bucket, source, cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max,
                 fan_max_avg, fan_max_max, n)
            SELECT
                bucket, 'real', cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max,
                fan_max_avg, fan_max_max, n
            FROM \(table);
            """)
        try exec("DROP TABLE \(table);")
        try exec("ALTER TABLE \(temp) RENAME TO \(table);")
    }

    private func sanitizeRollupGPUTemps(_ table: String) throws {
        try exec("""
            UPDATE \(table)
            SET gpu_temp_avg = NULL
            WHERE source = 'real';
            """)
        try exec("""
            UPDATE \(table)
            SET gpu_temp_max = NULL
            WHERE source = 'real'
              AND gpu_temp_max IS NOT NULL
              AND gpu_temp_max < ?;
            """, bindings: [.double(Self.minimumTrustedRealGPUTempC)])
    }

    private func createIndexes() throws {
        try exec("CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);")
        try exec("CREATE INDEX IF NOT EXISTS idx_samples_source_ts ON samples(source, ts);")
        try exec("CREATE INDEX IF NOT EXISTS idx_alerts_kind_ts ON alerts(kind, ts);")
    }

    private func pragmas() throws {
        // WAL mode is more durable and faster for our small write workload.
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous  = NORMAL;")
    }

    // MARK: - Aggregated queries (Overview, Heatmap, Compare)

    /// Return per-day stats over `[from, to]`. The query groups raw
    /// samples by local-day bucket. This powers the heatmap and the
    /// overview page's 7/30-day trend cards.
    func fetchDailyStats(from fromSec: Int64, to toSec: Int64) throws -> [DailyStats] {
        let samples = try fetchRawSamples(from: fromSec, to: toSec)
        let calendar = Calendar.current
        var buckets: [Date: DailyStatsAccumulator] = [:]

        for sample in samples {
            let day = calendar.startOfDay(for: sample.timestamp)
            buckets[day, default: DailyStatsAccumulator(date: day)].add(sample)
        }

        return buckets.values
            .map(\.stats)
            .sorted { $0.date < $1.date }
    }

    /// Per-hour stats. Used for the last-24h trend on the Overview page.
    func fetchHourlyStats(from fromSec: Int64, to toSec: Int64) throws -> [HourlyStats] {
        let sql = """
            SELECT
                (ts / 3600) * 3600                                AS bucket,
                COUNT(*)                                          AS n,
                MAX(cpu_temp)                                     AS cpu_peak,
                AVG(cpu_temp)                                     AS cpu_avg,
                MIN(cpu_temp)                                     AS cpu_min,
                MAX(gpu_temp)                                     AS gpu_peak,
                AVG(gpu_temp)                                     AS gpu_avg,
                MAX(CASE WHEN fan_max > 0 THEN fan_max END)       AS fan_peak,
                AVG(CASE WHEN fan_max > 0 THEN fan_max END)       AS fan_avg
            FROM samples
            WHERE ts BETWEEN ? AND ?
            GROUP BY bucket
            ORDER BY bucket;
            """
        let rows = try query(sql, bindings: [.int64(fromSec), .int64(toSec)]) { stmt in
            let bucket = Int64(sqlite3_column_int64(stmt, 0))
            return HourlyStats(
                hour:           Date(timeIntervalSince1970: TimeInterval(bucket)),
                sampleCount:    Int(sqlite3_column_int(stmt, 1)),
                cpuTempPeak:    sqlite3_column_double_opt(stmt, 2),
                cpuTempAvg:     sqlite3_column_double_opt(stmt, 3),
                cpuTempMin:     sqlite3_column_double_opt(stmt, 4),
                gpuTempPeak:    sqlite3_column_double_opt(stmt, 5),
                gpuTempAvg:     sqlite3_column_double_opt(stmt, 6),
                fanRpmPeak:     sqlite3_column_int_opt(stmt, 7),
                fanRpmAvg:      sqlite3_column_double_opt(stmt, 8)
            )
        }
        return rows
    }

    /// Aggregate stats for a single range. Used by the overview cards.
    func fetchSummaryStats(from fromSec: Int64, to toSec: Int64,
                            thresholdC: Double = 70.0) throws -> SummaryStats {
        let sql = """
            SELECT
                COUNT(*)                                          AS n,
                MAX(cpu_temp)                                     AS cpu_peak,
                AVG(cpu_temp)                                     AS cpu_avg,
                MIN(cpu_temp)                                     AS cpu_min,
                MAX(gpu_temp)                                     AS gpu_peak,
                AVG(gpu_temp)                                     AS gpu_avg,
                MAX(CASE WHEN fan_max > 0 THEN fan_max END)       AS fan_peak,
                AVG(CASE WHEN fan_max > 0 THEN fan_max END)       AS fan_avg
            FROM samples
            WHERE ts BETWEEN ? AND ?;
            """
        let rows = try query(sql, bindings: [
            .int64(fromSec),
            .int64(toSec),
        ]) { stmt in
            SummaryStats(
                from:    Date(timeIntervalSince1970: TimeInterval(fromSec)),
                to:      Date(timeIntervalSince1970: TimeInterval(toSec)),
                sampleCount: Int(sqlite3_column_int(stmt, 0)),
                cpuTempPeak: sqlite3_column_double_opt(stmt, 1),
                cpuTempAvg:  sqlite3_column_double_opt(stmt, 2),
                cpuTempMin:  sqlite3_column_double_opt(stmt, 3),
                gpuTempPeak: sqlite3_column_double_opt(stmt, 4),
                gpuTempAvg:  sqlite3_column_double_opt(stmt, 5),
                fanRpmPeak:  sqlite3_column_int_opt(stmt, 6),
                fanRpmAvg:   sqlite3_column_double_opt(stmt, 7),
                cpuSecondsAboveThreshold: 0
            )
        }
        var summary = rows.first ?? SummaryStats.empty(
            from: Date(timeIntervalSince1970: TimeInterval(fromSec)),
            to:   Date(timeIntervalSince1970: TimeInterval(toSec))
        )
        let seconds = try fetchThresholdDurationSeconds(
            from: fromSec,
            to: toSec,
            thresholdC: thresholdC
        )
        summary = SummaryStats(
            from: summary.from,
            to: summary.to,
            sampleCount: summary.sampleCount,
            cpuTempPeak: summary.cpuTempPeak,
            cpuTempAvg: summary.cpuTempAvg,
            cpuTempMin: summary.cpuTempMin,
            gpuTempPeak: summary.gpuTempPeak,
            gpuTempAvg: summary.gpuTempAvg,
            fanRpmPeak: summary.fanRpmPeak,
            fanRpmAvg: summary.fanRpmAvg,
            cpuSecondsAboveThreshold: seconds
        )
        return summary
    }

    /// Per-hour CPU duration above `thresholdC` over `[from, to]`.
    /// Used by the Overview "Above 70°C today" card.
    func fetchHourlyThresholdDurations(from fromSec: Int64, to toSec: Int64,
                                       thresholdC: Double = 70.0) throws -> [HourlyThresholdDuration] {
        guard fromSec < toSec else { return [] }
        let samples = try fetchTemperatureSamplesForDuration(from: fromSec, to: toSec)
        let sampleInterval = durationSampleInterval()
        let maxRepresentedInterval = Int64(max(sampleInterval * 2, 120))
        let calendar = Calendar.current
        var buckets: [Int64: Int64] = [:]

        for (index, sample) in samples.enumerated() {
            guard let temp = sample.cpuTemp, temp > thresholdC else { continue }

            let nextTs = index + 1 < samples.count ? samples[index + 1].ts : toSec
            let representedEnd = min(nextTs, sample.ts + maxRepresentedInterval, toSec)
            var cursor = max(sample.ts, fromSec)
            guard representedEnd > cursor else { continue }

            while cursor < representedEnd {
                let hourStart = localHourStart(containing: cursor, calendar: calendar)
                let hourEnd = localHourEnd(after: hourStart, calendar: calendar)
                let chunkEnd = min(representedEnd, hourEnd)
                buckets[hourStart, default: 0] += chunkEnd - cursor
                cursor = chunkEnd
            }
        }

        var result: [HourlyThresholdDuration] = []
        var hour = localHourStart(containing: fromSec, calendar: calendar)
        while hour < toSec {
            result.append(HourlyThresholdDuration(
                hour: Date(timeIntervalSince1970: TimeInterval(hour)),
                secondsAboveThreshold: Int(buckets[hour] ?? 0)
            ))
            hour = localHourEnd(after: hour, calendar: calendar)
        }
        return result
    }

    /// Per-day CPU duration above 70°C and 75°C over `[from, to]`.
    /// Used by the Heatmap tab to color days by sustained heat rather than
    /// by a single peak sample.
    func fetchDailyThresholdDurations(from fromSec: Int64, to toSec: Int64) throws -> [DailyThresholdDuration] {
        guard fromSec < toSec else { return [] }
        let samples = try fetchTemperatureSamplesForDuration(from: fromSec, to: toSec)
        let sampleInterval = durationSampleInterval()
        let maxRepresentedInterval = Int64(max(sampleInterval * 2, 120))
        let calendar = Calendar.current
        var above70: [Int64: Int64] = [:]
        var above75: [Int64: Int64] = [:]

        for (index, sample) in samples.enumerated() {
            guard let temp = sample.cpuTemp, temp > 70 else { continue }

            let nextTs = index + 1 < samples.count ? samples[index + 1].ts : toSec
            let representedEnd = min(nextTs, sample.ts + maxRepresentedInterval, toSec)
            var cursor = max(sample.ts, fromSec)
            guard representedEnd > cursor else { continue }

            while cursor < representedEnd {
                let dayStart = localDayStart(containing: cursor, calendar: calendar)
                let dayEnd = localDayEnd(after: dayStart, calendar: calendar)
                let chunkEnd = min(representedEnd, dayEnd)
                let seconds = chunkEnd - cursor
                above70[dayStart, default: 0] += seconds
                if temp > 75 {
                    above75[dayStart, default: 0] += seconds
                }
                cursor = chunkEnd
            }
        }

        var result: [DailyThresholdDuration] = []
        var day = localDayStart(containing: fromSec, calendar: calendar)
        while day < toSec {
            result.append(DailyThresholdDuration(
                date: Date(timeIntervalSince1970: TimeInterval(day)),
                secondsAbove70: Int(above70[day] ?? 0),
                secondsAbove75: Int(above75[day] ?? 0)
            ))
            day = localDayEnd(after: day, calendar: calendar)
        }
        return result
    }

    private func fetchThresholdDurationSeconds(from fromSec: Int64, to toSec: Int64,
                                               thresholdC: Double) throws -> Int {
        try fetchHourlyThresholdDurations(
            from: fromSec,
            to: toSec,
            thresholdC: thresholdC
        )
        .reduce(0) { $0 + $1.secondsAboveThreshold }
    }

    private func fetchTemperatureSamplesForDuration(from fromSec: Int64, to toSec: Int64) throws -> [(ts: Int64, cpuTemp: Double?)] {
        let sampleInterval = Int64(max(durationSampleInterval(), 1))
        let lookback = max(sampleInterval * 2, 120)
        let fromWithLookback = max(0, fromSec - lookback)
        let sql = """
            SELECT ts, cpu_temp
            FROM samples
            WHERE ts BETWEEN ? AND ?
            ORDER BY ts;
            """
        return try query(sql, bindings: [
            .int64(fromWithLookback),
            .int64(toSec),
        ]) { stmt in
            (
                ts: Int64(sqlite3_column_int64(stmt, 0)),
                cpuTemp: sqlite3_column_double_opt(stmt, 1)
            )
        }
    }

    private func durationSampleInterval() -> Int {
        ((try? loadConfig()) ?? Config()).sampleIntervalSec
    }

    private func localHourStart(containing seconds: Int64, calendar: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let start = calendar.dateInterval(of: .hour, for: date)?.start
            ?? Date(timeIntervalSince1970: TimeInterval((seconds / 3600) * 3600))
        return Int64(start.timeIntervalSince1970)
    }

    private func localHourEnd(after hourStart: Int64, calendar: Calendar) -> Int64 {
        let start = Date(timeIntervalSince1970: TimeInterval(hourStart))
        let end = calendar.date(byAdding: .hour, value: 1, to: start)
            ?? start.addingTimeInterval(3600)
        return max(hourStart + 1, Int64(end.timeIntervalSince1970))
    }

    private func localDayStart(containing seconds: Int64, calendar: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return Int64(calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    private func localDayEnd(after dayStart: Int64, calendar: Calendar) -> Int64 {
        let start = Date(timeIntervalSince1970: TimeInterval(dayStart))
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86400)
        return max(dayStart + 1, Int64(end.timeIntervalSince1970))
    }

    /// Fetch raw samples for export. Returns rows in `[from, to]`
    /// ordered by ts. Used by CSV export and the comparison chart.
    func fetchRawForExport(from fromSec: Int64, to toSec: Int64) throws -> [Sample] {
        return try fetchRawSamples(from: fromSec, to: toSec)
    }

    // MARK: - Sample I/O

    func insert(_ s: Sample) throws {
        let ts = Int64(s.timestamp.timeIntervalSince1970)
        let pState = s.maxPState ?? -1
        let fanMax = s.maxFanRPM ?? -1
        let gpuTempRaw = s.gpuTempRawC ?? s.gpuTempC
        let gpuTempTrusted = Self.trustedGPUTemp(s.gpuTempC, source: s.source)
        let sql = """
            INSERT OR REPLACE INTO samples
                (ts, cpu_temp, gpu_temp, gpu_temp_raw, cpu_freq, cpu_load, gpu_load, p_state, fan_max, source)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """
        try exec(sql, bindings: [
            .int64(ts),
            .optionalDouble(s.cpuTempC),
            .optionalDouble(gpuTempTrusted),
            .optionalDouble(gpuTempRaw),
            .optionalDouble(s.cpuFreqGHz),
            .optionalDouble(s.cpuLoad),
            .optionalDouble(s.gpuLoad),
            .int64(Int64(pState)),
            .int64(Int64(fanMax)),
            .text(s.source.rawValue),
        ])
    }

    /// Number of days raw 1-minute samples are kept before being rolled up
    /// into hourly buckets. The dust-risk detector learns a best-observed
    /// cooling reference from raw per-sample history, because rollups drop
    /// the load/P-State distribution. Keep roughly a year of raw history
    /// plus the recent comparison window; floor at 35 so the default
    /// 30-day charts always have raw data.
    func rawRetentionDays() -> Int {
        let cfg = (try? loadConfig()) ?? Config()
        return max(35, Self.bestCoolingModelRetentionDays + cfg.compareDays + 8)
    }

    /// Fetch samples in `[from, to]` (unix seconds), ordered by ts.
    /// Combines raw, hourly, and daily tables so the chart always has
    /// *some* data even for very old time ranges.
    func fetchSamples(from fromSec: Int64, to toSec: Int64) throws -> [Sample] {
        // We pull from each table separately and merge. SQLite has
        // UNION ALL but mixing time scales is cleaner in Swift.
        var out: [Sample] = []

        let retentionDays = Int64(rawRetentionDays())

        // Raw (within the retention window)
        let rawCutoff = Int64(Date().timeIntervalSince1970) - retentionDays * 86400
        let rawFrom = max(fromSec, rawCutoff)
        if rawFrom <= toSec {
            let rows = try fetchRawSamples(from: rawFrom, to: toSec)
            out.append(contentsOf: rows)
        }

        // Hourly (retention window .. 1 year)
        let hourCutoff = Int64(Date().timeIntervalSince1970) - 365 * 86400
        let hourFrom = max(fromSec, hourCutoff)
        if hourFrom <= toSec && hourFrom < rawCutoff {
            let rows = try fetchHourlySamples(from: hourFrom, to: min(toSec, rawCutoff))
            out.append(contentsOf: rows)
        }

        // Daily (older than 1 year)
        if fromSec < hourCutoff {
            let rows = try fetchDailySamples(from: fromSec, to: min(toSec, hourCutoff))
            out.append(contentsOf: rows)
        }

        return out.sorted { $0.timestamp < $1.timestamp }
    }

    private func fetchRawSamples(from: Int64, to: Int64) throws -> [Sample] {
        let sql = """
            SELECT ts, cpu_temp, gpu_temp, gpu_temp_raw, cpu_freq, cpu_load, gpu_load, p_state, fan_max, source
            FROM samples WHERE ts BETWEEN ? AND ? ORDER BY ts;
            """
        return try query(sql, bindings: [.int64(from), .int64(to)]) { stmt in
            let sourceRaw = String(cString: sqlite3_column_text(stmt, 9))
            return Sample(
                timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                cpuTempC:   sqlite3_column_double_opt(stmt, 1),
                gpuTempC:   sqlite3_column_double_opt(stmt, 2),
                gpuTempRawC: sqlite3_column_double_opt(stmt, 3),
                cpuFreqGHz: sqlite3_column_double_opt(stmt, 4),
                cpuLoad:    sqlite3_column_double_opt(stmt, 5),
                gpuLoad:    sqlite3_column_double_opt(stmt, 6),
                cpuPState:  [Int(sqlite3_column_int(stmt, 7))].filter { $0 >= 0 },
                fanRPMs:    [Int(sqlite3_column_int(stmt, 8))].filter { $0 >= 0 },
                source:     SampleSource(rawValue: sourceRaw) ?? .real
            )
        }
    }

    /// Fetch RAW per-sample rows in `[from, to]` for statistical analysis
    /// (the degradation detector). Unlike `fetchSamples`, this never falls
    /// back to the hourly/daily rollups — those have lost the per-sample
    /// load/temperature distribution and the P-State dimension, both of
    /// which the Mann-Whitney test and load-bucketing require. The caller
    /// must ensure raw data is retained long enough to cover its window
    /// (see `rawRetentionDays` / Aggregator).
    func fetchRawSamplesForAnalysis(from fromSec: Int64, to toSec: Int64) throws -> [Sample] {
        try fetchRawSamples(from: fromSec, to: toSec)
    }

    private func fetchHourlySamples(from: Int64, to: Int64) throws -> [Sample] {
        let sql = """
            SELECT bucket, cpu_temp_avg, gpu_temp_avg, fan_max_avg
            FROM samples_hourly WHERE bucket BETWEEN ? AND ? ORDER BY bucket;
            """
        return try query(sql, bindings: [.int64(from), .int64(to)]) { stmt in
            Sample(
                timestamp:  Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                cpuTempC:   sqlite3_column_double_opt(stmt, 1),
                gpuTempC:   sqlite3_column_double_opt(stmt, 2),
                gpuTempRawC: nil,
                cpuFreqGHz: nil,
                cpuLoad:    nil,
                gpuLoad:    nil,
                cpuPState:  [],
                fanRPMs:    [Int(sqlite3_column_double_opt(stmt, 3) ?? 0)].filter { $0 > 0 }
            )
        }
    }

    private func fetchDailySamples(from: Int64, to: Int64) throws -> [Sample] {
        let sql = """
            SELECT bucket, cpu_temp_avg, gpu_temp_avg, fan_max_avg
            FROM samples_daily WHERE bucket BETWEEN ? AND ? ORDER BY bucket;
            """
        return try query(sql, bindings: [.int64(from), .int64(to)]) { stmt in
            Sample(
                timestamp:  Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                cpuTempC:   sqlite3_column_double_opt(stmt, 1),
                gpuTempC:   sqlite3_column_double_opt(stmt, 2),
                gpuTempRawC: nil,
                cpuFreqGHz: nil,
                cpuLoad:    nil,
                gpuLoad:    nil,
                cpuPState:  [],
                fanRPMs:    [Int(sqlite3_column_double_opt(stmt, 3) ?? 0)].filter { $0 > 0 }
            )
        }
    }

    // MARK: - Alert log

    /// Returns true if an alert of the same `kind` was sent within the
    /// last `cooldownSeconds` seconds. Used to throttle notifications.
    func recentAlert(kind: String, withinSec: Int64) throws -> Bool {
        let sql = "SELECT COUNT(*) FROM alerts WHERE kind = ? AND ts > ?;"
        let since = Int64(Date().timeIntervalSince1970) - withinSec
        let rows = try query(sql, bindings: [.text(kind), .int64(since)]) { stmt in
            sqlite3_column_int(stmt, 0)
        }
        return rows.first.map { $0 > 0 } ?? false
    }

    func recordAlert(kind: String, details: String) throws {
        try exec("INSERT INTO alerts (ts, kind, details) VALUES (?, ?, ?);",
                 bindings: [
                    .int64(Int64(Date().timeIntervalSince1970)),
                    .text(kind),
                    .text(details),
                 ])
    }

    // MARK: - Config

    func loadConfig() throws -> Config {
        let sql = "SELECT sample_interval, temp_threshold, fan_threshold, baseline_days, compare_days, notif_enabled, cooling_calibrated_at FROM config WHERE id = 0;"
        let rows = try query(sql, bindings: []) { stmt -> Config in
            Config(
                sampleIntervalSec: Int(sqlite3_column_int(stmt, 0)),
                tempThresholdC:    sqlite3_column_double(stmt, 1),
                fanThresholdRPM:   Int(sqlite3_column_int(stmt, 2)),
                baselineDays:      Int(sqlite3_column_int(stmt, 3)),
                compareDays:       Int(sqlite3_column_int(stmt, 4)),
                notificationsEnabled: sqlite3_column_int(stmt, 5) != 0,
                coolingCalibrationStartedAt: sqlite3_column_int64_opt(stmt, 6)
            )
        }
        return rows.first ?? Config()
    }

    func saveConfig(_ cfg: Config) throws {
        let sql = """
            UPDATE config SET
                sample_interval = ?,
                temp_threshold  = ?,
                fan_threshold   = ?,
                baseline_days   = ?,
                compare_days    = ?,
                notif_enabled   = ?,
                cooling_calibrated_at = ?
            WHERE id = 0;
            """
        try exec(sql, bindings: [
            .int64(Int64(cfg.sampleIntervalSec)),
            .double(cfg.tempThresholdC),
            .int64(Int64(cfg.fanThresholdRPM)),
            .int64(Int64(cfg.baselineDays)),
            .int64(Int64(cfg.compareDays)),
            .int64(cfg.notificationsEnabled ? 1 : 0),
            .optionalInt64(cfg.coolingCalibrationStartedAt),
        ])
    }

    // MARK: - Maintenance

    /// Delete every sample row and rollup. Used by the "Clear all data"
    /// button in the Settings tab. Leaves the schema in place.
    func clearAllSamples() throws {
        try exec("DELETE FROM samples;")
        try exec("DELETE FROM samples_hourly;")
        try exec("DELETE FROM samples_daily;")
        try exec("DELETE FROM alerts;")
    }

    /// Delete only rows that came from the synthetic generator.
    /// Leaves real SMC samples untouched. Used when the user wants
    /// to start fresh with curated synthetic data without losing
    /// any actual measurements they've collected.
    func clearSyntheticData() throws {
        try exec("DELETE FROM samples       WHERE source = 'synthetic';")
        try exec("DELETE FROM samples_hourly WHERE source = 'synthetic';")
        try exec("DELETE FROM samples_daily  WHERE source = 'synthetic';")
    }

    /// Counts of rows per source, for the UI's "X real, Y synthetic"
    /// display.
    func sourceCounts() throws -> (real: Int, synthetic: Int) {
        let rows = try query("""
            SELECT source, COUNT(*) FROM samples GROUP BY source;
            """, bindings: []) { stmt -> (String, Int) in
            let s = String(cString: sqlite3_column_text(stmt, 0))
            return (s, Int(sqlite3_column_int(stmt, 1)))
        }
        var real = 0
        var synthetic = 0
        for (src, n) in rows {
            if src == "synthetic" { synthetic = n } else { real = n }
        }
        return (real, synthetic)
    }

    // MARK: - Transaction wrapper

    /// Run `body` inside an SQLite transaction. Commits on success,
    /// rolls back on throw. Use for bulk inserts (e.g. synthetic data
    /// generation) where 10k+ rows would otherwise dominate the cost
    /// of individual fsyncs.
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Aggregation (delegated to Aggregator.swift)

    /// Move raw rows older than `rawCutoffSec` into samples_hourly.
    /// Move hourly rows older than `hourCutoffSec` into samples_daily.
    /// The rollup groups by (bucket, source) so real and synthetic
    /// data stay in separate rows.
    func aggregate(rawCutoffSec: Int64, hourCutoffSec: Int64) throws {
        // 1) raw -> hourly, grouped by (bucket, source)
        try exec("""
            INSERT OR REPLACE INTO samples_hourly
                (bucket, source, cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max,
                 fan_max_avg, fan_max_max, n)
            SELECT
                (ts / 3600) * 3600 AS bucket,
                source,
                AVG(cpu_temp), MAX(cpu_temp),
                AVG(gpu_temp), MAX(gpu_temp),
                AVG(CASE WHEN fan_max > 0 THEN fan_max END),
                MAX(CASE WHEN fan_max > 0 THEN fan_max END),
                COUNT(*)
            FROM samples
            WHERE ts < ?
            GROUP BY bucket, source;
            """, bindings: [.int64(rawCutoffSec)])
        try exec("DELETE FROM samples WHERE ts < ?;", bindings: [.int64(rawCutoffSec)])

        // 2) hourly -> daily, also grouped by source
        try exec("""
            INSERT OR REPLACE INTO samples_daily
                (bucket, source, cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max,
                 fan_max_avg, fan_max_max, n)
            SELECT
                (bucket / 86400) * 86400 AS bucket,
                source,
                AVG(cpu_temp_avg), MAX(cpu_temp_max),
                AVG(gpu_temp_avg), MAX(gpu_temp_max),
                AVG(fan_max_avg),  MAX(fan_max_max),
                SUM(n)
            FROM samples_hourly
            WHERE bucket < ?
            GROUP BY bucket, source;
            """, bindings: [.int64(hourCutoffSec)])
        try exec("DELETE FROM samples_hourly WHERE bucket < ?;", bindings: [.int64(hourCutoffSec)])
    }

    // MARK: - Low-level helpers

    private enum Binding {
        case int64(Int64)
        case double(Double)
        case text(String)
        case optionalDouble(Double?)
        case optionalInt64(Int64?)
    }

    private static func trustedGPUTemp(_ value: Double?, source: SampleSource) -> Double? {
        guard let value else { return nil }
        guard source == .real else { return value }
        return value >= minimumTrustedRealGPUTempC ? value : nil
    }

    private func tableHasColumn(_ table: String, column: String) throws -> Bool {
        let rows = try query("PRAGMA table_info(\(table));", bindings: []) { stmt -> String in
            String(cString: sqlite3_column_text(stmt, 1))
        }
        return rows.contains(column)
    }

    private func userVersion() throws -> Int {
        let rows = try query("PRAGMA user_version;", bindings: []) { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }
        return rows.first ?? 0
    }

    private func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    private func exec(_ sql: String, bindings: [Binding] = []) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        try bindAll(stmt, bindings)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, bindings: [Binding], map: (OpaquePointer?) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        try bindAll(stmt, bindings)
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(map(stmt))
        }
        return rows
    }

    private func bindAll(_ stmt: OpaquePointer?, _ bindings: [Binding]) throws {
        for (i, b) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int64(let v):
                guard sqlite3_bind_int64(stmt, idx, v) == SQLITE_OK else { throw DBError.bindFailed }
            case .double(let v):
                guard sqlite3_bind_double(stmt, idx, v) == SQLITE_OK else { throw DBError.bindFailed }
            case .text(let v):
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                    throw DBError.bindFailed
                }
            case .optionalDouble(let v):
                if let v {
                    guard sqlite3_bind_double(stmt, idx, v) == SQLITE_OK else { throw DBError.bindFailed }
                } else {
                    guard sqlite3_bind_null(stmt, idx) == SQLITE_OK else { throw DBError.bindFailed }
                }
            case .optionalInt64(let v):
                if let v {
                    guard sqlite3_bind_int64(stmt, idx, v) == SQLITE_OK else { throw DBError.bindFailed }
                } else {
                    guard sqlite3_bind_null(stmt, idx) == SQLITE_OK else { throw DBError.bindFailed }
                }
            }
        }
    }
}

private struct DailyStatsAccumulator {
    let date: Date
    var sampleCount = 0
    var cpuPeak: Double?
    var cpuSum = 0.0
    var cpuCount = 0
    var cpuMin: Double?
    var gpuPeak: Double?
    var gpuSum = 0.0
    var gpuCount = 0
    var fanPeak: Int?
    var fanSum = 0.0
    var fanCount = 0

    mutating func add(_ sample: Sample) {
        sampleCount += 1

        if let cpu = sample.cpuTempC {
            cpuPeak = max(cpuPeak ?? cpu, cpu)
            cpuMin = min(cpuMin ?? cpu, cpu)
            cpuSum += cpu
            cpuCount += 1
        }

        if let gpu = sample.gpuTempC {
            gpuPeak = max(gpuPeak ?? gpu, gpu)
            gpuSum += gpu
            gpuCount += 1
        }

        if let fan = sample.maxFanRPM, fan > 0 {
            fanPeak = max(fanPeak ?? fan, fan)
            fanSum += Double(fan)
            fanCount += 1
        }
    }

    var stats: DailyStats {
        DailyStats(
            date: date,
            sampleCount: sampleCount,
            cpuTempPeak: cpuPeak,
            cpuTempAvg: cpuCount > 0 ? cpuSum / Double(cpuCount) : nil,
            cpuTempMin: cpuMin,
            gpuTempPeak: gpuPeak,
            gpuTempAvg: gpuCount > 0 ? gpuSum / Double(gpuCount) : nil,
            fanRpmPeak: fanPeak,
            fanRpmAvg: fanCount > 0 ? fanSum / Double(fanCount) : nil
        )
    }
}

// MARK: - Column helper
//
// sqlite3_column_double returns 0 for SQL NULL. We can't distinguish
// "value is 0" from "value is NULL" with that function alone. This
// helper checks the column type first and returns nil for NULL.

private func sqlite3_column_double_opt(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
    if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
    return sqlite3_column_double(stmt, col)
}

private func sqlite3_column_int_opt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
    if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
    return Int(sqlite3_column_int64(stmt, col))
}

private func sqlite3_column_int64_opt(_ stmt: OpaquePointer?, _ col: Int32) -> Int64? {
    if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
    return sqlite3_column_int64(stmt, col)
}

// MARK: - Errors

enum DBError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .openFailed(let m):     return "sqlite open failed: \(m)"
        case .prepareFailed(let m):  return "sqlite prepare failed: \(m)"
        case .stepFailed(let m):     return "sqlite step failed: \(m)"
        case .bindFailed:            return "sqlite bind failed"
        }
    }
}
