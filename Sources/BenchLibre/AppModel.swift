import SwiftUI
import AppKit
import BenchCore

@MainActor
final class AppModel: ObservableObject {
    @Published var language = AppLanguage.resolved(UserDefaults.standard.string(forKey: "preferredLanguage")) {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "preferredLanguage")
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
    @Published var hardware = SystemInfo.capture()
    @Published var reports: [BenchmarkReport] = []
    @Published var exporting = false
    @Published var loadingHistory = true
    @Published var current: BenchmarkReport?
    @Published private(set) var comparisonReference: BenchmarkReport?
    @Published private(set) var preparingComparison = false
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
    @Published private var statusKey = "Ready for a new benchmark."
    @Published private var statusValues: [String: String] = [:]
    private var statusKind: BenchmarkKind?
    var status: String {
        var values = statusValues
        if let statusKind { values["test"] = statusKind.localizedTitle(language) }
        if statusKey == "Report from {date}", let current {
            values["date"] = current.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale))
        }
        return text(statusKey, values)
    }
    func text(_ key: String, _ values: [String: String] = [:]) -> String {
        Localizer(language).text(key, table: .app, values: values)
    }
    private func setStatus(_ key: String, _ values: [String: String] = [:], kind: BenchmarkKind? = nil) {
        statusKind = kind
        statusValues = values
        statusKey = key
    }
    private struct PresentedFailure { let key: String; let reason: Error }
    @Published private var presentedFailure: PresentedFailure?
    var error: String? {
        get {
            guard let failure = presentedFailure else { return nil }
            let reason = (failure.reason as? BenchmarkFailure)?.localizedDescription(in: language)
                ?? Localizer(language).text(failure.reason.localizedDescription)
            return text(failure.key, ["reason": reason])
        }
        set { if newValue == nil { presentedFailure = nil } }
    }
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
        guard !running, !exporting, !loadingHistory, !preparingComparison, !enabled.isEmpty else { return }
        let config = BenchmarkConfiguration(secondsPerTest: durations[preset], threads: threads,
                                            enabled: BenchmarkKind.allCases.filter { enabled.contains($0) }, repetitions: repetitions)
        let cancellation = CancellationToken()
        let runID = UUID()
        currentRunID = runID
        token = cancellation
        running = true; stopping = false; fraction = 0; activeKind = nil
        current = nil; results = [:]; liveValues = [:]; liveSamples = [:]; page = 0
        comparisonReference = nil
        summaries = [:]; liveCondition = nil
        setStatus("Preparing measurements…")
        let runLanguage = language
        task = Task.detached(priority: .userInitiated) { [self] in
            do {
                let report = try BenchmarkRunner.run(configuration: config, cancellation: cancellation, language: runLanguage) { [self] update in
                    Task { @MainActor [self] in
                        guard self.running, !self.stopping, self.currentRunID == runID else { return }
                        self.activeKind = update.kind; self.fraction = max(self.fraction, update.overallFraction)
                        self.setStatus("Benchmarking {test} — pass {pass}/{total}", ["pass": String(update.iteration), "total": String(update.repetitions)], kind: update.kind)
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
        stopping = true; setStatus("Stopping the test…"); token?.cancel()
    }

    private func finish(_ report: BenchmarkReport) async {
        stopping = true; token = nil; setStatus("Saving the report…")
        do {
            let (loaded, reference) = try await Task.detached(priority: .utility) {
                try ReportStore.save(report)
                let loaded = ReportStore.load()
                return (loaded, PersonalComparison.reference(for: report, in: loaded))
            }.value
            reports = loaded
            comparisonReference = reference
            setStatus("Session complete · report saved in the app container.")
        } catch {
            setStatus("Measurement complete · report retained in this window.")
            self.presentedFailure = PresentedFailure(key: "The report could not be saved: {reason}", reason: error)
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
            setStatus("Session stopped · no report added.")
        } else {
            setStatus("The session could not finish.")
            presentedFailure = PresentedFailure(key: "Benchmark failed: {reason}", reason: failure)
        }
    }

    func select(_ report: BenchmarkReport) {
        guard !running, !preparingComparison else { return }
        comparisonReference = nil
        preparingComparison = true
        current = report; results = Dictionary(report.results.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        summaries = Dictionary((report.summaries ?? []).map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        liveCondition = report.conditions?.last
        liveValues = [:]; liveSamples = [:]; page = 0; fraction = 1
        setStatus("Report from {date}")
        let history = reports
        Task { [weak self] in
            let reference = await Task.detached(priority: .utility) {
                PersonalComparison.reference(for: report, in: history)
            }.value
            guard let self, self.current?.id == report.id else { return }
            self.comparisonReference = reference
            self.preparingComparison = false
        }
    }

    func exportReport() {
        guard let current, !exporting, !running else { return }
        exporting = true
        Task { [weak self] in
            defer { self?.exporting = false }
            do {
                let url = try await Task.detached(priority: .utility) { try ReportStore.export(current) }.value
                self?.setStatus("JSON copy saved in Exports, inside the app container.")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self?.presentedFailure = PresentedFailure(key: "Unable to export JSON: {reason}", reason: error) }
        }
    }

    func copyReport() {
        guard let current, let data = try? ReportCodec.encode(current), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

