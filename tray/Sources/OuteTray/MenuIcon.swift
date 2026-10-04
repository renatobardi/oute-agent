import AppKit
import SwiftUI
import TrayCore

/// Desenha o `MenuSymbol` (#473, Kubo). Sem cor = template, pintado pelo sistema. O Gate sai no âmbar `--gate` do
/// `studio.css` do agent-studio, que troca com a aparência (claro e escuro).
enum MenuIcon {
    /// `--gate`: `oklch(0.5 0.12 70)` no claro e `oklch(0.83 0.14 80)` no escuro, em sRGB.
    static let gate = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.969, green: 0.737, blue: 0.314, alpha: 1)
            : NSColor(srgbRed: 0.557, green: 0.329, blue: 0, alpha: 1)
    }

    static func image(_ symbol: MenuSymbol) -> Image {
        guard symbol.tint == .gate,
              let tinted = NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil)?
                  .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [gate])) else {
            return Image(systemName: symbol.systemName).renderingMode(.template)
        }
        // fora do template: o menu não repinta o símbolo com a cor do texto
        tinted.isTemplate = false
        return Image(nsImage: tinted).renderingMode(.original)
    }
}

/// Uma linha do menu com símbolo. O texto entra como texto puro, sem interpretação (vem da API).
struct MenuLabel: View {
    let text: String
    let symbol: MenuSymbol

    init(_ text: String, _ symbol: MenuSymbol) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label { Text(verbatim: text) } icon: { MenuIcon.image(symbol) }
    }
}
