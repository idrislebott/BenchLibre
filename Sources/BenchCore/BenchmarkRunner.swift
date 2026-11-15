import Foundation

public struct SuiteUpdate: Sendable {
    public let kind: BenchmarkKind
    public let overallFraction: Double
    public let phaseFraction: Double
    public let value: Double?
    public let message: String
    public let completed: MetricResult?
    public let iteration: Int
    public let repetitions: Int
    public let condition: ConditionSample?
    public let summary: MeasurementSummary?
}

public enum BenchmarkRunner {
    public static let workloadVersion = "benchlibre-suite-v2"
    public static let applicationVersion = "0.2.0"

    static func validateResult(_ result: MetricResult, expected kind: BenchmarkKind) throws {
        guard result.kind == kind, result.unit == kind.unit,
              result.validated, result.value.isFinite, result.value > 0,
              result.elapsedSeconds.isFinite, result.elapsedSeconds > 0,
              result.checksum.isFinite,
              !result.samples.isEmpty, result.samples.allSatisfy({ $0.isFinite && $0 > 0 }),
              let work = result.workAmount, work.isFinite, work > 0,
              let seconds = result.timingSeconds, seconds.isFinite, seconds > 0,
              result.workUnit == kind.workUnit,
              result.timingSource == (kind == .gpu ? "metal-gpu-timestamps" : "monotonic-wall"),
              abs(kind.measuredValue(work: work, seconds: seconds) - result.value) <= result.value * 1e-9 else {
            throw BenchmarkFailure.validationFailed("Résultat \(kind.title) invalide : le rapport n’a pas été enregistré.")
        }
    }

    public static func run(configuration: BenchmarkConfiguration,
                           cancellation: CancellationToken,
                           progress: @escaping @Sendable (SuiteUpdate) -> Void = { _ in }) throws -> BenchmarkReport {
        try configuration.validate()
        try cancellation.check()
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
            reason: "Session de mesure BenchLibre")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let hardware = SystemInfo.capture()
        let monitor = ConditionMonitor()
        let started = Date()
        monitor.start()
        defer { _ = monitor.finish() }
        let initialThermal = monitor.latest?.thermalState ?? SystemInfo.thermalState
        var results: [MetricResult] = []
        var trials: [BenchmarkTrial] = []
        var summaries: [MeasurementSummary] = []
        var omissions: [TestOmission] = []
        var notes: [String] = []
        let repetitions = configuration.repetitions
        let total = Double(configuration.enabled.count * repetitions)

        for (kindIndex, kind) in configuration.enabled.enumerated() {
            var kindTrials: [BenchmarkTrial] = []
            var omission: String?
            for iteration in 1...repetitions {
                try cancellation.check()
                let offset = Double(kindIndex * repetitions + iteration - 1)
                let update: EngineProgress = { phase in
                    let fraction = min(1, max(0, phase.fraction.isFinite ? phase.fraction : 0))
                    progress(SuiteUpdate(kind: kind, overallFraction: (offset + fraction) / total,
                        phaseFraction: fraction, value: phase.value,
                        message: "\(kind.title) · passage \(iteration)/\(repetitions) — \(phase.message)",
                        completed: nil, iteration: iteration, repetitions: repetitions,
                        condition: monitor.latest, summary: nil))
                }
                let trialStart = monitor.elapsedSeconds
                update(EngineUpdate(fraction: 0, message: "Préparation…"))
                let result: MetricResult
                do {
                    switch kind {
                    case .cpu:
                        result = try CPUMemoryBenchmarks.runCPU(duration: configuration.secondsPerTest,
                            threads: configuration.threads, cancellation: cancellation, progress: update)
                    case .gpu:
                        result = try GPUBenchmark.run(duration: configuration.secondsPerTest,
                            cancellation: cancellation, progress: update)
                    case .memory:
                        result = try CPUMemoryBenchmarks.runMemory(duration: configuration.secondsPerTest,
                            cancellation: cancellation, progress: update)
                    case .latency:
                        result = try LatencyBenchmark.run(duration: configuration.secondsPerTest,
                            cancellation: cancellation, progress: update)
                    case .diskRead:
                        result = try DiskBenchmarks.runRead(duration: configuration.secondsPerTest,
                            cancellation: cancellation, progress: update)
                    case .diskWrite:
                        result = try DiskBenchmarks.runWrite(duration: configuration.secondsPerTest,
                            cancellation: cancellation, progress: update)
                    }
                } catch BenchmarkFailure.unavailable(let reason) {
                    omission = reason
                    break
                }
                try validateResult(result, expected: kind)
                try cancellation.check()
                kindTrials.append(BenchmarkTrial(iteration: iteration, startedAtSeconds: trialStart,
                    endedAtSeconds: monitor.elapsedSeconds, result: result))
            }
            try cancellation.check()
            trials.append(contentsOf: kindTrials)
            if let omission {
                omissions.append(TestOmission(kind: kind, reason: omission, completedRuns: kindTrials.count))
                notes.append("\(kind.title) non mesuré : \(omission)")
                progress(SuiteUpdate(kind: kind,
                    overallFraction: Double(kindIndex + 1) / Double(configuration.enabled.count),
                    phaseFraction: 1, value: nil, message: "\(kind.title) indisponible : \(omission)",
                    completed: nil, iteration: kindTrials.count, repetitions: repetitions,
                    condition: monitor.latest, summary: nil))
                continue
            }
            let summary = try MeasurementStatistics.summarize(kind: kind, values: kindTrials.map { $0.result.value })
            // With an odd number of passes, the median is a real audited pass.
            let representative = kindTrials.sorted { $0.result.value < $1.result.value }[repetitions / 2].result
            results.append(representative)
            summaries.append(summary)
            progress(SuiteUpdate(kind: kind,
                overallFraction: Double(kindIndex + 1) / Double(configuration.enabled.count),
                phaseFraction: 1, value: summary.median, message: "\(kind.title) · médiane de \(repetitions) passage(s)",
                completed: representative, iteration: repetitions, repetitions: repetitions,
                condition: monitor.latest, summary: summary))
        }
        try cancellation.check()
        guard !results.isEmpty else { throw BenchmarkFailure.unavailable("Aucun test n’a pu être mesuré.") }
        let conditions = monitor.finish()
        let finalThermal = conditions.last?.thermalState ?? SystemInfo.thermalState
        if conditions.contains(where: { $0.thermalState != "Nominal" }) {
            notes.append("Un état thermique non nominal a été observé pendant la session ; voir le journal des conditions.")
        }
        if conditions.contains(where: \.lowPowerMode) {
            notes.append("Le mode économie d’énergie a été observé pendant la session.")
        }
        if Set(conditions.map(\.powerSource)).count > 1 {
            notes.append("L’alimentation a changé pendant la session.")
        }
        if repetitions == 1 { notes.append("Un seul passage : la dispersion entre passages n’est pas estimée.") }
        if configuration.secondsPerTest < 1 {
            notes.append("Exécution courte de validation ; ne pas utiliser comme résultat de référence.")
        }
        notes.append("Conditions observées au début, à la fin et environ chaque seconde ; ce journal ne certifie pas l’absence de bridage.")
        return BenchmarkReport(id: UUID(), formatVersion: 2, workloadVersion: workloadVersion,
            applicationVersion: applicationVersion, startedAt: started, endedAt: Date(),
            hardware: hardware, configuration: configuration, thermalBefore: initialThermal,
            thermalAfter: finalThermal, results: results, notes: notes,
            trials: trials, summaries: summaries, conditions: conditions, omissions: omissions)
    }
}
