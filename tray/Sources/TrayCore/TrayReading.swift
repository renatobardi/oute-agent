import Foundation

/// O que o tray sabe depois de cada tentativa de ler o `/v1/tray`. Leitura que falha (rede, 401, 500, corpo que
/// não é o contrato) não apaga nada: o último menu fica, com o aviso de há quanto tempo ele não é lido.
public struct TrayReading {
    public private(set) var snapshot: TraySnapshot?
    public private(set) var lastRead: Date?
    public private(set) var failing = false

    public init() {}

    public mutating func received(status: Int, body: Data, at date: Date) {
        guard status == 200, let decoded = try? TraySnapshot.decode(body) else {
            failing = true
            return
        }
        snapshot = decoded
        lastRead = date
        failing = false
    }

    public mutating func failed() {
        failing = true
    }

    public var barTitle: String {
        snapshot?.barTitle ?? "? · ?"
    }

    /// `nil` enquanto a última tentativa deu certo.
    public func notice(now: Date) -> String? {
        failing ? Age.sinceLastRead(lastRead, now: now) : nil
    }
}
