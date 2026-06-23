import Foundation
import SQLite3

enum LegacyDatabaseMigrator {
    private static let currentAppSupportName = "DustWatch"
    private static let legacyAppSupportName = "CleanNotificationMac"
    private static let databaseName = "data.db"
    private static let markerName = ".migrated-from-CleanNotificationMac"

    static func preparedDefaultDatabasePath() -> String {
        let currentPath = defaultDatabasePath(appSupportName: currentAppSupportName)
        let legacyPath = defaultDatabasePath(appSupportName: legacyAppSupportName)
        let markerPath = ((currentPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(markerName)

        do {
            try migrateIfNeeded(currentPath: currentPath, legacyPath: legacyPath, markerPath: markerPath)
        } catch {
            NSLog("LegacyDatabaseMigrator: migration failed: \(error.localizedDescription)")
        }

        return currentPath
    }

    static func migrateIfNeeded(currentPath: String, legacyPath: String, markerPath: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: markerPath),
              fm.fileExists(atPath: legacyPath) else { return }

        let legacyCounts = try counts(at: legacyPath)
        guard legacyCounts.totalRows > 0 else { return }

        let currentExists = fm.fileExists(atPath: currentPath)
        let currentCounts = currentExists ? (try? counts(at: currentPath)) : nil
        if let currentCounts, currentCounts.totalRows >= legacyCounts.totalRows {
            return
        }

        let currentURL = URL(fileURLWithPath: currentPath)
        let currentDir = currentURL.deletingLastPathComponent()
        try fm.createDirectory(at: currentDir, withIntermediateDirectories: true)

        let tempURL = currentDir.appendingPathComponent(".\(databaseName).legacy-migration-\(UUID().uuidString)")
        try removeDatabaseFiles(at: tempURL)
        try copySQLiteDatabase(from: legacyPath, to: tempURL.path)

        // Bring old databases up to the current schema before merging any rows
        // that may have been written by the renamed app during a first launch.
        do {
            _ = try Database(path: tempURL.path)
        }
        try checkpointDatabase(at: tempURL.path)

        if currentExists {
            do {
                try mergeRows(from: currentPath, into: tempURL.path)
                try checkpointDatabase(at: tempURL.path)
            } catch {
                NSLog("LegacyDatabaseMigrator: preserving current database without merge: \(error.localizedDescription)")
            }
            try backupExistingDatabase(at: currentURL, in: currentDir)
        }

        try removeDatabaseFiles(at: currentURL)
        try fm.moveItem(at: tempURL, to: currentURL)
        try removeDatabaseFiles(at: tempURL)

        let marker = """
        Migrated legacy database from \(legacyPath)
        Date: \(ISO8601DateFormatter().string(from: Date()))
        """
        try marker.write(toFile: markerPath, atomically: true, encoding: .utf8)
        NSLog("LegacyDatabaseMigrator: migrated legacy database from \(legacyPath) to \(currentPath)")
    }

    private static func defaultDatabasePath(appSupportName: String) -> String {
        let dir = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first ?? NSTemporaryDirectory()
        return (dir as NSString)
            .appendingPathComponent(appSupportName)
            .appending("/\(databaseName)")
    }

    private static func copySQLiteDatabase(from sourcePath: String, to destinationPath: String) throws {
        var source: OpaquePointer?
        var destination: OpaquePointer?

        guard sqlite3_open_v2(sourcePath, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MigrationError.openFailed(sqliteMessage(source))
        }
        defer { sqlite3_close(source) }

        guard sqlite3_open_v2(destinationPath, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MigrationError.openFailed(sqliteMessage(destination))
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw MigrationError.backupFailed(sqliteMessage(destination))
        }
        let stepRC = sqlite3_backup_step(backup, -1)
        let finishRC = sqlite3_backup_finish(backup)
        guard stepRC == SQLITE_DONE, finishRC == SQLITE_OK else {
            throw MigrationError.backupFailed(sqliteMessage(destination))
        }
    }

    private static func mergeRows(from sourcePath: String, into destinationPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(destinationPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MigrationError.openFailed(sqliteMessage(db))
        }
        defer { sqlite3_close(db) }

        try exec(db, "ATTACH DATABASE \(sqlString(sourcePath)) AS incoming;")
        defer { try? exec(db, "DETACH DATABASE incoming;") }

        if try tableExists("samples", in: "incoming", db: db) {
            try exec(db, """
                INSERT OR IGNORE INTO samples
                    (ts, cpu_temp, gpu_temp, gpu_temp_raw, cpu_freq, cpu_load, gpu_load, p_state, fan_max, source)
                SELECT
                    ts, cpu_temp, gpu_temp, gpu_temp_raw, cpu_freq, cpu_load, gpu_load, p_state, fan_max, source
                FROM incoming.samples;
                """)
        }

        if try tableExists("samples_hourly", in: "incoming", db: db) {
            try exec(db, """
                INSERT OR IGNORE INTO samples_hourly
                    (bucket, source, cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max, fan_max_avg, fan_max_max, n)
                SELECT
                    bucket, source, cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max, fan_max_avg, fan_max_max, n
                FROM incoming.samples_hourly;
                """)
        }

        if try tableExists("samples_daily", in: "incoming", db: db) {
            try exec(db, """
                INSERT OR IGNORE INTO samples_daily
                    (bucket, source, cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max, fan_max_avg, fan_max_max, n)
                SELECT
                    bucket, source, cpu_temp_avg, cpu_temp_max, gpu_temp_avg, gpu_temp_max, fan_max_avg, fan_max_max, n
                FROM incoming.samples_daily;
                """)
        }

        if try tableExists("alerts", in: "incoming", db: db) {
            try exec(db, """
                INSERT OR IGNORE INTO alerts (ts, kind, details)
                SELECT ts, kind, details
                FROM incoming.alerts;
                """)
        }
    }

    private static func counts(at path: String) throws -> DatabaseCounts {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MigrationError.openFailed(sqliteMessage(db))
        }
        defer { sqlite3_close(db) }

        return DatabaseCounts(
            samples: try countRows(in: "samples", db: db),
            hourly: try countRows(in: "samples_hourly", db: db),
            daily: try countRows(in: "samples_daily", db: db),
            alerts: try countRows(in: "alerts", db: db)
        )
    }

