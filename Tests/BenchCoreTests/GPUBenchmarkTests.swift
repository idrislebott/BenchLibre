import XCTest
import Metal
@testable import BenchCore

final class GPUBenchmarkTests: XCTestCase {
    func testInvalidDurationIsRejectedBeforeGPUWork() {
        for duration in [0.0, -1, Double.nan, Double.infinity, 121] {
            XCTAssertThrowsError(try GPUBenchmark.run(duration: duration, cancellation: CancellationToken(), progress: { _ in }))
        }
    }

    func testAlreadyCancelledDoesNotCreateGPUWork() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try GPUBenchmark.run(duration: 0.1, cancellation: token, progress: { _ in })) { error in
            guard case BenchmarkFailure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
    }

    func testShortMetalRunValidatesResultsAndProgress() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device on this runner") }
        let recorder = ProgressRecorder()
        let result = try GPUBenchmark.run(duration: 0.12, cancellation: CancellationToken(), progress: { recorder.append($0.fraction) })
        XCTAssertEqual(result.kind, .gpu)
        XCTAssertEqual(result.unit, "GFLOP/s")
        XCTAssertTrue(result.validated)
        XCTAssertTrue(result.value.isFinite && result.value > 0)
        XCTAssertGreaterThanOrEqual(result.elapsedSeconds, 0.1)
        XCTAssertFalse(result.samples.isEmpty)
        XCTAssertTrue(result.checksum.isFinite && result.checksum > 0)
        let work = try XCTUnwrap(result.workAmount)
        let gpuSeconds = try XCTUnwrap(result.timingSeconds)
        XCTAssertEqual(result.workUnit, "FLOP")
        XCTAssertEqual(result.timingSource, "metal-gpu-timestamps")
        XCTAssertTrue(work.isFinite && work > 0)
        XCTAssertTrue(gpuSeconds.isFinite && gpuSeconds > 0)
        XCTAssertEqual(work.truncatingRemainder(dividingBy: 536_870_912), 0, accuracy: 0.0001)
        XCTAssertEqual(result.value, work / gpuSeconds / 1_000_000_000, accuracy: result.value * 1e-12)
        let fractions = recorder.values
        XCTAssertEqual(fractions.first, 0)
        XCTAssertEqual(fractions.last, 1)
        XCTAssertTrue(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
