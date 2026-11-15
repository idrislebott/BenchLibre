import Foundation

public enum BenchmarkKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, latency
    case diskRead = "disk-read"
    case diskWrite = "disk-write"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU Metal"
        case .memory: return "Mémoire"
        case .latency: return "Latence mémoire"
        case .diskRead: return "Lecture disque"
        case .diskWrite: return "Écriture disque"
        }
    }
    public var unit: String {
        switch self {
        case .cpu, .gpu: return "GFLOP/s"
        case .latency: return "ns/accès"
        case .memory, .diskRead, .diskWrite: return "Go/s"
        }
    }
    public var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.3.layers.3d"
        case .memory: return "memorychip"
        case .latency: return "timer"
        case .diskRead: return "internaldrive"
        case .diskWrite: return "internaldrive.fill"
        }
    }
    public var lowerIsBetter: Bool { self == .latency }
    public var isDisk: Bool { self == .diskRead || self == .diskWrite }
    public static var defaultSelection: [BenchmarkKind] { [.cpu, .gpu, .memory, .latency] }
    var workUnit: String {
        switch self {
        case .cpu, .gpu: return "FLOP"
        case .latency: return "dependent-loads"
        case .memory, .diskRead, .diskWrite: return "logical-bytes"
        }
    }
    func measuredValue(work: Double, seconds: Double) -> Double {
        lowerIsBetter ? seconds / work * 1e9 : work / seconds / 1e9
    }
}

public struct EngineUpdate: Sendable {
    public var fraction: Double
    public var value: Double?
    public var message: String
    public init(fraction: Double, value: Double? = nil, message: String) {
        self.fraction = fraction; self.value = value; self.message = message
    }
}
public typealias EngineProgress = @Sendable (EngineUpdate) -> Void

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw BenchmarkFailure.cancelled } }
}

public enum BenchmarkFailure: LocalizedError {
    case cancelled
    case invalidConfiguration(String)
    case unavailable(String)
    case validationFailed(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Test arrêté."
        case .invalidConfiguration(let s), .unavailable(let s), .validationFailed(let s): return s
        }
    }
}

public struct MetricResult: Codable, Identifiable, Sendable {
    public var kind: BenchmarkKind
    public var value: Double
    public var unit: String
    public var elapsedSeconds: Double
    public var samples: [Double]
    public var checksum: Double
    public var details: String
    public var validated: Bool
    public var workAmount: Double?
    public var workUnit: String?
    public var timingSeconds: Double?
    public var timingSource: String?
    public var id: String { kind.rawValue }
    public init(kind: BenchmarkKind, value: Double, unit: String, elapsedSeconds: Double, samples: [Double], checksum: Double, details: String, validated: Bool,
                workAmount: Double? = nil, workUnit: String? = nil, timingSeconds: Double? = nil, timingSource: String? = nil) {
        self.kind = kind; self.value = value; self.unit = unit; self.elapsedSeconds = elapsedSeconds
        self.samples = samples; self.checksum = checksum; self.details = details; self.validated = validated
        self.workAmount = workAmount; self.workUnit = workUnit; self.timingSeconds = timingSeconds; self.timingSource = timingSource
    }
}

public struct BenchmarkConfiguration: Codable, Sendable {
    public var secondsPerTest: Double
    public var threads: Int
    public var enabled: [BenchmarkKind]
    public var repetitions: Int
    public init(secondsPerTest: Double = 10, threads: Int = ProcessInfo.processInfo.activeProcessorCount, enabled: [BenchmarkKind] = BenchmarkKind.defaultSelection, repetitions: Int = 3) {
        self.secondsPerTest = secondsPerTest; self.threads = threads; self.enabled = enabled; self.repetitions = repetitions
    }
    private enum CodingKeys: String, CodingKey { case secondsPerTest, threads, enabled, repetitions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        secondsPerTest = try values.decode(Double.self, forKey: .secondsPerTest)
        threads = try values.decode(Int.self, forKey: .threads)
        enabled = try ReportLimits.array(BenchmarkKind.self, from: values, key: .enabled, limit: 6)
        repetitions = try values.decodeIfPresent(Int.self, forKey: .repetitions) ?? 1
    }
    public func validate() throws {
        guard secondsPerTest.isFinite, secondsPerTest >= 0.1, secondsPerTest <= 120,
              threads > 0, threads <= 256, !enabled.isEmpty, Set(enabled).count == enabled.count else {
            throw BenchmarkFailure.invalidConfiguration("Configuration de test invalide.")
        }
        guard [1, 3, 5].contains(repetitions) else {
            throw BenchmarkFailure.invalidConfiguration("Le nombre de passages doit être 1, 3 ou 5.")
        }
    }
}