    private static func countRows(in table: String, db: OpaquePointer?) throws -> Int64 {
        guard try tableExists(table, in: "main", db: db) else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.prepareFailed(sqliteMessage(db))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw MigrationError.stepFailed(sqliteMessage(db))
        }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func tableExists(_ table: String, in schema: String, db: OpaquePointer?) throws -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM \(schema).sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MigrationError.prepareFailed(sqliteMessage(db))
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw MigrationError.bindFailed
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func checkpointDatabase(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MigrationError.openFailed(sqliteMessage(db))
        }
        defer { sqlite3_close(db) }
        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private static func backupExistingDatabase(at currentURL: URL, in directory: URL) throws {
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDir = directory.appendingPathComponent("pre-legacy-migration-\(timestamp)", isDirectory: true)
        var copied = false

        for url in databaseFileSet(for: currentURL) where fm.fileExists(atPath: url.path) {
            if !copied {
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            }
            let destination = backupDir.appendingPathComponent(url.lastPathComponent)
            try fm.copyItem(at: url, to: destination)
            copied = true
        }
    }

    private static func removeDatabaseFiles(at databaseURL: URL) throws {
        let fm = FileManager.default
        for url in databaseFileSet(for: databaseURL) where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    private static func databaseFileSet(for databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? sqliteMessage(db)
            sqlite3_free(error)
            throw MigrationError.stepFailed(message)
        }
    }

    private static func sqlString(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqliteMessage(_ db: OpaquePointer?) -> String {
        guard let db else { return "unknown sqlite error" }
        return String(cString: sqlite3_errmsg(db))
    }
}

private struct DatabaseCounts {
    let samples: Int64
    let hourly: Int64
    let daily: Int64
    let alerts: Int64

    var totalRows: Int64 {
        samples + hourly + daily + alerts
    }
}

private enum MigrationError: LocalizedError {
    case openFailed(String)
    case backupFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "open failed: \(message)"
        case .backupFailed(let message):
            return "backup failed: \(message)"
        case .prepareFailed(let message):
            return "prepare failed: \(message)"
        case .stepFailed(let message):
            return "step failed: \(message)"
        case .bindFailed:
            return "bind failed"
        }
    }
}
