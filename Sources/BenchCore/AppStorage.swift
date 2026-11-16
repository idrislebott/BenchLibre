import Foundation
import Darwin

/// Every production data URL is derived from the sandbox-aware Foundation directory.
/// The signed application bundle is read-only; no user-selected external-file entitlement is used.
public enum AppStorage {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BenchLibre", isDirectory: true)
    }
    public static var reports: URL { root.appendingPathComponent("Reports", isDirectory: true) }
    public static var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    public static var temporary: URL { root.appendingPathComponent("Temporary", isDirectory: true) }

    public static func validateExportName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128, !name.hasPrefix("."), name.hasSuffix(".json"),
              name.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
                  (48...57).contains(scalar.value) || [45, 46, 95].contains(scalar.value)
              }) else {
            throw BenchmarkFailure.invalidConfiguration(Localizer(.english).text("The JSON name must use ASCII letters, digits, hyphens, underscores or dots, with no path. The file stays inside the container."))
        }
    }

    @discardableResult static func prepare(_ component: String) throws -> URL {
        guard ["Reports", "Exports", "Temporary"].contains(component) else {
            throw BenchmarkFailure.invalidConfiguration(Localizer(.english).text("Storage directory is not allowed."))
        }
        let base = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let baseFD = try openDirectory(base)
        defer { _ = Darwin.close(baseFD) }
        let appFD = try childDirectory("BenchLibre", under: baseFD)
        defer { _ = Darwin.close(appFD) }
        let childFD = try childDirectory(component, under: appFD)
        defer { _ = Darwin.close(childFD) }
        return root.appendingPathComponent(component, isDirectory: true)
    }

    private static func childDirectory(_ name: String, under parent: Int32) throws -> Int32 {
        if Darwin.mkdirat(parent, name, mode_t(0o700)) != 0 && errno != EEXIST { throw failure(Localizer(.english).text("Directory creation was refused")) }
        let fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(Localizer(.english).text("Directory is missing or a symbolic link was refused")) }
        var metadata = stat()
        guard Darwin.fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), (metadata.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(fd)
            throw BenchmarkFailure.unavailable(Localizer(.english).text("The directory does not belong to the app's user account."))
        }
        return fd
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { throw failure(Localizer(.english).text("Unable to securely open the directory")) }
        return fd
    }

    static func readJSON(in directory: URL, name: String) throws -> Data {
        try validateExportName(name)
        let directoryFD = try openDirectory(directory)
        defer { _ = Darwin.close(directoryFD) }
        let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure(Localizer(.english).text("JSON file is inaccessible or a symbolic link was refused")) }
        defer { _ = Darwin.close(fd) }
        var metadata = stat()
        guard Darwin.fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= Int64(ReportLimits.maximumBytes) else {
            throw BenchmarkFailure.validationFailed(Localizer(.english).text("A report must be a bounded regular file with a single link."))
        }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw BenchmarkFailure.validationFailed(Localizer(.english).text("Empty JSON buffer.")) }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure(Localizer(.english).text("Incomplete JSON read")) }
                offset += count
            }
        }
        return data
    }

    static func writeJSON(_ data: Data, in directory: URL, name: String) throws -> URL {
        try validateExportName(name)
        guard !data.isEmpty, data.count <= ReportLimits.maximumBytes else {
            throw BenchmarkFailure.validationFailed(Localizer(.english).text("The report exceeds the allowed size."))
        }
        let directoryFD = try openDirectory(directory)
        defer { _ = Darwin.close(directoryFD) }
        var existing = stat()
        if Darwin.fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_nlink == 1 else {
                throw BenchmarkFailure.unavailable(Localizer(.english).text("The destination is a link or special file; write refused."))
            }
        } else if errno != ENOENT { throw failure(Localizer(.english).text("Unable to check the destination")) }
        let temporaryName = ".pending-\(UUID().uuidString)"
        let fd = Darwin.openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw failure(Localizer(.english).text("Unable to create the report")) }
        defer { _ = Darwin.close(fd); _ = Darwin.unlinkat(directoryFD, temporaryName, 0) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw BenchmarkFailure.validationFailed(Localizer(.english).text("Empty report.")) }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure(Localizer(.english).text("Incomplete JSON write")) }
                offset += count
            }
        }
        while Darwin.fsync(fd) != 0 { if errno != EINTR { throw failure(Localizer(.english).text("Unable to synchronize the report")) } }
        guard Darwin.renameat(directoryFD, temporaryName, directoryFD, name) == 0 else { throw failure(Localizer(.english).text("Unable to atomically publish the report")) }
        return directory.appendingPathComponent(name)
    }

    static func failure(_ message: String) -> BenchmarkFailure {
        .unavailable(Localizer(.english).text("{v0}: {v1}", values: ["v0": String(describing: message), "v1": String(describing: String(cString: strerror(errno)))]))
    }
}
