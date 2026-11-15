import XCTest
@testable import BenchCore
import BenchKernels

final class CPUMemoryTests: XCTestCase {
    func testCPUReferenceAndOperationCounting() {
        XCTAssertEqual(bl_cpu_validate(), 1)
        let zero = bl_cpu_fp32(0, 0)
        XCTAssertEqual(zero.operations, 0)
        XCTAssertEqual(zero.checksum, 23.5)
        let measured = bl_cpu_fp32(31, 17)
        XCTAssertEqual(measured.operations, 31 * 64)
        XCTAssertTrue(measured.checksum.isFinite)
        XCTAssertGreaterThan(measured.checksum, 0)
    }

    func testTriadReferenceAndTrafficCounting() throws {
        // Cover a partial period, a complete input period and a period plus tail.
        for count in [1, 31, 4_096, 4_127] {
            let buffers = try XCTUnwrap(bl_memory_create(count))
            defer { bl_memory_destroy(buffers) }
            XCTAssertEqual(bl_memory_float_count(buffers), count)
            XCTAssertEqual(bl_memory_logical_bytes_per_pass(buffers), UInt64(count) * 12)
            XCTAssertEqual(bl_memory_validate(buffers), 0)
            bl_memory_triad(buffers)
            XCTAssertEqual(bl_memory_validate(buffers), 1)
            XCTAssertEqual(bl_memory_checksum(buffers), bl_memory_expected_checksum(buffers))
        }
    }

    func testCPUProducesFiniteMeasuredWork() throws {
        let result = try CPUMemoryBenchmarks.runCPU(duration: 0.1, threads: 2,
                                                   cancellation: CancellationToken(), progress: { _ in })
        XCTAssertTrue(result.validated)
        XCTAssertGreaterThan(result.value, 0)
        XCTAssertGreaterThanOrEqual(result.elapsedSeconds, 0.1)
        XCTAssertEqual(result.unit, "GFLOP/s")
        XCTAssertTrue(result.samples.allSatisfy { $0.isFinite && $0 > 0 })
        XCTAssertTrue(result.checksum.isFinite)
        let work = try XCTUnwrap(result.workAmount)
        let measuredTime = try XCTUnwrap(result.timingSeconds)
        XCTAssertEqual(result.workUnit, "FLOP")
        XCTAssertEqual(result.timingSource, "monotonic-wall")
        XCTAssertEqual(result.elapsedSeconds, measuredTime)
        XCTAssertEqual(result.value, work / measuredTime / 1_000_000_000, accuracy: 1e-12)
    }

    func testMemoryReportsAuditableWorkAndTime() throws {
        let result = try CPUMemoryBenchmarks.runMemory(duration: 0.1,
                                                      cancellation: CancellationToken(), progress: { _ in })
        let work = try XCTUnwrap(result.workAmount)
        let measuredTime = try XCTUnwrap(result.timingSeconds)
        XCTAssertTrue(result.validated)
        XCTAssertGreaterThan(work, 0)
        XCTAssertEqual(result.workUnit, "logical-bytes")
        XCTAssertEqual(result.timingSource, "monotonic-wall")
        XCTAssertEqual(result.elapsedSeconds, measuredTime)
        XCTAssertEqual(result.value, work / measuredTime / 1_000_000_000, accuracy: 1e-12)
        XCTAssertEqual(work.truncatingRemainder(dividingBy: 192 * 1_024 * 1_024), 0)
    }

    func testInvalidCPUConfigurationIsRejected() {
        XCTAssertThrowsError(try CPUMemoryBenchmarks.runCPU(duration: .nan, threads: 1,
                                                           cancellation: CancellationToken(), progress: { _ in }))
        XCTAssertThrowsError(try CPUMemoryBenchmarks.runCPU(duration: 0.1, threads: 0,
                                                           cancellation: CancellationToken(), progress: { _ in }))
    }

    func testCancelledEnginesStopBeforeAllocationOrWork() {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try CPUMemoryBenchmarks.runCPU(duration: 0.1, threads: 1,
                                                           cancellation: token, progress: { _ in })) { error in
            guard case BenchmarkFailure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try CPUMemoryBenchmarks.runMemory(duration: 0.1,
                                                              cancellation: token, progress: { _ in })) { error in
            guard case BenchmarkFailure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
