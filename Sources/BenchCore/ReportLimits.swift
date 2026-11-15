import Foundation

/// Bounds are checked before allocating typed arrays from an untrusted report.
enum ReportLimits {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let samplesPerPass = 4_096
    static let maximumConditions = 10_000
    static func array<T: Decodable, K: CodingKey>(_ type: T.Type, from container: KeyedDecodingContainer<K>, key: K, limit: Int) throws -> [T] {
        var stream = try container.nestedUnkeyedContainer(forKey: key)
        guard (stream.count ?? 0) <= limit else { throw invalid() }
        var result: [T] = []
        result.reserveCapacity(min(stream.count ?? 0, limit))
        while !stream.isAtEnd {
            guard result.count < limit else { throw invalid() }
            result.append(try stream.decode(T.self))
        }
        return result
    }
    static func optionalArray<T: Decodable, K: CodingKey>(_ type: T.Type, from container: KeyedDecodingContainer<K>, key: K, limit: Int) throws -> [T]? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        return try array(type, from: container, key: key, limit: limit)
    }
    static func string(_ value: String, maximum: Int = 16_384) throws {
        guard value.utf8.count <= maximum else { throw invalid() }
    }
    static func shape(_ report: BenchmarkReport) throws {
        if let duration = report.monotonicElapsedSeconds, !duration.isFinite || duration < 0 { throw invalid() }
        // Bound dates before handing them to Foundation's calendar formatter.
        for date in [report.startedAt, report.endedAt] {
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else { throw invalid() }
        }
        guard report.results.count <= 6, (report.trials?.count ?? 0) <= 30,
              (report.summaries?.count ?? 0) <= 6, (report.conditions?.count ?? 0) <= maximumConditions,
              (report.omissions?.count ?? 0) <= 6, report.notes.count <= 32 else { throw invalid() }
        try string(report.workloadVersion, maximum: 256); try string(report.applicationVersion, maximum: 64)
        for value in [report.hardware.model, report.hardware.chip, report.hardware.gpu, report.hardware.operatingSystem,
                      report.hardware.architecture, report.hardware.powerSource, report.thermalBefore, report.thermalAfter] {
            try string(value, maximum: 1_024)
        }
        for result in report.results + (report.trials ?? []).map(\.result) {
            guard result.samples.count <= samplesPerPass else { throw invalid() }
            try string(result.details)
        }
        for note in report.notes { try string(note, maximum: 4_096) }
        for omission in report.omissions ?? [] { try string(omission.reason, maximum: 4_096) }
        for sample in report.conditions ?? [] {
            try string(sample.thermalState, maximum: 64); try string(sample.powerSource, maximum: 64)
        }
    }
    private static func invalid() -> BenchmarkFailure { .validationFailed("Le rapport dépasse les limites de taille ou de nombre d’éléments.") }
}
