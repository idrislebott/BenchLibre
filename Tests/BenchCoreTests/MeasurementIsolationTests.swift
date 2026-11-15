import XCTest
@testable import BenchCore

final class MeasurementIsolationTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func update(_ fraction: Double) -> SuiteUpdate {
        SuiteUpdate(kind: .cpu, overallFraction: fraction, phaseFraction: fraction,
                    value: nil, message: "Fixture", completed: nil, iteration: 1,
                    repetitions: 1, condition: nil, summary: nil)
    }

    func testBusyObserverDoesNotBlockProducerOrAccumulateUnboundedUpdates() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let log = Log()
        let relay = BenchmarkProgressRelay { value in
            if value.overallFraction == 0 {
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            log.append(value.overallFraction)
        }
        relay.enqueue(update(0))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // The observer remains deliberately blocked. Producing all updates
        // must finish without waiting for it, retaining only the newest one.
        for index in 1...10_000 { relay.enqueue(update(Double(index) / 10_000)) }
        release.signal()
        relay.flush()
        XCTAssertEqual(log.values, [0, 1])
    }

    private final class BlockingReader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func read() -> ConditionMonitor.Reading {
            lock.lock(); count += 1; let current = count; lock.unlock()
            if current == 2 {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return ConditionMonitor.Reading(thermalState: "Nominal", powerSource: "Secteur", lowPowerMode: false)
        }
    }

    func testSlowConditionCaptureDoesNotBlockBenchmarkSnapshots() {
        let reader = BlockingReader()
        let monitor = ConditionMonitor(interval: 1, maximumSamples: 8,
            clock: { DispatchTime.now().uptimeNanoseconds }, read: { reader.read() }, schedulesTimer: false)
        monitor.start()
        let captureFinished = DispatchGroup()
        captureFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            monitor.sampleNow()
            captureFinished.leave()
        }
        XCTAssertEqual(reader.entered.wait(timeout: .now() + 2), .success)
        let snapshotFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertEqual(monitor.latest?.elapsedSeconds, 0)
            XCTAssertGreaterThanOrEqual(monitor.elapsedSeconds, 0)
            snapshotFinished.signal()
        }
        // Releasing the capture only after this assertion proves that the
        // benchmark snapshot is independent of the potentially slow IOKit read.
        XCTAssertEqual(snapshotFinished.wait(timeout: .now() + 1), .success)
        reader.release.signal()
        XCTAssertEqual(captureFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(monitor.finish().count, 3)
    }
}
