import XCTest
@testable import BenchCore

final class ReportBoundaryTests: XCTestCase {
    private func fixture() -> BenchmarkReport {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let result = MetricResult(kind: .cpu, value: 2, unit: "GFLOP/s", elapsedSeconds: 0.1,
                                  samples: [2], checksum: 1, details: "Bounded fixture", validated: true)
        return BenchmarkReport(id: UUID(), formatVersion: 1, workloadVersion: "boundary-fixture",
                               applicationVersion: "0.3.0", startedAt: started,
                               endedAt: started.addingTimeInterval(0.1),
                               hardware: HardwareSummary(model: "FixtureMac", chip: "FixtureCPU", gpu: "FixtureGPU",
                                                         memoryBytes: 1_024, logicalCores: 1,
                                                         operatingSystem: "FixtureOS", architecture: "arm64", powerSource: "Secteur"),
                               configuration: BenchmarkConfiguration(secondsPerTest: 0.1, threads: 1,
                                                                     enabled: [.cpu], repetitions: 1),
                               thermalBefore: "Nominal", thermalAfter: "Nominal", results: [result], notes: [])
    }

    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ReportCodec.encode(fixture())) as? [String: Any])
    }

    func testSampleLimitAppliesToEncodingAndUntrustedJSONDecoding() throws {
        var report = fixture()
        report.results[0].samples = Array(repeating: 2, count: ReportLimits.samplesPerPass)
        let atLimit = try ReportCodec.decode(ReportCodec.encode(report))
        XCTAssertEqual(atLimit.results[0].samples.count, ReportLimits.samplesPerPass)
        report.results[0].samples.append(2)
        XCTAssertThrowsError(try ReportCodec.encode(report))

        var json = try object()
        var results = try XCTUnwrap(json["results"] as? [[String: Any]])
        results[0]["samples"] = Array(repeating: 2, count: ReportLimits.samplesPerPass + 1)
        json["results"] = results
        let hostile = try JSONSerialization.data(withJSONObject: json)
        XCTAssertLessThan(hostile.count, ReportLimits.maximumBytes)
        XCTAssertThrowsError(try ReportCodec.decode(hostile))
    }

    func testOversizedPayloadIsRejectedBeforeTypedDecoding() throws {
        var payload = try ReportCodec.encode(fixture())
        // Trailing JSON whitespace keeps this a valid document while crossing the byte limit.
        payload.append(Data(repeating: 0x20, count: ReportLimits.maximumBytes + 1 - payload.count))
        XCTAssertEqual(payload.count, ReportLimits.maximumBytes + 1)
        XCTAssertThrowsError(try ReportCodec.decode(payload))
        XCTAssertThrowsError(try ReportCodec.decode(Data()))
    }

    func testTextAndCollectionLimitsApplyToBothCodecDirections() throws {
        var report = fixture()
        report.results[0].details = String(repeating: "a", count: 16_385)
        XCTAssertThrowsError(try ReportCodec.encode(report))
        var json = try object()
        var results = try XCTUnwrap(json["results"] as? [[String: Any]])
        results[0]["details"] = report.results[0].details
        json["results"] = results
        XCTAssertThrowsError(try ReportCodec.decode(JSONSerialization.data(withJSONObject: json)))

        report = fixture()
        report.notes = Array(repeating: "note", count: 33)
        XCTAssertThrowsError(try ReportCodec.encode(report))
        json = try object()
        json["notes"] = report.notes
        XCTAssertThrowsError(try ReportCodec.decode(JSONSerialization.data(withJSONObject: json)))
    }
}
