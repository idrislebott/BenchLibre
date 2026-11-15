import Foundation
import Darwin
import BenchCore

enum CLI {
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        let modes: Set<String> = ["--cli", "--smoke", "--info", "--help"]
        guard args.contains(where: modes.contains) else { return }
        do {
            let valued: Set<String> = ["--seconds", "--threads", "--tests", "--repetitions", "--output"]
            var options: [String: String] = [:]
            var switches: Set<String> = []
            var index = 0
            while index < args.count {
                let flag = args[index]
                guard options[flag] == nil, !switches.contains(flag) else {
                    throw BenchmarkFailure.invalidConfiguration("Option répétée : \(flag)")
                }
                if modes.contains(flag) { switches.insert(flag); index += 1; continue }
                guard valued.contains(flag) else { throw BenchmarkFailure.invalidConfiguration("Option inconnue : \(flag)") }
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else {
                    throw BenchmarkFailure.invalidConfiguration("Valeur manquante pour \(flag).")
                }
                options[flag] = args[index + 1]
                index += 2
            }
            if switches.contains("--help") {
                print("""
                BenchLibre \(BenchmarkRunner.applicationVersion)
                --info                    Configuration du Mac en JSON
                --cli                     Session de mesure (10 s, 3 passages par défaut)
                --smoke                   Vérification courte (0,25 s, 1 passage)
                --seconds N               Durée cible par passage (0,1 à 120 s)
                --repetitions N           1, 3 ou 5 passages par test
                --threads N               Nombre de threads CPU
                --tests LIST              cpu,gpu,memory,latency,disk-read,disk-write ou all
                --output PATH             Rapport JSON (sinon sortie standard)
                Les tests disque sont optionnels. Écriture : 512 Mio mesurés maximum
                et 64 Mio de préparation par passage, dans un fichier temporaire.
                """)
                exit(0)
            }
            if switches.contains("--info") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(SystemInfo.capture()), as: UTF8.self)); exit(0)
            }
            let smoke = switches.contains("--smoke")
            func doubleOption(_ flag: String, fallback: Double) throws -> Double {
                guard let raw = options[flag] else { return fallback }
                guard let value = Double(raw) else { throw BenchmarkFailure.invalidConfiguration("\(flag) attend un nombre.") }
                return value
            }
            func intOption(_ flag: String, fallback: Int) throws -> Int {
                guard let raw = options[flag] else { return fallback }
                guard let value = Int(raw) else { throw BenchmarkFailure.invalidConfiguration("\(flag) attend un entier.") }
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
                            throw BenchmarkFailure.invalidConfiguration("Test inconnu : \(value)")
                        }
                        return kind
                    }
                }
            }
            let config = BenchmarkConfiguration(secondsPerTest: seconds, threads: threads, enabled: kinds, repetitions: repetitions)
            let report = try BenchmarkRunner.run(configuration: config, cancellation: CancellationToken())
            let data = try ReportCodec.encode(report)
            if let output = options["--output"] {
                try data.write(to: URL(fileURLWithPath: output), options: .atomic)
                print("Rapport enregistré : \(output)")
            } else { print(String(decoding: data, as: UTF8.self)) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("BenchLibre : \(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
}
