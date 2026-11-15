import SwiftUI
import BenchCore

@main
struct BenchLibreApp: App {
    @StateObject private var model: AppModel
    init() {
        CLI.runIfRequested()
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup("BenchLibre") {
            MainView().environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1020, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 790)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Lancer le benchmark") { model.start() }.keyboardShortcut("r").disabled(model.running || model.enabled.isEmpty)
                Button("Exporter le rapport…") { model.exportReport() }.keyboardShortcut("e").disabled(model.current == nil)
            }
            CommandMenu("Données pour les nerds") {
                Toggle("Afficher les détails", isOn: $model.showDetails).keyboardShortcut("n", modifiers: [.command, .shift])
                Toggle("Courbes des échantillons", isOn: $model.showCharts)
                Divider()
                Button("Lire le protocole") { model.page = 2 }
            }
        }
    }
}
