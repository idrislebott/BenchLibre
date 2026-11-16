// SPDX-License-Identifier: MIT
import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case english = "en"
    case french = "fr"
    public var id: String { rawValue }
    public var locale: Locale {
        Locale(identifier: self == .english ? "en_US" : "fr_FR")
    }
    public static func resolved(_ preference: String?) -> AppLanguage {
        preference.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

public enum LocalizationTable: String, CaseIterable, Sendable {
    case core = "Core"
    case interface = "Interface"
    case app = "App"
}

/// Explicit language values prevent one session or window from changing another
/// session's messages. Localization never changes benchmark data or units.
public struct Localizer: Sendable {
    public let language: AppLanguage
    public init(_ language: AppLanguage = .english) { self.language = language }

    private final class ResourceOwner {}
    private static let bundles: [AppLanguage: Bundle] = {
        let owner = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            ? Bundle.main : Bundle(for: ResourceOwner.self)
        guard let resources = owner.resourceURL,
              let ownBundle = Bundle(url: resources.appendingPathComponent("BenchLibre_BenchCore.bundle")) else { return [:] }
        var result: [AppLanguage: Bundle] = [:]
        for language in AppLanguage.allCases {
            if let url = ownBundle.url(forResource: language.rawValue, withExtension: "lproj"),
               let localized = Bundle(url: url) { result[language] = localized }
        }
        return result
    }()

    public func text(_ key: String, table: LocalizationTable = .core, values: [String: String] = [:]) -> String {
        let template = Self.bundles[language]?.localizedString(forKey: key, value: key, table: table.rawValue) ?? key
        guard !values.isEmpty else { return template }
        // One pass, named replacements only. Values are appended verbatim:
        // no C format strings and no recursive expansion of user/OS text.
        var output = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{",
               let closing = template[cursor...].firstIndex(of: "}") {
                let name = String(template[template.index(after: cursor)..<closing])
                if let value = values[name] { output += value }
                else { output += template[cursor...closing] }
                cursor = template.index(after: closing)
            } else {
                output.append(template[cursor])
                cursor = template.index(after: cursor)
            }
        }
        return output
    }
}
