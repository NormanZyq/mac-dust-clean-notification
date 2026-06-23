import XCTest
@testable import DustWatch

final class BaselineComparatorTests: XCTestCase {
    func testStrongSignalWithShortReferenceIsElevatedNotCleaning() throws {
        let database = try temporaryDatabase()
        let anchor = Date().addingTimeInterval(-4 * 3600)

        for day in [-7, -6] {
            try addDay(database, anchor: anchor, dayOffset: day, loadedTemp: 43)
        }
        for day in [-4, -3, -2, -1, 0] {
            try addDay(database, anchor: anchor, dayOffset: day, loadedTemp: 50)
        }

        let assessment = try BaselineComparator.assessDustRisk(
            database: database,
            config: Config(compareDays: 5)
        )

        XCTAssertEqual(assessment.level, .elevated)
        XCTAssertEqual(assessment.referenceDayCount, 2)
        XCTAssertGreaterThanOrEqual(assessment.evidence?.supportingRecentDayCount ?? 0, 3)
    }

    func testMatureMultiDaySignalRecommendsCleaning() throws {
        let database = try temporaryDatabase()
        let anchor = Date().addingTimeInterval(-4 * 3600)

        for day in -11 ... -4 {
            try addDay(database, anchor: anchor, dayOffset: day, loadedTemp: 43)
        }
        for day in [-2, -1, 0] {
            try addDay(database, anchor: anchor, dayOffset: day, loadedTemp: 50)
        }

        let assessment = try BaselineComparator.assessDustRisk(
            database: database,
            config: Config(compareDays: 3)
        )

        XCTAssertEqual(assessment.level, .needsCleaning)
        XCTAssertGreaterThanOrEqual(assessment.referenceDayCount, 7)
        XCTAssertGreaterThanOrEqual(assessment.evidence?.supportingRecentDayCount ?? 0, 3)
    }

    private func temporaryDatabase() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        return try Database(path: url.path)
    }

    private func addDay(
        _ database: Database,
        anchor: Date,
        dayOffset: Int,
        loadedTemp: Double
    ) throws {
        let dayStart = anchor.addingTimeInterval(TimeInterval(dayOffset * 86400))
        for i in 0 ..< 40 {
            try database.insert(Sample(
                timestamp: dayStart.addingTimeInterval(TimeInterval(i * 60)),
                cpuTempC: 40,
                gpuTempC: 40,
                cpuFreqGHz: 1.2,
                cpuLoad: 0.02,
                gpuLoad: 0.02,
                cpuPState: [0],
                fanRPMs: [1000]
            ))
        }
        for i in 0 ..< 40 {
            try database.insert(Sample(
                timestamp: dayStart.addingTimeInterval(TimeInterval((120 + i) * 60)),
                cpuTempC: loadedTemp,
                gpuTempC: loadedTemp,
                cpuFreqGHz: 1.8,
                cpuLoad: 0.13,
                gpuLoad: 0.02,
                cpuPState: [1],
                fanRPMs: [1000]
            ))
        }
    }
}
