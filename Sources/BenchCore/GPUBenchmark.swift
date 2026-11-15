// SPDX-License-Identifier: MIT
import Foundation
import Metal
import Darwin
import CryptoKit

/// Fixed FP32 work with bounded resources, observable outputs and GPU timestamps.
/// This synchronous API belongs on a worker task. It does not certify peak
/// hardware occupancy or predict a game's frame rate.
public enum GPUBenchmark {
    public static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }
    public static var deviceName: String? { MTLCreateSystemDefaultDevice()?.name }
    private static let threadCount = 32_768
    private static let iterations: UInt32 = 512
    private static let maximumBatch = 64
    private static let flopsPerThreadIteration: UInt64 = 32
    private static let defaultBundleName = "BenchLibre_BenchCore.bundle"
    static let expectedShaderSHA256 = "a7dfa6d8eb168939869b17df232fe4b3733efdadb87a04d1dbf1381023ac5041"
    private final class ResourceOwner {}

    public static func run(duration: Double, cancellation: CancellationToken, progress: @escaping EngineProgress) throws -> MetricResult {
        try autoreleasepool { try measure(duration: duration, cancellation: cancellation, progress: progress) }
    }

    private static func measure(duration: Double, cancellation: CancellationToken, progress: @escaping EngineProgress) throws -> MetricResult {
        guard duration.isFinite, duration >= 0.1, duration <= 120 else {
            throw BenchmarkFailure.invalidConfiguration("Durée GPU invalide (0,1 à 120 secondes).")
        }
        try cancellation.check()
        progress(EngineUpdate(fraction: 0, message: "Préparation du pipeline Metal…"))
        try cancellation.check()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw BenchmarkFailure.unavailable("Aucun GPU Metal utilisable sur ce Mac.")
        }
        let options = MTLCompileOptions()
        // Dependent, explicit FMAs retain strict rounding semantics. No unsafe
        // fast-math/reassociation or algebraic closed-form loop replacement.
        if #available(macOS 15, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        } else { options.fastMathEnabled = false }
        let library = try device.makeLibrary(source: try shaderSource(), options: options)
        guard let function = library.makeFunction(name: "fp32_fma_v2") else {
            throw BenchmarkFailure.unavailable("Le noyau Metal vérifié est introuvable.")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        try cancellation.check()
        guard pipeline.threadExecutionWidth > 0, pipeline.maxTotalThreadsPerThreadgroup > 0 else {
            throw BenchmarkFailure.unavailable("Les limites du pipeline Metal sont invalides.")
        }
        let seedBytes = threadCount * MemoryLayout<SIMD4<Float>>.stride
        let outputElements = threadCount * maximumBatch
        let outputBytes = outputElements * MemoryLayout<SIMD4<Float>>.stride
        guard seedBytes <= device.maxBufferLength, outputBytes <= device.maxBufferLength,
              let seeds = device.makeBuffer(length: seedBytes, options: .storageModeShared),
              let output = device.makeBuffer(length: outputBytes, options: .storageModeShared) else {
            throw BenchmarkFailure.unavailable("Impossible d’allouer les tampons GPU bornés (32 Mio de sorties maximum).")
        }
        seeds.label = "BenchLibre FP32 input"
        output.label = "BenchLibre distinct FP32 dispatch outputs"
        let source = seeds.contents().bindMemory(to: SIMD4<Float>.self, capacity: threadCount)
        let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: outputElements)
        for index in 0..<threadCount { source.advanced(by: index).initialize(to: seed(index)) }
        let poison = SIMD4<Float>(repeating: .nan)
        values.initialize(repeating: poison, count: outputElements)
        // Raw host views do not retain their MTLBuffer owners. Explicitly end
        // their trivial typed lifetimes before releasing those owners.
        defer {
            source.deinitialize(count: threadCount)
            values.deinitialize(count: outputElements)
            withExtendedLifetime((seeds, output)) {}
        }
        let readView = UnsafeBufferPointer(start: values, count: outputElements)
        let groupWidth = min(256, pipeline.maxTotalThreadsPerThreadgroup,
                             min(pipeline.threadExecutionWidth, 64) * 4)

        func dispatch(_ loopCount: UInt32, repetitions: Int) throws -> Double {
            // Command buffers/encoders are bounded to one autorelease scope per
            // batch even on Swift worker threads without an event-loop pool.
            try autoreleasepool {
                try cancellation.check()
                guard (1...maximumBatch).contains(repetitions),
                      let commands = queue.makeCommandBuffer(),
                      let encoder = commands.makeComputeCommandEncoder() else {
                    throw BenchmarkFailure.unavailable("Impossible de créer une commande Metal bornée.")
                }
                commands.label = "BenchLibre FP32-FMA-v2"
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(seeds, offset: 0, index: 0)
                encoder.setBuffer(output, offset: 0, index: 1)
                var count = loopCount
                var elements = UInt32(threadCount)
                var capacity = UInt32(outputElements)
                encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
                encoder.setBytes(&elements, length: MemoryLayout<UInt32>.size, index: 3)
                encoder.setBytes(&capacity, length: MemoryLayout<UInt32>.size, index: 5)
                for slice in 0..<repetitions {
                    var offset = UInt32(slice * threadCount)
                    encoder.setBytes(&offset, length: MemoryLayout<UInt32>.size, index: 4)
                    encoder.dispatchThreads(MTLSize(width: threadCount, height: 1, depth: 1),
                                           threadsPerThreadgroup: MTLSize(width: groupWidth, height: 1, depth: 1))
                }
                encoder.endEncoding()
                let hostStart = now()
                commands.commit()
                commands.waitUntilCompleted()
                let hostSeconds = seconds(hostStart, now())
                if let error = commands.error {
                    throw BenchmarkFailure.unavailable("Erreur du GPU : \(error.localizedDescription)")
                }
                guard commands.status == .completed else {
                    throw BenchmarkFailure.unavailable("La commande Metal ne s’est pas terminée.")
                }
                let gpuSeconds = try checkedGPUSeconds(start: commands.gpuStartTime,
                                                       end: commands.gpuEndTime, hostSeconds: hostSeconds)
                try cancellation.check()
                return gpuSeconds
            }
        }

        _ = try dispatch(16, repetitions: 1)
        _ = try validate(values: readView, iterations: 16, slices: 1)
        progress(EngineUpdate(fraction: 0, message: "Échauffement et validation du GPU…"))
        let calibration = try dispatch(iterations, repetitions: 1)
        let batch = Int(max(1, min(Double(maximumBatch), (0.015 / calibration).rounded(.down))))
        // Poison active output slices again after calibration. A missed GPU
        // write cannot be hidden by a valid result left by the warm-up.
        values.update(repeating: poison, count: threadCount * batch)
        let flopsPerDispatch = Double(UInt64(threadCount) * UInt64(iterations) * flopsPerThreadIteration)
        let flopsPerBatch = flopsPerDispatch * Double(batch)
        let start = now()
        var sampleStart = start
        var totalGPUSeconds = 0.0
        var totalFLOPs = 0.0
        var sampleGPUSeconds = 0.0
        var sampleFLOPs = 0.0
        var observedChecksum = 0.0
        var samples: [Double] = []
        var batches = 0
        while seconds(start, now()) < duration {
            let gpuSeconds = try dispatch(iterations, repetitions: batch)
            // Every dispatch owns a separate output slice. Consume a returned
            // SIMD value from every slice after each completed batch; this is
            // outside the GPU timestamp denominator and no results are discarded.
            let probe = batches % threadCount
            for slice in 0..<batch {
                let observed = readView[slice * threadCount + probe]
                for lane in 0..<4 {
                    guard observed[lane].isFinite else {
                        throw BenchmarkFailure.validationFailed("Une sortie GPU n’a pas été écrite correctement.")
                    }
                    observedChecksum += Double(observed[lane])
                }
            }
            totalGPUSeconds += gpuSeconds
            totalFLOPs += flopsPerBatch
            sampleGPUSeconds += gpuSeconds
            sampleFLOPs += flopsPerBatch
            batches += 1
            let elapsed = seconds(start, now())
            if seconds(sampleStart, now()) >= 0.2 {
                let rate = sampleFLOPs / sampleGPUSeconds / 1_000_000_000
                samples.append(rate)
                progress(EngineUpdate(fraction: min(0.999, elapsed / duration), value: rate,
                                     message: "Calcul FP32 sur \(device.name)"))
                sampleStart = now(); sampleGPUSeconds = 0; sampleFLOPs = 0
            }
        }
        let elapsed = seconds(start, now())
        if sampleGPUSeconds > 0 { samples.append(sampleFLOPs / sampleGPUSeconds / 1_000_000_000) }
        try cancellation.check()
        let checksum = observedChecksum + (try validate(values: readView, iterations: iterations, slices: batch))
        guard totalGPUSeconds > 0, totalFLOPs > 0, batches > 0, checksum.isFinite else {
            throw BenchmarkFailure.validationFailed("Le test GPU n’a produit aucune mesure valide.")
        }
        let value = totalFLOPs / totalGPUSeconds / 1_000_000_000
        guard value.isFinite, value > 0, samples.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BenchmarkFailure.validationFailed("Le débit GPU mesuré n’est pas valide.")
        }
        progress(EngineUpdate(fraction: 1, value: value, message: "Sorties GPU consommées et contrôlées"))
        return MetricResult(kind: .gpu, value: value, unit: "GFLOP/s", elapsedSeconds: elapsed,
                            samples: samples, checksum: checksum,
                            details: "FP32-FMA-v2 : 32 768 threads × 512 itérations × 16 fma (2 FLOP/fma), soit 536 870 912 FLOP par dispatch. \(batch) dispatch(s) par commande, \(batches) commandes, sorties distinctes par dispatch (32 Mio maximum). Horodatages GPU vérifiés et cumulés ; consommation CPU d’une sortie par dispatch après chaque commande, contrôle fini exhaustif des sorties finales et référence scalaire sur 7 positions × 4 composantes par tranche, hors dénominateur GPU. Échauffement, calibration et validation exclus du débit. Initialisation, contrôle de bornes et réduction font partie du noyau chronométré, sans être ajoutés au compte de FLOP. \(device.name). Source SHA-256 : \(expectedShaderSHA256). Ce débit ne certifie pas une occupation matérielle de 100 %.",
                            validated: true, workAmount: totalFLOPs, workUnit: "FLOP",
                            timingSeconds: totalGPUSeconds, timingSource: "metal-gpu-timestamps")
    }

    static func checkedGPUSeconds(start: Double, end: Double, hostSeconds: Double) throws -> Double {
        let gpuSeconds = end - start
        // Public Metal timestamps share system mach time. Allow a small clock
        // calibration tolerance, but reject impossible command-buffer spans.
        guard start.isFinite, end.isFinite, start > 0, end > start,
              gpuSeconds.isFinite, hostSeconds.isFinite, hostSeconds > 0,
              gpuSeconds <= hostSeconds + max(0.005, hostSeconds * 0.1) else {
            throw BenchmarkFailure.unavailable("Horodatage GPU absent ou incohérent ; aucun débit estimé n’est substitué.")
        }
        return gpuSeconds
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1_000_000_000 }

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

    private static func validate(values: UnsafeBufferPointer<SIMD4<Float>>, iterations: UInt32, slices: Int) throws -> Double {
        guard (1...maximumBatch).contains(slices), values.count >= slices * threadCount else {
            throw BenchmarkFailure.validationFailed("Bornes des sorties GPU invalides.")
        }
        var checksum = 0.0
        for value in values.prefix(slices * threadCount) {
            for lane in 0..<4 {
                guard value[lane].isFinite else {
                    throw BenchmarkFailure.validationFailed("Une sortie GPU est non finie ou n’a pas été écrite.")
                }
                checksum += Double(value[lane])
            }
        }
        let probes = [0, 1, 17, threadCount / 3, threadCount / 2, threadCount - 2, threadCount - 1]
        let expectedValues = probes.map { reference(seed($0), iterations: iterations) }
        for slice in 0..<slices {
            for (position, index) in probes.enumerated() {
                let expected = expectedValues[position]
                for lane in 0..<4 {
                    let actual = values[slice * threadCount + index][lane]
                    let tolerance = max(Float(0.0005), abs(expected[lane]) * 0.00005)
                    guard abs(actual - expected[lane]) <= tolerance else {
                        throw BenchmarkFailure.validationFailed("Résultat GPU incorrect dans la tranche \(slice), point \(index), composante \(lane).")
                    }
                }
            }
        }
        return checksum
    }

    private static func shaderSource() throws -> String {
        // The app only reads its exact embedded, signed resource location.
        // Test hosts use the bundle containing this module's marker class.
        // Never consult the working directory, environment, or Bundle.module's
        // generated development-path fallbacks at application runtime.
        let owner = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            ? Bundle.main : Bundle(for: ResourceOwner.self)
        guard let resources = owner.resourceURL else {
            throw BenchmarkFailure.unavailable("Les ressources propres au module sont introuvables.")
        }
        let shader = resources.appendingPathComponent(defaultBundleName, isDirectory: true)
            .appendingPathComponent("Contents/Resources/Shaders/Compute.metal")
        return try readVerifiedShader(at: shader, containedIn: owner.bundleURL)
    }

    /// Bounded, no-follow reads anchored to the own-bundle descriptor. Internal
    /// for resource-boundary tests; production supplies only the fixed URL above.
    static func readVerifiedShader(at url: URL, containedIn owner: URL) throws -> String {
        guard owner.isFileURL, url.isFileURL else {
            throw BenchmarkFailure.unavailable("Les ressources Metal doivent être des fichiers du bundle propre.")
        }
        let root = owner.standardizedFileURL
        let target = url.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard root.isFileURL, target.isFileURL, !root.path.utf8.contains(0),
              !target.path.utf8.contains(0), target.path.hasPrefix(prefix) else {
            throw BenchmarkFailure.unavailable("La source Metal doit appartenir au bundle de l’application.")
        }
        let components = String(target.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw BenchmarkFailure.unavailable("Chemin de ressource Metal invalide.")
        }
        var directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw BenchmarkFailure.unavailable("Le bundle de ressources Metal est inaccessible.") }
        defer { _ = Darwin.close(directory) }
        for component in components.dropLast() {
            let next = component.withCString { Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
            guard next >= 0 else { throw BenchmarkFailure.unavailable("Une ressource Metal est inaccessible ou contient un lien symbolique.") }
            _ = Darwin.close(directory)
            directory = next
        }
        let descriptor = components[components.count - 1].withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw BenchmarkFailure.unavailable("La source Metal embarquée est inaccessible.") }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= 16_384 else {
            throw BenchmarkFailure.unavailable("La source Metal doit être un fichier ordinaire de taille bornée.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw BenchmarkFailure.unavailable("Source Metal vide.") }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw BenchmarkFailure.unavailable("Lecture incomplète de la source Metal.") }
                offset += count
            }
        }
        var extra: UInt8 = 0
        var trailing: Int
        repeat { trailing = Darwin.read(descriptor, &extra, 1) } while trailing < 0 && errno == EINTR
        guard trailing == 0 else { throw BenchmarkFailure.unavailable("La source Metal a changé pendant sa lecture.") }
        let data = Data(bytes)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedShaderSHA256, let source = String(data: data, encoding: .utf8) else {
            throw BenchmarkFailure.unavailable("L’empreinte de la source Metal ne correspond pas à cette version du benchmark.")
        }
        return source
    }
}
