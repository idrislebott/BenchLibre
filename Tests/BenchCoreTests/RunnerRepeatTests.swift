import XCTest
@testable import BenchCore

final class RunnerRepeatTests: XCTestCase {
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [SuiteUpdate] = []
        func append(_ value: SuiteUpdate) { lock.lock(); entries.append(value); lock.unlock() }
        var values: [SuiteUpdate] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func testThreeActualPassesKeepRawDataAndDisplayTheMedian() throws {
        let log = ProgressLog()
        let report = try BenchmarkRunner.run(configuration:
            BenchmarkConfiguration(secondsPerTest: 0.1, threads: 1, enabled: [.cpu], repetitions: 3),
            cancellation: CancellationToken(), progress: { log.append($0) })
        let trials = try XCTUnwrap(report.trials)
        let summary = try XCTUnwrap(report.summaries?.first)
        let result = try XCTUnwrap(report.results.first)
        let conditions = try XCTUnwrap(report.conditions)
        XCTAssertEqual(report.formatVersion, 2)
        XCTAssertEqual(report.totalSeconds, try XCTUnwrap(report.monotonicElapsedSeconds))
        XCTAssertEqual(trials.map(\.iteration), [1, 2, 3])
        XCTAssertEqual(Set(trials.map(\.kind)), [.cpu])
        XCTAssertEqual(summary.runCount, 3)
        XCTAssertEqual(summary.median, trials.map { $0.result.value }.sorted()[1])
        XCTAssertEqual(result.value, summary.median)
        XCTAssertNotNil(summary.standardDeviation)
        XCTAssertNotNil(summary.coefficientOfVariationPercent)
        for trial in trials {
            try BenchmarkRunner.validateResult(trial.result, expected: .cpu)
            XCTAssertLessThanOrEqual(trial.startedAtSeconds, trial.endedAtSeconds)
        }
        XCTAssertGreaterThanOrEqual(conditions.count, 2)
        XCTAssertEqual(conditions.first?.elapsedSeconds, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(conditions.last?.elapsedSeconds), try XCTUnwrap(trials.last?.endedAtSeconds))
        let progress = log.values
        XCTAssertEqual(Set(progress.map(\.iteration)), [1, 2, 3])
        XCTAssertTrue(progress.allSatisfy { $0.overallFraction.isFinite && (0...1).contains($0.overallFraction) })
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.overallFraction <= $1.overallFraction })
        XCTAssertEqual(progress.last?.overallFraction, 1)
        XCTAssertEqual(progress.filter { $0.completed != nil }.count, 1)
        let decoded = try ReportCodec.decode(ReportCodec.encode(report))
        XCTAssertEqual(decoded.trials?.count, 3)
        XCTAssertEqual(decoded.results[0].value, summary.median)
        XCTAssertEqual(decoded.totalSeconds, report.totalSeconds, accuracy: 1e-9)
    }

    func testKernelIntervalsAndLegacyWallTimingRemainExplicitlyAuditable() throws {
        for source in ["monotonic-kernel-intervals", "monotonic-wall"] {
            let latency = MetricResult(kind: .latency, value: 100, unit: "ns/accès", elapsedSeconds: 0.25,
                samples: [100], checksum: 3, details: "Fixture", validated: true,
                workAmount: 1_000_000, workUnit: "dependent-loads", timingSeconds: 0.1, timingSource: source)
            try BenchmarkRunner.validateResult(latency, expected: .latency)
            let memory = MetricResult(kind: .memory, value: 1, unit: "Go/s", elapsedSeconds: 0.25,
                samples: [1], checksum: 3, details: "Fixture", validated: true,
                workAmount: 100_000_000, workUnit: "logical-bytes", timingSeconds: 0.1, timingSource: source)
            try BenchmarkRunner.validateResult(memory, expected: .memory)
        }
        let estimatedGPU = MetricResult(kind: .gpu, value: 2, unit: "GFLOP/s", elapsedSeconds: 0.1,
            samples: [2], checksum: 1, details: "Fixture", validated: true,
            workAmount: 200_000_000, workUnit: "FLOP", timingSeconds: 0.1, timingSource: "monotonic-wall")
        XCTAssertThrowsError(try BenchmarkRunner.validateResult(estimatedGPU, expected: .gpu))
    }

    func testCancellationDuringSecondPassDoesNotReturnACompletedReport() {
        let token = CancellationToken()
        XCTAssertThrowsError(try BenchmarkRunner.run(configuration:
            BenchmarkConfiguration(secondsPerTest: 0.1, threads: 1, enabled: [.cpu], repetitions: 3),
            cancellation: token) { update in
                if update.iteration == 2 { token.cancel() }
            }) { failure in
                guard case BenchmarkFailure.cancelled = failure else { return XCTFail("Expected cancellation, got \(failure)") }
            }
        XCTAssertTrue(token.isCancelled)
    }
}
