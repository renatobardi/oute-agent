import SwiftUI
import TrayCore

/// Tray do oute-agent (#260, ADR-08 §10): mostra o que o `GET /v1/tray` do agent-studio devolve. Não age: aprovar
/// e recusar abrem o Terminal no `oute approve <id>`. A lógica sem tela mora no `TrayCore`.
struct OuteTrayApp: App {
    @StateObject private var model = TrayModel()

    var body: some Scene {
        MenuBarExtra {
            TrayMenu(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: SakuraIcon.bar)
                Text(model.reading.barTitle)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// A entrada do binário. `OuteTray --write-icon <arquivo>` grava o ícone do app e sai, sem abrir o tray: é como
/// o `oute tray install` monta o `.icns` (#563). Sem argumento, abre o tray.
@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--write-icon" {
            exit(SakuraIcon.writeAppIcon(to: URL(fileURLWithPath: arguments[2])) ? 0 : 1)
        }
        OuteTrayApp.main()
    }
}
