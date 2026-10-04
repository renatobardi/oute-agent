/// O id de um pedido vem do container do agente e vira argumento de um comando no Terminal: só passa o formato
/// que o `oute-propose` imprime, `^[0-9]{8}-[0-9]{6}-[a-z0-9-]+$`, conferido byte a byte (sem regex: o `$` de
/// uma regex aceitaria uma quebra de linha no fim).
public enum ProposalID {
    public static func isValid(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count >= 17 else { return false }
        let dash = UInt8(ascii: "-")
        guard bytes[0..<8].allSatisfy(isDigit), bytes[8] == dash,
              bytes[9..<15].allSatisfy(isDigit), bytes[15] == dash else { return false }
        return bytes[16...].allSatisfy { isDigit($0) || isLower($0) || $0 == dash }
    }

    private static func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
    private static func isLower(_ b: UInt8) -> Bool { b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z") }
}
