import SwiftUI
import AppKit
import BenchCore

private let ink = Color(red: 0.055, green: 0.065, blue: 0.080)
private let panel = Color(red: 0.092, green: 0.106, blue: 0.126)
private let accent = Color(red: 0.48, green: 0.94, blue: 0.73)
private let muted = Color(red: 0.53, green: 0.58, blue: 0.64)

private struct ResultGuide {
    let title: String
    let purpose: String
    let unit: String
    let explanation: String
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(value >= 1000 ? 0 : value > 0 && value < 1 ? 3 : 1)).locale(model.language.locale))
    }

    private func guide(_ kind: BenchmarkKind) -> ResultGuide {
        switch kind {
        case .cpu:
            return ResultGuide(title: l("Processor"), purpose: l("Measured speed for repeated calculations."),
                unit: l("billion operations per second"),
                explanation: l("This counts operations completed each second. A higher value means more calculations in this test. The workload uses floating-point numbers; an application's speed also depends on the work it performs."))
        case .gpu:
            return ResultGuide(title: l("Graphics processor"), purpose: l("Measured ability to perform many calculations in parallel."),
                unit: l("billion operations per second"),
                explanation: l("This counts operations completed by the graphics processor each second. A higher value means more calculations in this test. A game's frame rate also depends on its engine, settings and scene; FPS are not measured here."))
        case .memory:
            return ResultGuide(title: l("Memory transfers"), purpose: l("Amount of data processed in memory each second."),
                unit: l("GB transferred per second"),
                explanation: l("One GB is one billion bytes. RAM capacity describes how much data fits in memory; this rate describes transfer speed in this test. A single worker operates on three memory blocks."))
        case .latency:
            return ResultGuide(title: l("Memory access time"), purpose: l("Average wait to retrieve a value from memory."),
                unit: l("nanoseconds per access"),
                explanation: l("A nanosecond is one billionth of a second. A lower value means less waiting. The test follows a path where each access depends on the previous one; processor caches also contribute to the result."))
        case .diskRead:
            return ResultGuide(title: l("File reading"), purpose: l("Measured speed when reading a large file."),
                unit: l("GB read per second"),
                explanation: l("One GB is one billion bytes. The file is read sequentially on the volume holding BenchLibre's data. This rate describes that sequential read; opening many small files is a different workload."))
        case .diskWrite:
            return ResultGuide(title: l("File writing"), purpose: l("Measured speed when saving a large file."),
                unit: l("GB written per second"),
                explanation: l("One GB is one billion bytes. The test writes a temporary file sequentially and includes a system synchronization request. The result also depends on the file system and hardware caches."))
        }
    }

    private func l(_ key: String, _ values: [String: String] = [:]) -> String {
        Localizer(model.language).text(key, table: .interface, values: values)
    }
    private func unitLabel(_ raw: String) -> String {
        switch raw { case "Go/s": return l("GB/s"); case "ns/accès": return l("ns/access"); default: return raw }
    }
    private func thermalLabel(_ raw: String) -> String {
        switch raw {
        case "Nominal": return l("No constraint reported")
        case "Modéré": return l("Moderate constraint")
        case "Élevé": return l("High constraint")
        case "Critique": return l("Critical constraint")
        default: return l("Information unavailable")
        }
    }
    private func powerLabel(_ raw: String) -> String {
        switch raw { case "Batterie", "Battery": return l("Battery"); case "Secteur", "AC Power", "AC power": return l("AC power"); default: return l("Unknown") }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if model.page == 0 { dashboard }
                    else if model.page == 1 { history }
                    else { protocolView }
                }.padding(32).padding(.top, 8)
            }.background(ink)
        }
        .background(ink)
        .tint(accent)
        .alert("BenchLibre", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 11) {
                Image(systemName: "waveform.path").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
                    .frame(width: 37, height: 37).background(accent, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("BenchLibre").font(.system(size: 17, weight: .semibold))
                    Text(l("MACOS BENCHMARK")).font(.system(size: 8, weight: .bold)).tracking(1.5).foregroundStyle(muted)
                }
            }.padding(.horizontal, 20)
            VStack(spacing: 6) {
                nav(l("Benchmark"), icon: "speedometer", page: 0)
                nav(l("History"), icon: "clock.arrow.circlepath", page: 1)
                nav(l("The protocol"), icon: "text.book.closed", page: 2)
            }.padding(.horizontal, 12)
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 8) {
                Text(l("Language")).font(.system(size: 11)).foregroundStyle(muted)
                Picker(l("Language"), selection: $model.language) {
                    Text("English").tag(AppLanguage.english)
                    Text("Français").tag(AppLanguage.french)
                }.pickerStyle(.menu).labelsHidden().accessibilityLabel("Language / Langue")
            }.padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: 24)).foregroundStyle(accent.opacity(0.9))
                Text(model.hardware.chip).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(l("{v0} threads · {v1} GiB RAM", ["v0": String(describing: model.hardware.logicalCores), "v1": String(describing: model.hardware.physicalMemoryGB)])).font(.system(size: 11)).foregroundStyle(muted)
                Text(model.hardware.model).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                Divider().overlay(.white.opacity(0.04)).padding(.vertical, 5)
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 5, height: 5)
                    Text(l("LOCAL · MIT · v{v0}", ["v0": String(describing: BenchmarkRunner.applicationVersion)])).font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(muted)
                }
            }.padding(20)
        }.padding(.top, 49).padding(.bottom, 8).frame(width: 215).background(Color.white.opacity(0.018))
    }

    private func nav(_ title: String, icon: String, page: Int) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                Spacer()
                if model.page == page { RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 15) }
            }.foregroundStyle(model.page == page ? accent : Color.white.opacity(0.6))
                .padding(.horizontal, 13).padding(.vertical, 12)
                .background(model.page == page ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.page == 0 ? l("UNDERSTAND PERFORMANCE") : model.page == 1 ? l("YOUR LOCAL MEASUREMENTS") : l("EXPLAINABLE MEASUREMENTS"))
                    .font(.system(size: 9, weight: .bold)).tracking(1.8).foregroundStyle(accent)
                Text(model.page == 0 ? (model.current == nil ? l("Measure your Mac.") : l("Understand your results.")) : model.page == 1 ? l("Every session counts.") : l("An open protocol."))
                    .font(.system(size: 31, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text(model.page == 0 ? l("Every number is explained. Track changes using the same tests.") : model.page == 1 ? l("Find your results and export them for comparison.") : l("The code, calculations and conditions behind every result."))
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            if model.current != nil {
                Button { model.exportReport() } label: { Label(l("Export results"), systemImage: "square.and.arrow.up") }
                    .controlSize(.regular).disabled(model.exporting || model.running).help(l("Saves a copy inside the app container and reveals it in Finder.")).padding(.top, 19)
            } else {
                Text(l("100% LOCAL")).font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(muted).padding(.horizontal, 11).padding(.vertical, 7)
                    .overlay(Capsule().stroke(.white.opacity(0.12))).padding(.top, 18)
            }
        }
    }


    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let report = model.current {
                resultOverview(report)
                DisclosureGroup(l("Run another benchmark")) { sessionControls.padding(.top, 12) }
                    .font(.system(size: 13, weight: .medium))
            } else if !model.running {
                VStack(alignment: .leading, spacing: 8) {
                    Label(l("Create your reference measurement"), systemImage: "flag")
                        .font(.system(size: 16, weight: .semibold))
                    Text(l("You can then track performance using the same tests. Each result is explained beneath its number."))
                        .font(.system(size: 12)).foregroundStyle(muted)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            if model.current == nil { sessionControls }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13), count: 3), spacing: 13) {
                ForEach(BenchmarkKind.allCases) { kind in metricCard(kind) }
            }
            conditions
            if model.showDetails { nerdDetails }
        }
    }

    private func resultOverview(_ report: BenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.comparisonReference == nil ? l("Your reference measurement is ready") : l("Your results in context"),
                  systemImage: model.comparisonReference == nil ? "flag.fill" : "arrow.left.arrow.right")
                .font(.system(size: 19, weight: .semibold))
            if model.preparingComparison {
                Text(l("Looking for a comparable session in your history…"))
                    .font(.system(size: 12)).foregroundStyle(muted)
            } else if let reference = model.comparisonReference {
                Text(l("The changes below compare this session with {v0}, using the same hardware configuration and test settings.", ["v0": String(describing: reference.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.language.locale)))]))
                    .font(.system(size: 12)).foregroundStyle(muted)
                Text(l("These are observed differences. Run-to-run variation and conditions may also explain them."))
                    .font(.system(size: 11)).foregroundStyle(muted)
            } else {
                Text(l("There is no comparable session in your history yet. Keep this one to track changes in performance."))
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Text(l("{v0} areas measured · {v1} {v2} per area", ["v0": String(describing: report.results.count), "v1": String(describing: report.configuration.repetitions), "v2": String(describing: report.configuration.repetitions > 1 ? l("passes") : l("pass"))]))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
            if let reference = model.comparisonReference {
                if !PersonalComparison.sameOperatingSystem(report.hardware.operatingSystem, reference.hardware.operatingSystem) {
                    Label(l("The macOS versions differ. Software may also explain the change."), systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                if comparisonConditionsDiffer(report, reference) {
                    Label(l("Power source, Low Power Mode or thermal conditions differ between the sessions."), systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(accent.opacity(0.18)))
    }

    private func comparisonConditionsDiffer(_ current: BenchmarkReport, _ reference: BenchmarkReport) -> Bool {
        let currentPower = Set(current.conditions?.map(\.powerSource) ?? [current.hardware.powerSource])
        let oldPower = Set(reference.conditions?.map(\.powerSource) ?? [reference.hardware.powerSource])
        return currentPower != oldPower
            || Set(current.conditions?.map(\.lowPowerMode) ?? []) != Set(reference.conditions?.map(\.lowPowerMode) ?? [])
            || Set(current.conditions?.map(\.thermalState) ?? [current.thermalBefore, current.thermalAfter])
                != Set(reference.conditions?.map(\.thermalState) ?? [reference.thermalBefore, reference.thermalAfter])
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 19) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(l("Choose your benchmark")).font(.system(size: 15, weight: .semibold))
                        Text(l("{v0} s per pass · {v1} test(s) selected", ["v0": String(describing: model.durations[model.preset].formatted(.number.locale(model.language.locale))), "v1": String(describing: model.enabled.count)]))
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    Picker(l("Duration"), selection: $model.preset) {
                        Text(l("Quick")).tag(0); Text(l("Standard")).tag(1); Text(l("Extended")).tag(2)
                    }.pickerStyle(.segmented).frame(width: 290).disabled(model.running)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                    ForEach(BenchmarkKind.allCases) { kind in
                        Button {
                            if model.enabled.contains(kind) { model.enabled.remove(kind) } else { model.enabled.insert(kind) }
                        } label: {
                            Label(guide(kind).title, systemImage: model.enabled.contains(kind) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 8)
                                .foregroundStyle(model.enabled.contains(kind) ? accent : muted)
                                .background(model.enabled.contains(kind) ? accent.opacity(0.08) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(model.running).accessibilityLabel(l("Test {v0}", ["v0": String(describing: kind.localizedTitle(model.language))]))
                    }
                }
                HStack(spacing: 10) {
                    Text(l("Passes per test")).font(.system(size: 11)).foregroundStyle(muted)
                    Picker(l("Passes per test"), selection: $model.repetitions) {
                        Text("1").tag(1); Text("3").tag(3); Text("5").tag(5)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 135).disabled(model.running)
                    Spacer()
                    Text(l("{v0} CPU threads", ["v0": String(describing: model.threads)])).font(.system(size: 11)).foregroundStyle(muted)
                    Stepper(l("CPU threads"), value: $model.threads, in: 1...max(1, model.hardware.logicalCores)).labelsHidden().disabled(model.running)
                }
                if model.enabled.contains(where: { $0.isDisk }) {
                    Text(l("Storage: 64 MiB temporary file. Each write pass uses at most 512 MiB measured writes plus 64 MiB preparation."))
                        .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if model.running { ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 15) }
                            Text(model.running && !model.stopping ? l("Benchmarking: ") + (model.activeKind.map { guide($0).title } ?? l("preparing")) : model.status).font(.system(size: 11)).foregroundStyle(model.running ? Color.white : muted).lineLimit(2)
                        }
                        if model.running {
                            ProgressView(value: model.fraction).progressViewStyle(.linear).tint(accent)
                            Text(l("{v0}% · {v1}", ["v0": String(describing: Int(model.fraction * 100)), "v1": String(describing: model.activeKind?.localizedTitle(model.language) ?? l("Starting"))]))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                        } else {
                            Text(l("Use the same settings and close demanding tasks when comparing sessions."))
                                .font(.system(size: 10)).foregroundStyle(muted.opacity(0.8)).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if model.running {
                        Button(l("Stop")) { model.stop() }.controlSize(.large).disabled(model.stopping)
                    } else {
                        Button { model.start() } label: { Label(l("Benchmark this Mac"), systemImage: "play.fill").fontWeight(.semibold).padding(.horizontal, 6) }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(accent).foregroundStyle(ink)
                            .disabled(model.enabled.isEmpty || model.exporting || model.loadingHistory || model.preparingComparison).keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func metricCard(_ kind: BenchmarkKind) -> some View {
        let result = model.results[kind]
        let value = result?.value ?? (model.running ? model.liveValues[kind] : nil)
        let active = model.running && model.activeKind == kind
        let samples = result?.samples ?? model.liveSamples[kind] ?? []
        let summary = model.summaries[kind]
        let description = guide(kind)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(active ? accent : .white.opacity(0.7))
                Spacer()
                Text(active ? l("RUNNING") : result != nil ? l("MEASURED") : model.current != nil ? l("NOT MEASURED") : !model.enabled.contains(kind) ? l("OPTIONAL") : l("NOT STARTED"))
                    .font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(active || result != nil ? accent : muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(description.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(description.purpose).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(number(value)).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(description.unit).font(.system(size: 10)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(kind.lowerIsBetter ? l("Less waiting is better") : l("Higher throughput is better"),
                  systemImage: kind.lowerIsBetter ? "arrow.down" : "arrow.up")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
            if let result, let reference = model.comparisonReference,
               let previous = reference.results.first(where: { $0.kind == kind }),
               let change = PersonalComparison.percentChange(current: result, reference: previous) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(comparisonReading(kind, change: change))
                        .font(.system(size: 12, weight: .semibold))
                    Text(kind.lowerIsBetter ? l("Wait time: {v0}", ["v0": String(describing: changeLabel(change))]) : l("Measured throughput: {v0}", ["v0": String(describing: changeLabel(change))]))
                        .font(.system(size: 11)).foregroundStyle(muted)
                    Text(l("Change from the local reference")).font(.system(size: 10)).foregroundStyle(muted)
                }.padding(.vertical, 4)
            }
            if let summary {
                Text(summary.runCount > 1 ? l("Middle value of {v0} passes", ["v0": String(describing: summary.runCount)]) : l("Only one pass completed"))
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
            DisclosureGroup(l("Understand this result")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(description.explanation)
                    if let summary, summary.runCount > 1 {
                        Text(l("Across passes: {v0} to {v1} {v2}. The middle value is the actual pass in the middle of the sorted results.", ["v0": String(describing: number(summary.minimum)), "v1": String(describing: number(summary.maximum)), "v2": String(describing: description.unit)]))
                    }
                    if result == nil, let omission = model.current?.omissions?.first(where: { $0.kind == kind }) {
                        Text(l("This area could not be measured: {v0}", ["v0": String(describing: omission.reason)]))
                    }
                }.font(.system(size: 11)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.system(size: 11))
            if model.showCharts, samples.count > 1 {
                Sparkline(values: samples).stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(height: 30).padding(.top, 2)
                Text(l("Changes during one pass · adjusted scale"))
                    .font(.system(size: 9)).foregroundStyle(muted)
            }
            if model.showDetails {
                Text(l("{v0} · {v1}", ["v0": String(describing: kind.localizedTitle(model.language)), "v1": String(describing: unitLabel(result?.unit ?? kind.unit))])).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                if let summary, let cv = summary.coefficientOfVariationPercent {
                    Text(l("CV {v0}% · {v1}–{v2}", ["v0": String(describing: number(cv)), "v1": String(describing: number(summary.minimum)), "v2": String(describing: number(summary.maximum))]))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                }
                if let result { Text(l("Original report text")).font(.system(size: 9)); Text(result.details).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(4) }
            }
        }.padding(19).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(panel, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(active ? accent.opacity(0.5) : .white.opacity(0.07), lineWidth: 1))
    }

    private func changeLabel(_ percent: Double) -> String {
        guard abs(percent) >= 0.05 else { return l("less than 0.1% change") }
        return (percent > 0 ? "+" : "") + percent.formatted(.number.precision(.fractionLength(1)).locale(model.language.locale)) + " %"
    }

    private func comparisonReading(_ kind: BenchmarkKind, change: Double) -> String {
        guard abs(change) >= 0.05 else { return l("Change below 0.1%") }
        if kind.lowerIsBetter { return change < 0 ? l("Shorter observed wait") : l("Longer observed wait") }
        if kind == .cpu || kind == .gpu {
            return change > 0 ? l("More operations per second") : l("Fewer operations per second")
        }
        return change > 0 ? l("More data per second") : l("Less data per second")
    }


    private var conditions: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(l("WHAT CAN AFFECT THE MEASUREMENT")).font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(muted)
                Spacer()
                Button { model.showDetails.toggle() } label: {
                    Label(model.showDetails ? l("Hide details") : l("Nerd details"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 20) {
                condition(l("Power source"), value: powerLabel(model.liveCondition?.powerSource ?? model.current?.hardware.powerSource ?? model.hardware.powerSource), symbol: "bolt.fill")
                condition(l("Thermal state reported by macOS"), value: thermalReading, symbol: "thermometer.medium")
                condition(l("Low Power Mode"), value: model.liveCondition.map { $0.lowPowerMode ? l("On") : l("Off") } ?? l("Not observed"), symbol: "leaf")
            }
            if let report = model.current {
                if report.conditions?.contains(where: \.lowPowerMode) == true {
                    Text(l("Low Power Mode was enabled during at least part of this session. It may limit performance."))
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                if report.conditions?.contains(where: { ["Modéré", "Élevé", "Critique"].contains($0.thermalState) }) == true {
                    Text(l("macOS reported thermal constraints during this session. The results may be affected."))
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                if (report.omissions?.count ?? 0) > 0 {
                    Text(l("Some areas were not measured. Their cards explain why."))
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                if report.conditions == nil {
                    Text(l("Full conditions were not recorded for this older session."))
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
            } else {
                Text(l("Power, other running tasks and heat can affect results."))
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
        }.padding(.horizontal, 3)
    }

    private var thermalReading: String {
        let raw = model.liveCondition?.thermalState ?? model.current?.thermalAfter ?? SystemInfo.thermalState
        return thermalLabel(raw)
    }

    private func condition(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(muted).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 9)).foregroundStyle(muted)
                Text(value).font(.system(size: 11, weight: .medium))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nerdDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l("Nerd details")).font(.system(size: 13, weight: .semibold))
            detailRow(l("Protocol"), value: model.current?.workloadVersion ?? BenchmarkRunner.workloadVersion)
            detailRow(l("Architecture"), value: model.current?.hardware.architecture ?? model.hardware.architecture)
            detailRow("GPU", value: model.current?.hardware.gpu ?? model.hardware.gpu)
            detailRow(l("System"), value: model.current?.hardware.operatingSystem ?? model.hardware.operatingSystem)
            if let report = model.current {
                detailRow(l("Total duration"), value: l("{v0} s", ["v0": String(describing: report.totalSeconds.formatted(.number.precision(.fractionLength(2)).locale(model.language.locale)))]))
                detailRow(l("Validation"), value: report.results.allSatisfy(\.validated) ? l("Reference checks passed") : l("Incomplete"))
                detailRow(l("Passes"), value: l("{v0} per test · {v1} retained", ["v0": String(describing: report.configuration.repetitions), "v1": String(describing: report.trials?.count ?? report.results.count)]))
                Button(l("Copy JSON report")) { model.copyReport() }.font(.system(size: 11))
                if let log = report.conditions, !log.isEmpty {
                    DisclosureGroup(l("Conditions log ({v0})", ["v0": String(describing: log.count)])) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(log.suffix(12).enumerated()), id: \.offset) { _, sample in
                                Text(l("{v0} s · {v1} · {v2} · Low Power Mode {v3}", ["v0": String(describing: number(sample.elapsedSeconds)), "v1": String(describing: powerLabel(sample.powerSource)), "v2": String(describing: thermalLabel(sample.thermalState)), "v3": String(describing: sample.lowPowerMode ? l("yes") : l("no"))]))
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                            }
                            if log.count > 12 { Text(l("Only the last 12 observations are shown; the JSON contains the complete log.")).font(.system(size: 9)).foregroundStyle(muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.system(size: 11))
                }
            }
            Text(l("Thermal state comes from macOS; it is not a temperature in °C.")).font(.system(size: 10)).foregroundStyle(muted)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(muted).frame(width: 105, alignment: .leading)
            Text(value).textSelection(.enabled)
        }.font(.system(size: 10, design: .monospaced))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.reports.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(muted)
                    Text(l("Your first session is waiting.")).font(.system(size: 17, weight: .medium))
                    Text(l("Completed reports appear here, on this Mac.")).font(.system(size: 12)).foregroundStyle(muted)
                    Button(l("Start a benchmark")) { model.page = 0 }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding(.vertical, 90)
            } else {
                ForEach(model.reports) { report in
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(report.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.language.locale))).font(.system(size: 12, weight: .semibold))
                                Text(l("{v0} · {v1} s × {v2} pass(es) · v{v3}", ["v0": String(describing: report.hardware.chip), "v1": String(describing: report.configuration.secondsPerTest.formatted(.number.locale(model.language.locale))), "v2": String(describing: report.configuration.repetitions), "v3": String(describing: report.applicationVersion)]))
                                    .font(.system(size: 10)).foregroundStyle(muted)
                            }
                            Spacer()
                            Button(l("Read results")) { model.select(report) }.font(.system(size: 11)).disabled(model.running || model.preparingComparison)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 12) {
                            ForEach(report.results) { result in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(guide(result.kind).title).font(.system(size: 9)).foregroundStyle(muted)
                                    Text(l("{v0} {v1}", ["v0": String(describing: number(result.value)), "v1": String(describing: guide(result.kind).unit)])).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                                }
                            }
                        }
                    }.padding(15).background(panel, in: RoundedRectangle(cornerRadius: 11))
                }
            }
        }
    }

    private var protocolView: some View {
        VStack(alignment: .leading, spacing: 15) {
            protocolBlock("01", title: l("CPU compute"), body: l("FP32 operations are repeated on the selected workers. Warm-up and calibration happen before measurement. Throughput is the actual number of operations completed divided by elapsed time."))
            protocolBlock("02", title: l("GPU compute with Metal"), body: l("A compute kernel runs FMAs on the GPU. The result uses GPU command timestamps. Output values are checked against a CPU reference before and after measurement. This measures compute, not game FPS."))
            protocolBlock("03", title: l("Memory bandwidth"), body: l("The test computes A = B + 3 × C over three 64 MiB blocks. Throughput uses decimal GB/s, counting two reads and one write per element. It describes logical traffic, not physical DRAM traffic."))
            protocolBlock("04", title: l("Effective latency"), body: l("A randomized chain of dependent loads traverses a 64 MiB working set. Results are nanoseconds per access: lower is better. The entire memory hierarchy contributes; this does not certify physical DRAM latency."))
            protocolBlock("05", title: l("File reading and writing"), body: l("Each pass creates a private 64 MiB temporary file. I/O requires F_NOCACHE. Writes include fsync and are capped at 512 MiB measured writes plus 64 MiB preparation. Results describe file I/O on the temporary volume, including possible hardware caches. Test files are removed afterward."))
            protocolBlock("06", title: l("Repetitions and conditions"), body: l("Choose 1, 3 or 5 passes per test. The displayed result is the actual median pass. The min–max range and coefficient of variation describe differences across passes. Reports retain raw results and conditions observed about once per second. This does not certify absence of throttling. Compare identical profiles and settings."))
            HStack {
                Label(l("Source code under the MIT license"), systemImage: "chevron.left.forwardslash.chevron.right")
                Spacer()
                Text(BenchmarkRunner.workloadVersion).font(.system(size: 10, design: .monospaced))
            }.font(.system(size: 11)).foregroundStyle(accent).padding(.top, 8)
        }
    }
    private func protocolBlock(_ index: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 17) {
            Text(index).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct Sparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        let clean = ChartSeries.normalized(values)
        guard clean.count > 1, rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return Path() }
        return Path { path in
            for (index, value) in clean.enumerated() {
                let x = rect.minX + Double(index) / Double(clean.count - 1) * rect.width
                let y = rect.maxY - value * rect.height
                let point = CGPoint(x: x, y: y)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
