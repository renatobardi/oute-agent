import SwiftUI
import TrayCore

/// Tray do oute-agent (#260, ADR-08 §10): mostra o que o `GET /v1/tray` do agent-studio devolve. Não age: aprovar
/// e recusar abrem o Terminal no `oute approve <id>`. A lógica sem tela mora no `TrayCore`.
@main
struct OuteTrayApp: App {
    @StateObject private var model = TrayModel()

    var body: some Scene {
        MenuBarExtra {
            TrayMenu(model: model)
        } label: {
            HStack(spacing: 4) {
                MenuIcon.image(.bar)
                Text(model.reading.barTitle)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
