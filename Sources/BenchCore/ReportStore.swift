import Foundation
import Darwin

public enum ReportCodec {
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
    public static func encode(_ report: BenchmarkReport) throws -> Data {
        try ReportLimits.shape(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, target in
            var container = target.singleValueContainer()
            try container.encode(formatter().string(from: date))
        }
        let data = try encoder.encode(report)
        guard data.count <= ReportLimits.maximumBytes else { throw BenchmarkFailure.validationFailed("Rapport trop volumineux.") }
        return data
    }
    public static func decode(_ data: Data) throws -> BenchmarkReport {
        guard !data.isEmpty, data.count <= ReportLimits.maximumBytes else { throw BenchmarkFailure.validationFailed("Taille de rapport non autorisée.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let value = try container.decode(String.self)
            guard value.utf8.count <= 64 else { throw BenchmarkFailure.validationFailed("Date trop longue.") }
            guard let date = formatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date de rapport invalide")
            }
            return date
        }
        let report = try decoder.decode(BenchmarkReport.self, from: data)
        guard [1, 2].contains(report.formatVersion) else { throw BenchmarkFailure.unavailable("Version de rapport non prise en charge.") }
        try report.configuration.validate()
        guard !report.results.isEmpty, Set(report.results.map(\.kind)).count == report.results.count,
              report.results.allSatisfy({ report.configuration.enabled.contains($0.kind) }) else {
            throw BenchmarkFailure.validationFailed("Liste de résultats invalide.")
        }
        for result in report.results {
            guard result.validated, result.value.isFinite, result.value > 0, result.unit == result.kind.unit else {
                throw BenchmarkFailure.validationFailed("Mesure de rapport invalide.")
            }
            if report.formatVersion == 2 { try BenchmarkRunner.validateResult(result, expected: result.kind) }
        }
        // The UI indexes summaries by kind, including when reading a legacy
        // file with extension fields. Reject duplicates before it can form a
        // Dictionary(uniqueKeysWithValues:).
        if let summaries = report.summaries,
           Set(summaries.map(\.kind)).count != summaries.count {
            throw BenchmarkFailure.validationFailed("Plusieurs résumés décrivent le même test.")
        }
        if report.formatVersion == 2 { try validateVersion2(report) }
        return report
    }

    /// Local structural and numerical coherence only. These checks cannot
    /// attest that a client measured honestly or that hardware was unthrottled.
    private static func validateVersion2(_ report: BenchmarkReport) throws {
        guard let trials = report.trials, let summaries = report.summaries,
              let conditions = report.conditions, let omissions = report.omissions else {
            throw BenchmarkFailure.validationFailed("Le rapport v2 doit contenir passages, résumés, conditions et omissions.")
        }
        let completeKinds = Set(report.results.map(\.kind))
        let omittedKinds = Set(omissions.map(\.kind))
        let enabledKinds = Set(report.configuration.enabled)
        guard Set(summaries.map(\.kind)) == completeKinds,
              omittedKinds.count == omissions.count,
              completeKinds.isDisjoint(with: omittedKinds),
              completeKinds.union(omittedKinds) == enabledKinds else {
            throw BenchmarkFailure.validationFailed("Les résultats, résumés et omissions ne correspondent pas aux tests sélectionnés.")
        }
        guard report.startedAt.timeIntervalSince1970.isFinite,
              report.endedAt.timeIntervalSince1970.isFinite,
              report.monotonicElapsedSeconds != nil || report.endedAt >= report.startedAt else {
            throw BenchmarkFailure.validationFailed("La chronologie du rapport est invalide.")
        }

        let timeTolerance = 0.000_001
        var previousConditionTime = 0.0
        guard conditions.count >= 2, let firstCondition = conditions.first,
              firstCondition.elapsedSeconds <= timeTolerance else {
            throw BenchmarkFailure.validationFailed("Le journal doit contenir les conditions initiales et finales.")
        }
        for condition in conditions {
            guard condition.elapsedSeconds.isFinite, condition.elapsedSeconds >= 0,
                  condition.elapsedSeconds >= previousConditionTime,
                  !condition.thermalState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !condition.powerSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchmarkFailure.validationFailed("Le journal des conditions est invalide ou désordonné.")
            }
            previousConditionTime = condition.elapsedSeconds
        }
        if let elapsed = report.monotonicElapsedSeconds {
            guard abs(elapsed - previousConditionTime) <= timeTolerance else {
                throw BenchmarkFailure.validationFailed("La durée monotone ne correspond pas au journal des conditions.")
            }
        }

        let repetitions = report.configuration.repetitions
        var grouped: [BenchmarkKind: [BenchmarkTrial]] = [:]
        var identities = Set<String>()
        var previousTrialEnd = 0.0
        for trial in trials {
            guard enabledKinds.contains(trial.kind), (1...repetitions).contains(trial.iteration),
                  identities.insert(trial.id).inserted,
                  trial.startedAtSeconds.isFinite, trial.endedAtSeconds.isFinite,
                  trial.startedAtSeconds >= 0, trial.endedAtSeconds >= trial.startedAtSeconds,
                  trial.startedAtSeconds + timeTolerance >= previousTrialEnd,
                  trial.endedAtSeconds <= previousConditionTime + timeTolerance else {
                throw BenchmarkFailure.validationFailed("Un passage est dupliqué, désordonné ou hors du journal des conditions.")
            }
            try BenchmarkRunner.validateResult(trial.result, expected: trial.kind)
            grouped[trial.kind, default: []].append(trial)
            previousTrialEnd = trial.endedAtSeconds
        }

