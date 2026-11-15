// SPDX-License-Identifier: MIT
import Foundation
import Darwin

/// Sequential file I/O, rather than a measurement of the physical SSD bus.
/// Each invocation owns and removes its temporary file. F_NOCACHE disables
/// data caching for its descriptor; filesystem and device/controller effects
/// still belong to the result. No physical-media persistence claim is made.
public enum DiskBenchmarks {
    private static let mib = 1_024 * 1_024

    struct Settings {
        var fileBytes: Int = 64 * 1_024 * 1_024
        var chunkBytes: Int = 1_024 * 1_024
        var maximumTransferBytes: UInt64
        var temporaryRoot: URL = AppStorage.temporary

        init(fileBytes: Int = 64 * 1_024 * 1_024,
             chunkBytes: Int = 1_024 * 1_024,
             maximumTransferBytes: UInt64,
             temporaryRoot: URL = AppStorage.temporary) {
            self.fileBytes = fileBytes; self.chunkBytes = chunkBytes
            self.maximumTransferBytes = maximumTransferBytes; self.temporaryRoot = temporaryRoot
        }
    }

    private enum Operation { case read, write }

    public static func runRead(duration: Double, cancellation: CancellationToken,
                               progress: @escaping EngineProgress) throws -> MetricResult {
        try runRead(duration: duration, cancellation: cancellation,
                    settings: Settings(maximumTransferBytes: 64 * 1_024 * 1_024 * 1_024), progress: progress)
    }

    public static func runWrite(duration: Double, cancellation: CancellationToken,
                                progress: @escaping EngineProgress) throws -> MetricResult {
        try runWrite(duration: duration, cancellation: cancellation,
                     settings: Settings(maximumTransferBytes: 512 * 1_024 * 1_024), progress: progress)
    }

    static func runRead(duration: Double, cancellation: CancellationToken, settings: Settings,
                        progress: @escaping EngineProgress) throws -> MetricResult {
        try run(.read, duration: duration, cancellation: cancellation, settings: settings, progress: progress)
    }

    static func runWrite(duration: Double, cancellation: CancellationToken, settings: Settings,
                         progress: @escaping EngineProgress) throws -> MetricResult {
        try run(.write, duration: duration, cancellation: cancellation, settings: settings, progress: progress)
    }

