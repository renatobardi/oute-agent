/// A tabela local `~/.oute/tray-hosts`: uma linha `<host>=local` ou `<host>=<alias ssh>` por máquina. É dela, e
/// nunca do texto da API, que sai o destino do `ssh` de um pedido de outro host.
public struct TrayHosts: Equatable {
    public enum Target: Equatable {
        case local
        case ssh(alias: String)
    }

    private let targets: [String: Target]

    /// Linha fora do formato é ignorada (o host fica sem destino e o item do menu, desabilitado). `#` abre comentário.
    public init(text: String) {
        var targets: [String: Target] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.prefix { $0 != "#" }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let host = Self.trim(parts[0]), value = Self.trim(parts[1])
            guard Self.isName(host) else { continue }
            if value == "local" {
                targets[host] = .local
            } else if Self.isAlias(value) {
                targets[host] = .ssh(alias: value)
            }
        }
        self.targets = targets
    }

    private static func trim(_ text: Substring) -> String {
        var view = text
        while let first = view.first, first == " " || first == "\t" { view = view.dropFirst() }
        while let last = view.last, last == " " || last == "\t" { view = view.dropLast() }
        return String(view)
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
    }

    private static func isName(_ text: String) -> Bool {
        guard let first = text.utf8.first, isAlnum(first) else { return false }
        return text.utf8.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    /// O alias vai para a linha de comando do `ssh`: começa por letra ou dígito (nunca vira opção) e só leva
    /// letra, dígito, `.`, `_`, `-` e `@`.
    private static func isAlias(_ text: String) -> Bool {
        guard let first = text.utf8.first, isAlnum(first) else { return false }
        return text.utf8.allSatisfy {
            isAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "@")
        }
    }

    public func target(for host: String) -> Target? {
        targets[host]
    }
}
