import XCTest
@testable import BenchCore

final class LocalizationTests: XCTestCase {
    private let tables: [LocalizationTable] = [.core, .interface, .app]

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BenchCore/Localization", isDirectory: true)
    }

    private func catalog(_ language: AppLanguage, table: LocalizationTable) throws -> [String: String] {
        let url = sourceDirectory.appendingPathComponent(language.rawValue + ".lproj", isDirectory: true)
            .appendingPathComponent(table.rawValue + ".strings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private func translatedPair(in table: LocalizationTable) throws -> (String, String, String) {
        let english = try catalog(.english, table: table)
        let french = try catalog(.french, table: table)
        let key = try XCTUnwrap(english.keys.sorted().first { key in
            guard let en = english[key], let fr = french[key] else { return false }
            return en != fr && !en.contains("{") && !fr.contains("{")
        }, "Table needs a translated entry to test its packaged resources")
        return (key, try XCTUnwrap(english[key]), try XCTUnwrap(french[key]))
    }

    func testDefaultLanguageUsesEnglishPackagedMessages() throws {
        XCTAssertEqual(AppLanguage.resolved(nil), .english)
        XCTAssertEqual(AppLanguage.resolved("unknown"), .english)
        XCTAssertEqual(AppLanguage.resolved("en"), .english)
        XCTAssertEqual(AppLanguage.resolved("fr"), .french)
        let (key, english, french) = try translatedPair(in: .core)
        XCTAssertNotEqual(english, french)
        XCTAssertEqual(Localizer().text(key), english)
        XCTAssertEqual(Localizer(.english).text(key), english)
        XCTAssertEqual(Localizer(.french).text(key), french)
    }

    func testEveryTableCanSwitchWithoutChangingOtherLocalizers() throws {
        let english = Localizer(.english)
        let french = Localizer(.french)
        for table in tables {
            let (key, en, fr) = try translatedPair(in: table)
            XCTAssertEqual(english.text(key, table: table), en)
            XCTAssertEqual(french.text(key, table: table), fr)
            XCTAssertEqual(english.text(key, table: table), en)
        }
    }

    func testMissingEntryFallsBackToTheEnglishSourceKey() {
        let key = "Untranslated test message: 100% %@ %n"
        for table in tables {
            XCTAssertEqual(Localizer(.french).text(key, table: table), key)
        }
    }

    func testNamedValuesAreNotRecursivelyExpandedOrInterpretedAsFormats() {
        let key = "First {first}; second {second}; 100% %@ %n"
        let values = ["first": "{second}", "second": "done"]
        let expected = "First {second}; second done; 100% %@ %n"
        XCTAssertEqual(Localizer().text(key, values: values), expected)
        XCTAssertEqual(Localizer(.french).text(key, values: values), expected)
        XCTAssertEqual(Localizer().text("Unchanged {missing}", values: [:]), "Unchanged {missing}")
    }

    func testSelectedLanguageControlsNumberFormatting() {
        let english = 12.5.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.english.locale))
        let french = 12.5.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.french.locale))
        XCTAssertEqual(english, "12.5")
        XCTAssertEqual(french, "12,5")
    }

    func testGPUValidationUsesTheRequestedLanguageBeforeAnyGPUWork() {
        var descriptions: [String] = []
        for language in [AppLanguage.english, .french] {
            XCTAssertThrowsError(try GPUBenchmark.run(duration: .nan, cancellation: CancellationToken(),
                                                     language: language, progress: { _ in })) { error in
                descriptions.append(error.localizedDescription)
            }
        }
        XCTAssertEqual(descriptions.count, 2)
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
        XCTAssertNotEqual(descriptions.first, descriptions.last)
    }

    func testLanguageDoesNotCreateAnOSVersionChangeWarning() {
        let english = "Version 27.2.1 (Build 26B131)"
        let french = "Version 27.2.1 (assemblage 26B131)"
        XCTAssertTrue(PersonalComparison.sameOperatingSystem(english, french))
        XCTAssertTrue(PersonalComparison.sameOperatingSystem(french, english))
        XCTAssertTrue(PersonalComparison.sameOperatingSystem("Version 27.2.0 (Build 26B131)", "Version 27.2 (assemblage 26B131)"))
        XCTAssertTrue(PersonalComparison.sameOperatingSystem("Version 27.0 (Build 26B131)", "Version 27.0.0 (Build 26B131)"))
        XCTAssertFalse(PersonalComparison.sameOperatingSystem(english, "Version 27.2.2 (assemblage 26B131)"))
        XCTAssertFalse(PersonalComparison.sameOperatingSystem(english, "Version 27.2.1 (assemblage 26B132)"))
        XCTAssertFalse(PersonalComparison.sameOperatingSystem("Unknown OS 1", "Unknown OS 2"))
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertTrue(SystemInfo.operatingSystemDescription.hasPrefix("Version \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"))
        XCTAssertFalse(SystemInfo.operatingSystemDescription.contains("assemblage"))
    }

    func testCatalogsHaveTheSameKeysAndNamedTokens() throws {
        for table in tables {
            let english = try catalog(.english, table: table)
            let french = try catalog(.french, table: table)
            XCTAssertFalse(english.isEmpty)
            XCTAssertEqual(Set(english.keys), Set(french.keys), table.rawValue)
            for (key, value) in english {
                XCTAssertFalse(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(value.isEmpty, key)
                let translated = try XCTUnwrap(french[key])
                XCTAssertFalse(translated.isEmpty, key)
                XCTAssertEqual(tokens(key), tokens(value), "English token mismatch: \(key)")
                XCTAssertEqual(tokens(value), tokens(translated), "French token mismatch: \(key)")
            }
        }
    }

    func testCatalogsContainNoDuplicateDecodedKeys() throws {
        let expression = try NSRegularExpression(pattern: #"(?m)^\s*("(?:\\.|[^"\\])*")\s*="#)
        for language in [AppLanguage.english, .french] {
            for table in tables {
                let url = sourceDirectory.appendingPathComponent(language.rawValue + ".lproj", isDirectory: true)
                    .appendingPathComponent(table.rawValue + ".strings")
                let text = try String(contentsOf: url, encoding: .utf8)
                let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                var keys = Set<String>()
                for match in matches {
                    let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
                    let literal = String(text[range])
                    let minimal = Data((literal + " = \"test\";").utf8)
                    let parsed = try XCTUnwrap(PropertyListSerialization.propertyList(from: minimal, format: nil) as? [String: String])
                    let key = try XCTUnwrap(parsed.keys.first)
                    XCTAssertTrue(keys.insert(key).inserted, "Duplicate key in \(language.rawValue)/\(table.rawValue): \(key)")
                }
                XCTAssertEqual(keys.count, try catalog(language, table: table).count)
            }
        }
    }

    private func tokens(_ text: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
        return Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }
}
