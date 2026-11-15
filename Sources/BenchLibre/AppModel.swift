import SwiftUI
import AppKit
import BenchCore

@MainActor
final class AppModel: ObservableObject {
    @Published var hardware = SystemInfo.capture()
    @Published var reports: [BenchmarkReport] = []
    @Published var exporting = false
    @Published var loadingHistory = true
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

    init() {
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { ReportStore.load() }.value
            guard let self else { return }
            self.loadingHistory = false
            guard !self.running, self.current == nil else { return }
            self.reports = loaded
        }
    }

    func start() {
        guard !running, !exporting, !loadingHistory, !enabled.isEmpty else { return }
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
        guard running, !stopping else { return }
        stopping = true; status = "Arrêt du test…"; token?.cancel()
    }

    private func finish(_ report: BenchmarkReport) async {
        stopping = true; token = nil; status = "Enregistrement du rapport…"
        do {
            let loaded = try await Task.detached(priority: .utility) {
                try ReportStore.save(report)
                return ReportStore.load()
            }.value
            reports = loaded
            status = "Session terminée · rapport enregistré dans le conteneur."
        } catch {
            status = "Mesure terminée · rapport conservé dans cette fenêtre."
            self.error = "Le rapport n’a pas pu être enregistré : \(error.localizedDescription)"
        }
        currentRunID = nil
        task = nil
        running = false; stopping = false; activeKind = nil; fraction = 1
        current = report
        results = Dictionary(report.results.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        summaries = Dictionary((report.summaries ?? []).map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        liveCondition = report.conditions?.last
        hardware = report.hardware
    }

    private func fail(_ failure: Error) {
        currentRunID = nil
        task = nil
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
        current = report; results = Dictionary(report.results.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        summaries = Dictionary((report.summaries ?? []).map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        liveCondition = report.conditions?.last
        liveValues = [:]; liveSamples = [:]; page = 0; fraction = 1
        status = "Rapport du \(report.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func exportReport() {
        guard let current, !exporting, !running else { return }
        exporting = true
        Task { [weak self] in
            defer { self?.exporting = false }
            do {
                let url = try await Task.detached(priority: .utility) { try ReportStore.export(current) }.value
                self?.status = "Copie JSON enregistrée dans Exports, à l’intérieur du conteneur."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self?.error = "Copie JSON impossible : \(error.localizedDescription)" }
        }
    }

    func copyReport() {
        guard let current, let data = try? ReportCodec.encode(current), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

