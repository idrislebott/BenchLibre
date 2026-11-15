import XCTest
@testable import BenchCore
import BenchKernels

final class LatencyBenchmarkTests: XCTestCase {
    func testPermutationIsOneDeterministicCycleWithFixedSlotSpacing() throws {
        let first = try XCTUnwrap(bl_latency_create(257, 17))
        let same = try XCTUnwrap(bl_latency_create(257, 17))
        let other = try XCTUnwrap(bl_latency_create(257, 18))
        defer { bl_latency_destroy(first); bl_latency_destroy(same); bl_latency_destroy(other) }
        XCTAssertEqual(bl_latency_node_count(first), 257)
        XCTAssertEqual(bl_latency_working_set_bytes(first), 257 * 64)
        XCTAssertEqual(bl_latency_validate(first), 1)
        XCTAssertEqual(bl_latency_fingerprint(first), bl_latency_fingerprint(same))
        XCTAssertNotEqual(bl_latency_fingerprint(first), bl_latency_fingerprint(other))
        var visited = Set<UInt32>()
        var index: UInt32 = 0
        for _ in 0..<257 {
            XCTAssertTrue(visited.insert(index).inserted)
            index = bl_latency_next(first, index)
            XCTAssertLessThan(index, 257)
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(visited.count, 257)
        XCTAssertNil(bl_latency_create(0, 0))
        XCTAssertNil(bl_latency_create(1, 0))
        XCTAssertNil(bl_latency_create(1_048_577, 0))
    }

    func testDependentKernelCountsLoadsAndPreservesTraversalComposition() throws {
        let context = try XCTUnwrap(bl_latency_create(31, 987))
        defer { bl_latency_destroy(context) }
        for count: UInt64 in [0, 1, 7, 8, 9, 31, 63] {
            var reference: UInt32 = 0
            for _ in 0..<count { reference = bl_latency_next(context, reference) }
            let result = bl_latency_chase(context, 0, count)
            XCTAssertEqual(result.valid, 1)
            XCTAssertEqual(result.loads, count)
            XCTAssertEqual(result.final_index, reference)
            XCTAssertEqual(bl_latency_expected_index(context, 0, count), reference)
        }
        let first = bl_latency_chase(context, 0, 17)
        let second = bl_latency_chase(context, first.final_index, 19)
        XCTAssertEqual(second.final_index, bl_latency_chase(context, 0, 36).final_index)
        XCTAssertEqual(first.loads + second.loads, 36)
        XCTAssertEqual(bl_latency_chase(context, 31, 1).valid, 0)
    }

    func testShortLatencyMeasurementHasAuditableInverseRate() throws {
        let result = try LatencyBenchmark.measure(duration: 0.1, nodeCount: 4_096,
                                                  cancellation: CancellationToken(), progress: { _ in })
        let work = try XCTUnwrap(result.workAmount)
        let time = try XCTUnwrap(result.timingSeconds)
        XCTAssertEqual(result.kind, .latency)
        XCTAssertEqual(result.unit, "ns/accès")
        XCTAssertTrue(result.validated)
        XCTAssertGreaterThan(result.value, 0)
        XCTAssertGreaterThan(work, 0)
        XCTAssertGreaterThanOrEqual(time, 0.1)
        XCTAssertEqual(time, result.elapsedSeconds)
        XCTAssertEqual(result.workUnit, "dependent-loads")
        XCTAssertEqual(result.timingSource, "monotonic-kernel-intervals")
        XCTAssertEqual(result.value, time / work * 1_000_000_000, accuracy: 1e-12)
        XCTAssertTrue(result.samples.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertTrue(result.checksum.isFinite)
    }

    func testInvalidOrAlreadyCancelledRunDoesNotStartWork() {
        XCTAssertThrowsError(try LatencyBenchmark.run(duration: .nan, cancellation: CancellationToken(), progress: { _ in }))
        XCTAssertThrowsError(try LatencyBenchmark.run(duration: 0.01, cancellation: CancellationToken(), progress: { _ in }))
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try LatencyBenchmark.run(duration: 0.1, cancellation: token, progress: { _ in })) { error in
            guard case BenchmarkFailure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationDuringMeasurementStopsWithoutReturningAResult() {
        let token = CancellationToken()
        XCTAssertThrowsError(try LatencyBenchmark.measure(duration: 0.3, nodeCount: 4_096,
                                                         cancellation: token, progress: { update in
            if update.fraction > 0 { token.cancel() }
        })) { error in
            guard case BenchmarkFailure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
