// SPDX-License-Identifier: MIT
import Foundation
import Metal
import Darwin

/// A fixed FP32 compute workload, not a frame-rate or gaming score.
/// Every measured dispatch has identical dimensions on every Mac; calibration
/// changes only how many dispatches share a command buffer, not the kernel.
public enum GPUBenchmark {
    public static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }
    public static var deviceName: String? { MTLCreateSystemDefaultDevice()?.name }

    private static let threadCount = 32_768
    private static let iterations: UInt32 = 512
    private static let flopsPerThreadIteration: UInt64 = 32
    private static let defaultBundleName = "BenchLibre_BenchCore.bundle"

    public static func run(duration: Double, cancellation: CancellationToken, progress: @escaping EngineProgress) throws -> MetricResult {
        guard duration.isFinite, duration >= 0.1, duration <= 120 else {
            throw BenchmarkFailure.invalidConfiguration("Durée GPU invalide (0,1 à 120 secondes).")
        }
        try cancellation.check()
        progress(EngineUpdate(fraction: 0, message: "Préparation du pipeline Metal…"))
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw BenchmarkFailure.unavailable("Aucun GPU Metal utilisable sur ce Mac.")
        }
        let options = MTLCompileOptions()
        // Explicit fma plus disabled fast-math keeps the reference comparison
        // meaningful and prevents reassociation of the dependent FP32 chains.
        if #available(macOS 15, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        } else {
            options.fastMathEnabled = false
        }
        let library = try device.makeLibrary(source: try shaderSource(), options: options)
        guard let function = library.makeFunction(name: "fp32_fma_v1") else {
            throw BenchmarkFailure.unavailable("Le noyau de calcul Metal est introuvable.")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let bytes = threadCount * MemoryLayout<SIMD4<Float>>.stride
        guard let seeds = device.makeBuffer(length: bytes, options: .storageModeShared),
              let output = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw BenchmarkFailure.unavailable("Impossible d’allouer les tampons GPU.")
        }
        seeds.label = "BenchLibre FP32 input"
        output.label = "BenchLibre FP32 output"
        let source = seeds.contents().bindMemory(to: SIMD4<Float>.self, capacity: threadCount)
        for i in 0..<threadCount { source[i] = seed(i) }
        let groupWidth = max(1, min(256, pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth * 4))

        func dispatch(_ loopCount: UInt32, repetitions: Int) throws -> Double {
            try cancellation.check()
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
                throw BenchmarkFailure.unavailable("Impossible de créer une commande Metal.")
            }
            commands.label = "BenchLibre FP32-FMA-v1"
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(seeds, offset: 0, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            var count = loopCount
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
            for _ in 0..<repetitions {
                encoder.dispatchThreads(MTLSize(width: threadCount, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1))
            }
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error {
                throw BenchmarkFailure.unavailable("Erreur du GPU : \(error.localizedDescription)")
            }
            guard commands.status == .completed else {
                throw BenchmarkFailure.unavailable("La commande Metal ne s’est pas terminée.")
            }
            let gpuSeconds = commands.gpuEndTime - commands.gpuStartTime
            guard commands.gpuStartTime > 0, gpuSeconds.isFinite, gpuSeconds > 0 else {
                throw BenchmarkFailure.unavailable("Ce pilote ne fournit pas d’horodatage GPU valide ; aucun débit estimé n’est substitué.")
            }
            try cancellation.check()
            return gpuSeconds
        }

        // This validation dispatch also warms the pipeline. Neither it nor
        // calibration contributes any FLOPs or time to the reported rate.
        _ = try dispatch(16, repetitions: 1)
        _ = try validate(output: output, iterations: 16)
        progress(EngineUpdate(fraction: 0, message: "Échauffement et validation du GPU…"))
        let calibration = try dispatch(iterations, repetitions: 1)
        let batch = Int(max(1, min(64, (0.015 / calibration).rounded(.down))))
        let flopsPerDispatch = Double(UInt64(threadCount) * UInt64(iterations) * flopsPerThreadIteration)
        let flopsPerBatch = flopsPerDispatch * Double(batch)
        let start = now()
        var sampleStart = start
        var totalGPUSeconds = 0.0
        var totalFLOPs = 0.0
        var sampleGPUSeconds = 0.0
        var sampleFLOPs = 0.0
        var samples: [Double] = []
        var batches = 0

        while now() - start < duration {
            let gpuSeconds = try dispatch(iterations, repetitions: batch)
            totalGPUSeconds += gpuSeconds
            totalFLOPs += flopsPerBatch
            sampleGPUSeconds += gpuSeconds
            sampleFLOPs += flopsPerBatch
            batches += 1
            let elapsed = now() - start
            if now() - sampleStart >= 0.2 {
                let rate = sampleFLOPs / sampleGPUSeconds / 1_000_000_000
                samples.append(rate)
                progress(EngineUpdate(fraction: min(0.999, elapsed / duration), value: rate, message: "Calcul FP32 sur \(device.name)"))
                sampleStart = now()
                sampleGPUSeconds = 0
                sampleFLOPs = 0
            }
        }
        let elapsed = now() - start
        if sampleGPUSeconds > 0 { samples.append(sampleFLOPs / sampleGPUSeconds / 1_000_000_000) }
        try cancellation.check()
        let checksum = try validate(output: output, iterations: iterations)
        guard totalGPUSeconds > 0, totalFLOPs > 0, batches > 0 else {
            throw BenchmarkFailure.validationFailed("Le test GPU n’a produit aucune mesure.")
        }
        let value = totalFLOPs / totalGPUSeconds / 1_000_000_000
        guard value.isFinite, value > 0, samples.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BenchmarkFailure.validationFailed("Le débit GPU mesuré n’est pas valide.")
        }
        progress(EngineUpdate(fraction: 1, value: value, message: "GPU validé par la référence CPU"))
        return MetricResult(kind: .gpu, value: value, unit: "GFLOP/s", elapsedSeconds: elapsed,
                            samples: samples, checksum: checksum,
                            details: "FP32-FMA-v1 : 32 768 threads × 512 itérations × 16 fma (2 FLOP/fma), soit 536 870 912 FLOP par dispatch. Horodatage GPU ; \(batch) dispatch(s) par commande, \(batches) commandes. Débit pondéré par le temps GPU, hors échauffement et calibration ; initialisation et réduction exclues du compte. Référence CPU vérifiée sur 7 positions × 4 composantes, avant et après la mesure. \(device.name).",
                            validated: true, workAmount: totalFLOPs, workUnit: "FLOP",
                            timingSeconds: totalGPUSeconds, timingSource: "metal-gpu-timestamps")
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    private static func seed(_ index: Int) -> SIMD4<Float> {
        let word = UInt32(index) &* 1_664_525 &+ 1_013_904_223
        return SIMD4(Float(word & 0xffff) / 65_536 + 0.05,
                     Float((word >> 8) & 0xffff) / 65_536 + 0.10,
                     Float((word >> 16) & 0xffff) / 65_536 + 0.15,
                     Float((word >> 4) & 0xffff) / 65_536 + 0.20)
    }

    private static func reference(_ input: SIMD4<Float>, iterations: UInt32) -> SIMD4<Float> {
        let offsets: [[Float]] = [[0, 0, 0, 0], [0.25, 0.5, 0.75, 1], [1, 0.75, 0.5, 0.25], [0.125, 0.375, 0.625, 0.875]]
        let factors: [[Float]] = [[0.99991, 0.99983, 0.99979, 0.99971], [0.99967, 0.99961, 0.99953, 0.99947], [0.99943, 0.99937, 0.99929, 0.99923], [0.99919, 0.99913, 0.99907, 0.99901]]
        let addends: [[Float]] = [[0.00011, 0.00017, 0.00023, 0.00029], [0.00031, 0.00037, 0.00041, 0.00043], [0.00047, 0.00053, 0.00059, 0.00061], [0.00067, 0.00071, 0.00073, 0.00079]]
        var chains = (0..<4).map { chain in (0..<4).map { lane in input[lane] + offsets[chain][lane] } }
        for _ in 0..<iterations {
            for chain in 0..<4 {
                for lane in 0..<4 { chains[chain][lane] = fmaf(chains[chain][lane], factors[chain][lane], addends[chain][lane]) }
            }
        }
        return SIMD4((chains[0][0] + chains[1][0]) + chains[2][0] + chains[3][0],
                     (chains[0][1] + chains[1][1]) + chains[2][1] + chains[3][1],
                     (chains[0][2] + chains[1][2]) + chains[2][2] + chains[3][2],
                     (chains[0][3] + chains[1][3]) + chains[2][3] + chains[3][3])
    }

    private static func validate(output: MTLBuffer, iterations: UInt32) throws -> Double {
        let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: threadCount)
        let probes = [0, 1, 17, threadCount / 3, threadCount / 2, threadCount - 2, threadCount - 1]
        var checksum = 0.0
        for index in probes {
            let expected = reference(seed(index), iterations: iterations)
            for lane in 0..<4 {
                let actual = values[index][lane]
                let tolerance = max(Float(0.0005), abs(expected[lane]) * 0.00005)
                guard actual.isFinite, abs(actual - expected[lane]) <= tolerance else {
                    throw BenchmarkFailure.validationFailed("Résultat GPU incorrect au point \(index), composante \(lane).")
                }
                checksum += Double(actual)
            }
        }
        return checksum
    }

    private static func shaderSource() throws -> String {
        // In the standalone .app, prefer its sealed resources before accessing
        // Bundle.module (whose generated accessor can fatalError if misplaced).
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for root in roots {
            let bundleURL = root.appendingPathComponent(defaultBundleName, isDirectory: true)
            // SwiftPM's macOS bundle uses Contents/Resources; ask Bundle to
            // resolve that layout rather than assuming the flat bundle shape.
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: "Compute", withExtension: "metal", subdirectory: "Shaders"),
               FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
            let candidates = [bundleURL.appendingPathComponent("Contents/Resources/Shaders/Compute.metal"),
                              bundleURL.appendingPathComponent("Shaders/Compute.metal"),
                              root.appendingPathComponent("Shaders/Compute.metal")]
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "Compute", withExtension: "metal", subdirectory: "Shaders") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        #endif
        throw BenchmarkFailure.unavailable("Le fichier Compute.metal est absent des ressources de BenchLibre.")
    }
}
