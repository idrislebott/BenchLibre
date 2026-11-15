import XCTest
@testable import BenchCore

final class ReportTests: XCTestCase {
    func testInvalidConfigurationsAreRejected() {
        for config in [BenchmarkConfiguration(secondsPerTest: .nan), BenchmarkConfiguration(secondsPerTest: 0),
                       BenchmarkConfiguration(threads: 0), BenchmarkConfiguration(enabled: []),
                       BenchmarkConfiguration(enabled: [.cpu, .cpu]),
                       BenchmarkConfiguration(repetitions: 0), BenchmarkConfiguration(repetitions: 2),
                       BenchmarkConfiguration(repetitions: 7)] {
            XCTAssertThrowsError(try config.validate())
        }
    }

    func testCancellationStopsSuiteBeforeAnyWork() {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try BenchmarkRunner.run(configuration: BenchmarkConfiguration(secondsPerTest: 0.1), cancellation: token)) { failure in
            guard case BenchmarkFailure.cancelled = failure else { return XCTFail("Expected cancellation") }
        }
    }

    func testReportRoundTripPreservesAuditableResult() throws {
        let result = MetricResult(kind: .gpu, value: 2, unit: "GFLOP/s", elapsedSeconds: 1.5,
                                  samples: [1.8, 2.2], checksum: 5, details: "Test fixture", validated: true,
                                  workAmount: 2_000_000_000, workUnit: "FLOP", timingSeconds: 1, timingSource: "metal-gpu-timestamps")
        let started = Date(timeIntervalSince1970: 1_700_000_000.123)
        let report = BenchmarkReport(id: UUID(), formatVersion: 1, workloadVersion: "fixture-v1", applicationVersion: "0.1.0",
                                     startedAt: started, endedAt: started.addingTimeInterval(1.5), hardware: SystemInfo.capture(),
                                     configuration: BenchmarkConfiguration(secondsPerTest: 1.5), thermalBefore: "Nominal", thermalAfter: "Nominal",
                                     results: [result], notes: [])
        let decoded = try ReportCodec.decode(ReportCodec.encode(report))
        XCTAssertEqual(decoded.id, report.id)
        XCTAssertEqual(decoded.startedAt.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.totalSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(decoded.results[0].timingSource, "metal-gpu-timestamps")
        XCTAssertEqual(decoded.results[0].workAmount, 2_000_000_000)
    }
}
