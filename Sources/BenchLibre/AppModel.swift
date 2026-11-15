import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BenchCore

@MainActor
final class AppModel: ObservableObject {
    @Published var hardware = SystemInfo.capture()
    @Published var reports = ReportStore.load()
    @Published var current: BenchmarkReport?
    @Published var results: [BenchmarkKind: MetricResult] = [:]
    @Published var summaries: [BenchmarkKind: MeasurementSummary] = [:]
    @Published var liveCondition: ConditionSample?
    @Published var liveValues: [BenchmarkKind: Double] = [:]
    @Published var liveSamples: [BenchmarkKind: [Double]] = [:]
    @Published var enabled = Set(BenchmarkKind.defaultSelection)
    @Published var preset = 1
    @Published var threads = ProcessInfo.processInfo.activeProcessorCount
    @Published var repetitions = 3
    @Published var running = false
    @Published var stopping = false
    @Published var fraction = 0.0
    @Published var activeKind: BenchmarkKind?
    @Published var status = "Prêt pour une nouvelle mesure."
    @Published var error: String?
    @Published var page = 0
    @Published var showDetails = UserDefaults.standard.bool(forKey: "showBenchmarkDetails") {
        didSet { UserDefaults.standard.set(showDetails, forKey: "showBenchmarkDetails") }
    }
    @Published var showCharts = UserDefaults.standard.object(forKey: "showBenchmarkCharts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCharts, forKey: "showBenchmarkCharts") }
    }
    private var token: CancellationToken?
    private var task: Task<Void, Never>?
    private var currentRunID: UUID?
    let durations = [2.5, 10.0, 30.0]

    func start() {
        guard !running, !enabled.isEmpty else { return }
        let config = BenchmarkConfiguration(secondsPerTest: durations[preset], threads: threads,
                                            enabled: BenchmarkKind.allCases.filter { enabled.contains($0) }, repetitions: repetitions)
        let cancellation = CancellationToken()
        let runID = UUID()
        currentRunID = runID
        token = cancellation
        running = true; stopping = false; fraction = 0; activeKind = nil
        current = nil; results = [:]; liveValues = [:]; liveSamples = [:]; page = 0
        summaries = [:]; liveCondition = nil
        status = "Préparation des mesures…"
        task = Task.detached(priority: .userInitiated) { [self] in
            do {
                let report = try BenchmarkRunner.run(configuration: config, cancellation: cancellation) { [self] update in
                    Task { @MainActor [self] in
                        guard self.running, !self.stopping, self.currentRunID == runID else { return }
                        self.activeKind = update.kind; self.fraction = max(self.fraction, update.overallFraction)
                        self.status = update.message
                        self.liveCondition = update.condition
                        if let value = update.value, value.isFinite, value > 0 {
                            self.liveValues[update.kind] = value
                            self.liveSamples[update.kind] = Array(((self.liveSamples[update.kind] ?? []) + [value]).suffix(80))
                        }
                        if let result = update.completed { self.results[result.kind] = result }
                        if let summary = update.summary { self.summaries[summary.kind] = summary }
                    }
                }
                await finish(report)
            } catch {
                await fail(error)
            }
        }
    }

    func stop() {
        guard running else { return }
        stopping = true; status = "Arrêt du test…"; token?.cancel()
    }

    private func finish(_ report: BenchmarkReport) {
        currentRunID = nil
        running = false; stopping = false; activeKind = nil; fraction = 1; token = nil
        current = report; results = Dictionary(uniqueKeysWithValues: report.results.map { ($0.kind, $0) })
        summaries = Dictionary(uniqueKeysWithValues: (report.summaries ?? []).map { ($0.kind, $0) })
        liveCondition = report.conditions?.last
        hardware = report.hardware
        do { try ReportStore.save(report); reports = ReportStore.load(); status = "Session terminée · rapport enregistré sur ce Mac." }
        catch { status = "Mesure terminée · rapport conservé dans cette fenêtre."; self.error = "Le rapport local n’a pas pu être enregistré : \(error.localizedDescription)" }
    }

    private func fail(_ failure: Error) {
        currentRunID = nil
        running = false; stopping = false; activeKind = nil; token = nil
        if case BenchmarkFailure.cancelled = failure {
            status = "Session arrêtée · aucun rapport ajouté."
        } else {
            status = "La session n’a pas pu se terminer."
            error = failure.localizedDescription
        }
    }

    func select(_ report: BenchmarkReport) {
        guard !running else { return }
        current = report; results = Dictionary(uniqueKeysWithValues: report.results.map { ($0.kind, $0) })
        summaries = Dictionary(uniqueKeysWithValues: (report.summaries ?? []).map { ($0.kind, $0) })
        liveCondition = report.conditions?.last
        liveValues = [:]; liveSamples = [:]; page = 0; fraction = 1
        status = "Rapport du \(report.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func exportReport() {
        guard let current else { return }
        let owner = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BenchLibre-\(Int(current.startedAt.timeIntervalSince1970)).json"
        panel.title = "Exporter le rapport de benchmark"
        NSApp.activate()
        owner?.makeKeyAndOrderFront(nil)
        let response = panel.runModal()
        panel.orderOut(nil)
        owner?.makeKeyAndOrderFront(nil)
        guard response == .OK, let url = panel.url else { return }
        do {
            try ReportCodec.encode(current).write(to: url, options: .atomic)
            status = "Rapport exporté : \(url.lastPathComponent)"
        } catch { self.error = "Export impossible : \(error.localizedDescription)" }
    }

    func copyReport() {
        guard let current, let data = try? ReportCodec.encode(current), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

