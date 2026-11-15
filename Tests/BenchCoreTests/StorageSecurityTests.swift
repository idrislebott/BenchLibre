import XCTest
import Darwin
@testable import BenchCore

final class StorageSecurityTests: XCTestCase {
    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchLibre-security-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }

    func testExportNamesRejectPathsAndControlCharacters() {
        for name in ["", "../out.json", "/tmp/out.json", ".hidden.json", "sub/out.json", "bad\\out.json",
                     "bad\u{0}.json", "é.json", "out.JSON", String(repeating: "a", count: 129) + ".json"] {
            XCTAssertThrowsError(try AppStorage.validateExportName(name), name)
        }
        for name in ["BenchLibre-1.json", "x_y.z.json"] {
            XCTAssertNoThrow(try AppStorage.validateExportName(name))
        }
    }

    func testAtomicPrivateFileRoundTripAndOverwrite() throws {
        try fixture { root in
            let target = try AppStorage.writeJSON(Data("{\"a\":1}".utf8), in: root, name: "report.json")
            XCTAssertEqual(try AppStorage.readJSON(in: root, name: "report.json"), Data("{\"a\":1}".utf8))
            _ = try AppStorage.writeJSON(Data("{\"a\":2}".utf8), in: root, name: "report.json")
            XCTAssertEqual(try AppStorage.readJSON(in: root, name: "report.json"), Data("{\"a\":2}".utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["report.json"])
        }
    }

    func testSymbolicLinkCannotReadOrOverwriteItsTarget() throws {
        try fixture { root in
            let sentinel = root.appendingPathComponent("sentinel")
            let link = root.appendingPathComponent("link.json")
            let original = Data("DO NOT MODIFY".utf8)
            try original.write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
            XCTAssertThrowsError(try AppStorage.readJSON(in: root, name: "link.json"))
            XCTAssertThrowsError(try AppStorage.writeJSON(Data("{}".utf8), in: root, name: "link.json"))
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
        }
    }

    func testHardLinkCannotReadOrOverwriteItsTarget() throws {
        try fixture { root in
            let sentinel = root.appendingPathComponent("sentinel")
            let link = root.appendingPathComponent("link.json")
            let original = Data("DO NOT MODIFY".utf8)
            try original.write(to: sentinel)
            XCTAssertEqual(Darwin.link(sentinel.path, link.path), 0)
            XCTAssertThrowsError(try AppStorage.readJSON(in: root, name: "link.json"))
            XCTAssertThrowsError(try AppStorage.writeJSON(Data("{}".utf8), in: root, name: "link.json"))
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
        }
    }

    func testFIFOIsRejectedWithoutBlocking() throws {
        try fixture { root in
            let fifo = root.appendingPathComponent("pipe.json")
            XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(0o600)), 0)
            XCTAssertThrowsError(try AppStorage.readJSON(in: root, name: "pipe.json"))
            XCTAssertThrowsError(try AppStorage.writeJSON(Data("{}".utf8), in: root, name: "pipe.json"))
        }
    }

    func testDirectorySymlinkIsRejected() throws {
        try fixture { root in
            let actual = root.appendingPathComponent("actual", isDirectory: true)
            let linked = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
            XCTAssertThrowsError(try AppStorage.openDirectory(linked))
        }
    }

    func testOversizedAndEmptyFilesAreRejected() throws {
        try fixture { root in
            for (name, data) in [("empty.json", Data()), ("large.json", Data(repeating: 32, count: ReportLimits.maximumBytes + 1))] {
                XCTAssertThrowsError(try AppStorage.writeJSON(data, in: root, name: name))
                try data.write(to: root.appendingPathComponent(name))
                XCTAssertThrowsError(try AppStorage.readJSON(in: root, name: name))
            }
        }
    }
}
