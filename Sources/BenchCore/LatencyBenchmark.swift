// SPDX-License-Identifier: MIT
import Foundation
import Dispatch
import BenchKernels

/// Effective dependent-access latency through the memory/cache hierarchy.
/// Fixed-size indexed slots do not assume a particular hardware cache line.
public enum LatencyBenchmark {
    private static let publicNodeCount: UInt32 = 1_048_576 // 64 MiB / 64 bytes.
    private static let seed: UInt64 = 0x4c41_5445_4e43_5931
    private static let maximumChunk: UInt64 = 65_536
    private static let cancellationCheck: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
        guard let pointer else { return 0 }
        return Unmanaged<CancellationToken>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
    }

    public static func run(duration: Double, cancellation: CancellationToken,
                           language: AppLanguage = .english, progress: @escaping EngineProgress) throws -> MetricResult {
        try measure(duration: duration, nodeCount: publicNodeCount, cancellation: cancellation, language: language, progress: progress)
    }

    // A smaller footprint permits fast correctness checks. Production callers
    // always use publicNodeCount, so calibration never changes the workload.
    static func measure(duration: Double, nodeCount: UInt32, cancellation: CancellationToken,
                        language: AppLanguage = .english, progress: @escaping EngineProgress) throws -> MetricResult {
        guard duration.isFinite, duration >= 0.1, duration <= 120,
              nodeCount >= 2, nodeCount <= publicNodeCount else {
            throw BenchmarkFailure.invalidConfiguration(Localizer(language).text("Invalid latency test configuration."))
        }
        try cancellation.check()
        progress(EngineUpdate(fraction: 0, message: Localizer(language).text("Preparing the randomized latency cycle…")))
        let cancellationPointer = Unmanaged.passUnretained(cancellation).toOpaque()
        guard let context = bl_latency_create_cancellable(nodeCount, seed, cancellationCheck, cancellationPointer) else {
            try cancellation.check()
            throw BenchmarkFailure.unavailable(Localizer(language).text("Unable to allocate the latency test cycle."))
        }
        defer { bl_latency_destroy(context) }
        let bytes = bl_latency_working_set_bytes(context)
        guard bl_latency_validate_cancellable(context, cancellationCheck, cancellationPointer) == 1 else {
            try cancellation.check()
            throw BenchmarkFailure.validationFailed(Localizer(language).text("The latency test does not contain a valid complete cycle."))
        }
        try cancellation.check()

        // Sweep the entire immutable cycle once, in cancellation-bounded calls.
        var warmIndex: UInt32 = 0
        var remaining = UInt64(nodeCount)
        while remaining > 0 {
            try cancellation.check()
            let count = min(maximumChunk, remaining)
            let warmed = bl_latency_chase(context, warmIndex, count)
            guard warmed.valid == 1, warmed.loads == count else {
                throw BenchmarkFailure.validationFailed(Localizer(language).text("Latency test warm-up failed."))
            }
            warmIndex = warmed.final_index
            remaining -= count
        }
        guard warmIndex == 0 else { throw BenchmarkFailure.validationFailed(Localizer(language).text("Incomplete latency cycle after warm-up.")) }

        progress(EngineUpdate(fraction: 0, message: Localizer(language).text("Calibrating dependent accesses…")))
        var chunk: UInt64 = 4_096
        var calibrationIndex: UInt32 = 0
        while true {
            try cancellation.check()
            let started = now()
            let measured = bl_latency_chase(context, calibrationIndex, chunk)
            let elapsed = seconds(started, now())
            guard measured.valid == 1, measured.loads == chunk else {
                throw BenchmarkFailure.validationFailed(Localizer(language).text("The latency kernel produced an invalid work count."))
            }
            calibrationIndex = measured.final_index
            if elapsed >= 0.002 || chunk == maximumChunk { break }
            let scale = min(4, 0.004 / max(elapsed, 0.000_001))
            chunk = min(maximumChunk, max(chunk + 1, UInt64(Double(chunk) * scale)))
        }

        var index: UInt32 = 0
        var loads: UInt64 = 0
        var samples: [Double] = []
        var measuredSeconds = 0.0
        var sampleSeconds = 0.0
        var sampleLoads: UInt64 = 0
        while measuredSeconds < duration {
            try cancellation.check()
            let kernelStart = now()
            let measured = bl_latency_chase(context, index, chunk)
            let kernelSeconds = seconds(kernelStart, now())
            guard measured.valid == 1, measured.loads == chunk, kernelSeconds > 0 else {
                throw BenchmarkFailure.validationFailed(Localizer(language).text("A dependent-access chunk is invalid."))
            }
            index = measured.final_index
            loads += measured.loads
            measuredSeconds += kernelSeconds
            sampleSeconds += kernelSeconds
            let interval = sampleSeconds
            if interval >= 0.1 {
                let sample = interval / Double(loads - sampleLoads) * 1_000_000_000
                samples.append(sample)
                sampleSeconds = 0; sampleLoads = loads
                let elapsed = measuredSeconds
                progress(EngineUpdate(fraction: min(0.999, elapsed / duration),
                                     value: elapsed / Double(loads) * 1_000_000_000,
                                     message: Localizer(language).text("Dependent memory accesses · {v0} MiB…", values: ["v0": String(describing: bytes / 1_048_576)])))
            }
        }
        try cancellation.check()
        let elapsed = measuredSeconds
        let value = elapsed / Double(loads) * 1_000_000_000
        if loads > sampleLoads, sampleSeconds >= 0.05 {
            samples.append(sampleSeconds / Double(loads - sampleLoads) * 1_000_000_000)
        }
        if samples.isEmpty { samples = [value] }

        // Validate the full topology and the final index against an independent
        // scalar traversal outside the measured interval. Only one cycle at
        // most is needed because the topology was proved to be a single cycle.
        guard loads > 0, elapsed > 0, value.isFinite, value > 0,
              samples.allSatisfy({ $0.isFinite && $0 > 0 }),
              bl_latency_validate_cancellable(context, cancellationCheck, cancellationPointer) == 1 else {
            try cancellation.check()
            throw BenchmarkFailure.validationFailed(Localizer(language).text("The latency measurement could not be validated."))
        }
        let expected = bl_latency_expected_index(context, 0, loads)
        try cancellation.check()
        guard index == expected else { throw BenchmarkFailure.validationFailed(Localizer(language).text("The final dependent-access index is incorrect.")) }
        progress(EngineUpdate(fraction: 1, value: value, message: Localizer(language).text("Dependent-access latency validated.")))
        return MetricResult(kind: .latency, value: value, unit: "ns/accès", elapsedSeconds: elapsed,
                            samples: samples, checksum: Double(index),
                            details: Localizer(language).text("Pointer-chase-v2: deterministic cycle of {v0} UInt32 indices in {v1} bytes ({v2} MiB), nodes spaced 64 bytes apart, seed 0x4c4154454e435931. {v3} dependent loads; chunks of {v4} accesses. Sum of monotonic C kernel windows divided by accesses; calls included, Swift control and callbacks excluded; allocation, preparation, warm-up, calibration and validation excluded. Full cycle and final index checked. Effective latency through the cache hierarchy for this workload, not certified physical DRAM latency. Lower is better.", values: ["v0": String(describing: nodeCount), "v1": String(describing: bytes), "v2": String(describing: bytes / 1_048_576), "v3": String(describing: loads), "v4": String(describing: chunk)]),
                            validated: true, workAmount: Double(loads), workUnit: "dependent-loads",
                            timingSeconds: elapsed, timingSource: "monotonic-kernel-intervals")
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1_000_000_000 }
}
