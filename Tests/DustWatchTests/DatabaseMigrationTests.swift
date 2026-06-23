import XCTest
@testable import DustWatch
import SQLite3

final class DatabaseMigrationTests: XCTestCase {
    func testMigratesLegacyCleanNotificationDatabaseToDustWatchPath() throws {
        let root = temporaryDirectoryURL()
        let legacyURL = root
            .appendingPathComponent("CleanNotificationMac", isDirectory: true)
            .appendingPathComponent("data.db")
        let currentURL = root
            .appendingPathComponent("DustWatch", isDirectory: true)
            .appendingPathComponent("data.db")
        let markerURL = currentURL
            .deletingLastPathComponent()
            .appendingPathComponent(".test-migrated")

        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createVersionZeroDatabase(at: legacyURL.path)

        try LegacyDatabaseMigrator.migrateIfNeeded(
            currentPath: currentURL.path,
            legacyPath: legacyURL.path,
            markerPath: markerURL.path
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(try userVersion(at: currentURL.path), 3)
        XCTAssertEqual(try scalarInt64("SELECT count(*) FROM samples;", at: currentURL.path), 1)
        XCTAssertEqual(try scalarDouble("SELECT cpu_temp FROM samples WHERE ts = 1000;", at: currentURL.path), 55.0, accuracy: 0.001)
    }

    func testMigratesLegacyDatabaseOverFreshDustWatchDatabaseAndMergesRows() throws {
        let root = temporaryDirectoryURL()
        let legacyURL = root
            .appendingPathComponent("CleanNotificationMac", isDirectory: true)
            .appendingPathComponent("data.db")
        let currentDir = root.appendingPathComponent("DustWatch", isDirectory: true)
        let currentURL = currentDir.appendingPathComponent("data.db")
        let markerURL = currentDir.appendingPathComponent(".test-migrated")

        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
        try createVersionZeroDatabase(at: legacyURL.path)

        do {
            let currentDatabase = try Database(path: currentURL.path)
            try currentDatabase.insert(Sample(
                timestamp: Date(timeIntervalSince1970: 2_000),
                cpuTempC: 61.0,
                gpuTempC: nil,
                cpuFreqGHz: nil,
                cpuLoad: nil,
                gpuLoad: nil,
                cpuPState: [2],
                fanRPMs: [1_600],
                source: .real
            ))
        }

        try LegacyDatabaseMigrator.migrateIfNeeded(
            currentPath: currentURL.path,
            legacyPath: legacyURL.path,
            markerPath: markerURL.path
        )

        XCTAssertEqual(try scalarInt64("SELECT count(*) FROM samples;", at: currentURL.path), 2)
        XCTAssertEqual(try scalarInt64("SELECT count(*) FROM samples WHERE ts IN (1000, 2000);", at: currentURL.path), 2)
        let backupDirs = try FileManager.default.contentsOfDirectory(
            at: currentDir,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("pre-legacy-migration-") }
        XCTAssertEqual(backupDirs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDirs[0].appendingPathComponent("data.db").path))
    }

    func testMigratesVersionZeroDatabaseToCoolingCalibrationSchema() throws {
        let url = temporaryDatabaseURL()
        try createVersionZeroDatabase(at: url.path)

        let database = try Database(path: url.path)
        let config = try database.loadConfig()

        XCTAssertEqual(try userVersion(at: url.path), 3)
        XCTAssertTrue(try tableHasColumn("config", "cooling_calibrated_at", at: url.path))
        XCTAssertTrue(try tableHasColumn("samples", "source", at: url.path))
        XCTAssertTrue(try tableHasColumn("samples", "gpu_temp_raw", at: url.path))
        XCTAssertTrue(try tableHasColumn("samples_hourly", "source", at: url.path))
        XCTAssertTrue(try tableHasColumn("samples_daily", "source", at: url.path))

        XCTAssertEqual(config.sampleIntervalSec, 45)
        XCTAssertEqual(config.tempThresholdC, 4.5, accuracy: 0.001)
        XCTAssertEqual(config.fanThresholdRPM, 700)
        XCTAssertEqual(config.baselineDays, 42)
        XCTAssertEqual(config.compareDays, 5)
        XCTAssertFalse(config.notificationsEnabled)
        XCTAssertNil(config.coolingCalibrationStartedAt)

        let rawGPU = try scalarDouble("SELECT gpu_temp_raw FROM samples WHERE ts = 1000;", at: url.path)
        let trustedGPU = try nullableDouble("SELECT gpu_temp FROM samples WHERE ts = 1000;", at: url.path)
        XCTAssertEqual(rawGPU, 12.0, accuracy: 0.001)
        XCTAssertNil(trustedGPU)
    }

