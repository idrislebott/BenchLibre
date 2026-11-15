import XCTest
@testable import BenchCore

final class DiskBenchmarkTests: XCTestCase {
    private func withTemporaryRoot(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchLibre-DiskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }

    private func settings(_ root: URL) -> DiskBenchmarks.Settings {
        DiskBenchmarks.Settings(fileBytes: 1_024 * 1_024, chunkBytes: 64 * 1_024,
                                maximumTransferBytes: 4 * 1_024 * 1_024, temporaryRoot: root)
    }

    func testTinyReadAndWriteAreAuditableAndOnlyRemoveOwnedFiles() throws {
        try withTemporaryRoot { root in
            let sentinel = root.appendingPathComponent("keep.txt")
            let content = Data("unrelated file".utf8)
            try content.write(to: sentinel)
            let configuration = settings(root)
            let read = try DiskBenchmarks.runRead(duration: 0.1, cancellation: CancellationToken(),
                                                   settings: configuration, progress: { _ in })
            let write = try DiskBenchmarks.runWrite(duration: 0.1, cancellation: CancellationToken(),
                                                     settings: configuration, progress: { _ in })
            XCTAssertEqual(read.kind, .diskRead)
            XCTAssertEqual(write.kind, .diskWrite)
            XCTAssertEqual(read.checksum, write.checksum)
            for result in [read, write] {
                let work = try XCTUnwrap(result.workAmount)
                let time = try XCTUnwrap(result.timingSeconds)
                XCTAssertTrue(result.validated)
                XCTAssertGreaterThan(time, 0)
                XCTAssertEqual(result.elapsedSeconds, time)
                XCTAssertEqual(result.unit, "Go/s")
                XCTAssertEqual(result.workUnit, "logical-bytes")
                XCTAssertEqual(result.timingSource, "monotonic-wall")
                XCTAssertGreaterThanOrEqual(work, Double(configuration.fileBytes))
                XCTAssertLessThanOrEqual(work, Double(configuration.maximumTransferBytes))
                XCTAssertEqual(work.truncatingRemainder(dividingBy: Double(configuration.fileBytes)), 0)
                XCTAssertEqual(result.value, work / time / 1e9, accuracy: result.value * 1e-12)
                XCTAssertTrue(result.samples.allSatisfy { $0.isFinite && $0 > 0 })
                XCTAssertTrue(result.checksum.isFinite)
                XCTAssertTrue(result.details.contains("F_NOCACHE"))
                XCTAssertTrue(result.details.contains("validation exclus"))
            }
            XCTAssertTrue(write.details.contains("fsync inclus"))
            XCTAssertEqual(try Data(contentsOf: sentinel), content)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep.txt"])
        }
    }

    func testCancellationDuringTransferCleansUpTemporaryFile() throws {
        try withTemporaryRoot { root in
            let token = CancellationToken()
            XCTAssertThrowsError(try DiskBenchmarks.runWrite(duration: 0.1, cancellation: token,
                                                              settings: settings(root)) { update in
                if update.fraction > 0 { token.cancel() }
            }) { error in
                guard case BenchmarkFailure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(token.isCancelled)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testPrecancelAndInvalidConfigurationDoNotCreateFiles() throws {
        try withTemporaryRoot { root in
            let configuration = settings(root)
            let token = CancellationToken(); token.cancel()
            XCTAssertThrowsError(try DiskBenchmarks.runRead(duration: 0.1, cancellation: token,
                                                             settings: configuration, progress: { _ in })) { error in
                guard case BenchmarkFailure.cancelled = error else { return XCTFail("Unexpected error: \(error)") }
            }
            for duration in [Double.nan, .infinity, -1, 0.099, 120.1] {
                XCTAssertThrowsError(try DiskBenchmarks.runWrite(duration: duration, cancellation: CancellationToken(),
                                                                  settings: configuration, progress: { _ in })) { error in
                    guard case BenchmarkFailure.invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
                }
            }
            var unbounded = configuration
            unbounded.maximumTransferBytes = 513 * 1_024 * 1_024
            XCTAssertThrowsError(try DiskBenchmarks.runWrite(duration: 0.1, cancellation: CancellationToken(),
                                                              settings: unbounded, progress: { _ in }))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testUnusableTemporaryRootIsReportedWithoutAlteringIt() throws {
        try withTemporaryRoot { root in
            let regularFile = root.appendingPathComponent("keep.txt")
            let bytes = Data("preserve".utf8)
            try bytes.write(to: regularFile)
            XCTAssertThrowsError(try DiskBenchmarks.runRead(duration: 0.1, cancellation: CancellationToken(),
                                                             settings: settings(regularFile), progress: { _ in })) { error in
                guard case BenchmarkFailure.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: regularFile), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep.txt"])
        }
    }
}