    private static func run(_ operation: Operation, duration: Double, cancellation: CancellationToken,
                            settings: Settings, progress: @escaping EngineProgress) throws -> MetricResult {
        guard duration.isFinite, duration >= 0.1, duration <= 120,
              settings.fileBytes >= 4_096, settings.fileBytes <= 64 * mib,
              settings.fileBytes.isMultiple(of: 4_096), settings.chunkBytes >= 4_096,
              settings.chunkBytes <= settings.fileBytes,
              settings.fileBytes.isMultiple(of: settings.chunkBytes),
              settings.maximumTransferBytes >= UInt64(settings.fileBytes),
              settings.maximumTransferBytes.isMultiple(of: UInt64(settings.fileBytes)),
              settings.maximumTransferBytes <= (operation == .write ? 512 * 1_024 * 1_024 : 64 * 1_024 * 1_024 * 1_024) else {
            throw BenchmarkFailure.invalidConfiguration("Configuration du test fichier invalide (durée : 0,1 à 120 s).")
        }
        try cancellation.check()
        progress(EngineUpdate(fraction: 0, message: "Préparation du fichier temporaire de \(settings.fileBytes / mib) Mio…"))

        guard settings.temporaryRoot.isFileURL else {
            throw BenchmarkFailure.invalidConfiguration("Le dossier temporaire doit être local.")
        }
        if settings.temporaryRoot.standardizedFileURL == AppStorage.temporary.standardizedFileURL {
            _ = try AppStorage.prepare("Temporary")
        }
        let rootFD = try AppStorage.openDirectory(settings.temporaryRoot)
        defer { _ = Darwin.close(rootFD) }
        var filesystem = statfs()
        guard Darwin.fstatfs(rootFD, &filesystem) == 0 else { throw ioFailure("Espace libre inaccessible") }
        let available = Double(filesystem.f_bavail) * Double(filesystem.f_bsize)
        guard available.isFinite, available >= Double(settings.fileBytes + 64 * mib) else {
            throw BenchmarkFailure.unavailable("Espace libre insuffisant pour le fichier temporaire et sa réserve de 64 Mio.")
        }
        let workspaceName = "io-\(UUID().uuidString)"
        guard Darwin.mkdirat(rootFD, workspaceName, mode_t(0o700)) == 0 else {
            throw ioFailure("Création du dossier privé de mesure impossible")
        }
        let workspaceFD = Darwin.openat(rootFD, workspaceName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workspaceFD >= 0 else {
            _ = Darwin.unlinkat(rootFD, workspaceName, AT_REMOVEDIR)
            throw ioFailure("Ouverture du dossier privé impossible")
        }
        defer { _ = Darwin.close(workspaceFD) }
        var removed = false
        func cleanup() -> Bool {
            let fileRemoved = Darwin.unlinkat(workspaceFD, "payload.bin", 0) == 0 || errno == ENOENT
            let directoryRemoved = Darwin.unlinkat(rootFD, workspaceName, AT_REMOVEDIR) == 0 || errno == ENOENT
            removed = fileRemoved && directoryRemoved
            return removed
        }
        defer { if !removed { _ = cleanup() } }
        try cancellation.check()
        let descriptor = Darwin.openat(workspaceFD, "payload.bin", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ioFailure("Création du fichier temporaire impossible") }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_NOCACHE, 1) == 0 else {
            throw ioFailure("F_NOCACHE indisponible ; aucun débit avec cache de données n’est substitué")
        }

        var patternAllocation: UnsafeMutableRawPointer?
        guard posix_memalign(&patternAllocation, 4_096, settings.fileBytes) == 0, let pattern = patternAllocation else {
            throw BenchmarkFailure.unavailable("Allocation du tampon de référence impossible.")
        }
        defer { free(pattern) }
        var inputAllocation: UnsafeMutableRawPointer?
        guard posix_memalign(&inputAllocation, 4_096, settings.fileBytes) == 0, let input = inputAllocation else {
            throw BenchmarkFailure.unavailable("Allocation du tampon de lecture impossible.")
        }
        defer { free(input) }
        pattern.bindMemory(to: UInt64.self, capacity: settings.fileBytes / 8).initialize(repeating: 0, count: settings.fileBytes / 8)
        input.bindMemory(to: UInt64.self, capacity: settings.fileBytes / 8).initialize(repeating: 0, count: settings.fileBytes / 8)
        try fillPattern(pattern, bytes: settings.fileBytes, cancellation: cancellation)

        // Allocate and fill the file before opening any measured interval.
        try seekStart(descriptor)
        try transfer(descriptor, buffer: pattern, settings: settings, writing: true, cancellation: cancellation)
        try synchronize(descriptor, cancellation: cancellation)
        try seekStart(descriptor)
        try transfer(descriptor, buffer: input, settings: settings, writing: false, cancellation: cancellation)
        try validate(input, against: pattern, bytes: settings.fileBytes)
        let expectedChecksum = checksum(pattern, bytes: settings.fileBytes)
        try cancellation.check()

        var totalBytes: UInt64 = 0
        var measuredSeconds = 0.0
        var samples: [Double] = []
        var sampleBytes: UInt64 = 0
        var sampleSeconds = 0.0
        var finalChecksum = expectedChecksum
        let writing = operation == .write
        while measuredSeconds < duration && totalBytes < settings.maximumTransferBytes {
            try cancellation.check()
            let before = now()
            try seekStart(descriptor)
            try transfer(descriptor, buffer: writing ? pattern : input, settings: settings,
                         writing: writing, cancellation: cancellation)
            if writing { try synchronize(descriptor, cancellation: cancellation) }
            let interval = seconds(before, now())
            guard interval.isFinite, interval > 0 else {
                throw BenchmarkFailure.validationFailed("Intervalle d’E/S invalide.")
            }
            // Read validation is outside the measured I/O window. All bytes
            // must match; a bounded hash provides an observable report checksum.
            if !writing {
                try validate(input, against: pattern, bytes: settings.fileBytes)
                finalChecksum = checksum(input, bytes: settings.fileBytes)
                guard finalChecksum == expectedChecksum else {
                    throw BenchmarkFailure.validationFailed("Checksum de lecture fichier incorrect.")
                }
            }
            totalBytes += UInt64(settings.fileBytes)
            measuredSeconds += interval
            sampleBytes += UInt64(settings.fileBytes)
            sampleSeconds += interval
            let finishedSample = sampleSeconds >= 0.1 || totalBytes == settings.maximumTransferBytes
            if finishedSample {
                samples.append(Double(sampleBytes) / sampleSeconds / 1e9)
                sampleBytes = 0; sampleSeconds = 0
            }
            if finishedSample {
                progress(EngineUpdate(fraction: min(0.999, max(measuredSeconds / duration,
                                                               Double(totalBytes) / Double(settings.maximumTransferBytes))),
                                      value: Double(totalBytes) / measuredSeconds / 1e9,
                                      message: writing ? "Écriture séquentielle avec fsync…" : "Lecture séquentielle avec F_NOCACHE…"))
            }
        }
        if sampleBytes > 0 { samples.append(Double(sampleBytes) / sampleSeconds / 1e9) }
        try cancellation.check()
        if writing {
            // Verify the final written file after the final timed fsync.
            try seekStart(descriptor)
            try transfer(descriptor, buffer: input, settings: settings, writing: false, cancellation: cancellation)
            try validate(input, against: pattern, bytes: settings.fileBytes)
            finalChecksum = checksum(input, bytes: settings.fileBytes)
        }
        try cancellation.check()
        let rate = Double(totalBytes) / measuredSeconds / 1e9
        guard totalBytes > 0, measuredSeconds > 0, rate.isFinite, rate > 0,
              finalChecksum == expectedChecksum, !samples.isEmpty,
              samples.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BenchmarkFailure.validationFailed("La mesure fichier n’a pas produit de résultat vérifiable.")
        }
        let capped = totalBytes == settings.maximumTransferBytes && measuredSeconds < duration
        let capDescription = capped ? "Budget d’octets atteint avant la durée demandée." : "Fenêtre de durée demandée atteinte."
        let operationDescription = writing ? "Écriture séquentielle ; fsync inclus dans chaque fenêtre." : "Lecture séquentielle ; tous les octets vérifiés après chaque fenêtre."
        let details = "File-IO-v2. \(operationDescription) Fichier temporaire : \(settings.fileBytes) octets, blocs de \(settings.chunkBytes) octets ; \(totalBytes) octets transférés, plafond \(settings.maximumTransferBytes). \(capDescription) F_NOCACHE activé pour le descripteur : cache de données désactivé, sans garantie de contournement des caches du contrôleur ou du périphérique. Somme des fenêtres monotones seek + E/S\(writing ? " + fsync" : "") ; allocation, création initiale, premier accès et validation exclus. Fichier supprimé à la fin."
        guard cleanup() else {
            throw BenchmarkFailure.unavailable("La mesure est terminée mais le nettoyage du dossier privé a échoué.")
        }
        progress(EngineUpdate(fraction: 1, value: rate, message: writing ? "Écriture fichier validée." : "Lecture fichier validée."))
        return MetricResult(kind: writing ? .diskWrite : .diskRead, value: rate, unit: "Go/s",
                            elapsedSeconds: measuredSeconds, samples: samples, checksum: finalChecksum,
                            details: details, validated: true, workAmount: Double(totalBytes),
                            workUnit: "logical-bytes", timingSeconds: measuredSeconds, timingSource: "monotonic-wall")
    }

    private static func transfer(_ descriptor: Int32, buffer: UnsafeMutableRawPointer, settings: Settings,
                                 writing: Bool, cancellation: CancellationToken,
                                 update: ((Int) -> Void)? = nil) throws {
        var transferred = 0
        while transferred < settings.fileBytes {
            try cancellation.check()
            let amount = min(settings.chunkBytes, settings.fileBytes - transferred)
            let pointer = buffer.advanced(by: transferred)
            let count = writing ? Darwin.write(descriptor, pointer, amount) : Darwin.read(descriptor, pointer, amount)
            if count < 0 {
                if errno == EINTR { continue }
                throw ioFailure(writing ? "Écriture du fichier temporaire impossible" : "Lecture du fichier temporaire impossible")
            }
            guard count > 0 else {
                throw BenchmarkFailure.validationFailed(writing ? "Écriture interrompue sans progression." : "Fin du fichier temporaire avant les données attendues.")
            }
            transferred += count
            update?(transferred)
        }
    }

    private static func seekStart(_ descriptor: Int32) throws {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else { throw ioFailure("Positionnement du fichier temporaire impossible") }
    }

    private static func synchronize(_ descriptor: Int32, cancellation: CancellationToken) throws {
        while true {
            try cancellation.check()
            if Darwin.fsync(descriptor) == 0 { return }
            if errno != EINTR { throw ioFailure("Synchronisation du fichier temporaire impossible") }
        }
    }

    private static func fillPattern(_ pointer: UnsafeMutableRawPointer, bytes: Int, cancellation: CancellationToken) throws {
        let words = pointer.assumingMemoryBound(to: UInt64.self)
        var state: UInt64 = 0x6a09e667f3bcc909
        for index in 0..<(bytes / 8) {
            if index.isMultiple(of: 65_536) { try cancellation.check() }
            // SplitMix64: deterministic, nonconstant data prepared off-clock.
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            words[index] = (value ^ (value >> 31)).littleEndian
        }
    }

    private static func validate(_ actual: UnsafeMutableRawPointer, against reference: UnsafeMutableRawPointer,
                                 bytes: Int) throws {
        guard memcmp(actual, reference, bytes) == 0 else {
            throw BenchmarkFailure.validationFailed("Le contenu du fichier temporaire diffère de la référence.")
        }
    }

    private static func checksum(_ pointer: UnsafeMutableRawPointer, bytes: Int) -> Double {
        let words = pointer.assumingMemoryBound(to: UInt64.self)
        var hash: UInt64 = 0xcbf29ce484222325
        for index in stride(from: 0, to: bytes / 8, by: 512) {
            hash = (hash ^ UInt64(littleEndian: words[index])) &* 0x100000001b3
        }
        hash = (hash ^ UInt64(littleEndian: words[bytes / 8 - 1])) &* 0x100000001b3
        return Double(hash & 0x001f_ffff_ffff_ffff)
    }

    private static func ioFailure(_ message: String) -> BenchmarkFailure {
        let description = String(cString: strerror(errno))
        return .unavailable("\(message) : \(description)")
    }
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1e9 }
}