    func testMigratesVersionTwoDatabaseAndPersistsCalibrationMarker() throws {
        let url = temporaryDatabaseURL()
        try createVersionTwoDatabase(at: url.path)

        let database = try Database(path: url.path)
        var config = try database.loadConfig()
        XCTAssertEqual(try userVersion(at: url.path), 3)
        XCTAssertTrue(try tableHasColumn("config", "cooling_calibrated_at", at: url.path))
        XCTAssertEqual(config.sampleIntervalSec, 30)
        XCTAssertNil(config.coolingCalibrationStartedAt)

        config.coolingCalibrationStartedAt = 1_812_345_678
        try database.saveConfig(config)
        XCTAssertEqual(try database.loadConfig().coolingCalibrationStartedAt, 1_812_345_678)

        config.coolingCalibrationStartedAt = nil
        try database.saveConfig(config)
        XCTAssertNil(try database.loadConfig().coolingCalibrationStartedAt)
    }

    func testRepairsVersionThreeDatabaseMissingCalibrationColumn() throws {
        let url = temporaryDatabaseURL()
        try createVersionTwoDatabase(at: url.path)
        try withSQLite(url.path) { db in
            try exec(db, "PRAGMA user_version = 3;")
        }

        let database = try Database(path: url.path)
        XCTAssertEqual(try userVersion(at: url.path), 3)
        XCTAssertTrue(try tableHasColumn("config", "cooling_calibrated_at", at: url.path))
        XCTAssertNil(try database.loadConfig().coolingCalibrationStartedAt)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func createVersionZeroDatabase(at path: String) throws {
        try withSQLite(path) { db in
            try exec(db, """
                CREATE TABLE samples (
                    ts INTEGER PRIMARY KEY,
                    cpu_temp REAL,
                    gpu_temp REAL,
                    cpu_freq REAL,
                    cpu_load REAL,
                    gpu_load REAL,
                    p_state INTEGER,
                    fan_max INTEGER
                );
                """)
            try exec(db, "INSERT INTO samples VALUES (1000, 55.0, 12.0, 2.4, 0.5, 0.1, 4, 1800);")
            try exec(db, """
                CREATE TABLE samples_hourly (
                    bucket INTEGER PRIMARY KEY,
                    cpu_temp_avg REAL,
                    cpu_temp_max REAL,
                    gpu_temp_avg REAL,
                    gpu_temp_max REAL,
                    fan_max_avg REAL,
                    fan_max_max INTEGER,
                    n INTEGER
                );
                """)
            try exec(db, "INSERT INTO samples_hourly VALUES (0, 50.0, 60.0, 13.0, 14.0, 1500.0, 1700, 10);")
            try exec(db, """
                CREATE TABLE samples_daily (
                    bucket INTEGER PRIMARY KEY,
                    cpu_temp_avg REAL,
                    cpu_temp_max REAL,
                    gpu_temp_avg REAL,
                    gpu_temp_max REAL,
                    fan_max_avg REAL,
                    fan_max_max INTEGER,
                    n INTEGER
                );
                """)
            try exec(db, "INSERT INTO samples_daily VALUES (0, 50.0, 60.0, 13.0, 14.0, 1500.0, 1700, 10);")
            try exec(db, "CREATE TABLE alerts (ts INTEGER PRIMARY KEY, kind TEXT NOT NULL, details TEXT NOT NULL);")
            try exec(db, """
                CREATE TABLE config (
                    id INTEGER PRIMARY KEY CHECK (id = 0),
                    sample_interval INTEGER NOT NULL DEFAULT 60,
                    temp_threshold REAL NOT NULL DEFAULT 3.0,
                    fan_threshold INTEGER NOT NULL DEFAULT 500,
                    baseline_days INTEGER NOT NULL DEFAULT 60,
                    compare_days INTEGER NOT NULL DEFAULT 7,
                    notif_enabled INTEGER NOT NULL DEFAULT 1
                );
                """)
            try exec(db, "INSERT INTO config VALUES (0, 45, 4.5, 700, 42, 5, 0);")
            try exec(db, "PRAGMA user_version = 0;")
        }
    }

    private func createVersionTwoDatabase(at path: String) throws {
        try withSQLite(path) { db in
            try exec(db, """
                CREATE TABLE samples (
                    ts INTEGER PRIMARY KEY,
                    cpu_temp REAL,
                    gpu_temp REAL,
                    gpu_temp_raw REAL,
                    cpu_freq REAL,
                    cpu_load REAL,
                    gpu_load REAL,
                    p_state INTEGER,
                    fan_max INTEGER,
                    source TEXT NOT NULL DEFAULT 'real'
                );
                """)
            try exec(db, """
                CREATE TABLE samples_hourly (
                    bucket INTEGER NOT NULL,
                    source TEXT NOT NULL DEFAULT 'real',
                    cpu_temp_avg REAL,
                    cpu_temp_max REAL,
                    gpu_temp_avg REAL,
                    gpu_temp_max REAL,
                    fan_max_avg REAL,
                    fan_max_max INTEGER,
                    n INTEGER,
                    PRIMARY KEY (bucket, source)
                );
                """)
            try exec(db, """
                CREATE TABLE samples_daily (
                    bucket INTEGER NOT NULL,
                    source TEXT NOT NULL DEFAULT 'real',
                    cpu_temp_avg REAL,
                    cpu_temp_max REAL,
                    gpu_temp_avg REAL,
                    gpu_temp_max REAL,
                    fan_max_avg REAL,
                    fan_max_max INTEGER,
                    n INTEGER,
                    PRIMARY KEY (bucket, source)
                );
                """)
            try exec(db, "CREATE TABLE alerts (ts INTEGER PRIMARY KEY, kind TEXT NOT NULL, details TEXT NOT NULL);")
            try exec(db, """
                CREATE TABLE config (
                    id INTEGER PRIMARY KEY CHECK (id = 0),
                    sample_interval INTEGER NOT NULL DEFAULT 60,
                    temp_threshold REAL NOT NULL DEFAULT 3.0,
                    fan_threshold INTEGER NOT NULL DEFAULT 500,
                    baseline_days INTEGER NOT NULL DEFAULT 60,
                    compare_days INTEGER NOT NULL DEFAULT 7,
                    notif_enabled INTEGER NOT NULL DEFAULT 1
                );
                """)
            try exec(db, "INSERT INTO config VALUES (0, 30, 3.5, 600, 60, 3, 1);")
            try exec(db, "PRAGMA user_version = 2;")
        }
    }

    private func tableHasColumn(_ table: String, _ column: String, at path: String) throws -> Bool {
        try withSQLite(path) { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil), SQLITE_OK)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 1))
                if name == column { return true }
            }
            return false
        }
    }

    private func userVersion(at path: String) throws -> Int {
        try Int(scalarInt64("PRAGMA user_version;", at: path))
    }

    private func scalarDouble(_ sql: String, at path: String) throws -> Double {
        try withSQLite(path) { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            return sqlite3_column_double(stmt, 0)
        }
    }

    private func nullableDouble(_ sql: String, at path: String) throws -> Double? {
        try withSQLite(path) { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt, 0)
        }
    }

    private func scalarInt64(_ sql: String, at path: String) throws -> Int64 {
        try withSQLite(path) { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private func withSQLite<T>(_ path: String, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            XCTFail(message)
        }
    }
}
