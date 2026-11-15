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

    func testCancellationFromPreparationUpdateStopsBeforeGPUAllocation() {
        let token = CancellationToken()
        XCTAssertThrowsError(try GPUBenchmark.run(duration: 0.1, cancellation: token, progress: { _ in token.cancel() })) { error in
            guard case BenchmarkFailure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
    }

    func testGPUTimeRejectsInvalidOrImpossibleSpans() throws {
        XCTAssertEqual(try GPUBenchmark.checkedGPUSeconds(start: 10, end: 10.02, hostSeconds: 0.03), 0.02, accuracy: 1e-12)
        let invalid: [(Double, Double, Double)] = [(0, 1, 1), (1, 1, 1), (2, 1, 1),
            (.nan, 2, 1), (1, .infinity, 1), (1, 2, .nan),
            (1, 2, .infinity), (1, 2, 0), (1, 2, 0.01)]
        for (start, end, host) in invalid {
            XCTAssertThrowsError(try GPUBenchmark.checkedGPUSeconds(start: start, end: end, hostSeconds: host))
        }
    }

    func testResourceLoaderRejectsOutsideLinksAndUnboundedPayloads() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("BenchLibre-ShaderBoundary-\(UUID().uuidString)", isDirectory: true)
        let owner = fixture.appendingPathComponent("Owned", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside.metal")
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("outside sentinel".utf8).write(to: outside)
        XCTAssertThrowsError(try GPUBenchmark.readVerifiedShader(at: outside, containedIn: owner))
        let linked = owner.appendingPathComponent("Compute.metal")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertThrowsError(try GPUBenchmark.readVerifiedShader(at: linked, containedIn: owner)) { error in
            XCTAssertTrue(error.localizedDescription.contains("inaccessible"))
        }
        try FileManager.default.removeItem(at: linked)
        let linkedDirectory = owner.appendingPathComponent("Shaders", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture)
        XCTAssertThrowsError(try GPUBenchmark.readVerifiedShader(at: linkedDirectory.appendingPathComponent("outside.metal"), containedIn: owner)) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolique"))
        }
        let oversized = owner.appendingPathComponent("oversized.metal")
        try Data(repeating: 65, count: 16_385).write(to: oversized)
        XCTAssertThrowsError(try GPUBenchmark.readVerifiedShader(at: oversized, containedIn: owner)) { error in
            XCTAssertTrue(error.localizedDescription.contains("taille bornée"))
        }
        let modified = owner.appendingPathComponent("modified.metal")
        try Data("kernel changed".utf8).write(to: modified)
        XCTAssertThrowsError(try GPUBenchmark.readVerifiedShader(at: modified, containedIn: owner)) { error in
            XCTAssertTrue(error.localizedDescription.contains("empreinte"))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside sentinel".utf8))
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
        XCTAssertTrue(result.details.contains("FP32-FMA-v2"))
        XCTAssertTrue(result.details.contains(GPUBenchmark.expectedShaderSHA256))
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
