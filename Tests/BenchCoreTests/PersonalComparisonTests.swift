import XCTest
@testable import BenchCore

final class PersonalComparisonTests: XCTestCase {
    private func metric(_ kind: BenchmarkKind = .cpu, value: Double = 100) -> MetricResult {
        let seconds = kind.lowerIsBetter ? value / 1e9 : 1
        let work = kind.lowerIsBetter ? 1 : value * 1e9
        let source = kind == .gpu ? "metal-gpu-timestamps" :
            (kind == .memory || kind == .latency ? "monotonic-kernel-intervals" : "monotonic-wall")
        return MetricResult(kind: kind, value: value, unit: kind.unit, elapsedSeconds: 1,
                            samples: [value], checksum: 1, details: "Comparison fixture", validated: true,
                            workAmount: work, workUnit: kind.workUnit, timingSeconds: seconds, timingSource: source)
    }

    private func report(at seconds: Double = 1_700_000_000) -> BenchmarkReport {
        let start = Date(timeIntervalSince1970: seconds)
        return BenchmarkReport(id: UUID(), formatVersion: 2, workloadVersion: "comparison-suite-v3", applicationVersion: "0.3.0",
                               startedAt: start, endedAt: start.addingTimeInterval(2),
                               hardware: HardwareSummary(model: "FixtureMac", chip: "FixtureChip", gpu: "FixtureGPU",
                                                         memoryBytes: 16 * 1_073_741_824, logicalCores: 8,
                                                         operatingSystem: "FixtureOS1", architecture: "arm64", powerSource: "Secteur"),
                               configuration: BenchmarkConfiguration(secondsPerTest: 1, threads: 8,
                                                                     enabled: [.cpu, .memory], repetitions: 3),
                               thermalBefore: "Nominal", thermalAfter: "Nominal",
                               results: [metric(), metric(.memory)], notes: [])
    }

    func testNearestEarlierMatchingSessionIsSelectedRegardlessOfInputOrder() {
        let current = report(at: 1_700_000_100)
        let oldest = report(at: 1_700_000_000)
        let nearest = report(at: 1_700_000_090)
        let future = report(at: 1_700_000_110)
        var sameIdentity = report(at: 1_700_000_095); sameIdentity.id = current.id
        let simultaneous = report(at: 1_700_000_100)
        var overlapping = report(at: 1_700_000_099); overlapping.endedAt = current.startedAt.addingTimeInterval(1)
        XCTAssertEqual(PersonalComparison.reference(for: current, in: [future, oldest, sameIdentity, simultaneous, nearest, overlapping])?.id,
                       nearest.id)
    }

    func testChangedWorkloadFormatAndConfigurationAreRejected() {
        let current = report(at: 1_700_000_100)
        for change in 0..<8 {
            var previous = report()
            switch change {
            case 0: previous.workloadVersion = "comparison-suite-v2"
            case 1: previous.formatVersion = 1
            case 2: previous.configuration.secondsPerTest = 2
            case 3: previous.configuration.threads = 4
            case 4: previous.configuration.repetitions = 1
            case 5: previous.configuration.enabled.reverse()
            case 6: previous.configuration.enabled = [.cpu]
            default: previous.configuration.threads = 0
            }
            XCTAssertNil(PersonalComparison.reference(for: current, in: [previous]), "Changed field \(change)")
        }
    }

    func testInvalidNearestResultFallsBackToOlderAuditedSession() {
        let current = report(at: 1_700_000_100)
        let older = report()
        var nearest = report(at: 1_700_000_090)
        nearest.results[0].workAmount = 1
        XCTAssertEqual(PersonalComparison.reference(for: current, in: [nearest, older])?.id, older.id)
    }

