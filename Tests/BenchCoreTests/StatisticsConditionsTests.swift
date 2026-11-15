import XCTest
@testable import BenchCore

final class StatisticsConditionsTests: XCTestCase {
    func testSummaryUsesPassMedianAndSampleDispersion() throws {
        let summary = try MeasurementStatistics.summarize(kind: .cpu, values: [30, 10, 20])
        XCTAssertEqual(summary.kind, .cpu)
        XCTAssertEqual(summary.id, "cpu")
        XCTAssertEqual(summary.runCount, 3)
        XCTAssertEqual(summary.median, 20)
        XCTAssertEqual(summary.minimum, 10)
        XCTAssertEqual(summary.maximum, 30)
        XCTAssertEqual(try XCTUnwrap(summary.standardDeviation), 10, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.coefficientOfVariationPercent), 50, accuracy: 1e-12)
        let even = try MeasurementStatistics.summarize(kind: .memory, values: [5, 1, 7, 3])
        XCTAssertEqual(even.median, 4)
    }

    func testSinglePassHasNoInventedDispersion() throws {
        let summary = try MeasurementStatistics.summarize(kind: .gpu, values: [42])
        XCTAssertEqual(summary.median, 42)
        XCTAssertNil(summary.standardDeviation)
        XCTAssertNil(summary.coefficientOfVariationPercent)
    }

    func testInvalidPassesAreRejectedAndExtremeFiniteValuesStayFinite() throws {
        for values in [[], [0], [-1], [.nan], [.infinity], [2, .infinity]] as [[Double]] {
            XCTAssertThrowsError(try MeasurementStatistics.summarize(kind: .cpu, values: values))
        }
        let huge = try MeasurementStatistics.summarize(kind: .cpu, values: [1e308, 1e308, 5e307])
        XCTAssertTrue(try XCTUnwrap(huge.standardDeviation).isFinite)
        XCTAssertTrue(try XCTUnwrap(huge.coefficientOfVariationPercent).isFinite)
        let tiny = try MeasurementStatistics.summarize(kind: .cpu,
                                                       values: [.leastNonzeroMagnitude, .leastNonzeroMagnitude])
        XCTAssertEqual(tiny.median, .leastNonzeroMagnitude)
        XCTAssertEqual(tiny.standardDeviation, 0)
        XCTAssertEqual(tiny.coefficientOfVariationPercent, 0)
    }

    func testSummaryAndConditionCodablePreserveTheirMeanings() throws {
        let summary = try MeasurementStatistics.summarize(kind: .gpu, values: [10, 20, 30])
        let decoded = try JSONDecoder().decode(MeasurementSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.median, summary.median)
        XCTAssertEqual(decoded.coefficientOfVariationPercent, summary.coefficientOfVariationPercent)
        // Optional statistics can be absent in a single-pass representation.
        let minimal = Data(#"{"kind":"cpu","runCount":1,"median":5,"minimum":5,"maximum":5}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MeasurementSummary.self, from: minimal).standardDeviation)
        let condition = ConditionSample(elapsedSeconds: 1.25, thermalState: "Modéré",
                                        powerSource: "Batterie", lowPowerMode: true)
        let decodedCondition = try JSONDecoder().decode(ConditionSample.self, from: JSONEncoder().encode(condition))
        XCTAssertEqual(decodedCondition.elapsedSeconds, 1.25)
        XCTAssertEqual(decodedCondition.thermalState, "Modéré")
        XCTAssertEqual(decodedCondition.powerSource, "Batterie")
        XCTAssertTrue(decodedCondition.lowPowerMode)
    }

    func testMonitorRecordsBoundedStartPeriodicAndFinalObservations() throws {
        let source = TestConditionSource()
        let monitor = ConditionMonitor(interval: 1, maximumSamples: 3,
            clock: { source.time }, read: { source.reading() }, schedulesTimer: false)
        monitor.start()
        monitor.start()
        XCTAssertEqual(source.readCount, 1)
        XCTAssertEqual(monitor.latest?.elapsedSeconds, 0)
        XCTAssertEqual(monitor.elapsedSeconds, 0)
        source.advance(to: 1, lowPower: true)
        monitor.sampleNow()
        source.advance(to: 2, lowPower: false)
        monitor.sampleNow()
        source.advance(to: 3, lowPower: true)
        monitor.sampleNow()
        source.advance(to: 4, lowPower: false)
        let samples = monitor.finish()
        XCTAssertEqual(samples.map(\.elapsedSeconds), [0, 3, 4])
        XCTAssertEqual(samples.map(\.lowPowerMode), [false, true, false])
        XCTAssertEqual(monitor.latest?.elapsedSeconds, 4)
        XCTAssertEqual(monitor.elapsedSeconds, 4)
        let captured = source.readCount
        source.advance(to: 5, lowPower: true)
        monitor.sampleNow()
        monitor.start()
        XCTAssertEqual(monitor.finish().map(\.elapsedSeconds), [0, 3, 4])
        XCTAssertEqual(monitor.elapsedSeconds, 4)
        XCTAssertEqual(source.readCount, captured)
    }

    func testConcurrentQueuedSamplesCannotAppendAfterFinish() {
        let source = TestConditionSource()
        let monitor = ConditionMonitor(interval: 1, maximumSamples: 8,
            clock: { source.time }, read: { source.reading() }, schedulesTimer: false)
        monitor.start()
        let group = DispatchGroup()
        for _ in 0..<128 {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                monitor.sampleNow()
                group.leave()
            }
        }
        let final = monitor.finish()
        let captured = source.readCount
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(monitor.finish().count, final.count)
        XCTAssertEqual(source.readCount, captured)
        XCTAssertLessThanOrEqual(final.count, 8)
        XCTAssertEqual(final.first?.elapsedSeconds, 0)
    }

    func testMonitorFinishingBeforeStartDoesNotCreateAnObservation() {
        let source = TestConditionSource()
        let monitor = ConditionMonitor(interval: 1, maximumSamples: 3,
            clock: { source.time }, read: { source.reading() }, schedulesTimer: false)
        XCTAssertTrue(monitor.finish().isEmpty)
        monitor.start()
        XCTAssertNil(monitor.latest)
        XCTAssertEqual(source.readCount, 0)
    }

    func testActiveMonitorDoesNotRetainItselfThroughItsTimer() {
        weak var weakMonitor: ConditionMonitor?
        autoreleasepool {
            let monitor = ConditionMonitor()
            weakMonitor = monitor
            monitor.start()
        }
        XCTAssertNil(weakMonitor)
    }
}

private final class TestConditionSource: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: UInt64 = 0
    private var lowPower = false
    private var captures = 0
    var time: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return seconds * 1_000_000_000
    }
    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return captures
    }
    func advance(to seconds: UInt64, lowPower: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.seconds = seconds; self.lowPower = lowPower
    }
    func reading() -> ConditionMonitor.Reading {
        lock.lock(); defer { lock.unlock() }
        captures += 1
        return ConditionMonitor.Reading(thermalState: "Nominal", powerSource: "Batterie", lowPowerMode: lowPower)
    }
}
