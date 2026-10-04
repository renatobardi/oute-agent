import Foundation

/// "há X": a idade de um pedido, do último dado de uma máquina ou da última leitura do tray.
public enum Age {
    /// Uma unidade só, arredondada para baixo: "há 59 s", "há 5 min", "há 23 h", "há 3 d".
    public static func text(seconds: Int) -> String {
        let s = max(0, seconds)
        switch s {
        case ..<60: return "há \(s) s"
        case ..<3600: return "há \(s / 60) min"
        case ..<86400: return "há \(s / 3600) h"
        default: return "há \(s / 86400) d"
        }
    }

    /// O aviso do menu quando a leitura do `/v1/tray` falha: o último menu fica, com a idade dele.
    public static func sinceLastRead(_ last: Date?, now: Date) -> String {
        guard let last else { return "sem leitura" }
        return "sem leitura \(text(seconds: Int(now.timeIntervalSince(last))))"
    }
}
