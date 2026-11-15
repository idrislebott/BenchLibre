import XCTest
import BenchKernels

final class CKernelBoundaryTests: XCTestCase {
    func testMemoryNullContextIsSafeAndCannotValidate() {
        bl_memory_destroy(nil)
        bl_memory_triad(nil)
        XCTAssertEqual(bl_memory_float_count(nil), 0)
        XCTAssertEqual(bl_memory_logical_bytes_per_pass(nil), 0)
        XCTAssertEqual(bl_memory_validate(nil), 0)
        XCTAssertTrue(bl_memory_checksum(nil).isNaN)
        XCTAssertTrue(bl_memory_expected_checksum(nil).isNaN)
    }

    func testOversizedMemoryAndCPURequestsFailWithoutWork() {
        XCTAssertNil(bl_memory_create(0))
        XCTAssertNil(bl_memory_create(16 * 1_024 * 1_024 + 1))
        XCTAssertNil(bl_memory_create(Int.max))
        for iterations: UInt64 in [4_194_305, .max] {
            let rejected = bl_cpu_fp32(iterations, 0)
            XCTAssertEqual(rejected.operations, 0)
            XCTAssertTrue(rejected.checksum.isNaN)
        }
    }

    func testLatencyNullAndOutOfBoundsRequestsCannotTraverse() throws {
        bl_latency_destroy(nil)
        XCTAssertEqual(bl_latency_node_count(nil), 0)
        XCTAssertEqual(bl_latency_working_set_bytes(nil), 0)
        XCTAssertEqual(bl_latency_fingerprint(nil), 0)
        XCTAssertEqual(bl_latency_validate(nil), 0)
        XCTAssertEqual(bl_latency_next(nil, 0), UInt32.max)
        XCTAssertEqual(bl_latency_expected_index(nil, 0, 1), UInt32.max)
        XCTAssertNil(bl_latency_create(UInt32.max, 0))
        let missing = bl_latency_chase(nil, 0, UInt64.max)
        XCTAssertEqual(missing.valid, 0)
        XCTAssertEqual(missing.loads, 0)
        XCTAssertEqual(missing.final_index, UInt32.max)

        let context = try XCTUnwrap(bl_latency_create(2, 0))
        defer { bl_latency_destroy(context) }
        for loads: UInt64 in [1_048_577, .max] {
            let rejected = bl_latency_chase(context, 0, loads)
            XCTAssertEqual(rejected.valid, 0)
            XCTAssertEqual(rejected.loads, 0)
            XCTAssertEqual(rejected.final_index, UInt32.max)
        }
        XCTAssertEqual(bl_latency_next(context, 2), UInt32.max)
        XCTAssertEqual(bl_latency_next(context, UInt32.max), UInt32.max)
        XCTAssertEqual(bl_latency_expected_index(context, 2, 1), UInt32.max)
        XCTAssertEqual(bl_latency_expected_index(context, 0, UInt64.max), bl_latency_next(context, 0))
    }

    func testLatencyPreparationAndValidationHonorNativeCancellation() throws {
        let cancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in 1 }
        XCTAssertNil(bl_latency_create_cancellable(4_096, 0, cancelled, nil))
        let context = try XCTUnwrap(bl_latency_create(31, 0))
        defer { bl_latency_destroy(context) }
        XCTAssertEqual(bl_latency_validate_cancellable(context, cancelled, nil), 0)
        XCTAssertEqual(bl_latency_validate(context), 1)
    }
}
