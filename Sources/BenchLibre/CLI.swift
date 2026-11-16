import Foundation
import Darwin
import BenchCore

enum CLI {
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        let modes: Set<String> = ["--cli", "--smoke", "--info", "--help", "--security-info"]
        guard args.contains(where: modes.contains) else { return }
        // CLI language is explicit and never changes the GUI's saved preference.
        var language = AppLanguage.english
        if let index = args.firstIndex(of: "--language"), index + 1 < args.count {
            language = AppLanguage.resolved(args[index + 1])
        }
        func text(_ key: String, _ values: [String: String] = [:]) -> String {
            Localizer(language).text(key, table: .app, values: values)
        }
        do {
            let valued: Set<String> = ["--seconds", "--threads", "--tests", "--repetitions", "--output", "--language"]
            var options: [String: String] = [:]
            var switches: Set<String> = []
            var index = 0
            while index < args.count {
                let flag = args[index]
                guard options[flag] == nil, !switches.contains(flag) else {
                    throw BenchmarkFailure.invalidConfiguration(text("Repeated option: {flag}", ["flag": flag]))
                }
                if modes.contains(flag) { switches.insert(flag); index += 1; continue }
                guard valued.contains(flag) else { throw BenchmarkFailure.invalidConfiguration(text("Unknown option: {flag}", ["flag": flag])) }
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else {
                    throw BenchmarkFailure.invalidConfiguration(text("Missing value for {flag}.", ["flag": flag]))
                }
                options[flag] = args[index + 1]
                index += 2
            }
            if let value = options["--language"], AppLanguage(rawValue: value) == nil {
                throw BenchmarkFailure.invalidConfiguration(text("Language must be en or fr."))
            }
            if switches.contains("--help") {
                print("BenchLibre \(BenchmarkRunner.applicationVersion)")
                print(text("CLI help"))
                exit(0)
            }
            if switches.contains("--security-info") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(AppSecurity.diagnostic), as: UTF8.self)); exit(0)
            }
            if switches.contains("--info") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(SystemInfo.capture()), as: UTF8.self)); exit(0)
            }
            if let name = options["--output"] { try ReportStore.validateExportName(name) }
            let smoke = switches.contains("--smoke")
            func doubleOption(_ flag: String, fallback: Double) throws -> Double {
                guard let raw = options[flag] else { return fallback }
                guard let value = Double(raw) else { throw BenchmarkFailure.invalidConfiguration(text("{flag} requires a number.", ["flag": flag])) }
                return value
            }
            func intOption(_ flag: String, fallback: Int) throws -> Int {
                guard let raw = options[flag] else { return fallback }
                guard let value = Int(raw) else { throw BenchmarkFailure.invalidConfiguration(text("{flag} requires an integer.", ["flag": flag])) }
                return value
            }
            let seconds = try doubleOption("--seconds", fallback: smoke ? 0.25 : 10)
            let threads = try intOption("--threads", fallback: smoke ? min(2, ProcessInfo.processInfo.activeProcessorCount) : ProcessInfo.processInfo.activeProcessorCount)
            let repetitions = try intOption("--repetitions", fallback: smoke ? 1 : 3)
            var kinds = BenchmarkKind.defaultSelection
            if let raw = options["--tests"] {
                if raw == "all" { kinds = BenchmarkKind.allCases }
                else {
                    kinds = try raw.split(separator: ",", omittingEmptySubsequences: false).map { component in
                        let value = component.trimmingCharacters(in: .whitespaces)
                        guard let kind = BenchmarkKind(rawValue: value) else {
                            throw BenchmarkFailure.invalidConfiguration(text("Unknown test: {test}", ["test": value]))
                        }
                        return kind
                    }
                }
            }
            let config = BenchmarkConfiguration(secondsPerTest: seconds, threads: threads, enabled: kinds, repetitions: repetitions)
            let report = try BenchmarkRunner.run(configuration: config, cancellation: CancellationToken(), language: language)
            let data = try ReportCodec.encode(report)
            if let output = options["--output"] {
                let url = try ReportStore.export(report, name: output)
                print(text("Report saved in the container: {path}", ["path": url.path]))
            } else { print(String(decoding: data, as: UTF8.self)) }
            exit(0)
        } catch {
            let reason = (error as? BenchmarkFailure)?.localizedDescription(in: language) ?? error.localizedDescription
            FileHandle.standardError.write(Data("BenchLibre: \(reason)\n".utf8)); exit(1)
        }
    }
}
