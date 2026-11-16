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
                               language: AppLanguage = .english, progress: @escaping EngineProgress) throws -> MetricResult {
        try runRead(duration: duration, cancellation: cancellation, settings: Settings(maximumTransferBytes: 64 * 1_024 * 1_024 * 1_024), language: language, progress: progress)
    }

    public static func runWrite(duration: Double, cancellation: CancellationToken,
                                language: AppLanguage = .english, progress: @escaping EngineProgress) throws -> MetricResult {
        try runWrite(duration: duration, cancellation: cancellation, settings: Settings(maximumTransferBytes: 512 * 1_024 * 1_024), language: language, progress: progress)
    }

    static func runRead(duration: Double, cancellation: CancellationToken, settings: Settings,
                        language: AppLanguage = .english, progress: @escaping EngineProgress) throws -> MetricResult {
        try run(.read, duration: duration, cancellation: cancellation, settings: settings, language: language, progress: progress)
    }

    static func runWrite(duration: Double, cancellation: CancellationToken, settings: Settings,
                         language: AppLanguage = .english, progress: @escaping EngineProgress) throws -> MetricResult {
        try run(.write, duration: duration, cancellation: cancellation, settings: settings, language: language, progress: progress)
    }

    private static func run(_ operation: Operation, duration: Double, cancellation: CancellationToken,
                            settings: Settings, language: AppLanguage = .english, progress: @escaping EngineProgress) throws -> MetricResult {
        guard duration.isFinite, duration >= 0.1, duration <= 120,
              settings.fileBytes >= 4_096, settings.fileBytes <= 64 * mib,
              settings.fileBytes.isMultiple(of: 4_096), settings.chunkBytes >= 4_096,
              settings.chunkBytes <= settings.fileBytes,
              settings.fileBytes.isMultiple(of: settings.chunkBytes),
              settings.maximumTransferBytes >= UInt64(settings.fileBytes),
              settings.maximumTransferBytes.isMultiple(of: UInt64(settings.fileBytes)),
              settings.maximumTransferBytes <= (operation == .write ? 512 * 1_024 * 1_024 : 64 * 1_024 * 1_024 * 1_024) else {
            throw BenchmarkFailure.invalidConfiguration(Localizer(language).text("Invalid file test configuration (duration: 0.1 to 120 s)."))
        }
        try cancellation.check()
        progress(EngineUpdate(fraction: 0, message: Localizer(language).text("Preparing a {v0} MiB temporary file…", values: ["v0": String(describing: settings.fileBytes / mib)])))

        guard settings.temporaryRoot.isFileURL else {
            throw BenchmarkFailure.invalidConfiguration(Localizer(language).text("The temporary directory must be local."))
        }
        if settings.temporaryRoot.standardizedFileURL == AppStorage.temporary.standardizedFileURL {
            _ = try AppStorage.prepare("Temporary")
        }
        let rootFD = try AppStorage.openDirectory(settings.temporaryRoot)
        defer { _ = Darwin.close(rootFD) }
        var filesystem = statfs()
        guard Darwin.fstatfs(rootFD, &filesystem) == 0 else { throw ioFailure(Localizer(language).text("Free space is unavailable")) }
        let available = Double(filesystem.f_bavail) * Double(filesystem.f_bsize)
        guard available.isFinite, available >= Double(settings.fileBytes + 64 * mib) else {
            throw BenchmarkFailure.unavailable(Localizer(language).text("Insufficient free space for the temporary file and its 64 MiB reserve."))
        }
        let workspaceName = "io-\(UUID().uuidString)"
        guard Darwin.mkdirat(rootFD, workspaceName, mode_t(0o700)) == 0 else {
            throw ioFailure(Localizer(language).text("Unable to create a private measurement directory"))
        }
        let workspaceFD = Darwin.openat(rootFD, workspaceName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard workspaceFD >= 0 else {
            _ = Darwin.unlinkat(rootFD, workspaceName, AT_REMOVEDIR)
            throw ioFailure(Localizer(language).text("Unable to open the private directory"))
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
        guard descriptor >= 0 else { throw ioFailure(Localizer(language).text("Unable to create the temporary file")) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_NOCACHE, 1) == 0 else {
            throw ioFailure(Localizer(language).text("F_NOCACHE is unavailable; no data-cached rate is substituted"))
        }

        var patternAllocation: UnsafeMutableRawPointer?
        guard posix_memalign(&patternAllocation, 4_096, settings.fileBytes) == 0, let pattern = patternAllocation else {
            throw BenchmarkFailure.unavailable(Localizer(language).text("Unable to allocate the reference buffer."))
        }
        defer { free(pattern) }
        var inputAllocation: UnsafeMutableRawPointer?
        guard posix_memalign(&inputAllocation, 4_096, settings.fileBytes) == 0, let input = inputAllocation else {
            throw BenchmarkFailure.unavailable(Localizer(language).text("Unable to allocate the read buffer."))
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
                throw BenchmarkFailure.validationFailed(Localizer(language).text("Invalid I/O interval."))
            }
            // Read validation is outside the measured I/O window. All bytes
            // must match; a bounded hash provides an observable report checksum.
            if !writing {
                try validate(input, against: pattern, bytes: settings.fileBytes)
                finalChecksum = checksum(input, bytes: settings.fileBytes)
                guard finalChecksum == expectedChecksum else {
                    throw BenchmarkFailure.validationFailed(Localizer(language).text("Incorrect file read checksum."))
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
                                      message: writing ? Localizer(language).text("Sequential write with fsync…") : Localizer(language).text("Sequential read with F_NOCACHE…")))
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
            throw BenchmarkFailure.validationFailed(Localizer(language).text("File measurement produced no verifiable result."))
        }
        let capped = totalBytes == settings.maximumTransferBytes && measuredSeconds < duration
        let capDescription = capped ? Localizer(language).text("Byte budget reached before the requested duration.") : Localizer(language).text("Requested measurement duration reached.")
        let operationDescription = writing ? Localizer(language).text("Sequential write; fsync included in every window.") : Localizer(language).text("Sequential read; every byte checked after each window.")
        let details = Localizer(language).text("File-IO-v2. {v0} Temporary file: {v1} bytes, {v2}-byte blocks; {v3} bytes transferred, cap {v4}. {v5} F_NOCACHE enabled on the descriptor: data caching disabled, without a guarantee of bypassing device or controller caches. Sum of monotonic seek + I/O{v6} windows; allocation, initial creation, first touch and validation excluded. File removed afterward.", values: ["v0": String(describing: operationDescription), "v1": String(describing: settings.fileBytes), "v2": String(describing: settings.chunkBytes), "v3": String(describing: totalBytes), "v4": String(describing: settings.maximumTransferBytes), "v5": String(describing: capDescription), "v6": String(describing: writing ? Localizer(language).text(" + fsync") : "")])
        guard cleanup() else {
            throw BenchmarkFailure.unavailable(Localizer(language).text("The measurement finished but private-directory cleanup failed."))
        }
        progress(EngineUpdate(fraction: 1, value: rate, message: writing ? Localizer(language).text("File write validated.") : Localizer(language).text("File read validated.")))
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
                throw ioFailure(writing ? Localizer(.english).text("Unable to write the temporary file") : Localizer(.english).text("Unable to read the temporary file"))
            }
            guard count > 0 else {
                throw BenchmarkFailure.validationFailed(writing ? Localizer(.english).text("Write stopped without progress.") : Localizer(.english).text("Temporary file ended before the expected data."))
            }
            transferred += count
            update?(transferred)
        }
    }

    private static func seekStart(_ descriptor: Int32) throws {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else { throw ioFailure(Localizer(.english).text("Unable to seek to the start of the temporary file")) }
    }

    private static func synchronize(_ descriptor: Int32, cancellation: CancellationToken) throws {
        while true {
            try cancellation.check()
            if Darwin.fsync(descriptor) == 0 { return }
            if errno != EINTR { throw ioFailure(Localizer(.english).text("Unable to synchronize the temporary file")) }
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
            throw BenchmarkFailure.validationFailed(Localizer(.english).text("Temporary file contents differ from the reference."))
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
        return .unavailable(Localizer(.english).text("{v0}: {v1}", values: ["v0": String(describing: message), "v1": String(describing: description)]))
    }
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1e9 }
}
