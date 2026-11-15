import XCTest
@testable import BenchCore

final class ReportValidationTests: XCTestCase {
    private func fixture() throws -> BenchmarkReport {
        let values = [80.0, 100.0, 125.0]
        let trials = values.enumerated().map { offset, value in
            let result = MetricResult(kind: .latency, value: value, unit: "ns/accès", elapsedSeconds: 0.1,
                                      samples: [value], checksum: Double(offset), details: "Fixture \(offset)",
                                      validated: true, workAmount: 0.1 / value * 1e9, workUnit: "dependent-loads",
                                      timingSeconds: 0.1, timingSource: "monotonic-wall")
            let start = Double(offset) * 0.3 + 0.01
            return BenchmarkTrial(iteration: offset + 1, startedAtSeconds: start,
                                  endedAtSeconds: start + 0.2, result: result)
        }
        let started = Date(timeIntervalSince1970: 1_700_000_000.123)
        return BenchmarkReport(id: UUID(), formatVersion: 2, workloadVersion: "fixture-v2", applicationVersion: "0.2.0",
                               startedAt: started, endedAt: started.addingTimeInterval(1),
                               hardware: HardwareSummary(model: "FixtureMac", chip: "FixtureCPU", gpu: "FixtureGPU",
                                                         memoryBytes: 8 * 1_073_741_824, logicalCores: 2,
                                                         operatingSystem: "FixtureOS", architecture: "arm64", powerSource: "Secteur"),
                               configuration: BenchmarkConfiguration(secondsPerTest: 0.1, threads: 1,
                                                                     enabled: [.latency, .gpu], repetitions: 3),
                               thermalBefore: "Nominal", thermalAfter: "Nominal", results: [trials[1].result], notes: [],
                               trials: trials, summaries: [try MeasurementStatistics.summarize(kind: .latency, values: values)],
                               conditions: [ConditionSample(elapsedSeconds: 0, thermalState: "Nominal", powerSource: "Secteur", lowPowerMode: false),
                                            ConditionSample(elapsedSeconds: 1, thermalState: "Nominal", powerSource: "Secteur", lowPowerMode: false)],
                               omissions: [TestOmission(kind: .gpu, reason: "Indisponible dans cette fixture", completedRuns: 0)])
    }

    private func assertRejected(_ report: BenchmarkReport, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoded = try ReportCodec.encode(report)
        XCTAssertThrowsError(try ReportCodec.decode(encoded), file: file, line: line)
    }

    func testVersion2RoundTripPreservesTrialsSummaryAndOmission() throws {
        let report = try fixture()
        let decoded = try ReportCodec.decode(ReportCodec.encode(report))
        XCTAssertEqual(decoded.id, report.id)
        XCTAssertEqual(decoded.trials?.count, 3)
        XCTAssertEqual(decoded.summaries?.first?.median, 100)
        XCTAssertEqual(decoded.summaries?.first?.runCount, 3)
        XCTAssertEqual(decoded.results[0].value, 100)
        XCTAssertEqual(decoded.results[0].workAmount, report.trials?[1].result.workAmount)
        XCTAssertEqual(decoded.conditions?.count, 2)
        XCTAssertEqual(decoded.omissions?.first?.kind, .gpu)
    }

    func testPartialOmissionRetainsItsCompleteRawPasses() throws {
        var report = try fixture()
        let result = MetricResult(kind: .gpu, value: 2, unit: "GFLOP/s", elapsedSeconds: 0.1,
                                  samples: [2], checksum: 1, details: "GPU fixture", validated: true,
                                  workAmount: 200_000_000, workUnit: "FLOP", timingSeconds: 0.1,
                                  timingSource: "metal-gpu-timestamps")
        report.trials?.append(BenchmarkTrial(iteration: 1, startedAtSeconds: 0.85, endedAtSeconds: 0.99, result: result))
        report.omissions?[0].completedRuns = 1
        let decoded = try ReportCodec.decode(ReportCodec.encode(report))
        XCTAssertEqual(decoded.trials?.count, 4)
        XCTAssertEqual(decoded.omissions?.first?.completedRuns, 1)
        XCTAssertEqual(decoded.results.count, 1)
    }

    func testVersion2RequiresAllRawMetadataFields() throws {
        for field in 0..<4 {
            var report = try fixture()
            switch field {
            case 0: report.trials = nil
            case 1: report.summaries = nil
            case 2: report.conditions = nil
            default: report.omissions = nil
            }
            try assertRejected(report)
        }
    }

    func testDuplicateSummaryKindsAreRejectedInBothFormats() throws {
        for version in [1, 2] {
            var report = try fixture()
            report.formatVersion = version
            let duplicate = try XCTUnwrap(report.summaries?.first)
            report.summaries?.append(duplicate)
            try assertRejected(report)
        }
    }