        for representative in report.results {
            let kindTrials = grouped[representative.kind] ?? []
            guard kindTrials.count == repetitions,
                  let actual = summaries.first(where: { $0.kind == representative.kind }) else {
                throw BenchmarkFailure.validationFailed("Un test terminé ne contient pas tous les passages demandés.")
            }
            let expected = try MeasurementStatistics.summarize(kind: representative.kind,
                                                               values: kindTrials.map { $0.result.value })
            guard actual.runCount == expected.runCount, actual.median == expected.median,
                  actual.minimum == expected.minimum, actual.maximum == expected.maximum,
                  equivalent(actual.standardDeviation, expected.standardDeviation),
                  equivalent(actual.coefficientOfVariationPercent, expected.coefficientOfVariationPercent),
                  representative.value == expected.median,
                  kindTrials.contains(where: { sameResult($0.result, representative) }) else {
                throw BenchmarkFailure.validationFailed("Le résumé ou le passage médian ne correspond pas aux mesures brutes.")
            }
        }
        for omission in omissions {
            let kindTrials = grouped[omission.kind] ?? []
            let expectedIterations = Set((0..<kindTrials.count).map { $0 + 1 })
            guard !omission.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  omission.completedRuns == kindTrials.count, omission.completedRuns < repetitions,
                  Set(kindTrials.map(\.iteration)) == expectedIterations else {
                throw BenchmarkFailure.validationFailed("Une omission ne correspond pas aux passages conservés.")
            }
        }
    }

    private static func equivalent(_ actual: Double?, _ expected: Double?) -> Bool {
        switch (actual, expected) {
        case (nil, nil): return true
        case let (actual?, expected?):
            guard actual.isFinite, expected.isFinite, actual >= 0, expected >= 0 else { return false }
            return abs(actual - expected) <= max(1e-12, max(actual, expected) * 1e-9)
        default: return false
        }
    }

    private static func sameResult(_ left: MetricResult, _ right: MetricResult) -> Bool {
        left.kind == right.kind && left.value == right.value && left.unit == right.unit
            && left.elapsedSeconds == right.elapsedSeconds && left.samples == right.samples
            && left.checksum == right.checksum && left.details == right.details
            && left.validated == right.validated && left.workAmount == right.workAmount
            && left.workUnit == right.workUnit && left.timingSeconds == right.timingSeconds
            && left.timingSource == right.timingSource
    }
}

public enum ReportStore {
    public static var directory: URL { AppStorage.reports }
    public static var exportsDirectory: URL { AppStorage.exports }
    public static func validateExportName(_ name: String) throws { try AppStorage.validateExportName(name) }
    public static func save(_ report: BenchmarkReport) throws {
        let data = try ReportCodec.encode(report)
        _ = try ReportCodec.decode(data)
        let root = try AppStorage.prepare("Reports")
        _ = try AppStorage.writeJSON(data, in: root, name: "\(report.id.uuidString).json")
    }
    @discardableResult public static func export(_ report: BenchmarkReport, name: String? = nil) throws -> URL {
        let filename = name ?? "BenchLibre-\(report.id.uuidString).json"
        try validateExportName(filename)
        let data = try ReportCodec.encode(report)
        _ = try ReportCodec.decode(data)
        let root = try AppStorage.prepare("Exports")
        return try AppStorage.writeJSON(data, in: root, name: filename)
    }
    public static func load() -> [BenchmarkReport] { load(from: directory) }

    // Internal override is used only for isolated test fixtures, never from app arguments.
    static func load(from directory: URL) -> [BenchmarkReport] {
        guard let fd = try? AppStorage.openDirectory(directory) else { return [] }
        defer { _ = Darwin.close(fd) }
        let duplicateFD = Darwin.dup(fd)
        guard duplicateFD >= 0 else { return [] }
        guard let stream = Darwin.fdopendir(duplicateFD) else { _ = Darwin.close(duplicateFD); return [] }
        defer { _ = Darwin.closedir(stream) }
        var candidates: [(String, Int, Double)] = []
        var inspected = 0
        while let entry = Darwin.readdir(stream), inspected < 4_096 {
            inspected += 1
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String? in
                guard let terminator = bytes.firstIndex(of: 0) else { return nil }
                return String(bytes: bytes[..<terminator], encoding: .utf8)
            }
            guard let name, (try? AppStorage.validateExportName(name)) != nil else { continue }
            var info = stat()
            guard Darwin.fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  info.st_size > 0, info.st_size <= Int64(ReportLimits.maximumBytes) else { continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            candidates.append((name, Int(info.st_size), modified))
        }
        candidates.sort { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
        var reports: [UUID: BenchmarkReport] = [:]
        var bytes = 0
        for (name, size, _) in candidates.prefix(256) {
            guard bytes + size <= 32 * 1_024 * 1_024 else { continue }
            bytes += size
            guard let data = try? AppStorage.readJSON(in: directory, name: name),
                  let report = try? ReportCodec.decode(data), reports[report.id] == nil else { continue }
            reports[report.id] = report
            if reports.count == 100 { break }
        }
        return reports.values.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
    }
}
