import Foundation
import Dispatch
import BenchKernels

/// Reproducible microbenchmarks. CPU reports FP32 FMA work, while memory reports
/// STREAM-style triad logical traffic, not a guessed DRAM bus counter.
public enum CPUMemoryBenchmarks {
    private final class CPUAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: UInt64 = 0
        private var checksum: Double = 0
        private var invalid = false
        func record(_ result: BLCPUResult) {
            lock.lock(); defer { lock.unlock() }
            operations += result.operations
            checksum += result.checksum
            invalid = invalid || !result.checksum.isFinite || result.operations == 0
        }
        func snapshot() -> (operations: UInt64, checksum: Double, invalid: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (operations, checksum, invalid)
        }
    }

    private static func validateDuration(_ duration: Double) throws {
        guard duration.isFinite, duration >= 0.1, duration <= 120 else {
            throw BenchmarkFailure.invalidConfiguration("La durée d’un test doit être comprise entre 0,1 et 120 secondes.")
        }
    }
    private static func nanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) / 1_000_000_000
    }

    /// All requested workers run the same 8 × 4-lane FP32 FMA kernel. One FMA is
    /// two floating-point operations; a kernel iteration therefore counts 64 FLOPs.
    public static func runCPU(
        duration: Double,
        threads: Int,
        cancellation: CancellationToken,
        progress: @escaping EngineProgress
    ) throws -> MetricResult {
        try validateDuration(duration)
        guard threads >= 1, threads <= 256 else {
            throw BenchmarkFailure.invalidConfiguration("Le nombre de threads CPU doit être compris entre 1 et 256.")
        }
        try cancellation.check()
        progress(EngineUpdate(fraction: 0, message: "Validation du noyau FP32…"))
        guard bl_cpu_validate() == 1 else {
            throw BenchmarkFailure.validationFailed("Le noyau CPU ne correspond pas à sa référence scalaire.")
        }

        // Calibrate a short chunk, bounding cancellation latency and excluding
        // compilation, validation and warm-up from the measurement window.
        var iterations: UInt64 = 4_096
        let maximumChunk: UInt64 = 4_194_304
        while true {
            try cancellation.check()
            let start = nanoseconds()
            let result = bl_cpu_fp32(iterations, 17)
            let elapsed = seconds(start, nanoseconds())
            guard result.checksum.isFinite, result.operations == iterations * 64 else {
                throw BenchmarkFailure.validationFailed("Le calcul CPU a produit un résultat invalide.")
            }
            if elapsed >= 0.006 || iterations == maximumChunk { break }
            let ratio = min(8.0, 0.008 / max(elapsed, 0.000_001))
            iterations = min(maximumChunk, max(iterations + 1, UInt64(Double(iterations) * ratio)))
        }
        let chunkIterations = iterations
        DispatchQueue.concurrentPerform(iterations: threads) { worker in
            if !cancellation.isCancelled {
                _ = bl_cpu_fp32(chunkIterations, UInt32(worker + 1))
            }
        }
        try cancellation.check()

        let accumulator = CPUAccumulator()
        let group = DispatchGroup()
        let start = nanoseconds()
        let deadline = start + UInt64(duration * 1_000_000_000)
        for worker in 0..<threads {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var seed = UInt32(worker + 1)
                while !cancellation.isCancelled && nanoseconds() < deadline {
                    let value = bl_cpu_fp32(chunkIterations, seed)
                    accumulator.record(value)
                    seed &+= UInt32(threads)
                }
            }
        }

        var samples: [Double] = []
        var previousTime = start
        var previousOperations: UInt64 = 0
        while group.wait(timeout: .now() + 0.1) == .timedOut {
            let now = nanoseconds()
            let snapshot = accumulator.snapshot()
            let interval = seconds(previousTime, now)
            let delta = snapshot.operations - previousOperations
            if delta > 0, interval > 0 {
                samples.append(Double(delta) / interval / 1_000_000_000)
                previousTime = now
                previousOperations = snapshot.operations
            }
            let elapsed = seconds(start, now)
            let latest = snapshot.operations > 0 ? Double(snapshot.operations) / elapsed / 1_000_000_000 : nil
            progress(EngineUpdate(fraction: min(elapsed / duration, 0.995), value: latest,
                                  message: "Calcul FP32 sur \(threads) thread\(threads > 1 ? "s" : "")…"))
        }
        // Always join the workers before propagating cancellation.
        try cancellation.check()
        let end = nanoseconds()
        let snapshot = accumulator.snapshot()
        let elapsed = seconds(start, end)
        guard !snapshot.invalid, snapshot.operations > 0, snapshot.checksum.isFinite, elapsed > 0 else {
            throw BenchmarkFailure.validationFailed("La mesure CPU n’a pas produit de travail vérifiable.")
        }
        let value = Double(snapshot.operations) / elapsed / 1_000_000_000
        let lastInterval = seconds(previousTime, end)
        let delta = snapshot.operations - previousOperations
        if delta > 0, lastInterval >= 0.05 {
            samples.append(Double(delta) / lastInterval / 1_000_000_000)
        }
        if samples.isEmpty { samples = [value] }
        progress(EngineUpdate(fraction: 1, value: value, message: "Test CPU terminé."))
        return MetricResult(
            kind: .cpu, value: value, unit: "GFLOP/s", elapsedSeconds: elapsed,
            samples: samples, checksum: snapshot.checksum,
            details: "FP32 FMA, 8 chaînes SIMD de 4 éléments, 64 FLOP/itération, \(threads) thread\(threads > 1 ? "s" : ""). Somme du travail de tous les threads divisée par le temps monotone écoulé ; préparation et échauffement exclus.",
            validated: true,
            workAmount: Double(snapshot.operations), workUnit: "FLOP",
            timingSeconds: elapsed, timingSource: "monotonic-wall"
        )
    }

    /// A single-threaded triad over three 64 MiB arrays: 192 MiB working set,
    /// two logical reads plus one logical write per element (12 bytes).
    public static func runMemory(
        duration: Double,
        cancellation: CancellationToken,
        progress: @escaping EngineProgress
    ) throws -> MetricResult {
        try validateDuration(duration)
        try cancellation.check()
        progress(EngineUpdate(fraction: 0, message: "Préparation de 192 Mio de mémoire…"))
        let floatCount = 16 * 1_024 * 1_024
        guard let buffers = bl_memory_create(floatCount) else {
            throw BenchmarkFailure.unavailable("Impossible d’allouer les 192 Mio nécessaires au test mémoire.")
        }
        defer { bl_memory_destroy(buffers) }
        try cancellation.check()
        bl_memory_triad(buffers)
        guard bl_memory_validate(buffers) == 1 else {
            throw BenchmarkFailure.validationFailed("Le noyau mémoire ne correspond pas aux valeurs attendues.")
        }
        try cancellation.check()

        let bytesPerPass = bl_memory_logical_bytes_per_pass(buffers)
        let start = nanoseconds()
        let deadline = start + UInt64(duration * 1_000_000_000)
        var passes: UInt64 = 0
        var samples: [Double] = []
        var previousTime = start
        var previousPasses: UInt64 = 0
        while nanoseconds() < deadline {
            try cancellation.check()
            bl_memory_triad(buffers)
            passes += 1
            let now = nanoseconds()
            let interval = seconds(previousTime, now)
            if interval >= 0.1 {
                let sample = Double((passes - previousPasses) * bytesPerPass) / interval / 1_000_000_000
                samples.append(sample)
                previousTime = now
                previousPasses = passes
                progress(EngineUpdate(fraction: min(seconds(start, now) / duration, 0.995), value: sample,
                                      message: "Triade mémoire : deux lectures et une écriture…"))
            }
        }
        let end = nanoseconds()
        try cancellation.check()
        let elapsed = seconds(start, end)
        let checksum = bl_memory_checksum(buffers)
        let expected = bl_memory_expected_checksum(buffers)
        guard passes > 0, elapsed > 0, checksum.isFinite, checksum == expected,
              bl_memory_validate(buffers) == 1 else {
            throw BenchmarkFailure.validationFailed("La vérification complète du résultat mémoire a échoué.")
        }
        let value = Double(passes * bytesPerPass) / elapsed / 1_000_000_000
        let lastInterval = seconds(previousTime, end)
        if passes > previousPasses, lastInterval >= 0.05 {
            samples.append(Double((passes - previousPasses) * bytesPerPass) / lastInterval / 1_000_000_000)
        }
        if samples.isEmpty { samples = [value] }
        progress(EngineUpdate(fraction: 1, value: value, message: "Test mémoire terminé."))
        return MetricResult(
            kind: .memory, value: value, unit: "Go/s", elapsedSeconds: elapsed,
            samples: samples, checksum: checksum,
            details: "Triade mono-thread A = B + 3 × C, 3 × 64 Mio, \(passes) passages. Débit en Go/s décimaux (octets / 10⁹) : 2 lectures + 1 écriture, soit 12 octets logiques par élément. Le trafic matériel supplémentaire, dont write-allocate, n’est pas compté. Allocation, premier accès, échauffement et validation exclus.",
            validated: true,
            workAmount: Double(passes * bytesPerPass), workUnit: "logical-bytes",
            timingSeconds: elapsed, timingSource: "monotonic-wall"
        )
    }
}
