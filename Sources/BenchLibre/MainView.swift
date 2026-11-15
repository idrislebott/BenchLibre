import SwiftUI
import AppKit
import BenchCore

private let ink = Color(red: 0.055, green: 0.065, blue: 0.080)
private let panel = Color(red: 0.092, green: 0.106, blue: 0.126)
private let accent = Color(red: 0.48, green: 0.94, blue: 0.73)
private let muted = Color(red: 0.53, green: 0.58, blue: 0.64)

private func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(value >= 1000 ? 0 : value > 0 && value < 1 ? 3 : 1)))
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
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
                    Text("MACOS BENCHMARK").font(.system(size: 8, weight: .bold)).tracking(1.5).foregroundStyle(muted)
                }
            }.padding(.horizontal, 20)
            VStack(spacing: 6) {
                nav("Mesurer", icon: "speedometer", page: 0)
                nav("Historique", icon: "clock.arrow.circlepath", page: 1)
                nav("Le protocole", icon: "text.book.closed", page: 2)
            }.padding(.horizontal, 12)
            Spacer(minLength: 70)
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "desktopcomputer").font(.system(size: 24)).foregroundStyle(accent.opacity(0.9))
                Text(model.hardware.chip).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text("\(model.hardware.logicalCores) threads · \(model.hardware.physicalMemoryGB) Go RAM").font(.system(size: 11)).foregroundStyle(muted)
                Text(model.hardware.model).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                Divider().overlay(.white.opacity(0.04)).padding(.vertical, 5)
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 5, height: 5)
                    Text("LOCAL · MIT · v\(BenchmarkRunner.applicationVersion)").font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(muted)
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
                Text(model.page == 0 ? "VOTRE MAC, EN CHIFFRES" : model.page == 1 ? "VOS MESURES LOCALES" : "DES MESURES EXPLICABLES")
                    .font(.system(size: 9, weight: .bold)).tracking(1.8).foregroundStyle(accent)
                Text(model.page == 0 ? "Mesurez votre Mac." : model.page == 1 ? "Chaque session compte." : "Un protocole ouvert.")
                    .font(.system(size: 31, weight: .semibold, design: .rounded)).tracking(-0.7)
                Text(model.page == 0 ? "Calcul, mémoire et disque. Des passages répétés, des mesures explicables." : model.page == 1 ? "Retrouvez vos résultats et exportez-les pour les comparer." : "Le code, les calculs et les conditions de chaque résultat.")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            if model.current != nil {
                Button { model.exportReport() } label: { Label("Exporter JSON", systemImage: "square.and.arrow.up") }
                    .controlSize(.regular).padding(.top, 19)
            } else {
                Text("100 % LOCAL").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(muted).padding(.horizontal, 11).padding(.vertical, 7)
                    .overlay(Capsule().stroke(.white.opacity(0.12))).padding(.top, 18)
            }
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Session de mesure").font(.system(size: 15, weight: .semibold))
                        Text("\(model.durations[model.preset].formatted()) s par passage · \(model.enabled.count) tests sélectionnés")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    Picker("Durée", selection: $model.preset) {
                        Text("Rapide").tag(0); Text("Standard").tag(1); Text("Endurance").tag(2)
                    }.pickerStyle(.segmented).frame(width: 290).disabled(model.running)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                    ForEach(BenchmarkKind.allCases) { kind in
                        Button {
                            if model.enabled.contains(kind) { model.enabled.remove(kind) } else { model.enabled.insert(kind) }
                        } label: {
                            Label(kind.title, systemImage: model.enabled.contains(kind) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 8)
                                .foregroundStyle(model.enabled.contains(kind) ? accent : muted)
                                .background(model.enabled.contains(kind) ? accent.opacity(0.08) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(model.running).accessibilityLabel("Test \(kind.title)")
                    }
                }
                HStack(spacing: 10) {
                    Text("Passages / test").font(.system(size: 11)).foregroundStyle(muted)
                    Picker("Passages par test", selection: $model.repetitions) {
                        Text("1").tag(1); Text("3").tag(3); Text("5").tag(5)
                    }.pickerStyle(.segmented).frame(width: 135).disabled(model.running)
                    Spacer()
                    Text("\(model.threads) threads CPU").font(.system(size: 11)).foregroundStyle(muted)
                    Stepper("Threads CPU", value: $model.threads, in: 1...max(1, model.hardware.logicalCores)).labelsHidden().disabled(model.running)
                }
                if model.enabled.contains(where: { $0.isDisk }) {
                    Text("Disque : fichier temporaire de 64 Mio. Écriture : 512 Mio mesurés + 64 Mio de préparation au maximum par passage.")
                        .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            if model.running { ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 15) }
                            Text(model.status).font(.system(size: 11)).foregroundStyle(model.running ? Color.white : muted).lineLimit(2)
                        }
                        if model.running {
                            ProgressView(value: model.fraction).progressViewStyle(.linear).tint(accent)
                            Text("\(Int(model.fraction * 100)) % · \(model.activeKind?.title ?? "Initialisation")")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                        } else {
                            Text("Pour comparer deux sessions, gardez les mêmes réglages et fermez les tâches lourdes.")
                                .font(.system(size: 10)).foregroundStyle(muted.opacity(0.8)).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if model.running {
                        Button("Arrêter") { model.stop() }.controlSize(.large).disabled(model.stopping)
                    } else {
                        Button { model.start() } label: { Label("Mesurer le Mac", systemImage: "play.fill").fontWeight(.semibold).padding(.horizontal, 6) }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(accent).foregroundStyle(ink)
                            .disabled(model.enabled.isEmpty).keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 16))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13), count: 3), spacing: 13) {
                ForEach(BenchmarkKind.allCases) { kind in metricCard(kind) }
            }
            conditions
            if model.showDetails { nerdDetails }
        }
    }

    private func metricCard(_ kind: BenchmarkKind) -> some View {
        let result = model.results[kind]
        let value = result?.value ?? (model.running ? model.liveValues[kind] : nil)
        let active = model.running && model.activeKind == kind
        let samples = result?.samples ?? model.liveSamples[kind] ?? []
        let summary = model.summaries[kind]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(active ? accent : .white.opacity(0.7))
                Spacer()
                Text(active ? "EN COURS" : result != nil ? "MESURÉ" : model.current != nil ? "NON MESURÉ" : !model.enabled.contains(kind) ? "OPTIONNEL" : "EN ATTENTE")
                    .font(.system(size: 7, weight: .bold)).tracking(1).foregroundStyle(active || result != nil ? accent : muted)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(kind.title).font(.system(size: 14, weight: .semibold))
                Text(metricDescription(kind))
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number(value)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                Text(result?.unit ?? kind.unit).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            }
            if let summary {
                Text(summary.runCount > 1 ? "Médiane · \(summary.runCount) passages" : "1 passage · dispersion non estimée")
                    .font(.system(size: 9)).foregroundStyle(accent)
                if let cv = summary.coefficientOfVariationPercent {
                    Text("\(number(summary.minimum)) – \(number(summary.maximum)) \(kind.unit) · CV \(number(cv)) %")
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(muted).lineLimit(2)
                }
            }
            if model.showCharts {
                ZStack {
                    if samples.count > 1 { Sparkline(values: samples).stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)) }
                    else {
                        VStack(spacing: 8) {
                            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                            Text("Après la première mesure").font(.system(size: 9)).foregroundStyle(muted.opacity(0.65))
                        }
                    }
                }.frame(height: 32).padding(.top, 2)
                if result != nil {
                    Text((summary?.runCount ?? 1) > 1 ? "Échantillons du passage médian" : "Échantillons du passage")
                        .font(.system(size: 8)).foregroundStyle(muted)
                }
            }
            if model.showDetails, let result {
                Text(result.details).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).lineLimit(3)
            }
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(active ? accent.opacity(0.5) : .white.opacity(0.07), lineWidth: 1))
    }

    private func metricDescription(_ kind: BenchmarkKind) -> String {
        switch kind {
        case .cpu: return "Calcul FP32 multicœur"
        case .gpu: return "Calcul FP32 sur Metal"
        case .memory: return "Bande passante · triade"
        case .latency: return "Accès dépendants · plus bas = mieux"
        case .diskRead: return "Lecture séquentielle de fichier"
        case .diskWrite: return "Écriture de fichier avec fsync"
        }
    }

    private var conditions: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("CONDITIONS DE MESURE").font(.system(size: 8, weight: .bold)).tracking(1.4).foregroundStyle(muted)
                Spacer()
                Button { model.showDetails.toggle() } label: {
                    Label(model.showDetails ? "Masquer les détails" : "Données pour les nerds", systemImage: "slider.horizontal.3")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 24) {
                condition("Alimentation", value: model.liveCondition?.powerSource ?? model.current?.hardware.powerSource ?? model.hardware.powerSource, symbol: "bolt.fill")
                condition("Thermique", value: model.current.map { "\($0.thermalBefore) → \($0.thermalAfter)" } ?? model.liveCondition?.thermalState ?? SystemInfo.thermalState, symbol: "thermometer.medium")
                condition("Économie d’énergie", value: model.liveCondition.map { $0.lowPowerMode ? "Activée" : "Désactivée" } ?? "—", symbol: "leaf")
                condition("Observations", value: model.current?.conditions.map { String($0.count) } ?? (model.running ? "≈ 1 Hz" : "—"), symbol: "waveform.path")
            }
            if let report = model.current, !report.notes.isEmpty {
                Text(report.notes.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 3)
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
            Text("Données pour les nerds").font(.system(size: 13, weight: .semibold))
            detailRow("Protocole", value: model.current?.workloadVersion ?? BenchmarkRunner.workloadVersion)
            detailRow("Architecture", value: model.current?.hardware.architecture ?? model.hardware.architecture)
            detailRow("GPU", value: model.current?.hardware.gpu ?? model.hardware.gpu)
            detailRow("Système", value: model.current?.hardware.operatingSystem ?? model.hardware.operatingSystem)
            if let report = model.current {
                detailRow("Durée totale", value: "\(report.totalSeconds.formatted(.number.precision(.fractionLength(2)))) s")
                detailRow("Validation", value: report.results.allSatisfy(\.validated) ? "Références et contrôles réussis" : "Incomplète")
                detailRow("Passages", value: "\(report.configuration.repetitions) par test · \(report.trials?.count ?? report.results.count) conservés")
                Button("Copier le rapport JSON") { model.copyReport() }.font(.system(size: 11))
                if let log = report.conditions, !log.isEmpty {
                    DisclosureGroup("Journal des conditions (\(log.count))") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(log.suffix(12).enumerated()), id: \.offset) { _, sample in
                                Text("\(number(sample.elapsedSeconds)) s · \(sample.powerSource) · \(sample.thermalState) · économie \(sample.lowPowerMode ? "oui" : "non")")
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                            }
                            if log.count > 12 { Text("Les 12 dernières observations sont affichées ; le JSON contient le journal complet.").font(.system(size: 9)).foregroundStyle(muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.system(size: 11))
                }
            }
            Text("Thermique = état fourni par macOS, sans température en °C.").font(.system(size: 10)).foregroundStyle(muted)
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
                    Text("Votre première session vous attend.").font(.system(size: 17, weight: .medium))
                    Text("Les rapports terminés apparaissent ici, sur ce Mac.").font(.system(size: 12)).foregroundStyle(muted)
                    Button("Lancer une mesure") { model.page = 0 }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding(.vertical, 90)
            } else {
                ForEach(model.reports) { report in
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(report.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .semibold))
                                Text("\(report.hardware.chip) · \(report.configuration.secondsPerTest.formatted()) s × \(report.configuration.repetitions) passage(s) · v\(report.applicationVersion)")
                                    .font(.system(size: 10)).foregroundStyle(muted)
                            }
                            Spacer()
                            Button("Afficher") { model.select(report) }.font(.system(size: 11)).disabled(model.running)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 12) {
                            ForEach(report.results) { result in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.kind.title).font(.system(size: 9)).foregroundStyle(muted)
                                    Text("\(number(result.value)) \(result.unit)").font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
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
            protocolBlock("01", title: "Calcul CPU", body: "Des opérations flottantes FP32 sont répétées sur les threads sélectionnés. L’échauffement et la calibration précèdent la fenêtre mesurée. Le débit correspond au nombre d’opérations réellement exécutées, divisé par le temps écoulé.")
            protocolBlock("02", title: "Calcul GPU sur Metal", body: "Un noyau de calcul effectue des FMA sur le GPU. Le résultat utilise les timestamps des commandes GPU. Des valeurs de sortie sont comparées à une référence CPU avant et après la mesure. Ce test mesure du calcul, pas les FPS d’un jeu.")
            protocolBlock("03", title: "Bande passante mémoire", body: "Le test calcule A = B + 3 × C sur trois blocs de 64 Mio. Le débit est exprimé en Go/s décimaux, avec deux lectures et une écriture comptées par élément. Il mesure un débit logique, pas directement le trafic physique de la DRAM.")
            protocolBlock("04", title: "Latence effective", body: "Une chaîne aléatoire de lectures dépendantes parcourt un ensemble de travail de 64 Mio. Le résultat s’exprime en nanosecondes par accès : plus bas est meilleur. Il dépend de toute la hiérarchie mémoire et ne certifie pas la latence physique de la DRAM.")
            protocolBlock("05", title: "Lecture et écriture disque", body: "Chaque passage crée son propre fichier temporaire de 64 Mio. Les E/S demandent F_NOCACHE ; l’écriture inclut fsync et reste limitée à 512 Mio mesurés, plus 64 Mio de préparation. Le débit décrit les E/S fichier sur le volume temporaire, avec les caches matériels éventuels. Les fichiers du test sont supprimés à la fin.")
            protocolBlock("06", title: "Répétitions et conditions", body: "Choisissez 1, 3 ou 5 passages par test. Le résultat affiché est le passage médian ; l’intervalle min–max et le coefficient de variation décrivent les différences entre passages. Le rapport conserve les mesures brutes et les conditions observées environ chaque seconde. Ce suivi ne certifie pas l’absence de bridage. Comparez des profils et réglages identiques.")
            HStack {
                Label("Code source sous licence MIT", systemImage: "chevron.left.forwardslash.chevron.right")
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
        let clean = values.filter { $0.isFinite }
        guard clean.count > 1, let lo = clean.min(), let hi = clean.max() else { return Path() }
        let spread = max(hi - lo, max(abs(hi) * 0.12, 0.001))
        let lower = (lo + hi - spread) * 0.5
        return Path { path in
            for (index, value) in clean.enumerated() {
                let x = rect.minX + Double(index) / Double(clean.count - 1) * rect.width
                let y = rect.maxY - (0.12 + 0.76 * (value - lower) / spread) * rect.height
                let point = CGPoint(x: x, y: y)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