    func testHardwareMismatchIsRejected() {
        let current = report(at: 1_700_000_100)
        for change in 0..<6 {
            var previous = report()
            switch change {
            case 0: previous.hardware.model = "Another model"
            case 1: previous.hardware.chip = "Another chip"
            case 2: previous.hardware.gpu = "Another GPU"
            case 3: previous.hardware.memoryBytes *= 2
            case 4: previous.hardware.logicalCores += 1
            default: previous.hardware.architecture = "x86_64"
            }
            XCTAssertNil(PersonalComparison.reference(for: current, in: [previous]), "Changed field \(change)")
        }
    }

    func testOSAndObservedConditionsMayDifferAndRemainAvailableForDisclosure() {
        let current = report(at: 1_700_000_100)
        var previous = report()
        previous.applicationVersion = "0.3.1"
        previous.hardware.operatingSystem = "FixtureOS2"
        previous.hardware.powerSource = "Batterie"
        previous.thermalAfter = "Modéré"
        previous.conditions = [ConditionSample(elapsedSeconds: 0, thermalState: "Modéré", powerSource: "Batterie", lowPowerMode: true)]
        let selected = PersonalComparison.reference(for: current, in: [previous])
        XCTAssertEqual(selected?.id, previous.id)
        XCTAssertEqual(selected?.hardware.operatingSystem, "FixtureOS2")
        XCTAssertEqual(selected?.conditions?.first?.lowPowerMode, true)
    }

    func testMissingDuplicateOrUnauditedMetricsRejectTheSession() {
        let current = report(at: 1_700_000_100)
        for change in 0..<6 {
            var previous = report()
            switch change {
            case 0: previous.results.removeLast()
            case 1: previous.results.append(previous.results[0])
            case 2: previous.results[0].validated = false
            case 3: previous.results[0].workAmount = 1
            case 4: previous.results[1].timingSource = "monotonic-wall"
            default: previous.results.append(metric(.gpu))
            }
            XCTAssertNil(PersonalComparison.reference(for: current, in: [previous]), "Changed field \(change)")
        }
        var invalidCurrent = current
        invalidCurrent.results = []
        XCTAssertNil(PersonalComparison.reference(for: invalidCurrent, in: [report()]))
    }

    func testPercentChangesKeepTheirRawMeaningForThroughputAndLatency() throws {
        XCTAssertEqual(try XCTUnwrap(PersonalComparison.percentChange(current: metric(value: 125), reference: metric())), 25, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(PersonalComparison.percentChange(current: metric(.latency, value: 75), reference: metric(.latency))), -25, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(PersonalComparison.percentChange(current: metric(), reference: metric())), 0)
    }

    func testPercentRejectsIncompatibleMetadataAndInvalidAudits() {
        let previous = metric()
        for change in 0..<8 {
            var current = metric(value: 125)
            switch change {
            case 0: current.kind = .memory
            case 1: current.unit = "other"
            case 2: current.workUnit = "other"
            case 3: current.timingSource = "other"
            case 4: current.validated = false
            case 5: current.checksum = .infinity
            case 6: current.samples = [.nan]
            default: current.workAmount = nil
            }
            XCTAssertNil(PersonalComparison.percentChange(current: current, reference: previous), "Changed field \(change)")
        }
    }

    func testUnrepresentableChangesAndNonFiniteValuesAreRejected() {
        XCTAssertNil(PersonalComparison.percentChange(current: metric(value: 1e290), reference: metric(value: 1e-300)))
        XCTAssertNil(PersonalComparison.percentChange(current: metric(value: 1e-300), reference: metric(value: 1e290)))
        XCTAssertNil(PersonalComparison.percentChange(current: metric(value: 1e100), reference: metric(value: 1e-207)))
        for value in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertNil(PersonalComparison.percentChange(current: metric(value: value), reference: metric()))
            XCTAssertNil(PersonalComparison.percentChange(current: metric(), reference: metric(value: value)))
        }
        var invalidDate = report()
        invalidDate.startedAt = Date(timeIntervalSince1970: .nan)
        XCTAssertNil(PersonalComparison.reference(for: report(at: 1_700_000_100), in: [invalidDate]))
    }
}