public struct HardwareSummary: Codable, Sendable {
    public var model: String
    public var chip: String
    public var gpu: String
    public var memoryBytes: UInt64
    public var logicalCores: Int
    public var operatingSystem: String
    public var architecture: String
    public var powerSource: String
    public var physicalMemoryGB: Int { Int(memoryBytes / 1_073_741_824) }
}

public struct BenchmarkReport: Codable, Identifiable, Sendable {
    public var id: UUID
    public var formatVersion: Int
    public var workloadVersion: String
    public var applicationVersion: String
    public var startedAt: Date
    public var endedAt: Date
    public var hardware: HardwareSummary
    public var configuration: BenchmarkConfiguration
    public var thermalBefore: String
    public var thermalAfter: String
    public var results: [MetricResult]
    public var notes: [String]
    public var trials: [BenchmarkTrial]? = nil
    public var summaries: [MeasurementSummary]? = nil
    public var conditions: [ConditionSample]? = nil
    public var omissions: [TestOmission]? = nil
    public var monotonicElapsedSeconds: Double? = nil
    public var totalSeconds: Double { monotonicElapsedSeconds ?? endedAt.timeIntervalSince(startedAt) }
}

public struct BenchmarkTrial: Codable, Identifiable, Sendable {
    public var iteration: Int
    public var startedAtSeconds: Double
    public var endedAtSeconds: Double
    public var result: MetricResult
    public var kind: BenchmarkKind { result.kind }
    public var id: String { "\(kind.rawValue)-\(iteration)" }
}

public struct TestOmission: Codable, Sendable {
    public var kind: BenchmarkKind
    public var reason: String
    public var completedRuns: Int
}


extension MetricResult {
    private enum CodingKeys: String, CodingKey {
        case kind, value, unit, elapsedSeconds, samples, checksum, details, validated
        case workAmount, workUnit, timingSeconds, timingSource
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(BenchmarkKind.self, forKey: .kind)
        value = try c.decode(Double.self, forKey: .value)
        unit = try c.decode(String.self, forKey: .unit)
        elapsedSeconds = try c.decode(Double.self, forKey: .elapsedSeconds)
        samples = try ReportLimits.array(Double.self, from: c, key: .samples, limit: ReportLimits.samplesPerPass)
        checksum = try c.decode(Double.self, forKey: .checksum)
        details = try c.decode(String.self, forKey: .details)
        validated = try c.decode(Bool.self, forKey: .validated)
        workAmount = try c.decodeIfPresent(Double.self, forKey: .workAmount)
        workUnit = try c.decodeIfPresent(String.self, forKey: .workUnit)
        timingSeconds = try c.decodeIfPresent(Double.self, forKey: .timingSeconds)
        timingSource = try c.decodeIfPresent(String.self, forKey: .timingSource)
        try ReportLimits.string(details)
        try ReportLimits.string(unit, maximum: 64)
        if let workUnit { try ReportLimits.string(workUnit, maximum: 64) }
        if let timingSource { try ReportLimits.string(timingSource, maximum: 128) }
        guard value.isFinite, value > 0, elapsedSeconds.isFinite, elapsedSeconds > 0, checksum.isFinite,
              !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BenchmarkFailure.validationFailed("Mesure non finie, vide ou négative.")
        }
    }
}

extension BenchmarkReport {
    private enum CodingKeys: String, CodingKey {
        case id, formatVersion, workloadVersion, applicationVersion, startedAt, endedAt, hardware, configuration
        case thermalBefore, thermalAfter, results, notes, trials, summaries, conditions, omissions, monotonicElapsedSeconds
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        monotonicElapsedSeconds = try c.decodeIfPresent(Double.self, forKey: .monotonicElapsedSeconds)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        workloadVersion = try c.decode(String.self, forKey: .workloadVersion)
        applicationVersion = try c.decode(String.self, forKey: .applicationVersion)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        hardware = try c.decode(HardwareSummary.self, forKey: .hardware)
        configuration = try c.decode(BenchmarkConfiguration.self, forKey: .configuration)
        thermalBefore = try c.decode(String.self, forKey: .thermalBefore)
        thermalAfter = try c.decode(String.self, forKey: .thermalAfter)
        results = try ReportLimits.array(MetricResult.self, from: c, key: .results, limit: 6)
        notes = try ReportLimits.array(String.self, from: c, key: .notes, limit: 32)
        trials = try ReportLimits.optionalArray(BenchmarkTrial.self, from: c, key: .trials, limit: 30)
        summaries = try ReportLimits.optionalArray(MeasurementSummary.self, from: c, key: .summaries, limit: 6)
        conditions = try ReportLimits.optionalArray(ConditionSample.self, from: c, key: .conditions, limit: ReportLimits.maximumConditions)
        omissions = try ReportLimits.optionalArray(TestOmission.self, from: c, key: .omissions, limit: 6)
        try ReportLimits.shape(self)
    }
}
