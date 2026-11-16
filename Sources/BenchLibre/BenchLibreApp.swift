import SwiftUI
import BenchCore

@main
struct BenchLibreApp: App {
    @StateObject private var model: AppModel
    init() {
        AppSecurity.requireSandbox()
        let language = AppLanguage.resolved(UserDefaults.standard.string(forKey: "preferredLanguage"))
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        CLI.runIfRequested()
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup("BenchLibre") {
            MainView().environmentObject(model)
                .environment(\.locale, model.language.locale)
                .onDisappear { model.stop() }
                .preferredColorScheme(.dark)
                .frame(minWidth: 1020, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 790)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.text("Run benchmark")) { model.start() }.keyboardShortcut("r")
                    .disabled(model.running || model.exporting || model.loadingHistory || model.preparingComparison || model.enabled.isEmpty)
                Button(model.text("Export report…")) { model.exportReport() }.keyboardShortcut("e").disabled(model.current == nil)
            }
            CommandMenu(model.text("Nerd details")) {
                Toggle(model.text("Show details"), isOn: $model.showDetails).keyboardShortcut("n", modifiers: [.command, .shift])
                Toggle(model.text("Sample charts"), isOn: $model.showCharts)
                Divider()
                Button(model.text("Read the protocol")) { model.page = 2 }
            }
            CommandMenu(model.text("Language")) {
                Button("English") { model.language = .english }
                Button("Français") { model.language = .french }
            }
        }
        Settings {
            Form {
                Picker(model.text("Language"), selection: $model.language) {
                    Text("English").tag(AppLanguage.english)
                    Text("Français").tag(AppLanguage.french)
                }.accessibilityLabel("Language / Langue")
                Text(model.text("English is the default. Your language choice is saved for this app."))
                Text(model.text("The interface changes immediately. System-provided menus and dialogs may follow the new language after reopening the app."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(width: 440)
            .environment(\.locale, model.language.locale)
        }
    }
}