    func testSummaryStatisticsAndRepresentativeMustMatchRawPasses() throws {
        for field in 0..<7 {
            var report = try fixture()
            switch field {
            case 0: report.summaries?[0].median = 101
            case 1: report.summaries?[0].minimum = 79
            case 2: report.summaries?[0].maximum = 126
            case 3: report.summaries?[0].runCount = 1
            case 4: report.summaries?[0].standardDeviation = 0
            case 5: report.summaries?[0].coefficientOfVariationPercent = nil
            default: report.results[0] = try XCTUnwrap(report.trials?.first?.result)
            }
            try assertRejected(report)
        }
        var unmatched = try fixture()
        unmatched.results[0].details = "Not the retained median pass"
        try assertRejected(unmatched)
    }

    func testRawPassAuditsCountsAndChronologyAreValidated() throws {
        for field in 0..<7 {
            var report = try fixture()
            switch field {
            case 0: report.trials?[0].result.workAmount = 1
            case 1: report.trials?[1].iteration = 1
            case 2: report.trials?.removeLast()
            case 3: report.trials?[0].startedAtSeconds = -1
            case 4: report.trials?[0].endedAtSeconds = 0
            case 5: report.trials?[1].startedAtSeconds = 0.1
            default: report.trials?[2].endedAtSeconds = 1.1
            }
            try assertRejected(report)
        }
    }

    func testConditionsCoverAllPassesAndRemainMonotonic() throws {
        for field in 0..<5 {
            var report = try fixture()
            switch field {
            case 0: report.conditions?.removeLast()
            case 1: report.conditions?[0].elapsedSeconds = -1
            case 2: report.conditions?[0].elapsedSeconds = 0.5
            case 3: report.conditions?[1].elapsedSeconds = 0.5
            default: report.conditions?.insert(ConditionSample(elapsedSeconds: 1.1, thermalState: "Nominal", powerSource: "Secteur", lowPowerMode: false), at: 1)
            }
            try assertRejected(report)
        }
    }

    func testCompleteAndOmittedKindsFormAnExactPartition() throws {
        for field in 0..<6 {
            var report = try fixture()
            switch field {
            case 0: report.omissions = []
            case 1: report.omissions?.append(TestOmission(kind: .latency, reason: "Overlap", completedRuns: 0))
            case 2:
                let duplicate = try XCTUnwrap(report.omissions?.first)
                report.omissions?.append(duplicate)
            case 3: report.omissions?[0].completedRuns = 1
            case 4: report.omissions?[0].completedRuns = 3
            default: report.omissions?[0].reason = "  \n"
            }
            try assertRejected(report)
        }
    }

    func testLegacyReportWithoutRepetitionsOrMetadataDefaultsToOnePass() throws {
        var report = try fixture()
        report.formatVersion = 1
        report.configuration.enabled = [.cpu]
        report.results = [MetricResult(kind: .cpu, value: 2, unit: "GFLOP/s", elapsedSeconds: 0.1,
                                       samples: [2], checksum: 1, details: "Legacy fixture", validated: true)]
        report.trials = nil; report.summaries = nil; report.conditions = nil; report.omissions = nil
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: ReportCodec.encode(report)) as? [String: Any])
        var configuration = try XCTUnwrap(object["configuration"] as? [String: Any])
        configuration.removeValue(forKey: "repetitions")
        object["configuration"] = configuration
        let decoded = try ReportCodec.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.configuration.repetitions, 1)
        XCTAssertEqual(decoded.results[0].kind, .cpu)
        XCTAssertNil(decoded.trials)
        XCTAssertNil(decoded.summaries)
        XCTAssertNil(decoded.conditions)
        XCTAssertNil(decoded.omissions)
    }

    func testLoadingCopiedExportsDeduplicatesIdentitiesWithoutRemovingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BenchLibre-ReportValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try fixture()
        let encoded = try ReportCodec.encode(report)
        let original = directory.appendingPathComponent("\(report.id.uuidString).json")
        let copy = directory.appendingPathComponent("copied-export.json")
        try encoded.write(to: original)
        try encoded.write(to: copy)
        var other = report
        other.id = UUID()
        try ReportCodec.encode(other).write(to: directory.appendingPathComponent("another-report.json"))
        try Data("incomplete JSON".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let loaded = ReportStore.load(from: directory)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.id)), Set([report.id, other.id]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
        XCTAssertEqual(try Data(contentsOf: original), encoded)
        XCTAssertEqual(try Data(contentsOf: copy), encoded)
    }
}
